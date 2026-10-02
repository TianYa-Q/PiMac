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
    guard control.enabled else { return "远程控制已关闭" }
    switch control.connectionState {
    case .connected: return "已连接 · 可以开始对话"
    case .connecting: return "正在连接 Telegram"
    case .failed: return "连接暂时不可用"
    case .disconnected: return "等待连接"
    }
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "paperplane.fill")
            .font(.title2)
            .foregroundStyle(.tint)
            .frame(width: 44, height: 44)
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
          VStack(alignment: .leading, spacing: 5) {
            Text("把工作带到 Telegram").font(.headline)
            Text("发送消息、照片或文件，让 Mac 上的 Pi 接着处理。")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
        }

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
          Toggle("启用远程控制", isOn: $enabled)
            .toggleStyle(.switch).controlSize(.small)
          if hasChanges {
            Text("修改尚未生效，保存后才会改变连接。")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

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
              Text("允许的用户 ID").font(.caption.weight(.medium))
              TextField("你的 Telegram 数字 ID", text: $userID)
                .focused($focusedField, equals: .userID)
              Text("仅此用户的私聊可以操作 Mac；不是 @用户名或 Bot ID。")
                .font(.caption).foregroundStyle(.secondary)
            }
            if enabled && !credentialsValid {
              Label("请填写有效的 Token 和正整数用户 ID", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
            }
            Text("Token 明文保存在本机设置中。关闭开关、清空 Token 并保存可删除它。")
              .font(.caption).foregroundStyle(.secondary)
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
          Button("保存并应用", action: requestSave)
            .buttonStyle(.borderedProminent)
            .disabled(!hasChanges || (enabled && !credentialsValid))
          if hasChanges {
            Button("撤销修改", action: load).buttonStyle(.borderless)
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
        VStack(alignment: .leading, spacing: 8) {
          Label("连接后，在 Bot 私聊中发送 /help", systemImage: "bubble.left.and.text.bubble.right")
            .font(.callout.weight(.medium))
          Text("选择项目 → 发送任务 → 收到结果。Mac 需保持唤醒、联网并运行 Pi Mac；扩展确认仍需在 Mac 上处理。")
            .font(.caption).foregroundStyle(.secondary)
          DisclosureGroup("安全与消息处理") {
            Text(
              "远程任务拥有本机 Pi 的文件及命令执行权限，聊天内容会经过 Telegram（非端到端加密），请使用专属 Bot。首次连接前的旧消息不会执行，已连接过的 Bot 会在重启后继续处理待收消息。更换凭据会清除等待任务、未送达消息及会话关联；旧版钥匙串 Token 不会自动迁移或删除。"
            )
            .font(.caption).foregroundStyle(.secondary)
            .padding(.top, 6)
          }
          .font(.caption)
        }
      }
      .textFieldStyle(.roundedBorder)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
    } label: {
      Label("Telegram 远程控制", systemImage: "paperplane")
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
      message = enabled ? "已应用，连接状态见上方" : "已保存 · 远程控制关闭"
      saveFailed = false
      editingCredentials = false
      focusedField = nil
    } catch {
      message = error.localizedDescription
      saveFailed = true
    }
  }
}
