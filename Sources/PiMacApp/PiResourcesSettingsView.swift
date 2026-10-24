import AppKit
import SwiftUI

struct PiResourcesSettingsView: View {
  let store: PiResourceStore
  @State private var scope: PiResourceStore.Scope = .global
  @State private var search = ""
  @State private var skillLocation: PiResourceStore.SkillLocation = .pi
  @State private var catalog: Result<Catalog, Error>?
  @State private var document: PiResourceStore.Document?
  @State private var removal: PiResourceStore.Document?
  @State private var creatingSkill = false
  @State private var skillName = ""
  @State private var operationError: String?
  @State private var message = ""

  private struct Catalog {
    let instructions: PiResourceStore.Document
    let skills: [PiResourceStore.Entry]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Skills 与 AGENTS.md").font(.title3.bold())
        Spacer()
        Button("刷新", systemImage: "arrow.clockwise", action: refresh)
      }
      Picker("管理范围", selection: $scope) {
        ForEach(PiResourceStore.Scope.allCases) { scope in
          Text(scope.rawValue).tag(scope)
            .disabled(scope == .project && store.projectURL == nil)
        }
      }
      .pickerStyle(.segmented)
      if store.projectURL == nil {
        Text("选择项目后可管理项目文件。")
          .font(.caption).foregroundStyle(.secondary)
      }
      switch catalog {
      case .success(let catalog):
        instructionsCard(catalog.instructions)
        skillsCard(catalog.skills)
      case .failure(let error):
        Label("读取失败：\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red).textSelection(.enabled)
        Button("重试", action: refresh)
      case nil:
        ProgressView("读取文件…")
      }
      Label("保存后需重新打开 Pi 会话，正在运行的会话不受影响。", systemImage: "info.circle")
        .font(.caption).foregroundStyle(.secondary)
      DisclosureGroup("目录与加载说明") {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(PiResourceStore.SkillLocation.allCases) { location in
            if let directory = try? store.skillsDirectory(for: scope, location: location) {
              pathLabel(directory)
            }
          }
          Text(
            "此处管理 Pi 标准目录及 .agents/skills 中的文件，不代表当前会话已加载。其他配置路径、Pi 包及父目录资源仍由 Pi 加载，此处不修改。AGENTS.md 可能继承自项目父目录，也可能被同目录的 AGENTS.override.md 覆盖。"
          )
          Text("导入前请检查 Skill 中的指令和脚本。")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.top, 6)
      }
      .font(.caption).foregroundStyle(.secondary)
      if !message.isEmpty {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
    }
    .onAppear(perform: refresh)
    .onChange(of: scope) { _, _ in
      message = ""
      refresh()
    }
    .sheet(item: $document) { document in
      PiResourceEditor(store: store, document: document) {
        message = "已保存。重新打开 Pi 会话后加载变更。"
        refresh()
      }
    }
    .alert("新建 Skill", isPresented: $creatingSkill) {
      TextField("例如 code-review", text: $skillName)
      Button("取消", role: .cancel) {}
      Button("继续") {
        perform {
          document = try store.newSkill(named: skillName, scope: scope, location: skillLocation)
        }
      }
    } message: {
      Text("名称使用小写字母、数字和单连字符。保存前不会创建文件。")
    }
    .alert(
      "操作失败",
      isPresented: Binding(
        get: { operationError != nil }, set: { if !$0 { operationError = nil } }
      )
    ) {
      Button("好", role: .cancel) { operationError = nil }
    } message: {
      Text(operationError ?? "")
    }
    .alert(
      "移到废纸篓？",
      isPresented: Binding(
        get: { removal != nil }, set: { if !$0 { removal = nil } }
      )
    ) {
      Button("取消", role: .cancel) { removal = nil }
      Button("移到废纸篓", role: .destructive) {
        if let removal {
          perform {
            try store.trash(removal)
            message = "已移到废纸篓。正在运行的会话不受影响。"
            refresh()
          }
        }
        removal = nil
      }
    } message: {
      if let removal {
        Text(
          "\(removal.entry.removalURL.path)\n"
            + (removal.entry.removalURL == removal.entry.url
              ? "此文件将移到废纸篓，可从废纸篓恢复。"
              : "Skill 文件夹及其中的脚本、参考文件将一起移动，可从废纸篓恢复。"))
      }
    }
  }

  private func instructionsCard(_ document: PiResourceStore.Document) -> some View {
    GroupBox {
      HStack(spacing: 12) {
        Image(systemName: "doc.text").font(.title2).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text("AGENTS.md").font(.headline)
            if document.original == nil {
              Text("尚未创建").font(.caption).foregroundStyle(.secondary)
            }
          }
          pathLabel(document.entry.url)
        }
        Spacer(minLength: 8)
        Button(document.original == nil ? "创建" : "编辑") { self.document = document }
        if document.original != nil {
          Menu {
            Button("在 Finder 中显示") { reveal(document.entry.url) }
            Button("移到废纸篓", role: .destructive) { removal = document }
          } label: {
            Image(systemName: "ellipsis")
          }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .accessibilityLabel("AGENTS.md 更多操作")
        }
      }
      .controlSize(.small)
      .padding(6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func skillsCard(_ entries: [PiResourceStore.Entry]) -> some View {
    let filtered = entries.filter {
      search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
        || $0.url.path.localizedCaseInsensitiveContains(search)
    }
    return GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("Skills", systemImage: "sparkles").font(.headline)
          Text("\(entries.count)").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("导入…", action: importSkill)
          Button("新建") {
            skillName = ""
            creatingSkill = true
          }
        }
        .controlSize(.small)
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("搜索名称或路径", text: $search).textFieldStyle(.plain)
          if !search.isEmpty {
            Button {
              search = ""
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).accessibilityLabel("清除搜索")
          }
        }
        .padding(7)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        if filtered.isEmpty {
          Text(entries.isEmpty ? "此目录暂无 Skill，新建或导入一个开始使用。" : "没有匹配的 Skill。")
            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 10)
        } else {
          ForEach(filtered) { entry in
            Divider()
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(entry.title).font(.callout.weight(.medium)).lineLimit(2)
                Spacer()
                Button("编辑") { perform { document = try store.read(entry) } }
                Menu {
                  Button("在 Finder 中显示") { reveal(entry.url) }
                  Button("移到废纸篓", role: .destructive) {
                    perform { removal = try store.read(entry) }
                  }
                } label: {
                  Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(entry.title) 更多操作")
              }
              .controlSize(.small)
              pathLabel(entry.url)
            }
            .padding(.vertical, 5)
          }
        }
        Divider()
        HStack {
          Text("新建及导入到").foregroundStyle(.secondary)
          Picker("新建及导入位置", selection: $skillLocation) {
            ForEach(PiResourceStore.SkillLocation.allCases) { location in
              Text(location.rawValue).tag(location)
            }
          }
          .labelsHidden().frame(width: 130)
          Spacer()
        }
        .font(.caption).controlSize(.small)
      }
      .padding(6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func pathLabel(_ url: URL) -> some View {
    // 只缩写已知的用户目录前缀；完整路径保留在提示中，避免长路径撑高列表。
    let home = store.homeDirectory.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    let displayPath = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    return Text(displayPath).font(.caption.monospaced()).foregroundStyle(.secondary)
      .lineLimit(1).truncationMode(.middle)
      .textSelection(.enabled).help(path)
  }

  private func refresh() {
    catalog = Result {
      Catalog(
        instructions: try store.read(store.instructions(for: scope)),
        skills: try store.skills(for: scope))
    }
  }

  private func perform(_ operation: () throws -> Void) {
    do { try operation() } catch { operationError = error.localizedDescription }
  }

  private func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func importSkill() {
    let panel = NSOpenPanel()
    panel.title = "导入 Skill 文件夹"
    panel.message = "选择包含 SKILL.md 的文件夹，将连同脚本和参考文件一起复制。导入前请检查其中的指令和脚本。"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.showsHiddenFiles = true
    if panel.runModal() == .OK, let url = panel.url {
      perform {
        try store.importSkill(from: url, scope: scope, location: skillLocation)
        message = "已导入。重新打开 Pi 会话后加载变更。"
        refresh()
      }
    }
  }
}

