import SwiftUI

struct TelegramSettingsView: View {
  @ObservedObject var control: TelegramControl
  @State private var enabled = false
  @State private var token = ""
  @State private var userID = ""
  @State private var message = ""
  @State private var saveFailed = false
  @State private var editingCredentials = false
  @State private var confirmation: String?
  @FocusState private var focusedField: Field?

  private enum Field { case token, userID }

  private var hasChanges: Bool {
    enabled != control.enabled
      || token.trimmingCharacters(in: .whitespacesAndNewlines) != control.botToken
      || userID.trimmingCharacters(in: .whitespacesAndNewlines) != control.userID
  }

  private var credentialsValid: Bool {
    TelegramControl.validCredentials(token: token, userID: userID)
  }

  private var stateTitle: String {
    guard control.enabled else { return "已关闭" }
    switch control.connectionState {
    case .connected: return "已连接"
    case .connecting: return "连接中…"
    case .failed: return "连接失败"
    case .disconnected: return "等待连接"
    }
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            if control.enabled && control.connectionState == .connecting {
              ProgressView().controlSize(.mini)
            } else {
              Circle()
                .fill(control.enabled ? control.connectionState.color : Color.secondary)
                .frame(width: 7, height: 7)
            }
            Text(stateTitle).font(.callout.weight(.medium))
            Spacer()
            if hasChanges {
              Text("待应用").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
          }
          Text(control.status)
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          Divider()
          Toggle("启用", isOn: $enabled)
            .toggleStyle(.switch).controlSize(.small)
        }


        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Label("连接凭据", systemImage: "key.horizontal")
              .font(.callout.weight(.semibold))
            Spacer()
            Button(editingCredentials ? "收起" : "编辑") {
              editingCredentials.toggle()
            }
            .buttonStyle(.borderless)
          }
          if editingCredentials {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text("Bot Token").font(.caption.weight(.medium))
                Spacer()
                Link("创建 Bot ↗", destination: URL(string: "https://t.me/BotFather")!)
                  .font(.caption)
              }
              SecureField("粘贴 @BotFather 提供的 Token", text: $token)
                .focused($focusedField, equals: .token)
                .onSubmit { focusedField = .userID }
            }
            VStack(alignment: .leading, spacing: 6) {
              Text("用户 ID").font(.caption.weight(.medium))
              TextField("Telegram 数字 ID", text: $userID)
                .focused($focusedField, equals: .userID)
            }
            if enabled && !credentialsValid {
              Label("请填写有效的 Token 和正整数用户 ID", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
            }
          } else {
            HStack(alignment: .top) {
              Label(token.isEmpty ? "Token 未设置" : "Token 已设置", systemImage: "lock.shield")
              Spacer()
              Text(userID.isEmpty ? "用户 ID 未设置" : "用户 ID · \(userID)")
                .textSelection(.enabled)
            }
            .font(.caption).foregroundStyle(.secondary)
          }
        }

        HStack(spacing: 10) {
          Button("应用", action: requestSave)
            .buttonStyle(.borderedProminent)
            .disabled(!hasChanges || (enabled && !credentialsValid))
          if hasChanges {
            Button("还原", action: load).buttonStyle(.borderless)
          } else if control.enabled {
            Button("重新连接") { control.reconnect() }.buttonStyle(.borderless)
          }
          Spacer(minLength: 0)
          if !message.isEmpty {
            Label(message, systemImage: saveFailed ? "exclamationmark.circle" : "checkmark.circle")
              .font(.caption)
              .foregroundStyle(saveFailed ? Color.red : Color.secondary)
          }
        }

        Divider()
        DisclosureGroup("说明") {
          VStack(alignment: .leading, spacing: 8) {
            Text("Bot 私聊发送 /help。Mac 需保持唤醒、联网；扩展确认在 Mac 处理。")
            Text("仅允许该用户 ID 的私聊。远程任务可读写文件、执行命令；消息非端到端加密。")
            Text("Token 明文存于本机。关闭开关、清空 Token 并应用可删除；旧钥匙串记录需手动删除。")
            Text("首次连接不执行旧消息，重启后继续待收消息。更换凭据会清空队列、未送达消息及会话关联。")
          }
          .foregroundStyle(.secondary).padding(.top, 6)
        }
        .font(.caption)
      }
      .textFieldStyle(.roundedBorder)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
    } label: {
      Text("Telegram")
    }
    .onAppear(perform: load)
    .onChange(of: enabled) { _, _ in if hasChanges { clearFeedback() } }
    .onChange(of: token) { _, _ in if hasChanges { clearFeedback() } }
    .onChange(of: userID) { _, _ in if hasChanges { clearFeedback() } }
    .alert(
      "应用远程控制更改？",
      isPresented: Binding(
        get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
      )
    ) {
      Button("取消", role: .cancel) { confirmation = nil }
      Button("确认并应用", role: .destructive) { save() }
    } message: {
      Text(confirmation ?? "")
    }
  }

  private func clearFeedback() {
    message = ""
    saveFailed = false
  }

  private func load() {
    enabled = control.enabled
    userID = control.userID
    token = control.botToken
    editingCredentials = token.isEmpty || userID.isEmpty
    clearFeedback()
  }

  private func requestSave() {
    if let impact = control.configurationImpact(token: token, userID: userID, enabled: enabled) {
      confirmation = impact
    } else {
      save()
    }
  }

  private func save() {
    do {
      try control.configure(token: token, userID: userID, enabled: enabled)
      token = control.botToken
      userID = control.userID
      message = "已应用"
      saveFailed = false
      editingCredentials = false
      focusedField = nil
    } catch {
      message = error.localizedDescription
      saveFailed = true
    }
  }
}
