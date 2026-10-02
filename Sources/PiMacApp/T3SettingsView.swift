import AppKit
import Combine
import CoreImage
import SwiftUI

struct T3SettingsView: View {
  @ObservedObject var service: T3BridgeService
  let workspace: WorkspaceModel
  @State private var allowNetwork = false
  @State private var host = ""
  @State private var port = "3773"
  @State private var label = "我的 iPhone"
  @State private var showAddDevice = false
  @State private var interfaces: [T3NetworkEndpoint.Interface] = []
  @State private var showWarning = false
  @State private var showConnectConsent = false
  @State private var showConnectLogout = false
  @State private var revealCode = false
  @State private var clipboardChange: Int?
  @State private var ticks = 0
  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  private var endpoint: T3NetworkEndpoint? {
    guard let number = Int(port) else { return nil }
    return try? T3NetworkEndpoint(host: host, port: number)
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          Image(systemName: "iphone.and.arrow.forward")
            .font(.title2).foregroundStyle(.blue)
            .frame(width: 40, height: 40)
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
          VStack(alignment: .leading, spacing: 4) {
            Text("T3 iOS 连接").font(.headline)
            Text("在 iPhone 上查看会话、发送消息与管理任务")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Label(service.publicURL != nil ? "局域网已开启" : "仅本机",
                systemImage: service.publicURL != nil ? "circle.fill" : "lock.fill")
            .font(.caption)
            .foregroundStyle(service.publicURL != nil ? Color.green : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
        Divider()
        DisclosureGroup("功能与兼容性说明") {
          VStack(alignment: .leading, spacing: 8) {
            Text("桌面、手机和 Telegram 共用线程与任务状态。支持读取历史与实时会话、选择模型、在已有项目中新建会话及取消任务。")
            Text("支持文字及 PNG/JPEG/WebP 图片，每条最多 8 张、合计 8 MiB。执行中追加消息、worktree 和任意文件上传暂不支持。")
            Text("已配对手机可在 Mac 上执行 Pi 任务。Server 随应用启动，关闭手机访问不会停止桌面任务。旧 JSONL 历史不会自动接管，旧云绑定不自动迁移或撤销。")
          }
          .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
        if !service.isEnabled {
          Toggle("允许手机访问", isOn: $allowNetwork)
            .toggleStyle(.switch)
        }
        if allowNetwork && !service.isEnabled {
          if !interfaces.isEmpty {
            HStack {
              Text("本机 IP")
              Picker("本机 IP", selection: $host) {
                ForEach(interfaces) { item in
                  Text("\(item.address) · \(item.name)").tag(item.address)
                }
              }.labelsHidden()
            }.disabled(service.isEnabled)
          }
          HStack {
            TextField("本机私有 IPv4 地址", text: $host)
            TextField("端口", text: $port).frame(width: 90)
          }.textFieldStyle(.roundedBorder).disabled(service.isEnabled)
          Text("确认启动后会记住此 IP 和端口，软件重启会自动恢复；手动停止连接或取消允许访问后不再恢复。")
            .font(.caption).foregroundStyle(.secondary)
        }
        if allowNetwork {
          Label("仅限可信局域网：HTTP 不加密，请勿进行路由器端口转发。", systemImage: "exclamationmark.shield")
            .font(.caption).foregroundStyle(.orange)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        HStack {
          Button(
            service.isStopping
              ? "正在停止…" : service.isEnabled ? "关闭局域网访问" : allowNetwork ? "开启局域网访问" : "启动本机 Server"
          ) {
            if service.isEnabled {
              service.disable()
              allowNetwork = false
            } else if allowNetwork {
              showWarning = true
            } else {
              service.enable(workspace: workspace, network: nil)
            }
          }.disabled(
            service.isStopping || (!service.isEnabled && allowNetwork && endpoint == nil)
              || (!allowNetwork && service.serverURL != nil))
          Text(service.status).font(.caption).foregroundStyle(.secondary)
        }
        if let url = service.connectionURL {
          HStack {
            VStack(alignment: .leading, spacing: 5) {
              Text(service.publicURL == nil ? "本机地址" : "手机连接地址")
                .font(.caption).foregroundStyle(.secondary)
              Text(url.absoluteString).font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            }
            Spacer()
            Button { copy(url.absoluteString, secret: false) } label: {
              Label("复制地址", systemImage: "doc.on.doc")
            }
          }
          .padding(12)
          .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        if service.publicURL != nil {
          Divider()
          DisclosureGroup("添加设备", isExpanded: $showAddDevice) {
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                TextField("设备名称", text: $label).textFieldStyle(.roundedBorder)
                Button(service.pairing == nil ? "生成一次性配对码" : "重新生成") {
                  Task { await service.generatePairing(label: label) }
                }.disabled(service.managementBusy)
              }
              if let pairing = service.pairing, let base = service.publicURL {
                pairingView(pairing, base: base)
              }
            }
            .padding(.top, 8)
          }
        }
        if let diagnostic = service.connectStatus?.networkDiagnostic, !diagnostic.isEmpty {
          Text("局域网连接诊断：\(diagnostic)")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if service.port != nil {
          connectView
          HStack {
            Text("已授权设备（\(service.clients.count)）").font(.headline)
            Spacer()
            Button("刷新") { Task { await service.refreshClients() } }.disabled(
              service.managementBusy)
          }
          ForEach(service.clients) { client in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
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
        if !service.managementMessage.isEmpty {
          Text(service.managementMessage).font(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading).padding(10)
    }
    .task {
      interfaces = T3NetworkEndpoint.interfaces()
      if let saved = service.rememberedNetwork {
        allowNetwork = true
        host = saved.host
        port = String(saved.port)
      } else if host.isEmpty {
        host = interfaces.first?.address ?? ""
      }
      syncNetwork(service.publicURL)
    }
    .onChange(of: allowNetwork) { _, allowed in
      if !allowed { service.forgetNetworkPreference() }
    }
    .onChange(of: service.publicURL) { _, url in syncNetwork(url) }
    .task(id: service.port) { await service.refreshClients() }
    .onReceive(timer) { _ in
      service.expirePairing()
      ticks += 1
      if ticks % 3 == 0 { Task { await service.refreshClients() } }
    }
    .onChange(of: showAddDevice) { _, expanded in
      if !expanded {
        revealCode = false
        clearSecretClipboard()
        Task { await service.discardPairing() }
      }
    }
    .onChange(of: service.pairing?.id) { _, _ in
      revealCode = false
      clearSecretClipboard()
    }
    .onDisappear {
      clearSecretClipboard()
      Task { await service.discardPairing() }
    }
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
      Text("不会删除局域网配对或会话。需要访问官方服务才能确认撤销；失败时先停止状态上报，保留凭据供手动重试。")
    }
    .confirmationDialog("确认向所选网络开放会话？", isPresented: $showWarning, titleVisibility: .visible) {
      Button("确认启动连接") {
        guard let endpoint else { return }
        service.enable(workspace: workspace, network: endpoint)
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(
        "普通局域网 HTTP 不加密。仅在可信局域网使用。手机将能读取项目目录和历史会话正文，并可发送消息执行 Pi 任务。确认后会记住此 IP 和端口，软件重启时自动恢复，直到手动停止连接或取消允许访问。"
      )
    }
  }

  private var connectView: some View {
    GroupBox("T3 Connect 与 Cloudflare Tunnel（官方 Server）") {
      VStack(alignment: .leading, spacing: 8) {
        Text("官方 Server 管理账号、隧道与通知；原生 Workspace 仍独占 Pi 进程和会话写入。暂停上报只暂停通知，不会关闭隧道；停止连接或退出绑定才会停止隧道。")
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
          "手机须在 T3 iOS 登录同一账号，并开启系统通知、任务完成通知及锁屏实时活动。公网聊天走官方托管隧道；LAN 配对仍可独立使用。尚未完成 App Store 客户端与真实通知验收。"
        )
        .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder private func pairingView(_ pairing: T3Pairing, base: URL) -> some View {
    let url = pairing.url(base: base)
    HStack(alignment: .top, spacing: 16) {
      if let qr = qrCode(url.absoluteString) {
        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 148, height: 148)
          .padding(12).background(Color.white)
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("在 T3 iOS 添加服务器时填写地址及配对码，或用 App 内置扫描器扫 QR；不要用浏览器打开此链接。")
          .font(.caption)
        Text("一次性配对码为 12 位字母和数字；使用后失效。不要截图或分享给他人。")
          .font(.caption).foregroundStyle(.secondary)
        if let expiry = pairing.expiry {
          Text("剩余 \(max(0, Int(expiry.timeIntervalSinceNow))) 秒；关闭设置即撤销未使用的码。")
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("复制配对码") { copy(pairing.credential, secret: true) }
          Button("复制配对链接") { copy(url.absoluteString, secret: true) }
        }
        Toggle("显示完整配对码", isOn: $revealCode).font(.caption)
        if revealCode {
          Text(pairing.credential).font(.caption.monospaced()).textSelection(.enabled)
        }
        Button("撤销此配对码") { Task { await service.discardPairing() } }
          .disabled(service.managementBusy)
      }
    }
  }

  private func syncNetwork(_ url: URL?) {
    guard let url else { return }
    allowNetwork = true
    host = url.host ?? ""
    port = String(url.port ?? 3773)
  }

  private func qrCode(_ text: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
      let cg = CIContext().createCGImage(image, from: image.extent)
    else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }

  private func copy(_ text: String, secret: Bool) {
    let clipboard = NSPasteboard.general
    clipboard.clearContents()
    clipboard.setString(text, forType: .string)
    clipboardChange = secret ? clipboard.changeCount : nil
  }

  private func clearSecretClipboard() {
    if let count = clipboardChange, NSPasteboard.general.changeCount == count {
      NSPasteboard.general.clearContents()
    }
    clipboardChange = nil
  }
}
