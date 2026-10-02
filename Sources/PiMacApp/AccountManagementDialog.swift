import SwiftUI

/// Adapts the account extension's standard select dialog without changing its wire protocol.
struct AccountManagementPresentation {
  struct Account: Identifiable {
    let id: Int
    let name: String
    let isCurrent: Bool
    let isDefault: Bool
  }

  let provider: String
  let accounts: [Account]

  var credentialLabel: String {
    provider == "Codex legacy"
      ? AccountUsageProvider.legacyCodex.credentialLabel
      : AccountUsageProvider.chatGPT.credentialLabel
  }

  var loginTitle: String {
    provider == "Codex legacy" ? "登录 Legacy 账户" : "登录新版账户"
  }

  init?(dialog: ExtensionDialog) {
    guard case .select(let options) = dialog.kind,
      options == ["切换账户", "刷新额度", "登录新账户", "删除账户", "额度显示设置", "自动启动记录", "关闭"]
    else { return nil }
    let lines = dialog.title.components(separatedBy: "\n")
    switch lines.first {
    case "Codex legacy 多账户管理": provider = "Codex legacy"
    case "OpenAI ChatGPT 多账户管理": provider = "OpenAI ChatGPT"
    default: return nil
    }
    accounts = lines.dropFirst().filter { !$0.isEmpty && $0 != "尚未登录账户" }
      .enumerated().map { index, line in
        var name = line
        var current = false
        var defaultAccount = false
        if let start = line.range(of: "（", options: .backwards), line.hasSuffix("）") {
          let markers = String(line[start.upperBound..<line.index(before: line.endIndex)])
            .components(separatedBy: "、")
          if !markers.isEmpty && markers.allSatisfy({ ["当前会话", "新会话默认"].contains($0) }) {
            name = String(line[..<start.lowerBound])
            current = markers.contains("当前会话")
            defaultAccount = markers.contains("新会话默认")
          }
        }
        return Account(id: index, name: name, isCurrent: current, isDefault: defaultAccount)
      }
  }
}

struct AccountManagementDialogView: View {
  let presentation: AccountManagementPresentation
  let answer: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        Image(systemName: "person.2.fill")
          .font(.title2)
          .foregroundStyle(Color.accentColor)
          .frame(width: 44, height: 44)
          .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 4) {
          Text("多账户管理").font(.title3.weight(.semibold))
          badge(presentation.credentialLabel, accent: false)
        }
        Spacer()
        Text("\(presentation.accounts.count) 个账户")
          .font(.caption).foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 10) {
        Text("已登录账户").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        if presentation.accounts.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus").font(.title2)
            Text("尚未登录账户").font(.subheadline.weight(.medium))
            Text("登录后即可切换账户和查看额度").font(.caption)
          }
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity).padding(.vertical, 20)
          .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        } else {
          ScrollView {
            VStack(spacing: 0) {
              ForEach(presentation.accounts) { account in
                if account.id != 0 { Divider().padding(.leading, 46) }
                accountRow(account)
              }
            }
          }
          .frame(height: min(CGFloat(presentation.accounts.count) * 58, 232))
          .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
        }
      }

      VStack(spacing: 10) {
        HStack(spacing: 10) {
          action("切换账户", icon: "arrow.triangle.2.circlepath", prominent: true)
            .disabled(presentation.accounts.isEmpty)
          action("登录新账户", icon: "person.badge.plus", label: presentation.loginTitle)
        }
        HStack(spacing: 10) {
          action("刷新额度", icon: "arrow.clockwise")
          action("额度显示设置", icon: "slider.horizontal.3")
        }
      }

      Text(
        presentation.provider == "Codex legacy"
          ? "新版登录请先选择 openai 模型。Legacy 与新版凭据分开保存，不能直接迁移。"
          : "使用 Pi 原生 ChatGPT OAuth 登录新版凭据，不会自动覆盖 API Key。"
      )
      .font(.caption).foregroundStyle(.secondary)

      Divider()
      HStack(spacing: 16) {
        Button {
          answer("自动启动记录")
        } label: {
          Label("启动记录", systemImage: "clock.arrow.circlepath")
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        Button(role: .destructive) {
          answer("删除账户")
        } label: {
          Label("删除账户", systemImage: "trash")
        }
        .buttonStyle(.plain).foregroundStyle(.red)
        .disabled(presentation.accounts.isEmpty)
        Spacer()
        Button("关闭") { answer("关闭") }
          .keyboardShortcut(.cancelAction)
      }
      .font(.callout)
    }
    .padding(24)
    .frame(width: 480)
  }

  private func accountRow(_ account: AccountManagementPresentation.Account) -> some View {
    HStack(spacing: 10) {
      Image(systemName: account.isCurrent ? "person.crop.circle.fill" : "person.crop.circle")
        .font(.title3)
        .foregroundStyle(account.isCurrent ? Color.accentColor : Color.secondary)
      Text(account.name).font(.body.weight(.medium)).lineLimit(1)
        .truncationMode(.middle).help(account.name)
      Spacer(minLength: 8)
      if account.isCurrent { badge("当前会话", accent: true) }
      if account.isDefault { badge("新会话默认", accent: false) }
    }
    .padding(.horizontal, 14)
    .frame(height: 58)
    .accessibilityElement(children: .combine)
  }

  private func badge(_ title: String, accent: Bool) -> some View {
    Text(title).font(.system(size: 10, weight: .medium))
      .foregroundStyle(accent ? Color.accentColor : Color.secondary)
      .padding(.horizontal, 7).padding(.vertical, 4)
      .background(
        accent ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.06), in: Capsule()
      )
      .fixedSize()
  }

  private func action(_ title: String, icon: String, prominent: Bool = false, label: String? = nil)
    -> some View
  {
    Button {
      answer(title)
    } label: {
      Label(label ?? title, systemImage: icon)
        .font(.callout.weight(.medium))
        .frame(maxWidth: .infinity, minHeight: 38)
        .contentShape(Rectangle())
    }
    .buttonStyle(AccountManagementActionStyle(prominent: prominent))
  }
}

private struct AccountManagementActionStyle: ButtonStyle {
  let prominent: Bool
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(prominent ? Color.white : Color.primary)
      .background(
        prominent
          ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.09 : 0.045),
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(prominent ? 0 : 0.08))
      )
      .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
  }
}