struct PiResourceEditor: View {
  @Environment(\.dismiss) private var dismiss
  let store: PiResourceStore
  let document: PiResourceStore.Document
  let onSave: () -> Void
  @State private var text: String
  @State private var error: String?
  @State private var confirmingDiscard = false

  init(store: PiResourceStore, document: PiResourceStore.Document, onSave: @escaping () -> Void) {
    self.store = store
    self.document = document
    self.onSave = onSave
    _text = State(initialValue: document.text)
  }

  private var hasChanges: Bool { text != document.text }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(document.entry.title).font(.title3.bold())
        Spacer()
        if hasChanges { Text("未保存").font(.caption).foregroundStyle(.secondary) }
      }
      Text(document.entry.url.path).font(.caption.monospaced()).foregroundStyle(.secondary)
        .textSelection(.enabled)
      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .border(.quaternary)
      if let error {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        Text("保存为 UTF-8 Markdown。不会自动重载会话。")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("取消") {
          if hasChanges { confirmingDiscard = true } else { dismiss() }
        }
        .keyboardShortcut(.cancelAction)
        Button("保存") {
          do {
            try store.save(document, text: text)
            onSave()
            dismiss()
          } catch {
            self.error = error.localizedDescription
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!hasChanges && document.original != nil)
      }
    }
    .padding(24)
    // 默认提供宽编辑区，同时为小屏幕保留窗口边距，避免弹层超出可用桌面。
    .frame(
      width: min(1100, (NSScreen.main?.visibleFrame.width ?? 1200) - 96),
      height: min(720, (NSScreen.main?.visibleFrame.height ?? 820) - 96)
    )
    .interactiveDismissDisabled(hasChanges)
    .confirmationDialog("放弃未保存的修改？", isPresented: $confirmingDiscard) {
      Button("放弃修改", role: .destructive) { dismiss() }
      Button("继续编辑", role: .cancel) {}
    }
  }
}
