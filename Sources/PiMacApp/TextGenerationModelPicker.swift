import SwiftUI

struct TextGenerationModelPicker: View {
  @ObservedObject var store: TextGenerationModelStore
  let visibleModelIDs: Set<String>
  let connected: Bool
  let update: (String?) async -> Void

  private var candidates: [TextGenerationModelSettings.Candidate] {
    (store.snapshot?.candidates ?? []).filter { visibleModelIDs.contains($0.id) }
  }
  private var selectedID: String {
    guard let id = store.snapshot?.selection?.model, candidates.contains(where: { $0.id == id })
    else { return "" }
    return id
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("标题与辅助文本", systemImage: "text.badge.star")
        .font(.callout.weight(.semibold))
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 20) {
          VStack(alignment: .leading, spacing: 5) {
            Text("标题生成模型").font(.callout.weight(.medium))
            Text("仅可选择未隐藏的 Pi 模型。")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          if store.busy { ProgressView().controlSize(.small) }
          Picker("标题生成模型", selection: Binding(
            get: { selectedID },
            set: { id in if !id.isEmpty { Task { await update(id) } } }
          )) {
            if selectedID.isEmpty {
              Text(store.snapshot == nil ? "尚未读取" : "请选择可用模型").tag("")
            }
            ForEach(candidates) { model in Text(model.name).tag(model.id) }
          }
          .labelsHidden().pickerStyle(.menu).frame(width: 260)
          .disabled(!connected || store.busy || candidates.isEmpty || !store.error.isEmpty)
        }
        Text("沿用 T3 官方共享设置，也用于分支命名等辅助文本；不改变对话模型。隐藏或下架当前模型时，自动改用仍显示的 Pi 模型。")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if store.snapshot?.status == .noVisibleModels {
          Label("没有已显示的 Pi 模型；自动标题暂停。请先显示一个模型后刷新。", systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
        }
        if !connected {
          Text("连接 Server 后可读取和修改；离线时不会覆盖官方设置。")
            .font(.caption).foregroundStyle(.secondary)
        }
        if !store.error.isEmpty {
          Text(store.error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        if store.snapshot == nil || !store.error.isEmpty || store.snapshot?.status == .noVisibleModels {
          Button("重新读取") { Task { await update(nil) } }
            .controlSize(.small).disabled(!connected || store.busy)
        }
      }
      .padding(16)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
    }
    .task(id: connected) { if connected { await update(nil) } }
  }
}
