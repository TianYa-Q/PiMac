import AppKit
import CoreFoundation

/// 只在边界读取 Server 标签；合法空列表与协议损坏必须分开处理。
struct T3BrowserTab: Identifiable, Equatable {
  let id: String
  let title: String
  let url: String
  let failure: String?
  let revealID: String?

  static func read(_ result: [String: Any]) throws -> [Self] {
    guard let sessions = result["sessions"] as? [[String: Any]] else {
      throw T3DesktopClient.ClientError.rejected
    }
    var ids = Set<String>()
    return try sessions.compactMap { item in
      // 旧版缺省 runtime 表示桌面宿主；未知值则是协议错误，不能当作空列表。
      let runtime = item["runtime"] ?? "desktop"
      guard let runtime = runtime as? String, ["server", "desktop"].contains(runtime) else {
        throw T3DesktopClient.ClientError.rejected
      }
      guard runtime == "server" else { return nil }
      guard let id = item["tabId"] as? String, !id.isEmpty, id.count <= 128,
        ids.insert(id).inserted, let nav = item["navStatus"] as? [String: Any],
        let state = nav["_tag"] as? String,
        ["Idle", "Loading", "Success", "LoadFailed"].contains(state)
      else { throw T3DesktopClient.ClientError.rejected }
      let url: String
      let title: String
      if state == "Idle" {
        url = ""
        title = "空白标签"
      } else {
        guard let address = nav["url"] as? String, let name = nav["title"] as? String else {
          throw T3DesktopClient.ClientError.rejected
        }
        url = address
        title = name.isEmpty ? address : name
      }
      let failure: String?
      if state == "LoadFailed" {
        guard let description = nav["description"] as? String else {
          throw T3DesktopClient.ClientError.rejected
        }
        failure = description
      } else {
        failure = nil
      }
      let revealID: String?
      if let request = item["revealRequest"] {
        guard let request = request as? [String: Any], let requestID = request["id"] as? String,
          !requestID.isEmpty
        else { throw T3DesktopClient.ClientError.rejected }
        revealID = requestID
      } else {
        revealID = item["reveal"] as? Bool == true ? id : nil
      }
      return Self(id: id, title: title, url: url, failure: failure, revealID: revealID)
    }
  }
}

struct T3BrowserControl: Equatable {
  enum Owner: String {
    case agent, you
    case anotherViewer = "another-viewer"
    case unclaimed
  }
  struct Dialog: Equatable {
    let type: String
    let message: String
    let defaultValue: String
  }
  let canOperate: Bool
  let owner: Owner
  let generation: Int
  let dialog: Dialog?
  static let unavailable = Self(canOperate: false, owner: .unclaimed, generation: 0, dialog: nil)
  var isControlling: Bool { canOperate && owner == .you }
}

/// 文本帧在网络边界解析。未知通知可忽略，已知通知损坏则明确报错。
enum T3BrowserEvent: Equatable {
  case frame(NSImage)
  case control(T3BrowserControl)
  case viewport(CGSize)
  case clipboard(String)
  case popup(String)
  case notice(String)
  case ignored

  static func read(_ text: String) throws -> Self {
    guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      let type = object["type"] as? String
    else { throw T3DesktopClient.ClientError.rejected }
    switch type {
    case "control":
      guard let allowed = object["canOperate"] as? NSNumber,
        CFGetTypeID(allowed) == CFBooleanGetTypeID(),
        let ownerName = object["controller"] as? String,
        let owner = T3BrowserControl.Owner(rawValue: ownerName),
        let generation = object["generation"] as? NSNumber,
        CFGetTypeID(generation) != CFBooleanGetTypeID(),
        generation.doubleValue.isFinite, generation.doubleValue >= 0,
        generation.doubleValue.rounded() == generation.doubleValue
      else { throw T3DesktopClient.ClientError.rejected }
      let dialog: T3BrowserControl.Dialog?
      if let raw = object["dialog"], !(raw is NSNull) {
        guard let raw = raw as? [String: Any], let kind = raw["type"] as? String,
          let message = raw["message"] as? String, let initial = raw["defaultValue"] as? String
        else { throw T3DesktopClient.ClientError.rejected }
        dialog = .init(type: kind, message: message, defaultValue: initial)
      } else {
        dialog = nil
      }
      return .control(
        .init(
          canOperate: allowed.boolValue, owner: owner,
          generation: generation.intValue, dialog: dialog))
    case "viewport":
      guard let width = dimension(object["width"]), let height = dimension(object["height"]) else {
        throw T3DesktopClient.ClientError.rejected
      }
      return .viewport(CGSize(width: width, height: height))
    case "clipboard":
      guard let text = object["text"] as? String else { throw T3DesktopClient.ClientError.rejected }
      return .clipboard(text)
    case "popup":
      guard let id = object["tabId"] as? String, !id.isEmpty else {
        throw T3DesktopClient.ClientError.rejected
      }
      return .popup(id)
    case "fileChooser": return .notice("页面请求上传文件；当前可让代理上传，原生文件选择暂未接入。")
    case "download": return .notice("页面已下载文件，可让代理提供下载结果。")
    default: return .ignored
    }
  }

