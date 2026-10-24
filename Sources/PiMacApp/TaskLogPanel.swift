import SwiftUI

/// 独立于工具调用和 agent 回合的文件订阅，固定在会话下方；切换会话/日志时取消旧订阅。
struct TaskLogPanel: View {
  let source: TaskLogSource
  @State private var reader = TaskLogReader()
  @State private var snapshot: TaskLogSnapshot?
  @State private var failure: String?
  @State private var expanded: Bool
  @State private var followsTail = true

  init(source: TaskLogSource, initiallyExpanded: Bool = false) {
    self.source = source
    _expanded = State(initialValue: initiallyExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Button {
          expanded.toggle()
        } label: {
          Label("任务日志", systemImage: expanded ? "chevron.down" : "chevron.right")
        }
        .buttonStyle(.plain)
        Text(source.file.lastPathComponent)
          .lineLimit(1).truncationMode(.middle)
          .help(source.file.path)
        Spacer(minLength: 8)
        Text(failure == nil ? (expanded ? "本地 · 每秒更新" : "本地 · 已折叠") : "读取异常")
          .foregroundStyle(failure == nil ? Color.secondary : Color.orange)
        if expanded {
          Button(followsTail ? "暂停跟随" : "跟随最新") { followsTail.toggle() }
            .buttonStyle(.plain)
            .help("只控制滚动，不中断后台任务或日志读取")
        }
      }
      .font(.caption)
      .padding(.horizontal, 16).padding(.vertical, 9)
      if expanded {
        if let failure {
          Text(failure + (snapshot == nil ? "" : "；下方保留上次读取内容"))
            .font(.caption).foregroundStyle(.orange)
            .padding(.horizontal, 16).padding(.bottom, 6)
        }
        if let snapshot {
          if snapshot.isTruncated {
            Text("仅显示末尾 64 KB；较早内容仍保留在原日志文件")
              .font(.caption2).foregroundStyle(.secondary)
              .padding(.horizontal, 16)
          }
          if snapshot.text.isEmpty {
            Text("日志为空，等待写入")
              .font(.caption).foregroundStyle(.secondary)
              .padding(.horizontal, 16).padding(.bottom, 12)
          } else {
            ToolOutputView(
              text: snapshot.text, followsTail: followsTail, maximumHeight: 180,
              onTailPaused: { followsTail = false }
            )
            .padding(.horizontal, 7).padding(.bottom, 7)
          }
        } else if failure == nil {
          Text("正在读取日志…")
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
      }
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .overlay(alignment: .top) { Divider() }
    .task(id: source.id) {
      while !Task.isCancelled {
        if expanded {
          do {
            let next = try await reader.read(source)
            try Task.checkCancellation()
            if snapshot != next { snapshot = next }
            failure = nil
          } catch is CancellationError {
            return
          } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
          }
        }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }
}
