import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PiMacApp

@MainActor
struct AttachmentImageLoaderTests {
  private func encodedImage(type: UTType, width: Int = 1200, height: Int = 800) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(
        output, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }

  @Test func thumbnailIsBoundedDecodedSRGBAndPastePreservesOrientedResolution() async throws {
    let data = try encodedImage(type: .tiff)
    let thumbnail = try await Task.detached {
      try AttachmentImageLoader.decodedImage(data: data, maxPixelSize: 160)
    }.value
    #expect(max(thumbnail.width, thumbnail.height) == 160)
    #expect(thumbnail.bitsPerComponent == 8)
    #expect(thumbnail.colorSpace?.name == CGColorSpace.sRGB)
    let png = try await Task.detached { try AttachmentImageLoader.png(data: data) }.value
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 800)
    #expect(image.height == 1200)
    #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
  }

  @Test(arguments: [UTType.png, .jpeg, .heic])
  func clipboardFormatsBecomeDecodedPNG(type: UTType) async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let data = try encodedImage(type: type, width: 240, height: 160)
    pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
    let png = try await AttachmentImageLoader.shared.pastedPNG(
      name: pasteboard.name.rawValue, changeCount: pasteboard.changeCount)
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(max(decoded.width, decoded.height) == 240)
    #expect(decoded.bitsPerComponent == 8)
  }

  @Test func thumbnailCacheReusesBitmapAndInvalidatesReplacedFile() async throws {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/iphone-paste-fix/tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("photo.tiff")
    try encodedImage(type: .tiff).write(to: file)
    let loader = AttachmentImageLoader()
    let first = try await loader.thumbnail(url: file, maxPixelSize: 160)
    let second = try await loader.thumbnail(url: file, maxPixelSize: 160)
    #expect(first === second)
    try encodedImage(type: .tiff, width: 400, height: 800).write(to: file)
    let replaced = try await loader.thumbnail(url: file, maxPixelSize: 160)
    #expect(first !== replaced)
    #expect(replaced.width == 160)
    #expect(replaced.height == 80)
  }

  @Test func corruptImageAndChangedClipboardAreExplicitFailures() async throws {
    #expect(throws: AttachmentImageLoader.ImageError.self) {
      try AttachmentImageLoader.png(data: Data("broken image".utf8))
    }
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setData(try encodedImage(type: .png), forType: .png)
    let oldCount = pasteboard.changeCount
    pasteboard.clearContents()
    do {
      _ = try await AttachmentImageLoader.shared.pastedPNG(
        name: pasteboard.name.rawValue, changeCount: oldCount)
      Issue.record("不能读取新剪贴板冒充原来的图片")
    } catch AttachmentImageLoader.ImageError.clipboardChanged {}
  }

  @Test func asynchronousPasteAllowsTypingAndInsertsOnlyAfterConversion() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setData(try encodedImage(type: .tiff), forType: .tiff)
    let editor = ComposerTextView.SubmitTextView()
    var received: [Data] = []
    var pending: [Bool] = []
    var errors: [String] = []
    editor.onPasteImage = { data, mimeType in
      #expect(mimeType == "image/png")
      received.append(data)
      return ["[[图片]]"]
    }
    editor.onPastePendingChange = { pending.append($0) }
    editor.onPasteError = { errors.append($0) }
    editor.pasteImage(from: pasteboard)
    #expect(received.isEmpty)
    #expect(pending == [true])
    // 不等待图片完成也能编辑文本，完成时不会用粘贴前的旧文本覆盖新输入。
    editor.insertText("继续输入", replacementRange: NSRange(location: 0, length: 0))
    let tasks = Array(editor.imagePasteTasks.values)
    for task in tasks { await task.value }
    #expect(received.count == 1)
    #expect(editor.string == "继续输入 [[图片]]")
    #expect(errors.isEmpty)
    #expect(pending.last == false)
  }

  @Test func switchingConversationDiscardsPendingPasteWithoutCallingNewHandler() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setData(try encodedImage(type: .png), forType: .png)
    let editor = ComposerTextView.SubmitTextView()
    editor.pasteContextID = "first"
    var calls = 0
    editor.onPasteImage = { _, _ in
      calls += 1
      return ["wrong conversation"]
    }
    editor.pasteImage(from: pasteboard)
    let tasks = Array(editor.imagePasteTasks.values)
    editor.pasteContextID = "second"
    editor.string = "另一个会话"
    for task in tasks { await task.value }
    #expect(calls == 0)
    #expect(editor.string == "另一个会话")
    #expect(editor.imagePasteTasks.isEmpty)
  }

  @Test func failedPasteReportsErrorAndReleasesPendingState() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setData(Data("corrupt".utf8), forType: .tiff)
    let editor = ComposerTextView.SubmitTextView()
    var errors: [String] = []
    var pending = false
    editor.onPasteError = { errors.append($0) }
    editor.onPastePendingChange = { pending = $0 }
    editor.onPasteImage = { _, _ in
      Issue.record("损坏图片不能进入附件")
      return []
    }
    editor.pasteImage(from: pasteboard)
    let tasks = Array(editor.imagePasteTasks.values)
    for task in tasks { await task.value }
    #expect(errors.count == 1)
    #expect(!pending)
    #expect(editor.imagePasteTasks.isEmpty)
  }
}