  private static func dimension(_ raw: Any?) -> Double? {
    guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
      value.doubleValue.isFinite, (1...16_384).contains(value.doubleValue)
    else { return nil }
    return value.doubleValue
  }
}

/// UI 只构造可信的输入枚举，控制权判断仍以 Server 通知为唯一依据。
enum T3BrowserInput {
  case takeControl, releaseControl, reload
  case mouse(
    action: String, point: CGPoint, button: String, buttons: Int, count: Int, modifiers: Int)
  case wheel(point: CGPoint, delta: CGSize, modifiers: Int)
  case key(action: String, key: String, code: String, keyCode: Int, modifiers: Int, text: String?)
  case text(String)
  case resize(CGSize)
  case navigate(String)
  case history(Int)
  case dialog(accept: Bool, text: String)

  func isAllowed(by control: T3BrowserControl) -> Bool {
    guard control.canOperate else { return false }
    if case .takeControl = self { return control.owner == .agent || control.owner == .unclaimed }
    return control.isControlling
  }

  /// Server 每条 insertText 限制 10000 个 UTF-16 单元；按标量切块，既不截断粘贴也不拆开代理对。
  static func textChunks(_ text: String) -> [String] {
    var chunks: [String] = []
    var current = ""
    var units = 0
    for scalar in text.unicodeScalars {
      let count = scalar.value > 0xFFFF ? 2 : 1
      if units + count > 8000 {
        chunks.append(current)
        current = ""
        units = 0
      }
      current.unicodeScalars.append(scalar)
      units += count
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }

  var payload: [String: Any] {
    switch self {
    case .takeControl: return ["type": "takeControl"]
    case .releaseControl: return ["type": "releaseControl"]
    case .reload: return ["type": "reload"]
    case .mouse(let action, let point, let button, let buttons, let count, let modifiers):
      return [
        "type": "mouse", "action": action, "x": point.x, "y": point.y,
        "button": button, "buttons": buttons, "clickCount": count, "modifiers": modifiers,
      ]
    case .wheel(let point, let delta, let modifiers):
      return [
        "type": "wheel", "x": point.x, "y": point.y, "deltaX": delta.width,
        "deltaY": delta.height, "modifiers": modifiers,
      ]
    case .key(let action, let key, let code, let keyCode, let modifiers, let text):
      var result: [String: Any] = [
        "type": "key", "action": action, "key": key, "code": code,
        "keyCode": keyCode, "modifiers": modifiers,
      ]
      if let text { result["text"] = text }
      return result
    case .text(let text): return ["type": "text", "text": text]
    case .resize(let size):
      return ["type": "resize", "width": Int(size.width), "height": Int(size.height)]
    case .navigate(let url): return ["type": "navigate", "url": url]
    case .history(let delta): return ["type": "history", "delta": delta]
    case .dialog(let accept, let text):
      return ["type": "dialog", "accept": accept, "promptText": text]
    }
  }
}

/// 画面可能缩放、留黑边且经过 Retina/服务端压缩；输入必须映射到 CSS 视口，而非图片像素。
enum BrowserPreviewGeometry {
  static func imageRect(image: CGSize, bounds: CGRect) -> CGRect {
    guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else {
      return .zero
    }
    let scale = min(bounds.width / image.width, bounds.height / image.height)
    let size = CGSize(width: image.width * scale, height: image.height * scale)
    return CGRect(
      x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
      width: size.width, height: size.height)
  }

  static func point(_ point: CGPoint, imageRect: CGRect, viewport: CGSize, clamp: Bool) -> CGPoint?
  {
    guard imageRect.width > 0, imageRect.height > 0, viewport.width > 0, viewport.height > 0,
      clamp || imageRect.contains(point)
    else { return nil }
    return CGPoint(
      x: min(
        viewport.width - 1, max(0, (point.x - imageRect.minX) / imageRect.width * viewport.width)),
      y: min(
        viewport.height - 1, max(0, (point.y - imageRect.minY) / imageRect.height * viewport.height)
      ))
  }
}

@MainActor
enum T3BrowserStream {
  static func receive(
    socket: URLSessionWebSocketTask, onFrame: (NSImage) -> Void,
    onEvent: (T3BrowserEvent) -> Void
  ) async throws {
    try await withTaskCancellationHandler {
      while !Task.isCancelled {
        let message = try await socket.receive()
        try Task.checkCancellation()
        switch message {
        case .data(let data):
          guard let frame = NSImage(data: data), frame.isValid else {
            throw T3DesktopClient.ClientError.rejected
          }
          onFrame(frame)
          try await socket.send(.string(#"{"type":"ack"}"#))
        case .string(let text): onEvent(try T3BrowserEvent.read(text))
        @unknown default: throw T3DesktopClient.ClientError.rejected
        }
      }
    } onCancel: {
      socket.cancel(with: .goingAway, reason: nil)
    }
  }
}
