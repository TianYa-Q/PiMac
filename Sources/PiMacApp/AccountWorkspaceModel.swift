import AppKit
import Combine
import Foundation

/// 工作台的数据协议与旧的扩展菜单分离，边界解码失败不能伪装成空账户。
struct AccountWorkspaceSnapshot: Decodable {
  struct Account: Decodable, Identifiable {
    let name: String
    let isDefault: Bool
    let isVisible: Bool
    let primary: Window?
    let secondary: Window?
    let capturedAt: Double?
    let error: String?
    var id: String { name }
  }

  struct Window: Decodable {
    let remainingPercent: Double
    let resetAt: Double?
  }

  struct Record: Decodable, Identifiable {
    let timestamp: Double
    let accountName: String
    let windowKind: String
    let status: String
    var id: String { "\(timestamp):\(accountName):\(windowKind)" }
  }

  let provider: String
  let accounts: [Account]
  let records: [Record]
  let monitorRunning: Bool
}

struct AccountAuthorizationState: Decodable {
  struct Request: Decodable, Identifiable {
    let id: String
    let method: String
    let title: String
    let options: [String]?
    let message: String?
    let placeholder: String?
  }
  struct Event: Decodable {
    let serial: Int
    let method: String
    let message: String?
    let url: String?
  }
  let flowID: String
  let busy: Bool
  let outcome: String
  let requests: [Request]
  let events: [Event]
}

@MainActor
final class AccountWorkspaceModel: ObservableObject {
  enum Page: Equatable {
    case account(String)
    case add
    case activity
    case diagnostics
  }
  enum Action: Equatable {
    case snapshot
    case refresh
    case setDefault(String)
    case visibility(String, Bool)
    case delete(String)
    case health
  }

  @Published private(set) var provider: AccountUsageProvider
  @Published private(set) var snapshot: AccountWorkspaceSnapshot?
  @Published var page: Page = .add
  @Published private(set) var isWorking = false
  @Published private(set) var isAuthorizing = false
  @Published private(set) var message = ""
  @Published private(set) var isError = false
  @Published private(set) var authorization: AccountAuthorizationState?
  @Published private(set) var authorizationURL: URL?
  @Published private(set) var authorizationMessage = ""
  @Published private(set) var authorizationTitle = ""
  @Published private(set) var responding = false
  @Published private var answeredRequestIDs: Set<String> = []

  var authorizationRequest: AccountAuthorizationState.Request? {
    authorization?.requests.first { !answeredRequestIDs.contains($0.id) }
  }
  private let transport: ([String: Any]) async throws -> [String: Any]
  private let openURL: (URL) -> Void
  private var work: Task<Void, Never>?
  private var loginTask: Task<Void, Never>?
  private var closed = false

  init(
    provider: AccountUsageProvider,
    snapshot: AccountWorkspaceSnapshot?,
    transport: @escaping ([String: Any]) async throws -> [String: Any],
    openURL: @escaping (URL) -> Void
  ) {
    self.provider = provider
    self.snapshot = snapshot
    self.transport = transport
    self.openURL = openURL
    if let first = snapshot?.accounts.first { page = .account(first.name) }
  }

  var selectedAccount: AccountWorkspaceSnapshot.Account? {
    guard case .account(let name) = page else { return nil }
    return snapshot?.accounts.first { $0.name == name }
  }
  var isBusy: Bool { isWorking || isAuthorizing }

  func load() {
    guard snapshot == nil, !isWorking else { return }
    perform(.snapshot)
  }

  func selectProvider(_ provider: AccountUsageProvider) {
    guard !isBusy, self.provider != provider else { return }
    self.provider = provider
    snapshot = nil
    page = .add
    perform(.snapshot)
  }

  func perform(_ action: Action) {
    guard !isBusy, !closed else { return }
    isWorking = true
    message = action == .refresh || action == .health ? "正在查询最新额度…" : "正在读取或保存…"
    isError = false
    var input: [String: Any] = ["provider": provider.rawValue]
    switch action {
    case .snapshot: input["operation"] = "snapshot"
    case .refresh: input["operation"] = "refresh"
    case .health: input["operation"] = "health"
    case .setDefault(let name):
      input["operation"] = "set-default"
      input["name"] = name
    case .delete(let name):
      input["operation"] = "delete"
      input["name"] = name
    case .visibility(let name, let visible):
      input["operation"] = "visibility"
      input["name"] = name
      input["visible"] = visible
    }
    work = Task {
      defer {
        isWorking = false
        work = nil
      }
      do {
        let result: AccountWorkspaceSnapshot = try await request(input)
        try Task.checkCancellation()
        try apply(result)
        switch action {
        case .snapshot: message = ""
        case .refresh: message = "额度已更新。查询失败的账户会单独标记。"
        case .setDefault: message = "已设为新会话默认；现有会话不变。"
        case .visibility(_, let visible): message = visible ? "已恢复展示与后台监测。" : "已隐藏额度并暂停该账户的后台监测。"
        case .delete: message = "账户已删除。"
        case .health:
          let failures = result.accounts.filter { $0.error != nil }.count
          message = "查询完成：\(result.accounts.filter(\.isVisible).count) 个可见账户，\(failures) 个查询失败。"
          isError = failures > 0
        }
      } catch is CancellationError {
        // 关闭工作台不重发未知结果的操作，也不停止任何会话。
      } catch {
        message = "操作未确认：请检查本机 Server、授权或文件权限。可重新读取状态核验，不会自动重发。"
        isError = true
      }
    }
  }

