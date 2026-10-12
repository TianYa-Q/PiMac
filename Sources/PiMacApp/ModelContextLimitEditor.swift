import SwiftUI

struct ModelContextLimitButton: View {
  let model: PiModel
  let currentLimit: Int?
  let isEnabled: Bool
  let save: (Int?) async throws -> Void
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented = true
    } label: {
      HStack(spacing: 4) {
        VStack(alignment: .trailing, spacing: 1) {
          Text((currentLimit ?? model.defaultContextWindow).map { $0.formatted() } ?? "未获取大小")
            .monospacedDigit().lineLimit(1)
          Text(currentLimit == nil ? "Pi 默认" : "手工设置")
            .font(.caption2).foregroundStyle(.secondary)
        }
        Image(systemName: "pencil").font(.caption2)
      }
    }
    .controlSize(.small)
    .disabled(!isEnabled)
    .help("设置此模型的总上下文 token 上限；影响 Pi 的自动压缩判断")
    .popover(isPresented: $isPresented) {
      ModelContextLimitEditor(model: model, currentLimit: currentLimit, save: save)
    }
  }
}

struct ModelContextLimitEditor: View {
  @Environment(\.dismiss) private var dismiss
  let model: PiModel
  let currentLimit: Int?
  let save: (Int?) async throws -> Void
  @State private var text: String
  @State private var errorMessage = ""
  @State private var isSaving = false

  init(model: PiModel, currentLimit: Int?, save: @escaping (Int?) async throws -> Void) {
    self.model = model
    self.currentLimit = currentLimit
    self.save = save
    _text = State(initialValue: currentLimit.map(String.init) ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("上下文大小限制").font(.headline)
      Text(model.name).font(.callout)
      Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
      Text(
        model.defaultContextWindow.map { "Pi 默认：\($0.formatted()) tokens" }
          ?? "Pi 默认：尚未获取（可刷新模型列表）"
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        TextField("留空使用 Pi 默认", text: $text)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("上下文 token 上限")
          .onSubmit { commit() }
        Text("tokens").font(.caption).foregroundStyle(.secondary)
      }
      Text("设置总上下文预算，自动压缩仍会提前预留空间。调大此值不会增加模型服务端的实际额度。")
        .font(.caption).foregroundStyle(.secondary)
      Text("写入 Pi models.json。新的 Pi 进程生效，已有会话不会立即变更。")
        .font(.caption).foregroundStyle(.secondary)
      if !errorMessage.isEmpty {
        Text(errorMessage).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Button("恢复默认") { commit(reset: true) }
          .disabled(currentLimit == nil || isSaving)
        Spacer()
        if isSaving { ProgressView().controlSize(.small) }
        Button("取消") { dismiss() }.disabled(isSaving)
        Button("保存") { commit() }
          .buttonStyle(.borderedProminent).disabled(isSaving)
      }
    }
    .padding(20)
    .frame(width: 360)
  }

  private func commit(reset: Bool = false) {
    guard !isSaving else { return }
    do {
      let tokens = reset ? nil : try ModelContextLimit.parse(text)
      isSaving = true
      errorMessage = ""
      Task {
        defer { isSaving = false }
        do {
          try await save(tokens)
          dismiss()
        } catch {
          errorMessage = "保存失败：\(error.localizedDescription)"
        }
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
