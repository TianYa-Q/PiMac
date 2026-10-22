import Foundation
import SwiftUI

struct ComposerSkill: Decodable, Equatable, Identifiable {
  let name: String
  let path: String
  let enabled: Bool
  let description: String?
  let displayName: String?
  let shortDescription: String?
  let userInvocable: Bool?

  var id: String { path }
  var title: String { displayName ?? name }
  var summary: String { shortDescription ?? description ?? "" }
  var invocation: String { "/skill:\(name)" }
}

struct SkillWorkspaceSnapshot: Decodable {
  let cwd: String
  let checkedAt: String
  let skills: [ComposerSkill]

  var validationDate: Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: checkedAt) ?? ISO8601DateFormatter().date(from: checkedAt)
  }

  func isCurrent(at now: Date) -> Bool {
    guard let date = validationDate else { return false }
    let age = now.timeIntervalSince(date)
    return age >= 0 && age < 300
  }
}

enum SkillCompletion {
  struct Trigger: Equatable {
    let query: String
    let range: NSRange
  }

  /// Pi 的 skill 命令由运行时在消息开头解析；不把路径或正文中的斜杠误当命令。
  static func trigger(text: String, selection: NSRange) -> Trigger? {
    let source = text as NSString
    guard selection.length == 0, selection.location > 0,
      selection.location <= source.length, source.hasPrefix("/")
    else { return nil }
    let prefix = source.substring(to: selection.location)
    guard !prefix.contains(where: { $0.isWhitespace }) else { return nil }
    let query = String(prefix.dropFirst())
    // 光标回到命令中间时替换整个 token，避免留下旧后缀拼成另一个命令。
    let token = text.prefix { !$0.isWhitespace }
    return Trigger(
      query: query.hasPrefix("skill:") ? String(query.dropFirst(6)) : query,
      range: NSRange(location: 0, length: token.utf16.count))
  }

  static func matches(_ skills: [ComposerSkill], query: String) -> [ComposerSkill] {
    var names = Set<String>()
    return skills.filter { skill in
      skill.enabled && skill.userInvocable != false
        && (query.isEmpty || skill.name.localizedCaseInsensitiveContains(query)
          || skill.title.localizedCaseInsensitiveContains(query)
          || skill.summary.localizedCaseInsensitiveContains(query))
        && names.insert(skill.name).inserted
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  static func insert(_ skill: ComposerSkill, text: String, trigger: Trigger) -> (String, NSRange) {
    let replacement = skill.invocation + " "
    let result = (text as NSString).replacingCharacters(in: trigger.range, with: replacement)
    return (result, NSRange(location: replacement.utf16.count, length: 0))
  }
}

struct CachedSkillCompletionList: View {
  @ObservedObject var cache: WorkspaceSkillCache
  let workspaceKey: WorkspaceSkillCache.Key
  let query: String
  let selectedIndex: Int
  let onSelect: (ComposerSkill) -> Void
  let onReload: () -> Void

  var body: some View {
    let state = cache.state(for: workspaceKey)
    let skills = SkillCompletion.matches(state.skills, query: query)
    SkillCompletionList(
      skills: skills, selectedIndex: min(selectedIndex, max(0, skills.count - 1)),
      isLoading: state.isLoading, hasLoaded: state.hasLoaded, error: state.error,
      onSelect: onSelect, onRetry: onReload)
  }
}

struct SkillCompletionList: View {
  let skills: [ComposerSkill]
  let selectedIndex: Int
  let isLoading: Bool
  let hasLoaded: Bool
  let error: String?
  let onSelect: (ComposerSkill) -> Void
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Label("Skills", systemImage: "sparkles")
        Spacer()
        Button("重新加载", action: onRetry)
        Text("↑↓ 选择 · Tab / Enter 补全 · Esc 关闭")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      if isLoading {
        HStack {
          ProgressView().controlSize(.small)
          Text("正在发现工作区 Skills…")
        }
        .font(.caption).padding(8)
      }
      if let error {
        HStack {
          Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
          Spacer()
          Button("重试", action: onRetry)
        }.padding(8)
      }
      if skills.isEmpty {
        if !isLoading && error == nil {
          Text(hasLoaded ? "没有匹配的 Skills" : "等待连接后加载 Skills…")
            .font(.caption).foregroundStyle(.secondary).padding(8)
        }
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                Button {
                  onSelect(skill)
                } label: {
                  VStack(alignment: .leading, spacing: 3) {
                    HStack {
                      Text("/\(skill.name)").font(.system(size: 12, weight: .medium))
                      if skill.title != skill.name {
                        Text(skill.title).font(.caption).foregroundStyle(.secondary)
                      }
                      Spacer()
                    }
                    if !skill.summary.isEmpty {
                      Text(skill.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                  }
                  .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                  .background(
                    index == selectedIndex ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                  )
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 滚动锚点与 ForEach 共用 skill 身份；过滤后的行不能复用旧索引的视图。
                .id(skill.id)
              }
            }
          }
          .frame(height: min(CGFloat(skills.count) * 57, 210))
          .onChange(of: selectedIndex) { _, index in
            guard skills.indices.contains(index) else { return }
            proxy.scrollTo(skills[index].id)
          }
        }
      }
    }
    .padding(8)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
  }
}
