import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 串行处理图片，避免多张 iPhone 原图同时解码造成瞬时内存峰值。
actor AttachmentImageLoader {
  static let shared = AttachmentImageLoader()
  private let cache = NSCache<NSString, CGImage>()

  init() {
    cache.totalCostLimit = 32 * 1024 * 1024
  }

  enum ImageError: LocalizedError {
    case invalidImage
    case clipboardChanged

    var errorDescription: String? {
      switch self {
      case .invalidImage: "无法读取图片，图片可能已损坏或尺寸过大"
      case .clipboardChanged: "剪贴板内容已变化，请重新粘贴"
      }
    }
  }

  /// 只在用户明确粘贴后访问剪贴板；跨设备传输和格式转换均不占用主线程。
  func pastedPNG(name: String, changeCount: Int) throws -> Data {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
    guard pasteboard.changeCount == changeCount else { throw ImageError.clipboardChanged }
    let types = pasteboard.types ?? []
    let preferred: [NSPasteboard.PasteboardType] = [
      .png, NSPasteboard.PasteboardType("public.jpeg"),
      NSPasteboard.PasteboardType("public.heic"), .tiff,
    ]
    let candidates =
      preferred.filter(types.contains)
      + types.filter {
        !preferred.contains($0) && Self.isImageType($0)
      }
    for type in candidates {
      guard let data = pasteboard.data(forType: type) else { continue }
      guard pasteboard.changeCount == changeCount else { throw ImageError.clipboardChanged }
      return try Self.png(data: data)
    }
    throw ImageError.invalidImage
  }

  nonisolated static func isImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
    UTType(type.rawValue)?.conforms(to: .image) == true
  }

  /// 强制落到已解码的 8-bit sRGB 位图，不把 HEIC/HDR 的惰性转换留给 SwiftUI。
  nonisolated static func decodedImage(data: Data, maxPixelSize: Int) throws -> CGImage {
    guard maxPixelSize > 0,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 16384, height <= 16384,
      width * height <= 64_000_000,
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
          kCGImageSourceShouldCacheImmediately: true,
          kCGImageSourceShouldAllowFloat: false,
        ] as CFDictionary),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ImageError.invalidImage }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let decoded = context.makeImage() else { throw ImageError.invalidImage }
    return decoded
  }

  nonisolated static func png(data: Data) throws -> Data {
    // 粘贴保留原始分辨率和方向；只对显示用缩略图降采样。
    let image = try decodedImage(data: data, maxPixelSize: 16384)
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { throw ImageError.invalidImage }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ImageError.invalidImage }
    return output as Data
  }

  func thumbnail(url: URL, maxPixelSize: Int) throws -> CGImage {
    // URL 会缓存 resourceValues；每次查询前清掉元数据缓存，避免原路径替换后仍命中旧图。
    var currentURL = url
    currentURL.removeAllCachedResourceValues()
    let values = try currentURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let key =
      "\(url.path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)|\(maxPixelSize)"
      as NSString
    if let image = cache.object(forKey: key) { return image }
    let image = try Self.decodedImage(data: Data(contentsOf: url), maxPixelSize: maxPixelSize)
    cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
    return image
  }
}

struct AttachmentThumbnail: View {
  let url: URL
  let maxPixelSize: Int
  @State private var image: CGImage?
  @State private var failed = false

  var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: 1).resizable()
      } else {
        Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
          .resizable()
          .scaledToFit()
          .foregroundStyle(.secondary)
          .padding(12)
          .accessibilityLabel(failed ? "图片无法加载" : "正在加载图片")
      }
    }
    .task(id: "\(url.absoluteString)|\(maxPixelSize)") {
      image = nil
      failed = false
      do {
        let loaded = try await AttachmentImageLoader.shared.thumbnail(
          url: url, maxPixelSize: maxPixelSize)
        try Task.checkCancellation()
        image = loaded
      } catch is CancellationError {
        // 离开视图后不回写已过期的加载结果。
      } catch {
        guard !Task.isCancelled else { return }
        failed = true
      }
    }
  }
}