  func startLogin(name: String, replacing: Bool) {
    guard !isBusy, !closed else { return }
    guard name.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil else {
      message = "名称需为 1–64 位字母、数字、点、下划线或连字符。"
      isError = true
      return
    }
    guard replacing || snapshot?.accounts.contains(where: { $0.name == name }) != true else {
      message = "名称已存在，请使用另一个名称；不会覆盖已有凭据。"
      isError = true
      return
    }
    page = .add
    isAuthorizing = true
    answeredRequestIDs.removeAll()
    message = ""
    isError = false
    authorizationTitle = replacing ? "重新授权 \(name)" : "添加账户 \(name)"
    authorizationMessage = "正在发起官方 OAuth 授权…"
    loginTask = Task {
      var flowID: String?
      var serial = 0
      defer {
        isAuthorizing = false
        authorization = nil
        authorizationURL = nil
        loginTask = nil
        if let flowID {
          let transport = transport
          Task { _ = try? await transport(["operation": "cancel", "flowID": flowID]) }
        }
      }
      do {
        var state: AccountAuthorizationState = try await request([
          "operation": replacing ? "reauthorize" : "login", "provider": provider.rawValue,
          "name": name,
        ])
        flowID = state.flowID
        while true {
          try Task.checkCancellation()
          guard ["working", "success", "cancelled", "failed"].contains(state.outcome),
            state.requests.allSatisfy({ request in
              ["input", "confirm", "select"].contains(request.method)
                && (request.method != "select" || request.options != nil)
            })
          else { throw T3DesktopClient.ClientError.rejected }
          authorization = state
          for event in state.events where event.serial > serial {
            serial = event.serial
            if event.method == "account_auth_url", let raw = event.url,
              let url = URL(string: raw), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil
            {
              authorizationURL = url
              openURL(url)
            } else if let text = event.message {
              authorizationMessage = text
            }
          }
          if !state.busy { break }
          try await Task.sleep(for: .milliseconds(400))
          state = try await request(["operation": "poll", "flowID": state.flowID])
        }
        if state.outcome == "success" {
          let result: AccountWorkspaceSnapshot = try await request([
            "operation": "snapshot", "provider": provider.rawValue,
          ])
          try Task.checkCancellation()
          try apply(result)
          page = .account(name)
          message = replacing ? "账户授权已更新，默认账户设置保持不变。" : "账户已添加并设为新会话默认，现有会话不变。"
        } else {
          message = state.outcome == "cancelled" ? "已取消授权。" : "授权失败，未添加账户。请检查网络、授权与文件权限。"
          isError = state.outcome != "cancelled"
        }
      } catch is CancellationError {
        message = "已停止授权等待；如刚完成浏览器回调，请重新读取账户核验。"
        isError = false
      } catch {
        message = "授权结果未确认，请重新读取账户列表核验。"
        isError = true
      }
    }
  }

  func respond(to request: AccountAuthorizationState.Request, value: String?, confirmed: Bool?) {
    guard let authorization, !responding, isAuthorizing,
      !answeredRequestIDs.contains(request.id)
    else { return }
    answeredRequestIDs.insert(request.id)
    responding = true
    Task {
      defer { responding = false }
      do {
        _ = try await transport([
          "operation": "respond", "flowID": authorization.flowID, "id": request.id,
          "value": value as Any? ?? NSNull(), "confirmed": confirmed as Any? ?? NSNull(),
          "cancelled": false,
        ])
      } catch {
        message = "授权输入未确认，不会自动重发；请取消后重新授权。"
        isError = true
      }
    }
  }

  func cancelLogin() { loginTask?.cancel() }

  func close() {
    closed = true
    work?.cancel()
    loginTask?.cancel()
  }

  private func request<T: Decodable>(_ input: [String: Any]) async throws -> T {
    let result = try await transport(input)
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: result))
  }

  private func apply(_ result: AccountWorkspaceSnapshot) throws {
    guard result.provider == provider.rawValue,
      Set(result.accounts.map(\.name)).count == result.accounts.count,
      result.accounts.filter(\.isDefault).count <= 1,
      result.accounts.allSatisfy({ account in
        !account.name.isEmpty
          && [account.primary, account.secondary].compactMap { $0 }.allSatisfy {
            $0.remainingPercent.isFinite && (0...100).contains($0.remainingPercent)
          }
      })
    else { throw T3DesktopClient.ClientError.rejected }
    let isInitialLoad = snapshot == nil
    snapshot = result
    if case .account(let name) = page, !result.accounts.contains(where: { $0.name == name }) {
      page = result.accounts.first.map { .account($0.name) } ?? .add
    } else if isInitialLoad, result.accounts.count > 0, page == .add, !isAuthorizing {
      page = .account(result.accounts[0].name)
    }
  }
}
