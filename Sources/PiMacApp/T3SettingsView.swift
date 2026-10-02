import Combine
import SwiftUI

struct T3SettingsView: View {
  @ObservedObject var service: T3BridgeService
  let workspace: WorkspaceModel
  @State private var showConnectConsent = false
  @State private var showConnectLogout = false
  private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

  var body: some View {
    GroupBox("T3 iOS 连接 · Tunnel") {
      VStack(alignment: .leading, spacing: 16) {
        Text("使用 App Store 版 T3 iOS，登录与 Mac 相同的账号，通过官方 Tunnel 查看会话、发送消息与管理任务。")
          .font(.caption).foregroundStyle(.secondary)
        Text(service.status).font(.caption).foregroundStyle(.secondary)
        if service.port != nil {
          connectView
          HStack {
            Text("已授权设备（\(service.clients.count)）").font(.headline)
            Spacer()
            Button("刷新") { Task { await service.refreshClients() } }
              .disabled(service.managementBusy)
          }
          ForEach(service.clients) { client in
            HStack {
              VStack(alignment: .leading) {
                Text(client.name)
                Text(client.connected ? "WebSocket 已连接" : "已授权 · 当前未连接")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("撤销授权", role: .destructive) { Task { await service.revokeClient(client.id) } }
                .disabled(service.managementBusy)
            }
          }
        }
        if let diagnostic = service.connectStatus?.networkDiagnostic, !diagnostic.isEmpty {
          DisclosureGroup("Tunnel 连接诊断（脱敏）") {
            Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled)
          }
        }
        if !service.managementMessage.isEmpty {
          Text(service.managementMessage).font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
    .task(id: service.port) { await service.refreshClients() }
    .onReceive(timer) { _ in Task { await service.refreshClients() } }
    .confirmationDialog(
      "授权官方 T3 Connect 与公网隧道？", isPresented: $showConnectConsent, titleVisibility: .visible
    ) {
      Button("打开官方授权网页") { Task { await service.connectAction("login") } }
      Button("取消", role: .cancel) {}
    } message: {
      Text(
        "请使用与 T3 iOS 相同的账号，在官方网页选择 Apple 登录。授权后，官方 T3 Server 会启用托管 Cloudflare Tunnel，允许同账号客户端通过受认证公网入口读取会话并执行 Pi 任务。聊天与附件经 Cloudflare 隧道传输，并非端到端加密；通知上报标题、模型及状态。缺少 cloudflared 时会用官方校验安装器下载。本机管理 IPC 不对外暴露，Pi Mac 不读取 Apple 密码。真实公网连接和 iPhone 通知仍需验收。"
      )
    }
    .confirmationDialog(
      "退出 T3 Connect 并撤销环境绑定？", isPresented: $showConnectLogout, titleVisibility: .visible
    ) {
      Button("退出并撤销绑定", role: .destructive) { Task { await service.connectAction("logout") } }
      Button("取消", role: .cancel) {}
    } message: {
      Text("不会删除会话。需要访问官方服务才能确认撤销；失败时先停止状态上报，保留凭据供手动重试。")
    }
  }

  private var connectView: some View {
    GroupBox("T3 Connect 与 Cloudflare Tunnel（官方 Server）") {
      VStack(alignment: .leading, spacing: 8) {
        Text("官方 Server 管理账号、隧道与通知；原生 Workspace 仍独占 Pi 进程和会话写入。暂停上报只暂停通知，不会关闭隧道；退出绑定才会停止隧道。")
          .font(.caption).foregroundStyle(.secondary)
        if let status = service.connectStatus {
          Text(
            status.linked
              ? (status.enabled ? "官方环境已绑定 · 状态上报已开启" : "官方环境已绑定 · 状态上报已暂停") : (status.authorized == true ? "账号已授权 · 环境尚未绑定" : "尚未绑定官方账号"))
          if !status.account.isEmpty {
            Text("官方账号 ID：\(status.account)").font(.caption).textSelection(.enabled)
          }
          if let count = status.deviceCount { Text("同账号开启通知的 iOS 设备：\(count)").font(.caption) }
          if let tunnel = status.tunnelStatus {
            Text("最近隧道配置反馈：\(tunnel)（不代表公网已可达）").font(.caption)
          }
          if let endpoint = status.tunnelURL, !endpoint.isEmpty {
            Text("官方公网地址：\(endpoint)").font(.caption).textSelection(.enabled)
          }
          HStack {
            if status.loginPending {
              Button("取消等待登录") { Task { await service.connectAction("cancel-login") } }
            } else if status.linked {
              Button(status.enabled ? "暂停上报" : "恢复上报") {
                Task { await service.connectAction(status.enabled ? "disable" : "enable") }
              }
              Button("重新授权") { Task { await service.connectAction("reauthorize") } }
              Button("退出并撤销绑定", role: .destructive) { showConnectLogout = true }
            } else {
              Button("通过官方网页登录（支持 Apple）") { showConnectConsent = true }
              if status.authorized == true {
                Button("重试已授权的绑定") { Task { await service.connectAction("retry-link") } }
                Button("重新授权") { Task { await service.connectAction("reauthorize") } }
              }
            }
            Spacer()
            Button(status.linked ? "查询官方设备" : "刷新") {
              Task {
                if status.linked {
                  await service.connectAction("refresh-devices")
                } else {
                  await service.refreshClients()
                }
              }
            }
          }.disabled(service.connectBusy || status.busy || !status.available)
          if !status.message.isEmpty {
            Text(status.message).font(.caption).foregroundStyle(.secondary)
          }
          Text(
            "本次上报：\(status.accepted)/\(status.requests) 已接受；投递排队 \(status.queuedDeliveries)，服务端成功 \(status.successfulDeliveries)，失败 \(status.failedDeliveries)。不代表手机已显示通知。"
          )
          .font(.caption).foregroundStyle(.secondary)
        } else {
          Text("读取连接状态中…").font(.caption).foregroundStyle(.secondary)
        }
        if !service.connectMessage.isEmpty {
          Text(service.connectMessage).font(.caption).foregroundStyle(.secondary)
        }
        Text(
          "手机须在 T3 iOS 登录同一账号，并开启系统通知、任务完成通知及锁屏实时活动。只通过官方托管 Tunnel 连接，不再提供 LAN 配对。请在手机 Environments 中删除旧的 Pi Mac · LAN 条目，再开启 Pi Mac · Tunnel。尚未完成 App Store 客户端与真实通知验收。"
        )
        .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }

}
