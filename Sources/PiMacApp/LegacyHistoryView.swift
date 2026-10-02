import SwiftUI

/// Explicit, read-only access to pre-migration records. Never starts a Pi runtime.
struct LegacyHistoryView: View {
  let projectURL: URL
  @Environment(\.dismiss) private var dismiss
  @State private var sessions: [SessionItem] = []
  @State private var selected: String?
  @State private var entries: [ChatEntry] = []
  @State private var loading = true

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("旧版历史 · \(projectURL.lastPathComponent)").font(.headline)
        Spacer()
        Button("关闭") { dismiss() }
      }
      Text("仅查看 ~/.pi/agent/sessions 中的记录，不修改原文件、不启动旧会话。继续对话的导入功能尚未接入。")
        .font(.caption).foregroundStyle(.secondary)
      HSplitView {
        List(sessions, id: \.path, selection: $selected) { session in
          VStack(alignment: .leading) {
            Text(session.title).lineLimit(2)
            Text(session.modifiedAt, style: .date).font(.caption).foregroundStyle(.secondary)
          }.tag(session.path)
        }.frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(entries) { entry in
              VStack(alignment: .leading, spacing: 6) {
                Text(entry.title).font(.caption.bold()).foregroundStyle(.secondary)
                Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
              }
            }
            if selected == nil {
              Text(loading ? "正在读取旧记录…" : sessions.isEmpty ? "此项目暂无旧版历史" : "选择一条记录查看")
                .foregroundStyle(.secondary)
            }
          }.padding()
        }.frame(minWidth: 420)
      }
    }.padding().frame(minWidth: 760, minHeight: 520)
      .task {
        let path = projectURL.standardizedFileURL.path
        sessions = await Task.detached { AppModel.discoverSessions(for: path) }.value
        loading = false
      }
      .task(id: selected) {
        entries = []
        guard let path = selected else { return }
        let project = projectURL.standardizedFileURL.path
        let result = await Task.detached {
          guard AppModel.sessionExists(at: path, for: project) else { return [ChatEntry]() }
          return AppModel.loadTranscript(at: path)
        }.value
        guard !Task.isCancelled, selected == path else { return }
        entries = result
      }
  }
}
