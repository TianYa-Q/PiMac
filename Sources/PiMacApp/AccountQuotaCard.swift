import SwiftUI

// Quota is a snapshot, not an ongoing operation. Avoid the native progress
// indicator's animation/redraws when the surrounding conversation updates.
private struct QuotaUsageBar: View {
  let remainingPercent: Double
  let color: Color

  private var fraction: Double {
    remainingPercent.isFinite ? max(0, min(100, remainingPercent)) / 100 : 0
  }

  var body: some View {
    GeometryReader { geometry in
      Capsule()
        .fill(Color.secondary.opacity(0.15))
        .overlay(alignment: .leading) {
          Capsule()
            .fill(color)
            .frame(width: geometry.size.width * fraction)
        }
    }
    .frame(height: 6)
    .transaction { $0.animation = nil }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("剩余额度")
    .accessibilityValue("\(Int((fraction * 100).rounded()))%")
  }
}

private struct CompactResetTime: View {
  let date: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      Text(Self.label(for: date, relativeTo: context.date))
    }
  }

  private static func label(for date: Date, relativeTo now: Date) -> String {
    let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
    if minutes == 0 { return "NOW" }

    let days = minutes / 1_440
    let hours = minutes % 1_440 / 60
    let remainingMinutes = minutes % 60
    if days > 0 { return hours > 0 ? "\(days)D\(hours)H" : "\(days)D" }
    if hours > 0 { return remainingMinutes > 0 ? "\(hours)H\(remainingMinutes)M" : "\(hours)H" }
    return "\(remainingMinutes)M"
  }
}

private struct ResetCreditsIcon: View {
  let credits: CodexResetCredits
  @State private var isHovered = false

  var body: some View {
    Image(systemName: "exclamationmark.circle")
      .font(.caption2)
      .foregroundStyle(.orange)
      .frame(width: 16, height: 16)
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .popover(isPresented: $isHovered, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
        hoverCard
      }
      .accessibilityLabel(accessibilityText)
  }

  private var hoverCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 7) {
        Image(systemName: "arrow.counterclockwise.circle.fill")
          .foregroundStyle(.orange)
        Text("已存储的重置机会")
          .font(.caption.bold())
        Spacer(minLength: 8)
        Text("\(credits.availableCount) 次")
          .font(.caption2.bold())
          .monospacedDigit()
          .foregroundStyle(.orange)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.orange.opacity(0.12), in: Capsule())
      }

      if credits.expirations.isEmpty {
        Text("未提供失效时间")
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else {
        Divider()
        VStack(alignment: .leading, spacing: 7) {
          ForEach(Array(credits.expirations.enumerated()), id: \.offset) { index, date in
            HStack(spacing: 7) {
              Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 12)
              Text("第 \(index + 1) 次")
                .font(.caption2)
                .foregroundStyle(.secondary)
              Spacer(minLength: 8)
              Text(date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2.weight(.medium))
                .monospacedDigit()
            }
          }
        }
      }
    }
    .foregroundStyle(.primary)
    .padding(12)
    .frame(width: 270)
  }

  private var accessibilityText: String {
    var lines = ["已存储的重置机会：\(credits.availableCount) 次"]
    lines.append(
      contentsOf: credits.expirations.map {
        "失效时间：\($0.formatted(date: .abbreviated, time: .shortened))"
      })
    return lines.joined(separator: "，")
  }
}

struct CodexAccountsView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var extensionUI: ExtensionUIModel

  var body: some View {
    CodexAccountsCard(
      snapshot: .init(
        sourceID: ObjectIdentifier(app), accounts: extensionUI.codexAccounts,
        gemini: extensionUI.geminiUsage,
        emptyStatus: extensionUI.statuses["account-usage"], message: app.accountQuotaMessage,
        canRefresh: app.isProcessRunning && !app.isRefreshingAccountQuota,
        isRefreshing: app.isRefreshingAccountQuota,
        maxAge: app.isBusy ? 60 : 180,
        canManage: app.canManageAccounts,
        canSwitch: app.canRestartSafely && app.supportsAccountSwitch),
      refresh: { app.refreshCodexAccounts(force: true) },
      manage: { app.openCodexAccountManager() },
      switchAccount: { app.switchCodexAccount(to: $0) }
    )
    .equatable()
  }
}

