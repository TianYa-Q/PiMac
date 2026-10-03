import SwiftUI

@MainActor
struct ScheduledTasksView: View {
  @ObservedObject var workspace: WorkspaceModel
  @ObservedObject private var server: T3DesktopClient
  @StateObject private var store: ScheduledTasksStore
  @Environment(\.dismiss) private var dismiss
  @State private var editor: ScheduledTaskDraft?
  @State private var deleting: DesktopScheduledTask?
  @State private var running: DesktopScheduledTask?
  @State private var searchText = ""
  @State private var filter = ScheduledTaskFilter.all

  init(workspace: WorkspaceModel) {
    self.workspace = workspace
    server = workspace.server
    _store = StateObject(
      wrappedValue: ScheduledTasksStore { method, payload in
        try await workspace.server.scheduledTasksRPC(method, payload: payload)
      })
  }

  private var busy: Bool { store.isLoading || store.isMutating }
  private var canAct: Bool { server.isConnected && !busy && !store.requiresRefresh }
  private var visibleTasks: [DesktopScheduledTask] {
    let projects = server.projects.reduce(into: [String: String]()) { result, row in
      if let id = row["id"] as? String { result[id] = row["title"] as? String ?? id }
    }
    return ScheduledTaskPresentation.visibleTasks(
      store.tasks, query: searchText, filter: filter, projectTitles: projects)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("定时任务", systemImage: "calendar.badge.clock").font(.title2.bold())
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button("刷新", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
          .disabled(busy || !server.isConnected)
        Button("新建", systemImage: "plus") {
          editor = ScheduledTaskDraft(
            projectID: workspace.selectedModel?.projectURL.flatMap { server.projectID(for: $0) }
              ?? server.projects.first?["id"] as? String ?? "",
            modelID: workspace.selectedModel?.selectedModelId ?? "")
        }
        .disabled(!canAct || server.projects.isEmpty)
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.isMutating)
      }
      Text("由本机 T3 Server 执行，Pi Mac 必须保持运行且唤醒。固定时间使用本机时区；派发成功不代表模型任务已完成。")
        .font(.caption).foregroundStyle(.secondary)
      if !server.isConnected {
        Label(server.status, systemImage: "wifi.slash").foregroundStyle(.orange)
      }
      if let error = store.errorMessage {
        HStack {
          Text(error).foregroundStyle(.red).font(.callout)
          Spacer()
          if store.requiresRefresh {
            Button("重试刷新") { Task { await store.refresh() } }
              .disabled(busy || !server.isConnected)
          }
        }
      }
      HStack {
        TextField("搜索标题、提示词、项目或模型", text: $searchText)
          .textFieldStyle(.roundedBorder)
        Picker("筛选", selection: $filter) {
          ForEach(ScheduledTaskFilter.allCases) { Text($0.title).tag($0) }
        }
        .frame(width: 160)
        Text("\(visibleTasks.count) / \(store.tasks.count)").font(.caption).foregroundStyle(
          .secondary)
      }
      if let refreshed = store.lastRefreshedAt {
        Text("最近刷新：\(refreshed.formatted(date: .omitted, time: .standard))")
          .font(.caption).foregroundStyle(.secondary)
      }
      if store.hasLoaded && store.tasks.isEmpty {
        ContentUnavailableView(
          "暂无定时任务", systemImage: "calendar", description: Text("点击“新建”设置周期和提示词。"))
      } else if store.hasLoaded && visibleTasks.isEmpty {
        ContentUnavailableView(
          "无匹配任务", systemImage: "magnifyingglass", description: Text("尝试其他关键词或筛选条件。"))
        Button("清除筛选") {
          searchText = ""
          filter = .all
        }
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(visibleTasks) { task in taskRow(task) }
          }
        }
      }
    }
    .padding(22)
    .frame(width: 780, height: 600)
    .interactiveDismissDisabled(store.isMutating)
    .task {
      while !Task.isCancelled {
        if server.isConnected && editor == nil && !store.requiresRefresh {
          await store.refresh()
        }
        do { try await Task.sleep(for: .seconds(3)) } catch { break }
      }
    }
    .sheet(item: $editor) { draft in
      ScheduledTaskEditor(draft: draft, server: server, store: store)
    }
    .alert(
      "删除定时任务？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    ) {
      Button("取消", role: .cancel) { deleting = nil }
      Button("删除", role: .destructive) {
        if let task = deleting { Task { await store.delete(task) } }
        deleting = nil
      }
    } message: {
      Text("删除后不会再触发；已经派发的会话不会被取消。")
    }
    .alert(
      "立即执行一次？", isPresented: Binding(get: { running != nil }, set: { if !$0 { running = nil } })
    ) {
      Button("取消", role: .cancel) { running = nil }
      Button("执行") {
        if let task = running { Task { await store.runNow(task) } }
        running = nil
      }
    } message: {
      Text("即使任务已暂停，也会向目标会话派发一次提示词，可能消耗模型额度。")
    }
  }

  private func taskRow(_ task: DesktopScheduledTask) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(task.title).font(.headline)
        Text(task.enabled ? "已启用" : "已暂停").font(.caption)
          .foregroundStyle(task.enabled ? .green : .secondary)
        Spacer()
        Button(task.enabled ? "暂停" : "启用") { Task { await store.setEnabled(task) } }
        Button("编辑") { editor = ScheduledTaskDraft(task: task) }
        Button("复制") { editor = ScheduledTaskDraft(copying: task) }
          .help("创建暂停的副本，不复制会话绑定或工作区策略")
        Button("立即执行") { running = task }.disabled(
          task.raw["lastRunStatus"] as? String == "running")
        Button(role: .destructive) {
          deleting = task
        } label: {
          Image(systemName: "trash")
        }
        .help("删除定时任务")
      }
      .disabled(!canAct)
      let project =
        server.projects.first { $0["id"] as? String == task.projectID }?["title"] as? String
        ?? "项目已移除"
      Text("\(project) · \(task.scheduleLabel) · \(task.threadID == nil ? "每次新建会话" : "绑定已有会话")")
        .font(.callout).foregroundStyle(.secondary)
      let selection = task.raw["modelSelection"] as? [String: Any] ?? [:]
      Text("模型：\(selection["model"] as? String ?? "—")")
        .font(.caption).foregroundStyle(.secondary)
      if let id = task.threadID {
        let title = server.thread(id)?["title"] as? String ?? id
        Text("目标会话：\(title)").font(.caption).foregroundStyle(.secondary)
      }
      Text(task.prompt).lineLimit(2).font(.callout).textSelection(.enabled)
      HStack {
        Text("下次：\(dateLabel(task.raw["nextRunAt"]))")
        Spacer()
        Text(
          "\(task.runStatusLabel) · \(task.raw["runCount"] as? Int ?? 0) 次 · 上次：\(dateLabel(task.raw["lastRunAt"]))"
        )
      }
      .font(.caption).foregroundStyle(.secondary)
      if let error = task.raw["lastRunError"] as? String, !error.isEmpty {
        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
      }
    }
    .padding(14)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
  }

  private func dateLabel(_ value: Any?) -> String {
    guard let string = value as? String else { return "—" }
    return T3DesktopClient.date(string).formatted(date: .abbreviated, time: .shortened)
  }
}

