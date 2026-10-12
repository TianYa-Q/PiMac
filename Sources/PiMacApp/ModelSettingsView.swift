import AppKit
import SwiftUI

struct ModelSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var app: AppModel
  @State private var search = ""
  @State private var onlyVisible = true

  private var filteredModels: [PiModel] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let visibleIDs = Set(app.models.map(\.id))
    return app.allModels.filter { model in
      (!onlyVisible || visibleIDs.contains(model.id))
        && (query.isEmpty || "\(model.name) \(model.id)".localizedCaseInsensitiveContains(query))
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "slider.horizontal.3")
          .font(.title2)
          .foregroundStyle(Color.accentColor)
          .frame(width: 40, height: 40)
          .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 4) {
          Text("模型与思考等级").font(.title2.bold())
          Text("管理模型显示、思考等级与上下文限制")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(action: app.reloadModelList) {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .disabled(!app.canReloadModelList || app.isLoadingConfiguration)
        .help("重新读取 Server 的可用模型列表")
        Button("完成") { dismiss() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 18)
      .background(Color(nsColor: .windowBackgroundColor))

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 10) {
            sectionTitle("会话默认值", icon: "bubble.left.and.bubble.right")
            VStack(spacing: 0) {
              settingRow("默认模型", detail: "仅用于新会话，不改变已有会话。") {
                Picker(
                  "默认模型",
                  selection: Binding(
                    get: { app.defaultModelID },
                    set: { app.setDefaultModel($0) }
                  )
                ) {
                  Text("自动选择").tag(nil as String?)
                  if let id = app.defaultModelID, !app.models.contains(where: { $0.id == id }) {
                    Text("\(id)（隐藏或不可用）").tag(Optional(id))
                  }
                  ForEach(app.models) { model in
                    Text("\(model.name) · \(model.provider)").tag(Optional(model.id))
                  }
                }
                .labelsHidden()
              }
              Divider().padding(.horizontal, 16)
              settingRow("默认思考等级", detail: "模型未设置专属等级时使用。") {
                Picker(
                  "默认思考等级",
                  selection: Binding(
                    get: { app.globalDefaultThinkingLevel },
                    set: { app.setGlobalDefaultThinkingLevel($0) }
                  )
                ) {
                  ForEach(PiModel.thinkingLevelOrder, id: \.self) { level in
                    Text(thinkingLevelLabel(level)).tag(level)
                  }
                }
                .labelsHidden()
              }
            }
            .background(
              Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
          }

          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
              .foregroundStyle(Color.accentColor)
              .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
              Text("上下文压缩").font(.caption.weight(.semibold))
              Text("可为每个模型设置上下文限制；自动压缩策略遵循 Pi 配置，也可使用 /compact 手动压缩。")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

          VStack(alignment: .leading, spacing: 10) {
            HStack {
              sectionTitle("可用模型", icon: "square.stack.3d.up")
              Spacer()
              Text("已显示 \(app.models.count) / \(app.allModels.count)")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: Capsule())
            }
            HStack(spacing: 8) {
              Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
              TextField("搜索模型名称或提供商", text: $search)
                .textFieldStyle(.plain)
              if !search.isEmpty {
                Button {
                  search = ""
                } label: {
                  Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
              }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
              Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            HStack {
              Toggle("仅已显示", isOn: $onlyVisible)
                .toggleStyle(.checkbox)
                .help("只查看已在对话选择列表中显示的模型")
              Spacer()
              Text("上下文限制 · tokens")
                .frame(width: 140, alignment: .trailing)
              Text("默认思考等级")
                .frame(width: 150, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary)

            LazyVStack(spacing: 0) {
              if filteredModels.isEmpty {
                Text(app.allModels.isEmpty ? "暂无模型，请连接 Server 后刷新。" : "没有匹配的模型")
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity).padding(24)
              }
              ForEach(filteredModels) { model in
                modelRow(model)
                if model.id != filteredModels.last?.id {
                  Divider().padding(.leading, 62).padding(.trailing, 14)
                }
              }
            }
            .background(
              Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 1))
          }
        }
        .padding(24)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(width: 780, height: 720)
  }

  private func sectionTitle(_ title: String, icon: String) -> some View {
    Label(title, systemImage: icon)
      .font(.callout.weight(.semibold))
      .foregroundStyle(.primary)
  }

  private func settingRow<Control: View>(
    _ title: String, detail: String, @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(spacing: 20) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      control()
        .pickerStyle(.menu)
        .controlSize(.regular)
        .frame(width: 260)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private func modelRow(_ model: PiModel) -> some View {
    HStack(spacing: 12) {
      Toggle(
        "显示 \(model.name)",
        isOn: Binding(
          get: { app.models.contains(where: { $0.id == model.id }) },
          set: { app.setModelVisible($0, modelID: model.id) }
        )
      )
      .labelsHidden().toggleStyle(.switch).controlSize(.small)
      .help("在对话模型列表中显示此模型")

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(model.name).font(.callout.weight(.medium))
            .lineLimit(1)
            .help(model.name)
          if model.id == app.selectedModelId {
            Text("当前").font(.caption2)
              .foregroundStyle(Color.accentColor)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Color.accentColor.opacity(0.12), in: Capsule())
          }
        }
        Text(model.id).font(.caption.monospaced())
          .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          .help(model.id)
      }
      Spacer(minLength: 8)
      ModelContextLimitButton(
        model: model, currentLimit: app.modelContextWindows[model.id],
        isEnabled: app.canReloadModelList && !app.isLoadingConfiguration,
        save: { try await app.setModelContextWindow($0, for: model.id) }
      )
      .frame(width: 140, alignment: .trailing)
      Picker(
        "专属默认思考等级",
        selection: Binding(
          get: { app.modelDefaultThinkingLevels[model.id] ?? "__global__" },
          set: { app.setDefaultThinkingLevel($0 == "__global__" ? nil : $0, for: model.id) }
        )
      ) {
        Text("跟随全局").tag("__global__")
        ForEach(model.thinkingLevels, id: \.self) { level in
          Text(thinkingLevelLabel(level)).tag(level)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .controlSize(.small)
      .frame(width: 150)
      .help("仅用于此模型的新会话；跟随全局时使用默认思考等级")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }
}