// Ignore unrelated streaming/heartbeat publications. Only a changed quota snapshot
// or control availability should redraw the card (including its material-backed rows).
private struct CodexAccountsCard: View, Equatable {
  struct Snapshot: Equatable {
    var sourceID: ObjectIdentifier
    var accounts: [CodexAccountStatus]
    var gemini: GeminiUsageStatus?
    var emptyStatus: String?
    var message: String
    var canRefresh: Bool
    var isRefreshing: Bool
    var maxAge: TimeInterval
    var canManage: Bool
    var canSwitch: Bool
  }

  let snapshot: Snapshot
  let refresh: () -> Void
  let manage: () -> Void
  let switchAccount: (String) -> Void
  @AppStorage("accountQuotaExpanded") private var isExpanded = false
  @AppStorage("accountQuotaSort") private var sort = AccountQuotaPresentation.Sort.name
  @State private var filter = AccountQuotaPresentation.Filter.all
  @State private var query = ""

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.snapshot == rhs.snapshot }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label("账户额度", systemImage: "gauge.with.dots.needle.50percent")
            .font(.caption.bold())
            .fixedSize()
          if !snapshot.message.isEmpty {
            Text(snapshot.message)
              .font(.caption2)
              .foregroundStyle(.red)
              .lineLimit(1)
              .truncationMode(.tail)
              .help(snapshot.message)
          }
          Spacer(minLength: 0)
          Button(action: refresh) {
            if snapshot.isRefreshing {
              ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .accessibilityLabel(snapshot.isRefreshing ? "正在刷新账户额度" : "刷新账户额度")
          .buttonStyle(.plain)
          .help("重新查询账户额度；不修改 Pi 授权")
          .disabled(!snapshot.canRefresh)
          Button("管理", action: manage)
            .buttonStyle(.plain)
            .font(.caption)
            .disabled(!snapshot.canManage)
          Button {
            withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
          } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          }
          .buttonStyle(.plain)
          .help(isExpanded ? "折叠账户额度" : "展开全部账户额度")
          .accessibilityLabel(isExpanded ? "折叠账户额度" : "展开全部账户额度")
        }

        if isExpanded {
          expandedAccounts
        } else {
          currentAccount
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private var expandedAccounts: some View {
    if snapshot.accounts.isEmpty && snapshot.gemini == nil {
      emptyStatus
    } else {
      HStack(spacing: 6) {
        TextField("搜索账户", text: $query)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("搜索额度账户")
        Menu {
          Picker("筛选", selection: $filter) {
            ForEach(AccountQuotaPresentation.Filter.allCases) { Text($0.title).tag($0) }
          }
          Picker("排序", selection: $sort) {
            ForEach(AccountQuotaPresentation.Sort.allCases) { Text($0.title).tag($0) }
          }
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("筛选：\(filter.title)；排序：\(sort.title)；当前账户置顶")
        .accessibilityLabel("账户额度筛选与排序")
      }
      TimelineView(.periodic(from: .now, by: 60)) { context in
        let accounts = AccountQuotaPresentation.accounts(
          snapshot.accounts, query: query, filter: filter, sort: sort,
          now: context.date, maxAge: snapshot.maxAge)
        let gemini = snapshot.gemini.flatMap {
          AccountQuotaPresentation.showsGemini(
            $0, query: query, filter: filter, now: context.date, maxAge: snapshot.maxAge) ? $0 : nil
        }
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("\(accounts.count + (gemini == nil ? 0 : 1)) 项 · \(filter.title)")
              .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if !query.isEmpty || filter != .all {
              Button("清除筛选") {
                query = ""
                filter = .all
              }
              .buttonStyle(.plain).font(.caption2)
            }
          }
          ScrollView {
            LazyVStack(spacing: 7) {
              if accounts.isEmpty && gemini == nil {
                Text("没有匹配的额度账户")
                  .font(.caption2).foregroundStyle(.secondary).padding(.vertical, 8)
              }
              ForEach(accounts) { account in accountRow(account) }
              if let gemini { geminiRow(gemini) }
            }
          }
          .frame(maxHeight: 240)
        }
      }
    }
  }

  @ViewBuilder
  private var currentAccount: some View {
    if let gemini = snapshot.gemini, gemini.isConfigured, gemini.isActive {
      geminiRow(gemini)
    } else if let account = snapshot.accounts.first(where: \.isActive)
      ?? snapshot.accounts.first(where: \.isDefault)
      ?? snapshot.accounts.first
    {
      accountRow(account)
    } else if let gemini = snapshot.gemini, gemini.isConfigured {
      geminiRow(gemini)
    } else {
      emptyStatus
    }
  }

  private var emptyStatus: some View {
    Text(snapshot.emptyStatus ?? "暂无账户额度数据，可点击刷新查询。")
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(5)
      .textSelection(.enabled)
  }

  private func accountRow(_ account: CodexAccountStatus) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 5) {
        Circle()
          .fill(account.isActive ? Color.green : Color.secondary.opacity(0.35))
          .frame(width: 7, height: 7)
        Text(account.name).font(.caption.bold()).lineLimit(1)
        if account.isDefault {
          Text("默认").font(.caption2).foregroundStyle(.secondary)
        }
        if account.isHidden {
          Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary)
        }
        if let resetCredits = account.resetCredits {
          ResetCreditsIcon(credits: resetCredits)
        }
        Spacer()
        if !account.isActive {
          Button("切换") { switchAccount(account.name) }
            .buttonStyle(.borderless)
            .font(.caption2)
            .disabled(!snapshot.canSwitch || !T3DesktopClient.isSwitchableAccountName(account.name))
            .help("空闲时通过 account-usage 扩展切换账户；执行结果以 Pi 回复为准")
        }
      }
      // The hover card extends over the quota rows, so its source row must paint above them.
      .zIndex(1)
      if let error = account.error {
        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2).help(error)
      } else if account.primary == nil && account.secondary == nil {
        Text(account.isHidden ? "额度已隐藏" : "暂无额度数据，可刷新重试")
          .font(.caption2).foregroundStyle(.secondary)
      } else {
        if let window = account.primary { usageRow(window, label: windowLabel(window)) }
        if let window = account.secondary { usageRow(window, label: windowLabel(window)) }
      }
      if !account.isHidden && (account.primary != nil || account.secondary != nil) {
        AccountQuotaFreshnessView(capturedAt: account.capturedAt, maxAge: snapshot.maxAge)
      }
    }
    .padding(7)
    .background(
      account.isActive ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 8))
  }

  private func geminiRow(_ status: GeminiUsageStatus) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 5) {
        Circle()
          .fill(status.isActive ? Color.green : Color.secondary.opacity(0.35))
          .frame(width: 7, height: 7)
        Text("Antigravity · Gemini").font(.caption.bold())
        Text("Antigravity").font(.caption2).foregroundStyle(.secondary)
        Spacer()
      }
      if let error = status.error {
        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2).help(error)
      } else if status.quotas.isEmpty {
        Text("暂无额度数据").font(.caption2).foregroundStyle(.secondary)
      } else {
        ForEach(status.quotas) { quota in
          HStack(spacing: 4) {
            Text(geminiWindowLabel(quota.window))
              .frame(width: 20, alignment: .leading)
            QuotaUsageBar(
              remainingPercent: quota.remainingPercent, color: usageColor(quota.remainingPercent)
            )
            .frame(minWidth: 24)
            .layoutPriority(1)
            Text("\(Int(quota.remainingPercent.rounded()))%")
              .monospacedDigit()
              .frame(width: 30, alignment: .trailing)
            if let resetAt = quota.resetAt {
              CompactResetTime(date: resetAt)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      }
      if !status.quotas.isEmpty {
        AccountQuotaFreshnessView(capturedAt: status.capturedAt, maxAge: snapshot.maxAge)
      }
    }
    .padding(7)
    .background(
      status.isActive ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 8))
  }

  private func usageRow(_ window: CodexUsageWindow, label: String) -> some View {
    HStack(spacing: 4) {
      Text(label).frame(width: 20, alignment: .leading)
      QuotaUsageBar(
        remainingPercent: window.remainingPercent, color: usageColor(window.remainingPercent)
      )
      .frame(minWidth: 24)
      .layoutPriority(1)
      Text("\(Int(window.remainingPercent.rounded()))%")
        .monospacedDigit()
        .frame(width: 30, alignment: .trailing)
      if let resetAt = window.resetAt {
        CompactResetTime(date: resetAt)
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }

  private func windowLabel(_ window: CodexUsageWindow) -> String {
    guard let seconds = window.windowSeconds else { return "Q" }
    return seconds <= 21_600 ? "\(Int((seconds / 3_600).rounded()))H" : "7D"
  }

  private func geminiWindowLabel(_ window: String?) -> String {
    guard let window else { return "Q" }
    if window.localizedCaseInsensitiveContains("5h")
      || window.localizedCaseInsensitiveContains("5 hour")
    {
      return "5H"
    }
    if window.localizedCaseInsensitiveContains("7d")
      || window.localizedCaseInsensitiveContains("week")
    {
      return "7D"
    }
    return "Q"
  }

  private func usageColor(_ percent: Double) -> Color {
    if percent < 20 { return .red }
    if percent < 50 { return .orange }
    return .green
  }
}
