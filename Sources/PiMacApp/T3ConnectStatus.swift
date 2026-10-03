import Foundation

struct T3ConnectStatus: Decodable, Equatable {
  let available: Bool
  let enabled: Bool
  let linked: Bool
  let authorized: Bool?
  let networkDiagnostic: String?
  let loginPending: Bool
  let busy: Bool
  let account: String
  let tunnelStatus: String?
  let tunnelURL: String?
  let backend: String?
  let deviceCount: Int?
  let message: String
  let requests: Int
  let accepted: Int
  let queuedDeliveries: Int
  let successfulDeliveries: Int
  let failedDeliveries: Int

  /// Connector/edge state is separate from account binding and publication.
  /// Even an edge registration does not prove phone rendering or public reachability.
  var tunnelDescription: String {
    switch tunnelStatus {
    case "connecting": return "隧道正在连接 Cloudflare…"
    case "connected": return "隧道已连接 Cloudflare · 手机可尝试连接"
    case "reconnecting": return "隧道连接中断 · 正在自动恢复…"
    case "running": return "隧道进程已启动 · 尚未确认连接"
    case "disabled": return linked ? "隧道尚未启动 · 等待恢复" : "隧道未开启"
    case "unsupported": return "当前平台不支持隧道"
    case let value? where value.hasPrefix("failed:"): return "隧道启动失败 · 请查看诊断并重试恢复"
    default: return "正在确认隧道连接状态…"
    }
  }
}
