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
      if service.port != nil {
        connectView
        devicesView
      } else {
        card {
          Label(service.status, systemImage: "server.rack")
            .font(.callout).foregroundStyle(.secondary)
        }
      }

      DisclosureGroup("说明") {
        VStack(alignment: .leading, spacing: 8) {
          Text("T3 iOS 登录同一账号，开启通知与实时活动。")
          Text("仅支持 Tunnel；删除旧 LAN 环境，改用 Pi Mac · Tunnel。")
          Text("暂停上报不关闭隧道，退出绑定才会停止。")
          Text("公网连接与 iPhone 通知仍需实机验收。")
        }
        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
      }
      .font(.caption)

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
        Label("T3 Connect", systemImage: "network").font(.headline)
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
            Text(status.linked ? "已绑定" : (status.authorized == true ? "已授权 · 待绑定" : "未绑定"))
              .font(.body.weight(.medium))
            Text(
              status.linked
                ? (status.enabled ? "上报已开启" : "上报已暂停 · 隧道保持开启")
                : "手机登录同一账号即可连接。"
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }

        if status.linked {
          Text(status.tunnelDescription)
            .font(.caption).foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          if status.loginPending {
            Button("取消登录") { Task { await service.connectAction("cancel-login") } }
          } else if status.linked {
            Button(status.enabled ? "暂停上报" : "恢复上报") {
              Task { await service.connectAction(status.enabled ? "disable" : "enable") }
            }
            Button("重试恢复") { Task { await service.connectAction("retry-link") } }
            Button("重新授权") { Task { await service.connectAction("reauthorize") } }
            Spacer()
            Button("退出绑定", role: .destructive) { showConnectLogout = true }
          } else {
            Button("登录绑定") { showConnectConsent = true }
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
            detailRow("隧道连接", value: status.tunnelDescription)
            Text("Cloudflare 连接确认不代表公网请求、手机显示或通知已成功。")
              .font(.caption).foregroundStyle(.secondary)
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
            Text(
              "\(status.accepted)/\(status.requests) 已接受 · 排队 \(status.queuedDeliveries) · 服务端成功 \(status.successfulDeliveries) · 失败 \(status.failedDeliveries)"
            )
            .font(.caption.monospacedDigit())
            Text("服务端统计不代表手机已显示通知。")
              .font(.caption).foregroundStyle(.secondary)
          }
          .padding(.top, 10)
        } label: {
          Text("详情").font(.callout)
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
        DisclosureGroup("诊断（脱敏）") {
          Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
        .font(.callout)
      }
    }
  }

  private var connectedClients: [T3PairedClient] {
    service.clients.filter(\.connected)
  }

  private var devicesView: some View {
    card {
      HStack {
        Label("设备", systemImage: "iphone").font(.headline)
        Text("\(connectedClients.count)").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button {
          Task { await service.refreshClients() }
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .controlSize(.small).disabled(service.managementBusy)
      }
      if connectedClients.isEmpty {
        Text("暂无连接")
          .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
      } else {
        ForEach(Array(connectedClients.enumerated()), id: \.element.id) { index, client in
          if index > 0 { Divider() }
          HStack(spacing: 12) {
            Image(systemName: "iphone")
              .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
              Text(client.name).font(.body.weight(.medium))
              Label("已连接", systemImage: "circle.fill")
                .font(.caption)
                .foregroundStyle(Color.green)
            }
            Spacer()
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
