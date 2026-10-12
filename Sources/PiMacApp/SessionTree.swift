import Foundation

/// 纯展示树：只组织当前筛选内的会话，不修改服务端的 lineage 或生命周期。
struct SessionTree {
  struct Row: Identifiable {
    let session: SessionItem
    let depth: Int
    let childCount: Int
    var id: String { session.path }
  }

  let roots: [SessionItem]
  private let parents: [String: String]
  private let children: [String: [SessionItem]]

  init(sessions: [SessionItem], parentPaths: [String: String]) {
    let paths = Set(sessions.map(\.path))
    let ranks = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($0.element.path, $0.offset) })
    // 父会话被筛选、归档或删除时，子会话提升为根节点，避免悄悄丢失。
    var parents = parentPaths.filter { paths.contains($0.key) && paths.contains($0.value) && $0.key != $0.value }
    var visited: Set<String> = []
    for session in sessions where !visited.contains(session.path) {
      var chain: [String] = []
      var positions: [String: Int] = [:]
      var current: String? = session.path
      while let path = current, !visited.contains(path) {
        if let start = positions[path] {
          // 损坏的循环关系只断开一条边，保证所有会话仍可达；用原排序确定稳定的根。
          if let root = chain[start...].min(by: { ranks[$0, default: 0] < ranks[$1, default: 0] }) {
            parents.removeValue(forKey: root)
          }
          break
        }
        positions[path] = chain.count
        chain.append(path)
        current = parents[path]
      }
      visited.formUnion(chain)
    }
    self.parents = parents
    var children: [String: [SessionItem]] = [:]
    var rootPaths: [String: String] = [:]
    for session in sessions {
      if let parent = parents[session.path] { children[parent, default: []].append(session) }
      var chain: [String] = []
      var current = session.path
      while let parent = parents[current], rootPaths[current] == nil {
        chain.append(current)
        current = parent
      }
      let root = rootPaths[current] ?? current
      rootPaths[current] = root
      for path in chain { rootPaths[path] = root }
    }
    self.children = children
    // 家族按最近成员的既有排序排列，新的子任务不会因父会话较旧而沉到列表底部。
    var familyRanks: [String: Int] = [:]
    for (index, session) in sessions.enumerated() {
      let root = rootPaths[session.path] ?? session.path
      familyRanks[root] = min(familyRanks[root] ?? index, index)
    }
    roots = sessions.filter { parents[$0.path] == nil }.sorted {
      familyRanks[$0.path, default: 0] < familyRanks[$1.path, default: 0]
    }
  }

  func ancestorPaths(of path: String) -> [String] {
    var result: [String] = []
    var current = path
    while let parent = parents[current] {
      result.append(parent)
      current = parent
    }
    return result
  }

  func rows(expandedPaths: Set<String>, rootLimit: Int) -> [Row] {
    var result: [Row] = []
    var stack = roots.prefix(max(0, rootLimit)).reversed().map { ($0, 0) }
    // 迭代遍历避免多层委派耗尽调用栈；分页只截断根节点，不拆散已展开的家族。
    while let (session, depth) = stack.popLast() {
      let descendants = children[session.path] ?? []
      result.append(Row(session: session, depth: depth, childCount: descendants.count))
      if expandedPaths.contains(session.path) {
        stack.append(contentsOf: descendants.reversed().map { ($0, depth + 1) })
      }
    }
    return result
  }
}
