import Combine
import SwiftUI

struct T3SettingsView: View {
  @ObservedObject var service: T3BridgeService
  let workspace: WorkspaceModel
  @State private var showConnectConsent = false
  @State private var showConnectLogout = false
  private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Image(systemName: "iphone.and.arrow.forward")
          .font(.title2).foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 4) {
          Text("连接 T3 iOS").font(.headline)
          Text("在 iPhone 登录同一账号，通过官方 Tunnel 访问会话与任务。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.bottom, 2)

      if service.port != nil {
        connectView
        devicesView
      } else {
        card {
          Label(service.status, systemImage: "server.rack")
            .font(.callout).foregroundStyle(.secondary)
        }
      }

      card {
        DisclosureGroup {
          VStack(alignment: .leading, spacing: 10) {
            Text("使用 App Store 版 T3 iOS，登录与 Mac 相同的账号，并开启系统通知、任务完成通知及锁屏实时活动。")
            Text("仅支持官方托管 Tunnel，不再提供 LAN 配对。请在手机 Environments 中删除旧的 Pi Mac · LAN 条目，再开启 Pi Mac · Tunnel。")
            Text("官方 Server 管理账号、隧道与通知；原生 Workspace 仍独占 Pi 进程和会话写入。暂停上报只暂停通知，不会关闭隧道；退出绑定才会停止隧道。")
            Text("尚未完成 App Store 客户端与真实通知验收。")
          }
          .font(.caption).foregroundStyle(.secondary)
          .padding(.top, 8)
        } label: {
          Label("手机设置与连接说明", systemImage: "info.circle").font(.callout)
        }
      }

      if !service.managementMessage.isEmpty {
        Text(service.managementMessage).font(.caption).foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
    card {
      HStack {
        Label("官方连接", systemImage: "network").font(.headline)
        Spacer()
        if service.connectBusy {
          ProgressView().controlSize(.small)
        }
      }
      if let status = service.connectStatus {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: status.linked ? "checkmark.circle.fill" : "link.circle")
            .foregroundStyle(status.linked ? Color.green : Color.secondary)
            .font(.title3)
          VStack(alignment: .leading, spacing: 4) {
            Text(status.linked ? "官方环境已绑定" : (status.authorized == true ? "账号已授权 · 等待绑定" : "尚未绑定官方账号"))
              .font(.body.weight(.medium))
            Text(status.linked
              ? (status.enabled ? "状态上报已开启" : "状态上报已暂停 · 隧道仍保持开启")
              : "授权后即可通过官方 Tunnel 连接此 Mac。")
              .font(.caption).foregroundStyle(.secondary)
          }
        }

        HStack(spacing: 8) {
          if status.loginPending {
            Button("取消等待登录") { Task { await service.connectAction("cancel-login") } }
          } else if status.linked {
            Button(status.enabled ? "暂停上报" : "恢复上报") {
              Task { await service.connectAction(status.enabled ? "disable" : "enable") }
            }
            Button("重新授权") { Task { await service.connectAction("reauthorize") } }
            Spacer()
            Button("退出并撤销绑定", role: .destructive) { showConnectLogout = true }
          } else {
            Button("登录并绑定账号") { showConnectConsent = true }
              .buttonStyle(.borderedProminent)
            if status.authorized == true {
              Button("重试绑定") { Task { await service.connectAction("retry-link") } }
              Button("重新授权") { Task { await service.connectAction("reauthorize") } }
            }
            Spacer()
          }
        }
        .controlSize(.small)
        .disabled(service.connectBusy || status.busy || !status.available)

        if !status.message.isEmpty {
          Text(status.message).font(.caption).foregroundStyle(.secondary)
        }
        if !service.connectMessage.isEmpty {
          Text(service.connectMessage).font(.caption).foregroundStyle(.secondary)
        }

        Divider()
        DisclosureGroup {
          VStack(alignment: .leading, spacing: 12) {
            detailRow("本机服务", value: service.status)
            if !status.account.isEmpty { detailRow("官方账号 ID", value: status.account) }
            if let count = status.deviceCount {
              detailRow("开启通知的 iOS 设备", value: "\(count)")
            }
            if let tunnel = status.tunnelStatus {
              detailRow("隧道配置反馈", value: "\(tunnel)（不代表公网已可达）")
            }
            if let endpoint = status.tunnelURL, !endpoint.isEmpty {
              detailRow("官方公网地址", value: endpoint)
            }
            HStack {
              Button("查询官方设备") { Task { await service.connectAction("refresh-devices") } }
                .disabled(!status.linked || service.connectBusy || status.busy || !status.available)
              Spacer()
            }
            Divider()
            Text("本次上报").font(.caption.weight(.medium))
            Text("\(status.accepted)/\(status.requests) 已接受 · 排队 \(status.queuedDeliveries) · 服务端成功 \(status.successfulDeliveries) · 失败 \(status.failedDeliveries)")
              .font(.caption.monospacedDigit())
            Text("服务端统计不代表手机已显示通知。")
              .font(.caption).foregroundStyle(.secondary)
          }
          .padding(.top, 10)
        } label: {
          Text("账号与上报详情").font(.callout)
        }
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("读取连接状态中…").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("刷新") { Task { await service.refreshClients() } }
            .disabled(service.managementBusy)
        }
      }
      if let diagnostic = service.connectStatus?.networkDiagnostic, !diagnostic.isEmpty {
        DisclosureGroup("Tunnel 连接诊断（脱敏）") {
          Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
        .font(.callout)
      }
    }
  }

  private var devicesView: some View {
    card {
      HStack {
        Label("已授权设备", systemImage: "iphone").font(.headline)
        Text("\(service.clients.count)").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button {
          Task { await service.refreshClients() }
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .controlSize(.small).disabled(service.managementBusy)
      }
      if service.clients.isEmpty {
        Text("暂无已授权设备，请在 T3 iOS 登录同一账号。")
          .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
      } else {
        ForEach(Array(service.clients.enumerated()), id: \.element.id) { index, client in
          if index > 0 { Divider() }
          HStack(spacing: 12) {
            Image(systemName: "iphone")
              .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
              Text(client.name).font(.body.weight(.medium))
              Label(client.connected ? "已连接" : "已授权 · 当前未连接",
                systemImage: client.connected ? "circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(client.connected ? Color.green : Color.secondary)
            }
            Spacer()
            Button("撤销授权", role: .destructive) { Task { await service.revokeClient(client.id) } }
              .controlSize(.small).disabled(service.managementBusy)
          }
          .padding(.vertical, 4)
        }
      }
    }
  }

  private func detailRow(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.caption).textSelection(.enabled)
    }
  }

  private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14, content: content)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
  }
}
