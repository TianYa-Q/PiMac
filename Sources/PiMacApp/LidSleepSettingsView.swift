import SwiftUI

/// 状态只从系统事实和会话阶段派生，不能用勾选状态代表已经生效。
enum LidSleepStatusKind: Equatable {
  case checking, applying, attention, active, battery, off

  init(state: LidSleepSystemState, requested: Bool, enabled: Bool, busy: Bool) {
    if busy {
      self = .applying
    } else {
      switch state {
      case .checking: self = .checking
      case .failed: self = .attention
      case .available(let onAC, let disabled):
        if disabled != (requested && onAC) || (requested && !enabled) {
          self = .attention
        } else if !requested {
          self = .off
        } else {
          self = onAC ? .active : .battery
        }
      }
    }
  }

  var title: String {
    switch self {
    case .checking: return "正在读取系统状态"
    case .applying: return "正在更新休眠策略"
    case .attention: return "需要处理"
    case .active: return "合盖运行已生效"
    case .battery: return "电池供电，允许正常休眠"
    case .off: return "已关闭，允许正常休眠"
    }
  }

  var symbol: String {
    switch self {
    case .checking, .applying: return "arrow.triangle.2.circlepath"
    case .attention: return "exclamationmark.triangle.fill"
    case .active: return "checkmark.shield.fill"
    case .battery: return "battery.100percent"
    case .off: return "moon.zzz.fill"
    }
  }

  var color: Color {
    switch self {
    case .checking, .applying: return .accentColor
    case .attention: return .orange
    case .active: return .green
    case .battery, .off: return .secondary
    }
  }
}

struct LidSleepStatusCard: View {
  let state: LidSleepSystemState
  let requested: Bool
  let enabled: Bool
  let busy: Bool

  private var kind: LidSleepStatusKind {
    LidSleepStatusKind(state: state, requested: requested, enabled: enabled, busy: busy)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: kind.symbol)
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(kind.color)
          .frame(width: 32, height: 32)
          .background(kind.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 4) {
          Text(kind.title).font(.system(.body, weight: .semibold))
          Text(state.managementDescription(requested: requested, enabled: enabled, busy: busy))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        if busy || kind == .checking {
          ProgressView().controlSize(.small)
        }
      }
      Divider()
      HStack {
        Text("当前电源").foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text(state.powerDescription)
      }
      HStack(alignment: .firstTextBaseline) {
        Text("系统休眠").foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text(state.sleepDescription).multilineTextAlignment(.trailing)
      }
    }
    .font(.caption)
    .padding(16)
    .background(kind.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12).strokeBorder(kind.color.opacity(0.16))
    }
    .accessibilityElement(children: .combine)
  }
}

struct LidSleepSettingsView: View {
  @ObservedObject private var controller = LidSleepController.shared
  @State private var confirming = false
  @State private var confirmingAccess = false
  @State private var installingAccess = true
  @AppStorage(LidSleepController.launchPreferenceKey) private var enableOnLaunch = false

  var body: some View {
    GroupBox("插电合盖运行") {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("合盖保持运行").font(.system(.body, weight: .semibold))
            Text("仅插电时生效，拔电后恢复正常休眠")
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
          Toggle(
            "合盖保持运行",
            isOn: Binding(
              get: { controller.requested },
              set: { value in
                if value { confirming = true } else { controller.setEnabled(false) }
              })
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(controller.busy)
        }

        VStack(alignment: .leading, spacing: 10) {
          LidSleepStatusCard(
            state: controller.systemState, requested: controller.requested,
            enabled: controller.enabled, busy: controller.busy)
          if controller.requested && !controller.enabled && !controller.busy {
            Button("重试开启", systemImage: "arrow.clockwise") { controller.setEnabled(true) }
              .controlSize(.small)
          } else if !controller.requested, !controller.busy,
            case .available(_, true) = controller.systemState
          {
            Button("恢复正常休眠", systemImage: "arrow.clockwise") { controller.setEnabled(false) }
              .controlSize(.small)
          }
        }

        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Text("启动时自动开启")
            Spacer(minLength: 12)
            Toggle("启动时自动开启", isOn: $enableOnLaunch)
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.small)
              .disabled(controller.busy)
          }
          Divider()
          HStack(spacing: 10) {
            Image(systemName: "lock.shield")
              .foregroundStyle(.secondary)
              .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
              Text("免密码权限")
              Text(
                controller.passwordlessConfigured
                  ? "已配置，无需重复授权"
                  : (controller.passwordlessAvailable ? "已有权限，无需重复配置" : "配置后可自动应用休眠策略")
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if controller.passwordlessConfigured || !controller.passwordlessAvailable {
              Button(controller.passwordlessConfigured ? "移除…" : "配置…") {
                installingAccess = !controller.passwordlessConfigured
                confirmingAccess = true
              }
              .controlSize(.small)
              .disabled(
                controller.busy || (!controller.passwordlessConfigured && controller.enabled)
              )
              .help("配置前请先关闭合盖运行；移除权限需要管理员授权。")
            } else {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                .accessibilityLabel("已有免密码权限")
            }
          }
        }

        VStack(alignment: .leading, spacing: 12) {
          Label {
            Text("保持通风，请勿合盖后放入包中。")
          } icon: {
            Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
          }
          .foregroundStyle(.secondary)
          DisclosureGroup("运行详情与说明") {
            VStack(alignment: .leading, spacing: 8) {
              Text("运行详情：\(controller.status)")
              Text("仅插电生效，无需外接显示器；拔电、关闭或退出后约 10 秒内恢复系统休眠开关。")
              Text("开启表示允许 PiMac 接管；是否生效以当前状态为准，失败不会取消开关。")
              Text("运行期间也会接管已有的禁用状态。退出后不再持续管理，其他应用的休眠断言仍由系统处理。")
              Text("合盖时请求关闭所有屏幕，开盖后可用键盘或触控板唤醒。仅插电不保证唤醒已合盖的 Mac。")
              Text("禁用休眠也会阻止手动休眠。请勿与其他防休眠工具同时使用。")
            }
            .foregroundStyle(.secondary).padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
        .font(.caption)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
    }
    .task {
      while !Task.isCancelled {
        await controller.refreshSystemState()
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
    }
    .confirmationDialog("允许插电合盖运行？", isPresented: $confirming, titleVisibility: .visible) {
      Button(controller.passwordlessAvailable || controller.passwordlessConfigured ? "开启" : "授权并开启")
      { controller.setEnabled(true) }
      Button("取消", role: .cancel) {}
    } message: {
      Text(
        "PiMac 将接管系统休眠开关（包括已有的禁用状态）：插电禁止休眠，拔电、关闭或退出后恢复。未配置免密码权限时需要管理员授权。成功开启后，下次启动自动尝试开启。请确保散热，勿与其他防休眠工具同时使用。"
      )
    }
    .confirmationDialog(
      installingAccess ? "配置一次授权免密码开启？" : "移除免密码权限？",
      isPresented: $confirmingAccess, titleVisibility: .visible
    ) {
      Button(installingAccess ? "授权、配置并开启" : "授权并移除") {
        controller.configurePasswordlessAccess(install: installingAccess)
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(
        installingAccess
          ? "将为当前账户安装一条 sudoers 规则，仅允许免密码执行 pmset -a disablesleep 0 和 1。其他以此账户运行的程序也能切换此开关，但不能借此执行任意管理员命令。不保存密码，不安装系统服务。"
          : "将关闭合盖运行及自动开启，并删除 Pi Mac 为当前账户安装的规则。移除需要管理员授权。")
    }
  }
}
