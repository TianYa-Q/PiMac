import SwiftUI

struct GitWorkspaceContext: Identifiable {
  let id = UUID()
  let cwd: String
  let threadID: String?
  let projectID: String?
}

struct GitWorkspaceView: View {
  @ObservedObject var store: GitWorkspaceStore
  @ObservedObject var server: T3DesktopClient
  let context: GitWorkspaceContext
  private var cwd: String { context.cwd }
  @Environment(\.dismiss) private var dismiss
  @State private var commitMessage = ""
  @State private var newBranch = ""
  @State private var pending: Operation?
  @State private var previewFile: GitWorkspaceStatus.File?

  private struct Operation: Identifiable {
    let id = UUID()
    let title: String
    let method: String
    let payload: [String: Any]
  }
  private var locked: Bool { store.busy || store.loading || store.requiresRefresh || !server.isConnected }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("源代码管理", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.title2.bold())
        Spacer()
        if store.loading || store.busy { ProgressView().controlSize(.small) }
        Button("刷新", systemImage: "arrow.clockwise") {
          Task { await store.refresh(client: server, cwd: cwd) }
        }.disabled(store.busy || store.loading || !server.isConnected)
        Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.busy)
      }
      Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
      if !server.isConnected {
        Label("Server 未连接，Git 操作不可用", systemImage: "wifi.slash").foregroundStyle(.orange)
      }
      if !store.message.isEmpty {
        Label(store.message, systemImage: store.requiresRefresh ? "exclamationmark.triangle" : "info.circle")
          .font(.callout).foregroundStyle(store.requiresRefresh ? Color.orange : Color.secondary)
          .padding(12).frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
      }
      if let url = store.pullRequestURL {
        Link("打开 Pull Request", destination: url).font(.callout)
      }
      if let status = store.status, status.isRepo {
        HStack(spacing: 12) {
          Label(status.branch ?? "Detached HEAD", systemImage: "arrow.triangle.branch")
            .font(.headline)
          Text("↑ \(status.ahead)  ↓ \(status.behind)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
          Spacer()
          Button("拉取") { queue("拉取远端更新", "vcs.pull", ["cwd": cwd]) }
            .disabled(locked || !status.hasUpstream || !status.files.isEmpty)
        }
        HStack {
          Menu("切换分支") {
            ForEach(store.branches, id: \.self) { branch in
              Button(branch) { queue("切换到 \(branch)", "vcs.switchRef", ["cwd": cwd, "refName": branch]) }
                .disabled(branch == status.branch)
            }
          }.disabled(locked || !status.files.isEmpty || store.branches.isEmpty)
          TextField("新分支名称", text: $newBranch).textFieldStyle(.roundedBorder)
          Button("创建并切换") {
            queue("创建并切换分支", "vcs.createRef", ["cwd": cwd,
              "refName": newBranch.trimmingCharacters(in: .whitespacesAndNewlines), "switchRef": true])
          }.disabled(locked || !status.files.isEmpty || newBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if !status.files.isEmpty {
          Text("有未提交变更时禁止切换分支或拉取，避免干扰正在进行的工作。")
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Text("工作区变更 · \(status.files.count)").font(.headline)
          Spacer()
          Button(store.selectedFiles.count == status.files.count ? "取消全选" : "全选") {
            store.selectedFiles = store.selectedFiles.count == status.files.count ? [] : Set(status.files.map(\.path))
          }.disabled(locked || status.files.isEmpty)
        }
        ScrollView {
          LazyVStack(spacing: 0) {
            if status.files.isEmpty {
              ContentUnavailableView("工作区干净", systemImage: "checkmark.seal", description: Text("没有待提交的文件"))
            }
            ForEach(status.files) { file in
              HStack {
                Toggle(isOn: Binding(get: { store.selectedFiles.contains(file.path) }, set: {
                  if $0 { store.selectedFiles.insert(file.path) } else { store.selectedFiles.remove(file.path) }
                })) { Text(file.path).font(.system(.callout, design: .monospaced)).lineLimit(1).help(file.path) }
                  .toggleStyle(.checkbox).disabled(locked)
                Spacer()
                Button { previewFile = file } label: { Image(systemName: "doc.text.magnifyingglass") }
                  .buttonStyle(.plain).help("查看差异").accessibilityLabel("查看 \(file.path) 的差异").disabled(locked)
                Text("+\(file.insertions)").foregroundStyle(.green)
                Text("−\(file.deletions)").foregroundStyle(.red)
              }.padding(10)
              Divider()
            }
          }
        }.frame(minHeight: 150).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        TextField("提交说明（只提交勾选的文件）", text: $commitMessage, axis: .vertical)
          .lineLimit(2...4).textFieldStyle(.roundedBorder).disabled(locked)
        HStack {
          Text("已选择 \(store.selectedFiles.count) 个文件").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("提交") { action("commit", title: "提交所选文件") }.disabled(locked || !canCommit)
          Button("提交并推送") { action("commit_push", title: "提交所选文件并推送") }.disabled(locked || !canCommit)
          Button("推送") { action("push", title: "推送当前分支") }.disabled(locked || status.branch == nil)
          Button("创建 PR") { action("create_pr", title: "创建 Pull Request") }.disabled(locked || status.branch == nil)
        }
      } else if !store.loading {
        ContentUnavailableView("未发现 Git 仓库", systemImage: "folder.badge.questionmark",
          description: Text("请先在此目录初始化 Git 仓库，然后刷新。"))
      }
      if store.busy { Text(store.progress).font(.callout).foregroundStyle(.secondary) }
    }
    .padding(24).frame(width: 760, height: 640)
    .interactiveDismissDisabled(store.busy)
    .task(id: cwd) { await store.refresh(client: server, cwd: cwd) }
    .sheet(item: $previewFile) { file in
      GitFilePreview(server: server, cwd: cwd, file: file.path)
    }
    .alert(item: $pending) { operation in
      Alert(title: Text(operation.title), message: Text("将在当前工作区执行原生 T3 Git 操作。提交会运行 Git hooks；推送或创建 PR 会访问远端。结果未确认时不会自动重试。"),
        primaryButton: .default(Text("执行")) {
          Task { await store.perform(client: server, method: operation.method, payload: operation.payload, cwd: cwd) }
        }, secondaryButton: .cancel())
    }
  }

  private var canCommit: Bool {
    GitWorkspaceStore.actionPayload(cwd: cwd, action: "commit", message: commitMessage, files: store.selectedFiles) != nil
  }
  private func action(_ action: String, title: String) {
    guard var payload = GitWorkspaceStore.actionPayload(cwd: cwd, action: action, message: commitMessage, files: store.selectedFiles) else { return }
    if let threadID = context.threadID { payload["threadId"] = threadID }
    if let projectID = context.projectID { payload["projectId"] = projectID }
    queue(title, "git.runStackedAction", payload)
  }
  private func queue(_ title: String, _ method: String, _ payload: [String: Any]) {
    pending = Operation(title: title, method: method, payload: payload)
  }
}
