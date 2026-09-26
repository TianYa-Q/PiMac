import SwiftUI

struct TelegramSettingsView: View {
  @ObservedObject var control: TelegramControl
  @State private var enabled = false
  @State private var token = ""
  @State private var userID = ""
  @State private var message = ""
  @State private var editingCredentials = false

  var body: some View {
    GroupBox("Telegram 远程控制") {
      VStack(alignment: .leading, spacing: 10) {
        Toggle("启用 Telegram Bot", isOn: $enabled)
        if editingCredentials {
          SecureField("BotFather 提供的 Bot Token", text: $token)
          TextField("允许的 Telegram 用户数字 ID（不是 @用户名）", text: $userID)
        } else {
          Text(token.isEmpty ? "未设置 Bot Token" : "Bot Token 已设置")
            .foregroundStyle(.secondary)
          Text(userID.isEmpty ? "未设置允许的用户 ID" : "允许的用户 ID：\(userID)")
            .foregroundStyle(.secondary)
        }
        Button(editingCredentials ? "完成编辑" : "编辑 Bot 凭据") {
          editingCredentials.toggle()
        }
        Text(
          "仅接受此用户的私聊。远程任务拥有与本机 Pi 相同的文件及命令执行权限；会话内容会发送至 Telegram。Token 以明文保存在本机应用设置中，请使用专属 Bot 并妥善保管。"
        )
        .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("保存并应用") {
            do {
              try control.configure(token: token, userID: userID, enabled: enabled)
              message = "已保存"
              editingCredentials = false
            } catch {
              message =
                (error as? TelegramControl.ConfigurationError)?.localizedDescription
                ?? "保存失败。"
            }
          }
          Text(message).font(.caption)
        }
        Text(control.status).font(.caption).textSelection(.enabled)
        Text(
          "保存后，向 Bot 发送 /help。Mac 需保持联网、唤醒且 Pi Mac 正在运行；启动前的消息不会执行。清空 Token 后保存可删除本地 Token。旧版钥匙串中的 Token 不会自动迁移或删除，升级后需重新填写。"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      .textFieldStyle(.roundedBorder)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
    }
    .onAppear {
      enabled = control.enabled
      userID = control.userID
      token = TelegramTokenStore.load()
    }
  }
}
