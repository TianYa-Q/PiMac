import SwiftUI

struct AccountVisibilityPresentation {
  struct Account: Identifiable {
    let id: Int
    let option: String
    let name: String
    let isVisible: Bool
  }

  let accounts: [Account]

  init?(dialog: ExtensionDialog) {
    guard dialog.title == "选择要显示或隐藏额度的账户",
      case .select(let options) = dialog.kind,
      options.allSatisfy({ $0.hasPrefix("✓ ") || $0.hasPrefix("○ ") })
    else { return nil }
    accounts = options.enumerated().map { index, option in
      Account(
        id: index, option: option, name: String(option.dropFirst(2)),
        isVisible: option.hasPrefix("✓ "))
    }
  }
}

struct AccountVisibilityDialogView: View {
  let presentation: AccountVisibilityPresentation
  let answer: (String) -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("额度显示设置", systemImage: "slider.horizontal.3")
        .font(.title3.weight(.semibold))
      Text("点击账户切换显示或隐藏，修改后返回账户管理。")
        .font(.callout).foregroundStyle(.secondary)
      if presentation.accounts.isEmpty {
        Text("暂无可设置的账户")
          .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
      } else {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(presentation.accounts) { account in
              if account.id != 0 { Divider().padding(.leading, 44) }
              Button {
                answer(account.option)
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: account.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(account.isVisible ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                  Text(account.name).font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                  Spacer()
                  Text(account.isVisible ? "已显示" : "已隐藏")
                    .font(.caption).foregroundStyle(.secondary)
                  Image(systemName: account.isVisible ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(account.isVisible ? Color.accentColor : Color.secondary)
                }
                .padding(.horizontal, 14).frame(height: 52)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .help(account.isVisible ? "隐藏 \(account.name) 的额度" : "显示 \(account.name) 的额度")
              .accessibilityLabel("\(account.name)，\(account.isVisible ? "已显示" : "已隐藏")")
            }
          }
        }
        .frame(height: min(CGFloat(presentation.accounts.count) * 52, 312))
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
      }
      Divider()
      HStack {
        Text("仅影响额度展示，不会删除或退出账户。")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("关闭", action: cancel).keyboardShortcut(.cancelAction)
      }
    }
    .padding(24).frame(width: 480)
  }
}
