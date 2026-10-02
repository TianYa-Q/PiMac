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
  @State private var revealCode = false
  @State private var clipboardChange: Int?
  @State private var ticks = 0
  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  private var endpoint: T3NetworkEndpoint? {
    guard let number = Int(port) else { return nil }
    return try? T3NetworkEndpoint(host: host, port: number)
  }

  var body: some View {
    GroupBox("T3 iOS 连接") {
      VStack(alignment: .leading, spacing: 12) {
        Text("可读取历史与实时会话，并发送文字及 PNG/JPEG/WebP 图片。忙碌时拒绝发送，不切换桌面选择。取消任务和新建会话尚未支持。")
        Text("已配对的手机可在 Mac 上执行 Pi 任务；图片每条最多 8 张、合计 8 MiB。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Toggle("允许手机访问（可信局域网 IPv4）", isOn: $allowNetwork)
          .disabled(service.isEnabled)
        if allowNetwork {
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
          Text("局域网 HTTP 不加密，会话和凭据可被网络监听。不要做路由器端口转发。")
            .font(.caption).foregroundStyle(.orange)
        }
        HStack {
          Button(service.isStopping ? "正在停止…" : service.isEnabled ? "停止连接" : "启动连接") {
            if service.isEnabled {
              service.disable()
              allowNetwork = false
            } else if allowNetwork {
              showWarning = true
            } else {
              service.enable(workspace: workspace, network: nil)
            }
          }.disabled(service.isStopping || (!service.isEnabled && allowNetwork && endpoint == nil))
          Text(service.status).font(.caption).foregroundStyle(.secondary)
        }
        if let url = service.connectionURL {
          HStack {
            Text("\(service.publicURL == nil ? "仅本机" : "手机连接地址")：")
            Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
            Spacer()
            Button("复制地址") { copy(url.absoluteString, secret: false) }
          }
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
        if service.port != nil {
          HStack {
            Text("已授权设备（\(service.clients.count)）").font(.headline)
            Spacer()
            Button("刷新") { Task { await service.refreshClients() } }.disabled(
              service.managementBusy)
          }
          if let diagnostics = service.readDiagnostics {
            VStack(alignment: .leading, spacing: 4) {
              Text("列表链路诊断（本次服务累计）").font(.caption.bold())
              Text(diagnostics.summary).font(.caption.monospaced())
              Text("已配对或 WebSocket 已连接不代表列表已加载；服务端生成快照也不代表手机已显示。")
                .font(.caption).foregroundStyle(.secondary)
            }.textSelection(.enabled)
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
      .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
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
        Text("一次性配对码不是六位数字；使用后失效。不要截图或分享给他人。")
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
