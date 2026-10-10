import SwiftUI

struct PS5GatewaySettingsView: View {
  @ObservedObject private var controller = PS5GatewayController.shared
  @State private var confirming = false

  private var statusColor: Color {
    switch controller.phase {
    case .active: return .green
    case .ready: return .blue
    case .error: return .orange
    default: return .secondary
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Image(systemName: "gamecontroller.fill")
          .font(.title2).foregroundStyle(.blue)
          .frame(width: 44, height: 44).background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 4) {
          Text("PS5 网关").font(.title3.bold())
          Text("通过 FlClash 转发 IPv4 流量").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text("实验性").font(.caption).foregroundStyle(.secondary)
      }
      GroupBox {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Label(controller.title, systemImage: controller.phase == .active ? "checkmark.circle.fill" : "circle.fill")
              .font(.headline).foregroundStyle(statusColor)
            Spacer()
            if controller.ownsSession {
              Button("停止网关") { controller.stop() }
                .disabled(controller.phase == .stopping)
            } else {
              Button("开启网关") { confirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(controller.phase != .ready)
            }
          }
          Text(controller.detail).font(.caption).foregroundStyle(.secondary)
          if [.checking, .authorizing, .starting, .stopping].contains(controller.phase) {
            ProgressView().controlSize(.small)
          }
          HStack {
            if !controller.tun.isEmpty {
              Label(controller.tun, systemImage: "network").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !controller.ownsSession {
              Button("重新检查") { controller.inspect() }
                .buttonStyle(.borderless).font(.caption)
                .disabled(controller.phase == .checking)
            }
          }
        }
        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
      }
      GroupBox("PS5 手动网络配置") {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top) {
            Text("网关").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
              if controller.addresses.isEmpty {
                Text("Mac 的局域网 IPv4").foregroundStyle(.secondary)
              } else {
                ForEach(controller.addresses, id: \.self) { address in
                  Text(address).textSelection(.enabled)
                }
              }
              Text("选择与 PS5 同网段的地址").font(.caption).foregroundStyle(.secondary)
            }
          }
          LabeledContent("DNS", value: "198.18.0.2").textSelection(.enabled)
          LabeledContent("代理 / MTU", value: "不使用 / 自动")
          Text("IP 和掩码按路由器网段设置；次 DNS 留空或填相同地址。")
            .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout).padding(6)
      }
      Text("请关闭 PS5 的 IPv6，并使用支持 UDP 的节点。")
        .font(.caption).foregroundStyle(.orange)
      DisclosureGroup("使用须知与诊断") {
        VStack(alignment: .leading, spacing: 10) {
          Text("应用内停止或退出会恢复本会话修改的参数；FlClash 核心、TUN 或网络参数变化也会结束会话。授权只使用系统弹窗，不保存密码、不安装免密码权限。")
          Text("运行中仅代表守护进程确认 TUN 与转发参数正常，不代表 PS5 已连接或游戏 UDP 已验证。请在 FlClash 中确认 PS5 的 TCP / UDP 使用代理节点。")
          Text("转发作用于整台 Mac，仅在可信局域网使用。这不是无泄漏 VPN；路由例外和 IPv6 仍可能旁路。保持 Mac 不休眠。")
          Text("强杀守护进程或系统崩溃无法保证恢复。恢复异常时不要盲目覆盖其他服务的参数；先检查 net.inet.ip.forwarding 与 net.inet.ip.redirect 的原值。")
          if !controller.diagnostics.isEmpty {
            Divider()
            Text(controller.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
        }
        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
      }
    }
    .task { if !controller.ownsSession { controller.inspect() } }
    .confirmationDialog("开启 PS5 网关？", isPresented: $confirming, titleVisibility: .visible) {
      Button("授权并开启") { controller.start() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("将临时修改整台 Mac 的 IPv4 转发参数，仅在可信网络使用。下一步是系统管理员授权；停止或退出应用时恢复参数。")
    }
  }
}
