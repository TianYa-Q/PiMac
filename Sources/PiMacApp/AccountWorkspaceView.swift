import SwiftUI

/// 单一工作台承载账户、授权、记录和诊断，操作不会销毁或重新呈现 sheet。
struct AccountWorkspaceView: View {
  @ObservedObject var model: AccountWorkspaceModel
  let close: () -> Void
  @State private var query = ""
  @State private var loginName = ""
  @State private var deletingAccount: String?
  @State private var reauthorizing = false

  private var accounts: [AccountWorkspaceSnapshot.Account] {
    (model.snapshot?.accounts ?? []).filter {
      query.isEmpty || $0.name.localizedStandardContains(query)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("账户工作台").font(.system(size: 20, weight: .semibold))
          Text("管理授权、额度与新会话默认账户").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Picker(
          "凭据类型",
          selection: Binding(get: { model.provider }, set: { model.selectProvider($0) })
        ) {
          Text("Codex Legacy").tag(AccountUsageProvider.legacyCodex)
          Text("ChatGPT").tag(AccountUsageProvider.chatGPT)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 230).disabled(model.isBusy)
      }
      .padding(24)
      Divider()
      HStack(spacing: 0) {
        sidebar.frame(width: 224)
        Divider()
        VStack(spacing: 0) {
          ScrollView {
            Group {
              switch model.page {
              case .account:
                if let account = model.selectedAccount { accountDetail(account) }
              case .add: addAccount
              case .activity: activity
              case .diagnostics: diagnostics
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
          }
          if let account = model.selectedAccount {
            Divider()
            accountActions(account).padding(.horizontal, 20).padding(.vertical, 12)
          }
        }
        .frame(maxWidth: .infinity)
      }
      .frame(height: 460)
      Divider()
      HStack(spacing: 10) {
        if model.isWorking { ProgressView().controlSize(.small) }
        Image(systemName: model.isError ? "exclamationmark.circle.fill" : "info.circle")
          .foregroundStyle(model.isError ? Color.orange : Color.secondary)
        Text(model.message.isEmpty ? "账户设置不改变正在运行的会话。" : model.message)
          .font(.caption).foregroundStyle(model.isError ? Color.orange : Color.secondary)
          .lineLimit(2).textSelection(.enabled)
        Spacer(minLength: 8)
        if model.isError {
          Button("重新读取") { model.perform(.snapshot) }
            .disabled(model.isBusy)
        }
        Button("关闭", action: close).keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 20).frame(height: 62)
    }
    .frame(width: 800)
    .background(Color(nsColor: .windowBackgroundColor))
    .task { model.load() }
    .interactiveDismissDisabled()
    .onChange(of: model.page) {
      deletingAccount = nil
      reauthorizing = false
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("账户").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Text("\(model.snapshot?.accounts.count ?? 0)").font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
      }
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索账户", text: $query).textFieldStyle(.plain)
      }
      .font(.callout).padding(8)
      .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
      ScrollView {
        VStack(spacing: 4) {
          if model.snapshot == nil {
            Text(model.isWorking ? "正在加载账户…" : "账户尚未读取")
              .font(.caption).foregroundStyle(.secondary).padding(.vertical, 20)
          } else if accounts.isEmpty {
            Text(query.isEmpty ? "尚未添加账户" : "没有匹配的账户")
              .font(.caption).foregroundStyle(.secondary).padding(.vertical, 20)
          }
          ForEach(accounts) { account in
            navigation(.account(account.name)) {
              HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                  .font(.system(size: 26)).foregroundStyle(Color.accentColor.opacity(0.75))
                VStack(alignment: .leading, spacing: 4) {
                  Text(account.name).font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).help(account.name)
                  Text(account.isDefault ? "新会话默认" : account.isVisible ? "已显示" : "已隐藏 · 暂停监测")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if account.error != nil {
                  Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }
              }
            }
          }
        }
      }
      Spacer(minLength: 0)
      navigation(.add) { Label("添加账户", systemImage: "plus.circle") }
      Divider()
      navigation(.activity) { Label("自动激活记录", systemImage: "clock.arrow.circlepath") }
      navigation(.diagnostics) { Label("监测与诊断", systemImage: "waveform.path.ecg") }
    }
    .padding(16)
    .background(Color.primary.opacity(0.018))
  }

  private func navigation<Content: View>(
    _ page: AccountWorkspaceModel.Page, @ViewBuilder content: () -> Content
  ) -> some View {
    Button {
      model.page = page
    } label: {
      content().font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading).padding(9)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      model.page == page ? Color.accentColor.opacity(0.12) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .disabled(model.isAuthorizing)
  }

  private func accountDetail(_ account: AccountWorkspaceSnapshot.Account) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Text(account.name).font(.title2.weight(.semibold)).textSelection(.enabled)
            .lineLimit(2).truncationMode(.middle)
          Text(account.isDefault ? "新会话默认账户" : "已授权账户")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          model.perform(.refresh)
        } label: {
          Label("刷新额度", systemImage: "arrow.clockwise")
        }
        .disabled(model.isBusy)
      }
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          quota("5 小时额度", window: account.primary)
          quota("每周额度", window: account.secondary)
        }
        if let error = account.error {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
        if let captured = account.capturedAt {
          Text(
            "更新于 \(Date(timeIntervalSince1970: captured / 1000).formatted(date: .omitted, time: .shortened)) · 剩余额度"
          )
          .font(.caption).foregroundStyle(.secondary)
        } else {
          Text("尚无额度数据，点击刷新查询。").font(.caption).foregroundStyle(.secondary)
        }
      }
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .center, spacing: 18) {
          VStack(alignment: .leading, spacing: 5) {
            Text("新会话默认").font(.callout.weight(.medium))
            Text("仅用于之后创建的会话，现有会话不变。")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          if account.isDefault {
            Label("已设为默认", systemImage: "checkmark.circle.fill")
              .font(.caption).foregroundStyle(Color.accentColor)
          } else {
            Button("设为默认") { model.perform(.setDefault(account.name)) }
              .disabled(model.isBusy)
          }
        }
        Divider()
        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 5) {
            Text("展示额度并自动监测").font(.callout.weight(.medium))
            Text("同步到侧栏与手机端。关闭后暂停查询及自动激活。")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          Toggle(
            "展示额度并自动监测",
            isOn: Binding(
              get: { account.isVisible },
              set: { model.perform(.visibility(account.name, $0)) })
          )
          .labelsHidden().toggleStyle(.switch).disabled(model.isBusy)
        }
      }
      .padding(16)
      .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }
  }

  private func accountActions(_ account: AccountWorkspaceSnapshot.Account) -> some View {
    Group {
      if reauthorizing {
        VStack(alignment: .leading, spacing: 10) {
          Text("重新授权将替换此账户的本机凭据，使用它的旧会话也可能受影响。")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("取消") { reauthorizing = false }
            Button("继续重新授权") { model.startLogin(name: account.name, replacing: true) }
              .disabled(model.isBusy)
          }
        }
      } else if deletingAccount == account.name {
        VStack(alignment: .leading, spacing: 10) {
          Text("确认删除 \(account.name)？").font(.callout.weight(.semibold))
          Text("将删除本机托管凭据。使用此账户的旧会话可能无法继续请求；此操作不可撤销。")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("取消") { deletingAccount = nil }
            Button("确认删除", role: .destructive) {
              deletingAccount = nil
              model.perform(.delete(account.name))
            }
            .disabled(model.isBusy)
          }
        }
      } else {
        HStack {
          Text(account.isDefault ? "默认账户不可删除，请先将其他账户设为默认。" : "仅删除本机凭据，不注销远端账户。")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("重新授权…") { reauthorizing = true }.disabled(model.isBusy)
          Button("删除账户…", role: .destructive) { deletingAccount = account.name }
            .disabled(account.isDefault || model.isBusy)
        }
      }
    }
  }

  private func quota(_ title: String, window: AccountWorkspaceSnapshot.Window?) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(window.map { "\(Int($0.remainingPercent))%" } ?? "—")
        .font(.system(size: 24, weight: .semibold, design: .rounded))
      if let window {
        ProgressView(value: window.remainingPercent, total: 100).tint(
          window.remainingPercent <= 10 ? .orange : .accentColor
        )
        .frame(height: 4)
        if let reset = window.resetAt {
          Text(
            "重置 \(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))"
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
      } else {
        Text("未查询或暂不可用").font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
  }

  private var addAccount: some View {
    VStack(alignment: .leading, spacing: 22) {
      Text(model.isAuthorizing ? model.authorizationTitle : "添加账户")
        .font(.title2.weight(.semibold))
      Text("使用 Pi 官方 OAuth 授权，凭据保存在本机。")
        .font(.callout).foregroundStyle(.secondary)
      if model.isAuthorizing {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("等待完成授权").font(.headline)
        }
        Text(model.authorizationMessage).font(.callout).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if let url = model.authorizationURL { Link("重新打开授权页面", destination: url) }
        if let request = model.authorizationRequest {
          AccountAuthorizationRequestView(model: model, request: request).id(request.id)
        }
        Button("取消授权") { model.cancelLogin() }
      } else {
        VStack(alignment: .leading, spacing: 10) {
          Text("账户名称").font(.callout.weight(.medium))
          TextField("例如 work 或 personal", text: $loginName)
            .textFieldStyle(.roundedBorder)
          Text("1–64 位字母、数字、点、下划线或连字符。名称不可重复。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Button {
          model.startLogin(name: loginName, replacing: false)
        } label: {
          Label("继续并打开官方授权", systemImage: "arrow.up.forward.square")
        }
        .buttonStyle(.borderedProminent).disabled(model.isBusy || loginName.isEmpty)
        Divider()
        Label("授权成功后设为新会话默认，不影响现有会话。", systemImage: "checkmark.shield")
        Label("Legacy 与新版凭据独立保存，不覆盖 API Key。", systemImage: "lock")
      }
    }
    .font(.callout)
  }

  private var activity: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("自动激活记录").font(.title2.weight(.semibold))
        Spacer()
        Button("更新记录") { model.perform(.snapshot) }
          .disabled(model.isBusy)
      }
      Text("后台对符合条件的满额窗口发送激活请求。发送成功不代表已验证窗口计时。最近 30 条，按时间倒序。")
        .font(.caption).foregroundStyle(.secondary)
      if model.snapshot?.records.isEmpty == true {
        ContentUnavailableView(
          "尚无激活记录", systemImage: "clock", description: Text("后台产生激活请求后，结果会显示在这里。"))
      }
      ForEach(model.snapshot?.records ?? []) { record in
        HStack(alignment: .top, spacing: 10) {
          Image(
            systemName: record.status == "success"
              ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
          )
          .foregroundStyle(record.status == "success" ? Color.green : Color.orange)
          VStack(alignment: .leading, spacing: 4) {
            Text("\(record.accountName) · \(record.windowKind)").font(.callout.weight(.medium))
            Text(record.status == "success" ? "激活请求已发送（未验证计时）" : "请求失败，后台将按策略重试")
              .font(.caption).foregroundStyle(.secondary)
            Text(Date(timeIntervalSince1970: record.timestamp / 1000).formatted())
              .font(.caption2).foregroundStyle(.secondary)
          }
          Spacer()
        }
        Divider()
      }
    }
  }

  private var diagnostics: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("监测与诊断").font(.title2.weight(.semibold))
      Label(
        model.snapshot?.monitorRunning == true ? "后台监测运行中" : "后台监测未确认运行",
        systemImage: model.snapshot?.monitorRunning == true
          ? "checkmark.circle.fill" : "exclamationmark.circle"
      )
      .foregroundStyle(model.snapshot?.monitorRunning == true ? Color.green : Color.orange)
      Text("监测独立于 Pi 会话运行，定期查询已显示账户的额度，并按策略自动激活。隐藏账户不参与查询或激活。")
        .font(.callout).foregroundStyle(.secondary)
      Button("立即检查所有可见账户") { model.perform(.health) }
        .buttonStyle(.borderedProminent).disabled(model.isBusy)
      ForEach((model.snapshot?.accounts ?? []).filter(\.isVisible)) { account in
        HStack(alignment: .top, spacing: 10) {
          Image(
            systemName: account.error != nil
              ? "exclamationmark.circle" : account.capturedAt == nil ? "clock" : "checkmark.circle")
          VStack(alignment: .leading, spacing: 4) {
            Text(account.name).font(.callout.weight(.medium))
            Text(account.error ?? (account.capturedAt == nil ? "尚未查询" : "最近一次额度查询成功"))
              .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
          Spacer()
        }
      }
      Divider()
      Text("切换当前会话的账户请使用侧栏额度卡片；这里的默认设置仅作用于之后创建的会话。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

private struct AccountAuthorizationRequestView: View {
  @ObservedObject var model: AccountWorkspaceModel
  let request: AccountAuthorizationState.Request
  @State private var input = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(request.title.replacingOccurrences(of: "[account-usage login] ", with: ""))
        .font(.callout.weight(.medium))
      if request.method == "select" {
        ForEach(request.options ?? [], id: \.self) { option in
          Button(option) { model.respond(to: request, value: option, confirmed: nil) }
        }
      } else if request.method == "confirm" {
        Text(request.message ?? "").font(.caption)
        Button("确认") { model.respond(to: request, value: nil, confirmed: true) }
      } else {
        TextField(request.placeholder ?? "授权信息", text: $input).textFieldStyle(.roundedBorder)
        Button("提交授权信息") { model.respond(to: request, value: input, confirmed: nil) }
          .disabled(input.isEmpty)
      }
    }
    .disabled(model.responding)
  }
}
