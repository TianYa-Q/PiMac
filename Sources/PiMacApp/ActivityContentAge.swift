import Foundation

/// 只按内容记录计时；轮询、重绘和折叠操作不应刷新最后活动时间。
enum ActivityContentAge {
  static func label(entries: [ChatEntry], at now: Date) -> String? {
    var pending = entries
    var latest: Date?
    while let entry = pending.popLast() {
      if let date = entry.contentUpdatedAt ?? entry.timestamp {
        latest = max(latest ?? date, date)
      }
      pending.append(contentsOf: entry.childToolEntries)
    }
    guard let latest else { return nil }
    let elapsed = now.timeIntervalSince(latest)
    guard elapsed > 60 else { return nil }
    return "上次新内容：\(Int(elapsed / 60)) 分钟前"
  }
}
