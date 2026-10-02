import XCTest

@testable import PiMacApp

final class TelegramChoiceTests: XCTestCase {
  func testSelectionSurvivesReorderingInsertionAndRemovalOfOtherItems() {
    for kind in TelegramPresentation.ChoiceKind.allCases {
      let command = TelegramPresentation.choiceCommand(kind, value: "selected")
      XCTAssertEqual(
        TelegramPresentation.choiceIndex(
          command, kind: kind, values: ["first", "selected", "last"]), 1)
      XCTAssertEqual(
        TelegramPresentation.choiceIndex(
          command, kind: kind, values: ["new", "last", "first", "selected"]), 3)
      XCTAssertEqual(TelegramPresentation.choiceIndex(command, kind: kind, values: ["selected"]), 0)
      XCTAssertNil(
        TelegramPresentation.choiceIndex(command, kind: kind, values: ["first", "last"]))
    }
  }

  func testMissingAmbiguousAndLegacyChoicesCannotSelectAnotherItem() {
    let command = TelegramPresentation.choiceCommand(.account, value: "work")
    XCTAssertNil(
      TelegramPresentation.choiceIndex(command, kind: .account, values: ["work", "work"]))
    XCTAssertNil(TelegramPresentation.choiceIndex(command, kind: .model, values: ["work"]))
    XCTAssertNil(TelegramPresentation.choiceIndex("account:1", kind: .account, values: ["work"]))
    XCTAssertNil(TelegramPresentation.choiceIndex("select:1", kind: .project, values: ["/project"]))
    XCTAssertNil(TelegramPresentation.choiceIndex("model:1", kind: .model, values: ["model"]))
  }

  func testChoiceIDsAreStableNamespacedAndWithinTelegramByteLimit() {
    let value = "/very long/" + String(repeating: "👩🏽‍💻项目", count: 100)
    var commands = Set<String>()
    for kind in TelegramPresentation.ChoiceKind.allCases {
      let command = TelegramPresentation.choiceCommand(kind, value: value)
      XCTAssertEqual(command, TelegramPresentation.choiceCommand(kind, value: value))
      XCTAssertEqual(TelegramPresentation.choiceKind(command), kind)
      XCTAssertLessThanOrEqual(command.utf8.count, 64)
      XCTAssertFalse(command.contains(value))
      commands.insert(command)
    }
    XCTAssertEqual(commands.count, 3)
  }

  func testNewMutationButtonsStillRequireMatchingCardSession() {
    let first = TelegramMessageSessionStore.Location(project: "/a", sessionPath: "/a/one")
    let second = TelegramMessageSessionStore.Location(project: "/a", sessionPath: "/a/two")
    for kind in [TelegramPresentation.ChoiceKind.model, .account] {
      let command = TelegramPresentation.choiceCommand(kind, value: "item")
      XCTAssertTrue(TelegramPresentation.canPerform(command, card: first, selected: first))
      XCTAssertFalse(TelegramPresentation.canPerform(command, card: first, selected: second))
      XCTAssertFalse(TelegramPresentation.canPerform(command, card: nil, selected: first))
    }
    let project = TelegramPresentation.choiceCommand(.project, value: "/b")
    XCTAssertTrue(TelegramPresentation.canPerform(project, card: nil, selected: nil))
    let rows = TelegramPresentation.footer(command: project, running: false, hasSession: true)
    XCTAssertTrue(rows.flatMap { $0 }.contains { $0["callback_data"] == "/new" })
  }

  func testSelectionFeedbackDoesNotClaimUnconfirmedSuccess() {
    let pending = TelegramPresentation.selectionFeedback(
      label: "模型", value: "provider/model", confirmed: false)
    XCTAssertTrue(pending.contains("切换待确认"))
    XCTAssertTrue(pending.contains("目标：provider/model"))
    XCTAssertFalse(pending.contains("✅"))
    let confirmed = TelegramPresentation.selectionFeedback(
      label: "推理强度", value: "high", confirmed: true)
    XCTAssertTrue(confirmed.contains("✅ 推理强度已切换"))
    XCTAssertTrue(confirmed.contains("high"))
  }

  func testStableChoiceCallbacksRequireAuthorizedPrivateChatAndValidID() throws {
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
    for kind in TelegramPresentation.ChoiceKind.allCases {
      let command = TelegramPresentation.choiceCommand(kind, value: "item")
      XCTAssertEqual(try update(command).authorizedCallback(userID: 42)?.command, command)
      XCTAssertNil(try update(command, user: 43).authorizedCallback(userID: 42))
      XCTAssertNil(try update(command, type: "group").authorizedCallback(userID: 42))
    }
    for command in [
      "project:", "modelid:abc", "accountid:" + String(repeating: "g", count: 32),
      "project:" + String(repeating: "a", count: 33),
    ] {
      XCTAssertNil(try update(command).authorizedCallback(userID: 42))
    }
  }
}
