import AppKit
import Combine
import Foundation

/// Application-wide coordinator for Pi extension UI.
///
/// Dialogs from every live RPC process are queued here, while session-specific status such as
/// the active Codex account is displayed only for the currently selected session.
@MainActor
final class ExtensionUIModel: ObservableObject {
  @Published var dialog: ExtensionDialog?
  @Published private(set) var statuses: [String: String] = [:]
  @Published private(set) var codexAccounts: [CodexAccountStatus] = []
  @Published private(set) var geminiUsage: GeminiUsageStatus?
  @Published private(set) var codexAccountsUpdatedAt: Date?

  private struct PendingDialog {
    let dialog: ExtensionDialog
    let source: AppModel
  }

  private struct AccountSnapshot {
    let accounts: [CodexAccountStatus]
    let gemini: GeminiUsageStatus?
    let updatedAt: Date?
  }

  private var presentedDialog: PendingDialog?
  private var queuedDialogs: [PendingDialog] = []
  private weak var selectedSource: AppModel?
  private var accountSnapshots: [ObjectIdentifier: AccountSnapshot] = [:]

  func selectSource(_ source: AppModel?) {
    selectedSource = source
    guard let source,
      let snapshot = accountSnapshots[ObjectIdentifier(source)]
    else {
      apply(AccountSnapshot(accounts: [], gemini: nil, updatedAt: nil))
      return
    }
    apply(snapshot)
  }

  func handle(_ event: PiRPCClient.JSON, from source: AppModel) {
    guard let method = event["method"] as? String,
      let requestID = event["id"] as? String
    else { return }

    let title = event["title"] as? String ?? "Pi 扩展"
    switch method {
    case "select":
      enqueue(
        ExtensionDialog(
          id: requestID,
          title: title,
          kind: .select(options: event["options"] as? [String] ?? [])
        ),
        from: source
      )
    case "confirm":
      enqueue(
        ExtensionDialog(
          id: requestID,
          title: title,
          kind: .confirm(message: event["message"] as? String ?? "")
        ),
        from: source
      )
    case "input", "editor":
      enqueue(
        ExtensionDialog(
          id: requestID,
          title: title,
          kind: .input(
            initialText: event["prefill"] as? String ?? "",
            placeholder: event["placeholder"] as? String ?? "",
            multiline: method == "editor"
          )
        ),
        from: source
      )
    case "notify":
      source.appendExtensionNotification(event["message"] as? String ?? "")
    case "setTitle":
      NSApp.mainWindow?.title = event["title"] as? String ?? "Pi Mac"
    case "set_editor_text":
      source.composerText = event["text"] as? String ?? ""
    case "setStatus":
      updateStatus(event, from: source)
    default:
      break
    }
  }

  func hasPendingRequests(from source: AppModel) -> Bool {
    (presentedDialog?.source === source) || queuedDialogs.contains { $0.source === source }
  }

  func answerDialog(value: String? = nil, confirmed: Bool? = nil, cancelled: Bool = false) {
    guard let pending = presentedDialog else { return }
    pending.source.sendExtensionResponse(
      id: pending.dialog.id,
      value: value,
      confirmed: confirmed,
      cancelled: cancelled
    )
    presentedDialog = nil
    dialog = nil
    presentNextDialog()
  }

  func removeRequests(from source: AppModel) {
    accountSnapshots.removeValue(forKey: ObjectIdentifier(source))
    if selectedSource === source { selectSource(nil) }

    let removed = queuedDialogs.filter { $0.source === source }
    queuedDialogs.removeAll { $0.source === source }
    for pending in removed {
      pending.source.sendExtensionResponse(id: pending.dialog.id, cancelled: true)
    }

    guard let presentedDialog, presentedDialog.source === source else { return }
    presentedDialog.source.sendExtensionResponse(id: presentedDialog.dialog.id, cancelled: true)
    self.presentedDialog = nil
    dialog = nil
    presentNextDialog()
  }

  private func enqueue(_ dialog: ExtensionDialog, from source: AppModel) {
    // Some extensions resend an unresolved request. Request IDs are scoped to their RPC
    // process, hence source identity is part of the duplicate check.
    let isDuplicate =
      [presentedDialog].compactMap { $0 }.contains {
        $0.source === source && $0.dialog.id == dialog.id
      }
      || queuedDialogs.contains {
        $0.source === source && $0.dialog.id == dialog.id
      }
    guard !isDuplicate else { return }

    queuedDialogs.append(PendingDialog(dialog: dialog, source: source))
    presentNextDialog()
  }

