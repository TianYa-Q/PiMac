import XCTest

@testable import PiMacApp

final class TelegramQueuePresentationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func items(_ count: Int) -> [TelegramQueuePresentation.Item] {
    (0..<count).map { index in
      .init(
        id: UUID(), preview: "task-\(index + 1)", attachmentCount: index == 0 ? 2 : 0,
        receivedAt: now.addingTimeInterval(-120))
    }
  }

  func testQueuePagesShowOnlyWaitingTasksAndMatchingCancellationIDs() {
    let tasks = items(7)
    let text = TelegramQueuePresentation.card(
      project: "demo", session: "work", items: tasks, localQueueCount: 2,
      blocker: "等待 Mac 确认", page: 2, now: now)
    XCTAssertTrue(text.contains("2/2 页"))
    XCTAssertTrue(text.contains("6. task-6"))
    XCTAssertTrue(text.contains("7. task-7"))
    XCTAssertFalse(text.contains("task-5"))
    XCTAssertTrue(text.contains("等待 2 分钟"))
    XCTAssertTrue(text.contains("Pi 另有 2 条排队 · Mac 管理"))
    XCTAssertTrue(text.contains("取消仅限等待任务，不停止执行"))
    XCTAssertLessThan(text.count, 260)
    let buttons = TelegramQueuePresentation.keyboard(items: tasks, page: 2).flatMap { $0 }
    let cancellations = buttons.compactMap { $0["callback_data"] }.compactMap(
      TelegramQueuePresentation.cancellation)
    XCTAssertEqual(cancellations.map(\.id), Array(tasks.suffix(2)).map(\.id))
    XCTAssertEqual(cancellations.map(\.page), [2, 2])
    XCTAssertTrue(buttons.contains { $0["callback_data"] == "/queue 1" })
  }

  func testLastPageClampsAfterCancellationAndEmptyQueuesRemainRefreshable() {
    let text = TelegramQueuePresentation.card(
      project: "demo", session: "work", items: items(5), localQueueCount: 0,
      blocker: "就绪后执行", page: 2, now: now)
    XCTAssertTrue(text.contains("1/1 页"))
    XCTAssertTrue(text.contains("5. task-5"))
    let empty = TelegramQueuePresentation.card(
      project: "demo", session: "work", items: [], localQueueCount: 0,
      blocker: "should not appear", page: Int.max, now: now)
    XCTAssertTrue(empty.contains("暂无等待任务"))
    XCTAssertFalse(empty.contains("should not appear"))
    XCTAssertEqual(
      TelegramQueuePresentation.keyboard(items: [], page: Int.max),
      [
        [TelegramPresentation.button("↻ 刷新队列", "/queue 1")]
      ])
  }

  func testAttachmentTasksAndLongPreviewsStayReadable() {
    let tasks = [
      TelegramQueuePresentation.Item(id: UUID(), preview: "", attachmentCount: 2, receivedAt: now),
      TelegramQueuePresentation.Item(
        id: UUID(), preview: String(repeating: "长", count: 200), attachmentCount: 0, receivedAt: now
      ),
    ]
    let text = TelegramQueuePresentation.card(
      project: "demo", session: "work", items: tasks, localQueueCount: 0,
      blocker: "就绪后执行", page: 1, now: now)
    XCTAssertTrue(text.contains("1. 附件任务"))
    XCTAssertTrue(text.contains("附件 2 个"))
    XCTAssertFalse(text.contains(String(repeating: "长", count: 200)))
    XCTAssertTrue(text.contains("…"))
  }

  func testWaitAgeAndCancellationCommandsHaveSafeBounds() {
    XCTAssertEqual(TelegramQueuePresentation.waitAge(receivedAt: now, now: now), "不到 1 分钟")
    XCTAssertEqual(
      TelegramQueuePresentation.waitAge(receivedAt: now.addingTimeInterval(10), now: now), "不到 1 分钟"
    )
    XCTAssertEqual(
      TelegramQueuePresentation.waitAge(receivedAt: now.addingTimeInterval(-3_600), now: now),
      "1 小时")
    XCTAssertEqual(
      TelegramQueuePresentation.waitAge(receivedAt: now.addingTimeInterval(-86_400), now: now),
      "超过 1 天")
    let id = UUID()
    let command = TelegramQueuePresentation.cancellationCommand(id: id, page: Int.max)
    XCTAssertLessThanOrEqual(command.utf8.count, 64)
    XCTAssertEqual(TelegramQueuePresentation.cancellation(command)?.id, id)
    XCTAssertEqual(TelegramQueuePresentation.cancellation(command)?.page, 1_000_000)
    for invalid in [
      "qcancel:bad:1", "qcancel:\(id):0", "qcancel:\(id):-1", "qcancel:\(id):1000001",
      "qcancel:\(id):1:extra",
    ] {
      XCTAssertNil(TelegramQueuePresentation.cancellation(invalid))
    }
  }

  func testQueueCancellationIsIndependentOfCurrentSelectionAndFooterExposesQueue() {
    let command = TelegramQueuePresentation.cancellationCommand(id: UUID(), page: 1)
    XCTAssertTrue(TelegramPresentation.canPerform(command, card: nil, selected: nil))
    let footer = TelegramPresentation.footer(command: "/status", running: true, hasSession: true)
    XCTAssertTrue(footer.flatMap { $0 }.contains { $0["callback_data"] == "/queue" })
    XCTAssertTrue(footer.allSatisfy { $0.count <= 3 })
  }

  func testQueueCallbacksRequireAuthorizedPrivateChat() throws {
    func update(_ command: String, user: Int = 42, type: String = "private") throws
      -> TelegramUpdate
    {
      let object: [String: Any] = [
        "update_id": 1,
        "callback_query": [
          "id": "callback", "from": ["id": user, "is_bot": false], "data": command,
          "message": ["message_id": 17, "chat": ["id": 42, "type": type]],
        ],
      ]
      return try JSONDecoder().decode(
        TelegramUpdate.self, from: JSONSerialization.data(withJSONObject: object))
    }
    for command in [
      "/queue", "/queue 2", TelegramQueuePresentation.cancellationCommand(id: UUID(), page: 1),
    ] {
      XCTAssertEqual(try update(command).authorizedCallback(userID: 42)?.command, command)
      XCTAssertNil(try update(command, user: 43).authorizedCallback(userID: 42))
      XCTAssertNil(try update(command, type: "group").authorizedCallback(userID: 42))
    }
    for command in ["/queue 0", "/queue -1", "qcancel:bad:1"] {
      XCTAssertNil(try update(command).authorizedCallback(userID: 42))
    }
  }
}
