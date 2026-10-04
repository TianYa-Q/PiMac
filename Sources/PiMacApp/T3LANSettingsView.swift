import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct T3LANSettingsView: View {
  @ObservedObject var service: T3BridgeService
  @State private var host = ""
  @State private var port = "3773"
  @State private var interfaces: [T3NetworkEndpoint.Interface] = []
  @State private var pairingQR: NSImage?
  private var endpoint: T3NetworkEndpoint? {
    guard let port = Int(port) else { return nil }
    return try? T3NetworkEndpoint(host: host, port: port)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("局域网直连", systemImage: "wifi").font(.headline)
        Spacer()
        Label(
          service.lanStateKnown ? (service.lanURL == nil ? "已关闭" : "正在监听") : "状态待确认",
          systemImage: service.lanStateKnown ? "circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(service.lanStateKnown ? Color.secondary : Color.orange)
      }
      if !service.lanStateKnown {
        Text("上一次请求未能确认结果。先读取实际状态，再更改入口或生成凭据。")
          .font(.caption).foregroundStyle(.orange)
      }
      if let url = service.lanURL {
        Text(url.absoluteString).font(.callout.monospaced()).textSelection(.enabled)
        Text("同一局域网内不经过 T3 Relay 或 Cloudflare；使用同一个 Server 和上游认证。")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("复制地址") { copy(url.absoluteString) }
          Button("生成配对凭据") { Task { await service.generateLANPairing() } }
            .disabled(!service.lanStateKnown)
          Spacer()
          Button("关闭直连") { Task { await service.configureLAN(nil) } }
            .disabled(!service.lanStateKnown)
        }
        if let pairing = service.lanPairing {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            pairingView(pairing, base: url, now: context.date)
          }
        }
      } else {
        Text("默认自动开启；手动关闭后会记住。仅绑定私有 IPv4 地址，不开放本机管理接口。")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Picker("网卡", selection: $host) {
            Text("选择网卡").tag("")
            ForEach(interfaces) { item in
              Text("\(item.name) · \(item.address)").tag(item.address)
            }
          }
          Button {
            refreshInterfaces()
          } label: {
            Image(systemName: "arrow.clockwise")
          }.help("重新扫描网卡")
        }
        if interfaces.isEmpty {
          Text("未找到可用私有 IPv4 网卡。请连接 Wi-Fi 或以太网后重新扫描。")
            .font(.caption).foregroundStyle(.orange)
        }
        HStack {
          TextField("端口（1024–65535）", text: $port).frame(width: 150)
          Button("开启局域网直连") {
            if let endpoint { Task { await service.configureLAN(endpoint) } }
          }
          .disabled(
            !service.lanStateKnown || endpoint == nil
              || !interfaces.contains(where: { $0.address == host }))
        }
      }
      HStack {
        Button("刷新入口状态") { Task { await service.refreshLAN() } }
        if service.lanBusy { ProgressView().controlSize(.small) }
      }
      if !service.lanMessage.isEmpty {
        Text(service.lanMessage).font(.caption).foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Text("局域网 HTTP 不加密，仅在可信网络使用；不要做公网端口转发。IP 改变后需重新选择网卡。关闭入口不会撤销已经配对的设备凭据。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .controlSize(.small)
    .disabled(service.lanBusy)
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    .onAppear { refreshInterfaces() }
    .onChange(of: service.lanPairing?.id, initial: true) { _, _ in
      pairingQR = service.lanPairing.flatMap { pairing in
        service.lanURL.flatMap { qrImage(pairing.url(base: $0).absoluteString) }
      }
    }

  }

  @ViewBuilder
  private func pairingView(_ pairing: T3Pairing, base: URL, now: Date) -> some View {
    if pairing.isValid(at: now), let expiry = pairing.expiry {
      let link = pairing.url(base: base)
      HStack(alignment: .top, spacing: 16) {
        if let image = pairingQR {
          Image(nsImage: image).interpolation(.none).resizable()
            .frame(width: 144, height: 144).padding(8).background(.white)
            .accessibilityLabel("局域网配对二维码，仅供自己的设备使用")
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("临时配对凭据").font(.callout.weight(.medium))
          Text("有效期至 \(expiry.formatted(date: .omitted, time: .shortened))")
            .font(.caption.monospacedDigit())
          Button("复制配对链接") {
            if pairing.isValid(at: Date()) { copy(link.absoluteString) }
          }
          Button("复制配对码") {
            if pairing.isValid(at: Date()) { copy(pairing.credential) }
          }
          Text("在 T3 iOS 手动添加局域网环境；支持配对链接的客户端可扫码。勿分享凭据。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    } else {
      Label("配对凭据已过期，请重新生成。", systemImage: "clock.badge.exclamationmark")
        .font(.caption).foregroundStyle(.orange)
    }
  }

  private func refreshInterfaces() {
    interfaces = T3NetworkEndpoint.interfaces()
    if !interfaces.contains(where: { $0.address == host }) {
      host =
        interfaces.first(where: { $0.name == "en0" })?.address ?? interfaces.first?.address ?? ""
    }
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  private func qrImage(_ value: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
      let image = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
}
