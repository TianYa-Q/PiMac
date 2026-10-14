import SwiftUI

/// 只从服务端 shell 派生展示，不维护另一份任务状态，也不伪造聊天消息。
struct ConversationSubagent: Identifiable, Equatable {
  enum Status: Equatable {
    case working, queued, completed, failed, stopped, idle, unknown

    var label: String {
      switch self {
      case .working: "进行中"
      case .queued: "排队中"
      case .completed: "已完成"
      case .failed: "失败"
      case .stopped: "已停止"
      case .idle: "空闲"
      case .unknown: "状态未知"
      }
    }

    var color: Color {
      switch self {
      case .working: .accentColor
      case .completed: .green
      case .failed: .red
      case .queued: .orange
      default: .secondary
      }
    }
  }

  let id: String
  let title: String
  let model: String
  let createdAt: Date?
  let status: Status
  let startedAt: Date?
  let completedAt: Date?

  /// 运行耗时从实际 run 开始计算，不把创建、排队时间算进去。
  /// 终态缺少结束时间时不猜测；父代理自己的 run 已结束但后代仍工作时，保留本轮耗时。
  func elapsedLabel(at now: Date) -> String? {
    guard status != .queued, let startedAt else { return nil }
    let end: Date
    if let completedAt {
      guard completedAt >= startedAt else { return nil }
      end = completedAt
    } else if status == .working {
      end = now
    } else {
      return nil
    }
    let seconds = Int(max(0, end.timeIntervalSince(startedAt)).rounded(.down))
    if seconds >= 3600 { return "\(seconds / 3600)时 \(seconds % 3600 / 60)分 \(seconds % 60)秒" }
    if seconds >= 60 { return "\(seconds / 60)分 \(seconds % 60)秒" }
    return "\(seconds)秒"
  }

  @MainActor
  static func children(parentID: String, threads: [[String: Any]]) -> [Self] {
    let running = T3V2Presentation.runningThreadIDs(threads: threads, locallyRunningIDs: [])
    var seen: Set<String> = []
    return threads.compactMap { thread -> Self? in
      guard T3V2Presentation.subagentParentID(thread) == parentID,
        let id = thread["id"] as? String, !id.isEmpty, seen.insert(id).inserted
      else { return nil }
      let status: Status
      if running.contains(id) {
        status = .working
      } else {
        switch thread["status"] as? String {
        case "queued": status = .queued
        case "completed": status = .completed
        case "failed": status = .failed
        case "cancelled", "interrupted", "rolled_back": status = .stopped
        case "idle": status = .idle
        default: status = .unknown
        }
      }
      let date = T3DesktopClient.date(thread["createdAt"])
      let selection = thread["modelSelection"] as? [String: Any] ?? [:]
      let model = [selection["instanceId"] as? String, selection["model"] as? String]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
      let title = (thread["title"] as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let start = T3DesktopClient.date(thread["latestRunStartedAt"])
      let end = T3DesktopClient.date(thread["latestRunCompletedAt"])
      let ownRunActive = T3V2Presentation.active.contains(thread["status"] as? String ?? "")
      return Self(id: id, title: title.isEmpty ? "子代理任务" : title,
        model: model, createdAt: date == .distantPast ? nil : date, status: status,
        startedAt: start == .distantPast ? nil : start,
        completedAt: ownRunActive || end == .distantPast ? nil : end)
    }.sorted {
      let left = $0.createdAt ?? .distantFuture
      let right = $1.createdAt ?? .distantFuture
      return left == right ? $0.id < $1.id : left < right
    }
  }
}

enum ConversationTimelineRow: Identifiable {
  case turn(ConversationTurn)
  case subagents([ConversationSubagent])

  var id: String {
    switch self {
    case .turn(let turn): "turn-\(turn.id)"
    case .subagents(let tasks): "subagents-\(tasks[0].id)"
    }
  }

  /// 在消息边界插入委派事件，避免整轮折叠把卡片挪到最终回复之后。
  /// 同一个边界的并行任务合并；缺失时间的历史任务放末尾，不猜测其发生顺序。
  static func build(messages: [ChatEntry], children: [ConversationSubagent]) -> [Self] {
    var groups: [Int: [ConversationSubagent]] = [:]
    for child in children {
      let boundary = child.createdAt.flatMap { date in
        messages.firstIndex { entry in entry.timestamp.map { $0 > date } ?? false }
      } ?? messages.count
      groups[boundary, default: []].append(child)
    }
    var result: [Self] = []
    var start = 0
    for boundary in groups.keys.sorted() {
      result += ConversationTurn.group(Array(messages[start..<boundary])).map { .turn($0) }
      result.append(.subagents(groups[boundary]!))
      start = boundary
    }
    result += ConversationTurn.group(Array(messages[start...])).map { .turn($0) }
    return result
  }
}

struct ConversationSubagentsView: View {
  let tasks: [ConversationSubagent]
  let onOpen: (String) -> Void
  @Environment(\.conversationExpansionStore) private var expansionStore
  @State private var localExpanded = true

  private var expansionKey: String { "subagents-\(tasks[0].id)" }
  private var expanded: Bool {
    get { expansionStore?.values[expansionKey] ?? localExpanded }
    nonmutating set {
      localExpanded = newValue
      expansionStore?.values[expansionKey] = newValue
    }
  }

  var body: some View {
    let working = tasks.filter { $0.status == .working }.count
    VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "person.2.fill").foregroundStyle(Color.accentColor)
          Text("\(tasks.count) 个子代理").fontWeight(.medium)
          if working > 0 {
            Text("\(working) 个进行中").foregroundStyle(Color.accentColor)
          }
          Spacer(minLength: 4)
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(tasks.count) 个子代理，\(expanded ? "收起" : "展开")")
      if expanded {
        VStack(spacing: 0) {
          ForEach(tasks) { task in
            Button { onOpen(task.id) } label: {
              HStack(alignment: .top, spacing: 9) {
                Circle().fill(task.status.color).frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                  Text(task.title).font(.callout.weight(.medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                  if !task.model.isEmpty {
                    Text(task.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
                VStack(alignment: .trailing, spacing: 4) {
                  Text(task.status.label).font(.caption).foregroundStyle(task.status.color)
                  if task.status == .working && task.completedAt == nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                      if let duration = task.elapsedLabel(at: context.date) {
                        Text(duration).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                      }
                    }
                  } else if let duration = task.elapsedLabel(at: .now) {
                    Text(duration).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                  }
                }
                .fixedSize(horizontal: true, vertical: false)
                .help("本轮运行时长，不含排队等待")
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                  .padding(.top, 2)
              }
              .padding(12)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开子代理：\(task.title)")
            if task.id != tasks.last?.id {
              Divider().padding(.horizontal, 12)
            }
          }
        }
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
      }
    }
    .padding(.vertical, 4)
  }
}
