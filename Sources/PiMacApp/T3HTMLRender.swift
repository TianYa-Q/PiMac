import CoreFoundation
import Foundation

/// 在 Server 边界解析工具结果；内部只传递已校验的页面引用，不把任意 JSON 当网页执行。
struct T3HTMLRender: Equatable, Sendable {
  struct Measurement: Equatable, Sendable {
    let width: Double
    let height: Double
  }
  let attachmentID: String
  let title: String
  let height: Double
  let measurements: [Measurement]

  static func isRenderTool(_ name: String) -> Bool {
    name == "html_render" || name.hasSuffix("__html_render") || name.hasSuffix(".html_render")
  }

  static func read(toolName: String, output: Any?) -> Self? {
    guard isRenderTool(toolName) else { return nil }
    var nodes = 128
    var bytes = 16_384
    var failed = false
    var exceeded = false
    func envelope(_ value: Any?, depth: Int) -> [String: Any]? {
      guard depth <= 4, nodes > 0 else {
        exceeded = true
        return nil
      }
      nodes -= 1
      if let text = value as? String {
        let data = Data(text.utf8)
        guard data.count <= bytes else {
          exceeded = true
          return nil
        }
        bytes -= data.count
        return envelope(try? JSONSerialization.jsonObject(with: data), depth: depth + 1)
      }
      if let blocks = value as? [Any] {
        guard blocks.count <= 32 else {
          exceeded = true
          return nil
        }
        var result: [String: Any]?
        for block in blocks {
          let text = (block as? [String: Any])?["text"]
          let next = envelope((text as? [String: Any])?["text"] ?? text, depth: depth + 1)
          if result == nil { result = next }
        }
        return result
      }
      guard let object = value as? [String: Any] else { return nil }
      if object["isError"] as? Bool == true || object["is_error"] as? Bool == true
        || object["error"] != nil || object["_tag"] as? String == "OrchestratorMcpFailure"
      {
        failed = true
        return nil
      }
      if let content = object["structuredContent"] ?? object["content"] {
        return envelope(content, depth: depth + 1)
      }
      return object
    }
    let result = envelope(output, depth: 0)
    guard !failed, !exceeded, let object = result?["htmlRender"] as? [String: Any],
      let id = object["attachmentId"] as? String, !id.isEmpty, id.count <= 256,
      // 页面只能引用 Server 附件，不接受文件路径、URL 或其他类型的附件。
      id.hasSuffix("-html"), id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
      let title = object["title"] as? String,
      let height = object["height"] as? NSNumber, CFGetTypeID(height) != CFBooleanGetTypeID(),
      height.doubleValue.isFinite
    else { return nil }
    var measurements: [Measurement] = []
    let pairs = (object["heights"] as? [[NSNumber]])?.map { $0.map(\.doubleValue) }
    if let pairs, !pairs.isEmpty, pairs.count <= 24,
      pairs.allSatisfy({
        $0.count == 2 && $0[0].isFinite && $0[0] >= 1 && $0[0] <= 10_000
          && $0[0].rounded() == $0[0] && $0[1].isFinite
      })
    {
      measurements = pairs.map { Measurement(width: $0[0], height: clamp($0[1])) }
        .sorted { $0.width < $1.width }
    }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return Self(
      attachmentID: id, title: trimmed.isEmpty ? "HTML" : String(trimmed.prefix(200)),
      height: clamp(height.doubleValue), measurements: measurements)
  }

  private static func clamp(_ value: Double) -> Double { min(2000, max(80, value)) }

  /// 使用会话滚动区的实际高度（已扣除输入框），为上下文留出空间。
  /// 限制的是宿主视口，不裁剪文档；长页面继续在 sandbox iframe 内滚动。
  func previewHeight(width: Double, contentHeight: Double?, viewportHeight: Double) -> Double {
    let available = viewportHeight.isFinite && viewportHeight > 0 ? viewportHeight : 600
    return min(frameHeight(width: width, contentHeight: contentHeight), available * 0.85)
  }

  func frameHeight(width: Double, contentHeight: Double?) -> Double {
    func measured(_ width: Double) -> Double {
      let high = measurements.firstIndex { $0.width >= width } ?? measurements.count - 1
      let low = measurements[high].width == width ? high : max(0, high - 1)
      return max(measurements[low].height, measurements[high].height)
    }
    guard !measurements.isEmpty else { return Self.clamp(min(height, contentHeight ?? height)) }
    let cap = measured(728) > height ? height : 2000
    return Self.clamp(min(cap, contentHeight ?? measured(width)))
  }
}
