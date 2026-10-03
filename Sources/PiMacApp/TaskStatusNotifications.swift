import AppKit
import Foundation
import UserNotifications

/// Observe live snapshots only. The first snapshot is a baseline, never a replay
/// of historical completions. Kept independent of notification permission/UI.
struct TaskStatusTracker {
  struct Event: Equatable {
    let threadID: String
    let turnID: String
    let title: String
    let state: String
    var message: String {
      switch state {
      case "error": return "任务执行失败，请查看会话。"
      case "interrupted": return "任务已取消。"
      default: return "任务已完成。"
      }
    }
  }
  private var initialized = false
  private var turns: [String: (id: String, state: String)] = [:]

  mutating func consume(_ threads: [[String: Any]]) -> [Event] {
    var events: [Event] = []
    for thread in threads {
      guard let id = thread["id"] as? String,
        let turn = thread["latestTurn"] as? [String: Any],
        let turnID = turn["turnId"] as? String,
        let state = turn["state"] as? String
      else { continue }
      let previous = turns[id]
      if initialized, ["completed", "error", "interrupted"].contains(state),
        previous?.id != turnID || previous?.state != state
      {
        events.append(
          Event(
            threadID: id, turnID: turnID,
            title: thread["title"] as? String ?? "Pi Mac 会话", state: state))
      }
      turns[id] = (turnID, state)
    }
    initialized = true
    return events
  }
}

@MainActor
final class TaskStatusNotifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = TaskStatusNotifications()

  private var center: UNUserNotificationCenter? {
    // A bare SwiftPM executable has no notification application identity.
    guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    return center
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }

  func requestPermission() async {
    guard let center else { return }
    do {
      _ = try await center.requestAuthorization(options: [.alert, .sound])
    } catch {
      NSLog("Pi Mac notification authorization failed")
    }
  }

  func deliver(_ event: TaskStatusTracker.Event) {
    guard let center else { return }
    let content = UNMutableNotificationContent()
    content.title = String(event.title.prefix(100))
    content.body = event.message
    // NSSound.beep() follows the alert sound selected in macOS Sound settings.
    // Keep the notification silent so it does not also play the default sound.
    content.sound = nil
    // Do not include prompts, outputs, paths or credentials in system notifications.
    let request = UNNotificationRequest(
      identifier: "task-\(event.threadID)-\(event.turnID)", content: content, trigger: nil)
    Task { @MainActor in
      let settings = await center.notificationSettings()
      do {
        try await center.add(request)
        // Respect the application's system notification sound preference.
        if settings.soundSetting == .enabled,
          settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        {
          NSSound.beep()
        }
      } catch {
        NSLog("Pi Mac task notification could not be delivered")
      }
    }
  }
}
