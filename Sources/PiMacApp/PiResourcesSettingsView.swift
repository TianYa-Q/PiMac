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
      Text(
        "直接管理 Pi 标准目录中的文件，不代表当前会话已加载。此处包含 Pi 目录及 .agents/skills；其他配置路径、Pi 包及父目录中的资源仍由 Pi 加载，此处不修改。AGENTS.md 也可能继承自项目父目录；同目录的 AGENTS.override.md 可能覆盖它。"
      )
      .font(.caption).foregroundStyle(.secondary)
      Text("保存后请重新打开 Pi 会话以加载变更；不会自动修改正在运行的会话。导入前请检查 Skill 中的指令和脚本。")
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
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("AGENTS.md", systemImage: "doc.text").font(.headline)
          Spacer()
          Text(document.original == nil ? "尚未创建" : "已存在")
            .font(.caption).foregroundStyle(.secondary)
        }
        pathLabel(document.entry.url)
        HStack {
          Button(document.original == nil ? "创建" : "编辑") { self.document = document }
          if document.original != nil {
            Button("在 Finder 中显示") { reveal(document.entry.url) }
            Spacer()
            Button("移到废纸篓", role: .destructive) { removal = document }
          }
        }
        .controlSize(.small)
      }
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
        Picker("新建及导入位置", selection: $skillLocation) {
          ForEach(PiResourceStore.SkillLocation.allCases) { location in
            Text(location.rawValue).tag(location)
          }
        }
        ForEach(PiResourceStore.SkillLocation.allCases) { location in
          if let directory = try? store.skillsDirectory(for: scope, location: location) {
            pathLabel(directory)
          }
        }
        TextField("搜索名称或路径", text: $search).textFieldStyle(.roundedBorder)
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
                .menuStyle(.borderlessButton).fixedSize()
              }
              .controlSize(.small)
              pathLabel(entry.url)
            }
            .padding(.vertical, 3)
          }
        }
      }
      .padding(6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func pathLabel(_ url: URL) -> some View {
    Text(url.path).font(.caption.monospaced()).foregroundStyle(.secondary)
      .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
    panel.message = "选择包含 SKILL.md 的文件夹，将连同脚本和参考文件一起复制。"
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
    .frame(width: 700, height: 540)
    .interactiveDismissDisabled(hasChanges)
    .confirmationDialog("放弃未保存的修改？", isPresented: $confirmingDiscard) {
      Button("放弃修改", role: .destructive) { dismiss() }
      Button("继续编辑", role: .cancel) {}
    }
  }
}