@MainActor
private struct ScheduledTaskEditor: View {
  @State var draft: ScheduledTaskDraft
  @ObservedObject var server: T3DesktopClient
  @ObservedObject var store: ScheduledTasksStore
  @Environment(\.dismiss) private var dismiss

  private var threads: [[String: Any]] {
    server.threads.filter { $0["projectId"] as? String == draft.projectID }
  }
  private var providerOptions: [ProjectOption] {
    var options = server.providers.compactMap { row -> ProjectOption? in
      guard let id = row["instanceId"] as? String else { return nil }
      return ProjectOption(id: id, title: row["title"] as? String ?? id)
    }
    if !options.contains(where: { $0.id == draft.modelInstanceID }) {
      options.append(
        ProjectOption(id: draft.modelInstanceID, title: "\(draft.modelInstanceID)（当前不可用）"))
    }
    return options.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  private var modelIDs: [String] {
    let provider = server.providers.first { $0["instanceId"] as? String == draft.modelInstanceID }
    let ids = (provider?["models"] as? [[String: Any]] ?? []).compactMap { $0["slug"] as? String }
    return Array(Set(ids + (draft.modelID.isEmpty ? [] : [draft.modelID]))).sorted()
  }
  private var busy: Bool { store.isMutating || store.isLoading }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(draft.original == nil ? "新建定时任务" : "编辑定时任务").font(.title2.bold())
      Form {
        TextField("标题", text: $draft.title)
        Picker("项目", selection: $draft.projectID) {
          Text("请选择").tag("")
          ForEach(
            server.projects.compactMap { row -> ProjectOption? in
              guard let id = row["id"] as? String else { return nil }
              return ProjectOption(id: id, title: row["title"] as? String ?? id)
            }
          ) { option in Text(option.title).tag(option.id) }
        }
        .disabled(draft.original != nil)
        Picker("目标会话", selection: $draft.threadID) {
          Text("每次新建会话").tag("")
          if !draft.threadID.isEmpty
            && !threads.contains(where: { $0["id"] as? String == draft.threadID })
          {
            Text("原绑定会话（当前列表不可见）").tag(draft.threadID)
          }
          ForEach(
            threads.compactMap { row -> ProjectOption? in
              guard let id = row["id"] as? String else { return nil }
              return ProjectOption(id: id, title: row["title"] as? String ?? id)
            }
          ) { option in Text(option.title).tag(option.id) }
        }
        Picker("Provider", selection: $draft.modelInstanceID) {
          ForEach(providerOptions) { option in Text(option.title).tag(option.id) }
        }
        Picker("模型", selection: $draft.modelID) {
          Text("请选择").tag("")
          ForEach(modelIDs, id: \.self) { Text($0).tag($0) }
        }
        Picker("周期", selection: $draft.scheduleType) {
          Text("固定间隔").tag("interval")
          Text("固定时间").tag("fixed_time")
        }
        if draft.scheduleType == "interval" {
          TextField("间隔（分钟，至少 1）", text: $draft.intervalMinutes)
          HStack {
            Text("快捷周期").foregroundStyle(.secondary)
            Button("15 分钟") { draft.intervalMinutes = "15" }
            Button("每小时") { draft.intervalMinutes = "60" }
            Button("每 24 小时") { draft.intervalMinutes = "1440" }
          }
          .buttonStyle(.bordered)
          .font(.caption)
        } else {
          TextField("本机时间（HH:MM）", text: $draft.timeOfDay)
          HStack {
            Text("星期")
            ForEach(0..<7) { day in
              Toggle(
                ["日", "一", "二", "三", "四", "五", "六"][day],
                isOn: Binding(
                  get: { draft.weekdays.contains(day) },
                  set: { if $0 { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) } }
                )
              ).toggleStyle(.button)
            }
          }
        }
        Toggle("启用任务", isOn: $draft.enabled)
        VStack(alignment: .leading) {
          Text("提示词")
          TextEditor(text: $draft.prompt).font(.body).frame(height: 120)
            .border(Color.secondary.opacity(0.3))
        }
      }
      .disabled(busy)
      Text(
        draft.original == nil
          ? "新会话使用项目主目录、完全访问／默认模式。绑定会话由 Server 的会话队列处理。"
          : "保留原任务的工作区、访问模式和模型选项；更换模型会清除旧模型选项。"
      )
      .font(.caption).foregroundStyle(.secondary)
      if let message = draft.validationMessage {
        Text(message).font(.caption).foregroundStyle(.orange)
      }
      if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
        Button("保存") {
          Task { if await store.save(draft) { dismiss() } }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          busy || !server.isConnected || draft.validationMessage != nil || store.requiresRefresh
        )
      }
    }
    .padding(24).frame(width: 600)
    .interactiveDismissDisabled(busy)
    .onChange(of: draft.projectID) { draft.threadID = "" }
    .onChange(of: draft.modelInstanceID) { draft.modelID = "" }
  }

  private struct ProjectOption: Identifiable {
    let id: String
    let title: String
  }
}
