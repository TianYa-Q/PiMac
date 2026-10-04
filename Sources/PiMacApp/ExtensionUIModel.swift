import AppKit
import Combine
import Foundation

/// Application-wide coordinator for Pi extension UI.
///
/// Dialogs from every live RPC process are queued here. Account selection is session-specific,
/// while quota snapshots are shared across sessions of the same account provider.
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

  private struct UsageSnapshot {
    let accounts: [CodexAccountStatus]
    let gemini: GeminiUsageStatus?
    let updatedAt: Date?
  }

  private struct SessionAccountSelection {
    let activeAccount: String?
    let provider: AccountUsageProvider
    let supportsAccountSwitch: Bool
    let managesSelectedAuth: Bool
    let geminiIsActive: Bool
    let updatedAt: Date?
  }

  private var presentedDialog: PendingDialog?
  private var queuedDialogs: [PendingDialog] = []
  private weak var selectedSource: AppModel?
  private var usageSnapshots: [AccountUsageProvider: UsageSnapshot] = [:]
  private var displayedUsageProvider = AccountUsageProvider.legacyCodex
  private var sessionAccountSelections: [ObjectIdentifier: SessionAccountSelection] = [:]
  private var awaitingSessionStatus: Set<ObjectIdentifier> = []
  private var sessionStatuses: [ObjectIdentifier: [String: String]] = [:]

  func sessionWillChange(for source: AppModel) {
    awaitingSessionStatus.insert(ObjectIdentifier(source))
  }

  func cancelSessionChange(for source: AppModel) {
    awaitingSessionStatus.remove(ObjectIdentifier(source))
  }

  func selectSource(_ source: AppModel?) {
    selectedSource = source
    applyStatusesForSelectedSource()
    // A newly created/resumed process has not reported its session account yet. Keep showing
    // the previous account meanwhile instead of briefly replacing the quota card with
    // “等待扩展提供账户信息…”. Its first status payload will apply the new selection.
    guard let source,
      sessionAccountSelections[ObjectIdentifier(source)] != nil
    else { return }
    applyUsageForSelectedSource()
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

  /// Expired or closed server requests must disappear without replaying a reply.
  func reconcileRequests(ids: Set<String>, from source: AppModel) {
    queuedDialogs.removeAll { $0.source === source && !ids.contains($0.dialog.id) }
    if let presentedDialog, presentedDialog.source === source,
      !ids.contains(presentedDialog.dialog.id)
    {
      self.presentedDialog = nil
      dialog = nil
      presentNextDialog()
    }
  }

  func hasPendingRequests(from source: AppModel) -> Bool {
    (presentedDialog?.source === source) || queuedDialogs.contains { $0.source === source }
  }

  func hasPendingDialog(for source: AppModel) -> Bool {
    presentedDialog?.source === source || queuedDialogs.contains { $0.source === source }
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
    awaitingSessionStatus.remove(ObjectIdentifier(source))
    sessionAccountSelections.removeValue(forKey: ObjectIdentifier(source))
    sessionStatuses.removeValue(forKey: ObjectIdentifier(source))
    if selectedSource === source { selectSource(nil) }

    cancelDialogs(from: source)
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
    if key == "account-usage-login" {
      if rawText.isEmpty { dismissCompletedLoginDialogs(from: source) }
      return
    }

    let text = Self.removingANSIEscapes(rawText)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceID = ObjectIdentifier(source)
    if !text.isEmpty {
      sessionStatuses[sourceID, default: [:]][key] = text
    } else if key != "account-usage" {
      // Keep the latest quota summary within this session, never another session's status.
      sessionStatuses[sourceID]?.removeValue(forKey: key)
    }
    if selectedSource == nil { selectedSource = source }
    applyStatusesForSelectedSource()
  }

  private func applyStatusesForSelectedSource() {
    let next = selectedSource.flatMap { sessionStatuses[ObjectIdentifier($0)] } ?? [:]
    if statuses != next { statuses = next }
  }

  private func dismissCompletedLoginDialogs(from source: AppModel) {
    cancelDialogs(from: source) { $0.title.hasPrefix("[account-usage login]") }
  }

  private func cancelDialogs(
    from source: AppModel, matching predicate: (ExtensionDialog) -> Bool = { _ in true }
  ) {
    func matches(_ pending: PendingDialog) -> Bool {
      pending.source === source && predicate(pending.dialog)
    }
    let removed = queuedDialogs.filter(matches)
    queuedDialogs.removeAll(where: matches)
    for pending in removed {
      pending.source.sendExtensionResponse(id: pending.dialog.id, cancelled: true)
    }
    if let presentedDialog, matches(presentedDialog) {
      source.sendExtensionResponse(id: presentedDialog.dialog.id, cancelled: true)
      self.presentedDialog = nil
      dialog = nil
      presentNextDialog()
    }
  }

  private func updateCodexAccounts(from text: String, source: AppModel) {
    guard !text.isEmpty, text.utf8.count <= 1_048_576,
      let data = text.data(using: .utf8),
      let payload = try? JSONSerialization.jsonObject(with: data) as? PiRPCClient.JSON,
      let version = AccountUsageSnapshot.number(payload["version"]), [1, 2].contains(version),
      let rawAccounts = payload["accounts"] as? [PiRPCClient.JSON]
    else { return }

    let providerID =
      version == 2 ? (payload["provider"] as? String ?? "openai-codex") : "openai-codex"
    guard let provider = AccountUsageProvider(rawValue: providerID) else { return }
    let usageSnapshot =
      usageSnapshots[provider] ?? UsageSnapshot(accounts: [], gemini: nil, updatedAt: nil)
    let updatedAt = AccountUsageSnapshot.date(payload["updatedAt"], milliseconds: true)
    // An explicitly malformed timestamp must not bypass out-of-order protection.
    guard payload["updatedAt"] == nil || updatedAt != nil else { return }
    let sourceID = ObjectIdentifier(source)
    let isFirstStatusAfterSessionChange = awaitingSessionStatus.remove(sourceID) != nil
    let active = payload["activeAccount"] as? String
    let defaultAccount = payload["defaultAccount"] as? String
    var seenNames: Set<String> = []
    let accounts = rawAccounts.compactMap { raw -> CodexAccountStatus? in
      guard let name = raw["name"] as? String, !name.isEmpty,
        seenNames.insert(name).inserted
      else { return nil }
      return CodexAccountStatus(
        name: name,
        isActive: name == active,
        isDefault: name == defaultAccount,
        isHidden: raw["hidden"] as? Bool ?? false,
        primary: Self.codexWindow(from: raw["primary"]),
        secondary: Self.codexWindow(from: raw["secondary"]),
        resetCredits: Self.codexResetCredits(from: raw["resetCredits"]),
        error: raw["error"] as? String,
        capturedAt: AccountUsageSnapshot.date(raw["capturedAt"], milliseconds: true)
      )
    }.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }

    let gemini: GeminiUsageStatus?
    if let rawGemini = payload["gemini"] as? PiRPCClient.JSON {
      let kind = rawGemini["kind"] as? String
      var seenQuotaIDs: Set<String> = []
      let quotas = (rawGemini["quotas"] as? [PiRPCClient.JSON] ?? []).compactMap {
        raw -> GeminiQuota? in
        guard let remaining = AccountUsageSnapshot.percent(raw["remainingPercent"]) else {
          return nil
        }
        let quota = GeminiQuota(
          remainingPercent: remaining,
          resetAt: AccountUsageSnapshot.date(raw["resetAt"], milliseconds: true),
          window: raw["window"] as? String
        )
        return seenQuotaIDs.insert(quota.id).inserted ? quota : nil
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

    // Only account selection belongs to a session. Ignore an older selection update from the
    // same process, but allow another process to have an independently selected account.
    let previousSelection = sessionAccountSelections[sourceID]
    let isInitialStatusFromSource =
      previousSelection == nil || previousSelection?.provider != provider
    let selectionIsCurrent =
      updatedAt.map { incoming in
        previousSelection?.updatedAt.map { incoming >= $0 } ?? true
      } ?? true
    if selectionIsCurrent {
      sessionAccountSelections[sourceID] = SessionAccountSelection(
        activeAccount: active,
        provider: provider,
        supportsAccountSwitch: version == 2
          ? payload["supportsAccountSwitch"] as? Bool ?? false : true,
        managesSelectedAuth: version == 2
          ? payload["managesSelectedAuth"] as? Bool ?? false : active != nil,
        geminiIsActive: gemini?.isActive ?? false,
        updatedAt: updatedAt ?? previousSelection?.updatedAt
      )
    }

    // Quotas, reset times, visibility, and errors are application-wide. A newly started Pi
    // process publishes an initial quota payload while opening a task, including when an
    // existing process is reused for a new session. That payload only establishes this session's
    // selected account; it must not replace an existing application-wide quota snapshot.
    // Subsequent payloads from the process are periodic or user-requested refreshes.
    let mayUpdateUsage =
      payload["source"] as? String == "host-query"
      || usageSnapshot.accounts.isEmpty && usageSnapshot.gemini == nil
      || (!isInitialStatusFromSource && !isFirstStatusAfterSessionChange)
    let usageIsCurrent =
      updatedAt.map { incoming in
        usageSnapshot.updatedAt.map { incoming >= $0 } ?? true
      } ?? true
    if mayUpdateUsage && usageIsCurrent {
      usageSnapshots[provider] = UsageSnapshot(
        accounts: accounts,
        gemini: gemini,
        updatedAt: updatedAt ?? usageSnapshot.updatedAt
      )
    }

    if selectedSource == nil { selectedSource = source }
    applyUsageForSelectedSource()
    // Account rotation belongs to account-usage inside Pi, not UI publications.
  }

  func usage(for source: AppModel?) -> (
    accounts: [CodexAccountStatus], gemini: GeminiUsageStatus?, updatedAt: Date?
  ) {
    let candidate = source.flatMap { sessionAccountSelections[ObjectIdentifier($0)] }
    let provider = usageProvider(for: source)
    let selection = candidate?.provider == provider ? candidate : nil
    let usageSnapshot =
      usageSnapshots[provider] ?? UsageSnapshot(accounts: [], gemini: nil, updatedAt: nil)
    // The first status event after a project switch can arrive from the process that was just
    // left while the new process is still starting. Keep the account currently shown (or use
    // the payload's account when bootstrapping) until the selected process reports its own
    // selection; never turn a valid shared quota snapshot into an empty card.
    let fallbackActiveAccount =
      source === selectedSource && selection == nil && provider == displayedUsageProvider
      ? (codexAccounts.first(where: \.isActive)?.name
        ?? usageSnapshot.accounts.first(where: \.isActive)?.name)
      : nil
    let activeAccount = selection != nil ? selection?.activeAccount : fallbackActiveAccount
    let geminiIsActive =
      selection?.geminiIsActive
      ?? (source === selectedSource ? geminiUsage?.isActive : nil)
      ?? (source === selectedSource ? usageSnapshot.gemini?.isActive : nil)
    let accounts = usageSnapshot.accounts.map { account in
      CodexAccountStatus(
        name: account.name,
        isActive: account.name == activeAccount,
        isDefault: account.isDefault,
        isHidden: account.isHidden,
        primary: account.primary,
        secondary: account.secondary,
        resetCredits: account.resetCredits,
        error: account.error,
        capturedAt: account.capturedAt
      )
    }.sorted {
      if $0.isActive != $1.isActive { return $0.isActive }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    let gemini = usageSnapshot.gemini.map {
      GeminiUsageStatus(
        isConfigured: $0.isConfigured,
        isActive: geminiIsActive ?? false,
        quotas: $0.quotas,
        error: $0.error
      )
    }

    return (accounts, gemini, usageSnapshot.updatedAt)
  }

  func supportsAccountSwitch(for source: AppModel) -> Bool {
    guard let selection = sessionAccountSelections[ObjectIdentifier(source)],
      AccountUsageProvider(modelID: source.selectedModelId) == selection.provider
    else { return false }
    return selection.supportsAccountSwitch
  }

  func managesSelectedAuth(for source: AppModel) -> Bool {
    supportsAccountSwitch(for: source)
      && sessionAccountSelections[ObjectIdentifier(source)]?.managesSelectedAuth == true
  }

  private func usageProvider(for source: AppModel?) -> AccountUsageProvider {
    guard let source else { return .legacyCodex }
    return AccountUsageProvider(modelID: source.selectedModelId)
      ?? sessionAccountSelections[ObjectIdentifier(source)]?.provider
      ?? .legacyCodex
  }

  private func applyUsageForSelectedSource() {
    let snapshot = usage(for: selectedSource)
    displayedUsageProvider = usageProvider(for: selectedSource)
    if codexAccounts != snapshot.accounts { codexAccounts = snapshot.accounts }
    if geminiUsage != snapshot.gemini { geminiUsage = snapshot.gemini }
    if codexAccountsUpdatedAt != snapshot.updatedAt {
      codexAccountsUpdatedAt = snapshot.updatedAt
    }
  }

  nonisolated private static func codexWindow(from value: Any?) -> CodexUsageWindow? {
    guard let raw = value as? PiRPCClient.JSON,
      let remaining = AccountUsageSnapshot.percent(raw["remainingPercent"])
    else { return nil }
    let resetAt = AccountUsageSnapshot.date(raw["resetAt"])
    return CodexUsageWindow(
      remainingPercent: remaining,
      resetAt: resetAt,
      windowSeconds: AccountUsageSnapshot.number(raw["windowSeconds"]).flatMap {
        (1...31_536_000).contains($0) ? $0 : nil
      }
    )
  }

  nonisolated private static func codexResetCredits(from value: Any?) -> CodexResetCredits? {
    guard let raw = value as? PiRPCClient.JSON,
      let count = AccountUsageSnapshot.number(raw["availableCount"]),
      count > 0, count < Double(Int.max), count.rounded(.towardZero) == count
    else { return nil }
    let expirations = (raw["credits"] as? [PiRPCClient.JSON] ?? []).compactMap {
      AccountUsageSnapshot.date($0["expiresAt"])
    }.sorted()
    return CodexResetCredits(availableCount: Int(count), expirations: expirations)
  }

  nonisolated private static func removingANSIEscapes(_ text: String) -> String {
    let pattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.stringByReplacingMatches(in: text, range: range, withTemplate: "")
  }
}