  private func presentNextDialog() {
    guard presentedDialog == nil, !queuedDialogs.isEmpty else { return }
    let next = queuedDialogs.removeFirst()
    presentedDialog = next
    dialog = next.dialog
  }

  private func updateStatus(_ event: PiRPCClient.JSON, from source: AppModel) {
    let key = event["statusKey"] as? String ?? "extension"
    let rawText = event["statusText"] as? String ?? ""
    if key == "account-usage-gui" {
      updateCodexAccounts(from: rawText, source: source)
      return
    }

    let text = Self.removingANSIEscapes(rawText)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty {
      if statuses[key] != text { statuses[key] = text }
    } else if key != "account-usage", statuses[key] != nil {
      // Keep the latest multi-account quota summary; transient statuses may clear themselves.
      statuses.removeValue(forKey: key)
    }
  }

  private func updateCodexAccounts(from text: String, source: AppModel) {
    guard !text.isEmpty,
      let data = text.data(using: .utf8),
      let payload = try? JSONSerialization.jsonObject(with: data) as? PiRPCClient.JSON,
      payload["version"] as? Int == 1,
      let rawAccounts = payload["accounts"] as? [PiRPCClient.JSON]
    else { return }

    let updatedAt = (payload["updatedAt"] as? Double).map {
      Date(timeIntervalSince1970: $0 / 1_000)
    }
    let sourceID = ObjectIdentifier(source)
    // Ignore stale results from this process, but never compare timestamps across sessions:
    // each session has a different active account and background sessions must not overwrite
    // the account marker shown for the selected session.
    if let updatedAt, let current = accountSnapshots[sourceID]?.updatedAt,
      updatedAt < current
    {
      return
    }

    let active = payload["activeAccount"] as? String
    let defaultAccount = payload["defaultAccount"] as? String
    let accounts = rawAccounts.compactMap { raw -> CodexAccountStatus? in
      guard let name = raw["name"] as? String else { return nil }
      return CodexAccountStatus(
        name: name,
        isActive: name == active,
        isDefault: name == defaultAccount,
        isHidden: raw["hidden"] as? Bool ?? false,
        primary: Self.codexWindow(from: raw["primary"]),
        secondary: Self.codexWindow(from: raw["secondary"]),
        error: raw["error"] as? String
      )
    }.sorted {
      if $0.isActive != $1.isActive { return $0.isActive }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }

    let gemini: GeminiUsageStatus?
    if let rawGemini = payload["gemini"] as? PiRPCClient.JSON {
      let kind = rawGemini["kind"] as? String
      let quotas = (rawGemini["quotas"] as? [PiRPCClient.JSON] ?? []).compactMap {
        raw -> GeminiQuota? in
        guard let remaining = raw["remainingPercent"] as? Double else { return nil }
        return GeminiQuota(
          remainingPercent: remaining,
          resetAt: (raw["resetAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1_000)
          },
          window: raw["window"] as? String
        )
      }
      gemini = GeminiUsageStatus(
        isConfigured: kind != "unconfigured",
        isActive: rawGemini["isActive"] as? Bool ?? false,
        quotas: quotas,
        error: rawGemini["error"] as? String
      )
    } else {
      gemini = nil
    }

    let snapshot = AccountSnapshot(
      accounts: accounts,
      gemini: gemini,
      updatedAt: updatedAt ?? accountSnapshots[sourceID]?.updatedAt
    )
    accountSnapshots[sourceID] = snapshot
    if selectedSource == nil { selectedSource = source }
    if selectedSource === source { apply(snapshot) }
  }

  private func apply(_ snapshot: AccountSnapshot) {
    if codexAccounts != snapshot.accounts { codexAccounts = snapshot.accounts }
    if geminiUsage != snapshot.gemini { geminiUsage = snapshot.gemini }
    if codexAccountsUpdatedAt != snapshot.updatedAt {
      codexAccountsUpdatedAt = snapshot.updatedAt
    }
  }

  nonisolated private static func codexWindow(from value: Any?) -> CodexUsageWindow? {
    guard let raw = value as? PiRPCClient.JSON,
      let remaining = raw["remainingPercent"] as? Double
    else { return nil }
    let resetAt = (raw["resetAt"] as? Double).map(Date.init(timeIntervalSince1970:))
    return CodexUsageWindow(
      remainingPercent: remaining,
      resetAt: resetAt,
      windowSeconds: raw["windowSeconds"] as? Double
    )
  }

  nonisolated private static func removingANSIEscapes(_ text: String) -> String {
    let pattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.stringByReplacingMatches(in: text, range: range, withTemplate: "")
  }
}
