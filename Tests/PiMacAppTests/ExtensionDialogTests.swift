import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ExtensionDialogTests {
  @Test func expiredPresentationCannotAnswerNextRequestWithTheSameRPCID() throws {
    let ui = ExtensionUIModel()
    let first = AppModel(restoreLastProjectOnLaunch: false)
    let second = AppModel(restoreLastProjectOnLaunch: false)
    let event: PiRPCClient.JSON = ["id": "same", "method": "confirm", "title": "Allow?"]
    ui.handle(event, from: first)
    let old = try #require(ui.dialog?.presentationID)
    ui.handle(event, from: second)
    #expect(ui.pendingDialogCount == 2)
    ui.reconcileRequests(ids: [], from: first)
    let next = try #require(ui.dialog?.presentationID)
    #expect(next != old)
    #expect(ui.pendingDialogCount == 1)
    ui.answerDialog(presentationID: old, confirmed: true)
    #expect(ui.dialog?.presentationID == next)
    ui.answerDialog(presentationID: next, cancelled: true)
    #expect(ui.dialog == nil)
    #expect(ui.pendingDialogCount == 0)
  }

  @Test func duplicateRequestsDoNotConsumeQueueCapacity() {
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    let event: PiRPCClient.JSON = ["id": "one", "method": "input"]
    ui.handle(event, from: source)
    ui.handle(event, from: source)
    #expect(ui.pendingDialogCount == 1)
    for index in 0..<100 {
      ui.handle(["id": "request-\(index)", "method": "select", "options": []], from: source)
    }
    #expect(ui.pendingDialogCount == ExtensionUIModel.maximumPendingDialogs)
    ui.removeRequests(from: source)
    #expect(ui.pendingDialogCount == 0)
    #expect(ui.dialog == nil)
    ui.handle(event, from: source)
    #expect(ui.pendingDialogCount == 1)
  }

  @Test func removingOnlyQueuedRequestsUpdatesCount() {
    let ui = ExtensionUIModel()
    let first = AppModel(restoreLastProjectOnLaunch: false)
    let second = AppModel(restoreLastProjectOnLaunch: false)
    ui.handle(["id": "first", "method": "input"], from: first)
    ui.handle(["id": "second", "method": "input"], from: second)
    ui.reconcileRequests(ids: [], from: second)
    #expect(ui.pendingDialogCount == 1)
    #expect(ui.dialog?.id == "first")
    ui.handle(["id": "third", "method": "editor"], from: second)
    ui.removeRequests(from: second)
    #expect(ui.pendingDialogCount == 1)
    #expect(ui.dialog?.id == "first")
  }

  @Test func dialogBudgetsUseUTF8AndNeverTruncateWireValues() {
    let atLimit = ExtensionDialog(
      id: "ok", title: "",
      kind: .confirm(message: String(repeating: "a", count: ExtensionDialogLimits.maximumBytes)))
    #expect(ExtensionDialogLimits.accepts(atLimit))
    let tooLarge = ExtensionDialog(
      id: "large", title: "a",
      kind: .confirm(message: String(repeating: "a", count: ExtensionDialogLimits.maximumBytes)))
    #expect(!ExtensionDialogLimits.accepts(tooLarge))
    #expect(
      !ExtensionDialogLimits.accepts(
        ExtensionDialog(
          id: "unicode", title: "",
          kind: .input(
            initialText: String(repeating: "😀", count: ExtensionDialogLimits.maximumBytes / 4),
            placeholder: "x", multiline: true))))
    #expect(
      !ExtensionDialogLimits.accepts(
        ExtensionDialog(
          id: "many", title: "",
          kind: .select(
            options: Array(repeating: "", count: ExtensionDialogLimits.maximumOptions + 1)))))
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    ui.handle(
      [
        "id": "large", "method": "confirm",
        "message": String(repeating: "x", count: ExtensionDialogLimits.maximumBytes + 1),
      ], from: source)
    #expect(ui.pendingDialogCount == 0)
    #expect(ui.dialog == nil)
  }

  @Test func invalidRepliesKeepTheDialogOpen() throws {
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    ui.handle(["id": "select", "method": "select", "options": ["Allow", "Deny"]], from: source)
    let id = try #require(ui.dialog?.presentationID)
    ui.answerDialog(presentationID: id, value: "not an option")
    #expect(ui.pendingDialogCount == 1)
    ui.answerDialog(presentationID: id, value: "Allow", confirmed: true)
    #expect(ui.dialog?.presentationID == id)
    ui.answerDialog(presentationID: id, value: "Allow", cancelled: true)
    #expect(ui.dialog?.presentationID == id)
    ui.answerDialog(presentationID: id, value: "Deny")
    #expect(ui.dialog == nil)
  }

  @Test func inputResponseBudgetAndConfirmationTypes() {
    let input = ExtensionDialog(
      id: "input", title: "", kind: .input(initialText: "", placeholder: "", multiline: true))
    let limit = String(repeating: "😀", count: ExtensionDialogLimits.maximumBytes / 4)
    #expect(ExtensionDialogLimits.acceptsInput(limit))
    #expect(!ExtensionDialogLimits.acceptsInput(limit + "a"))
    #expect(
      ExtensionDialogLimits.acceptsResponse(to: input, value: "", confirmed: nil, cancelled: false))
    #expect(
      !ExtensionDialogLimits.acceptsResponse(
        to: input, value: limit + "a", confirmed: nil, cancelled: false))
    let confirm = ExtensionDialog(id: "confirm", title: "", kind: .confirm(message: ""))
    #expect(
      ExtensionDialogLimits.acceptsResponse(
        to: confirm, value: nil, confirmed: false, cancelled: false))
    #expect(
      !ExtensionDialogLimits.acceptsResponse(
        to: confirm, value: "true", confirmed: nil, cancelled: false))
    #expect(
      ExtensionDialogLimits.acceptsResponse(
        to: confirm, value: nil, confirmed: nil, cancelled: true))
  }

  @Test func malformedRequestsFailClosedAndDuplicatesStayValid() throws {
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    let malformed: [PiRPCClient.JSON] = [
      ["id": "bad", "method": "select"],
      ["id": "bad", "method": "select", "options": ["allow", 1]],
      ["id": "bad", "method": "confirm", "message": 42],
      ["id": "bad", "method": "input", "prefill": NSNull()],
      ["id": "", "method": "editor"],
      ["id": "bad", "method": "confirm", "title": false],
    ]
    for event in malformed {
      #expect(ExtensionDialogRequest.parse(event) == nil)
      ui.handle(event, from: source)
      #expect(ui.pendingDialogCount == 0)
    }
    ui.handle(["id": "valid", "method": "select", "options": ["deny"]], from: source)
    let presentationID = try #require(ui.dialog?.presentationID)
    ui.handle(["id": "valid", "method": "select", "options": false], from: source)
    #expect(ui.dialog?.presentationID == presentationID)
    #expect(ui.pendingDialogCount == 1)
  }

  @Test func selectionRequiresAnExplicitVisibleIndex() {
    let all = ExtensionOptionSearch.filter(["Allow", "Deny", "Allow"], query: "")
    #expect(ExtensionOptionSearch.selectedValue(in: all, id: nil) == nil)
    #expect(ExtensionOptionSearch.selectedValue(in: all, id: 2) == "Allow")
    let filtered = ExtensionOptionSearch.filter(all.map(\.value), query: "Deny")
    #expect(ExtensionOptionSearch.selectedValue(in: filtered, id: 0) == nil)
    #expect(ExtensionOptionSearch.selectedValue(in: filtered, id: nil) == nil)
    #expect(ExtensionOptionSearch.selectedValue(in: filtered, id: 1) == "Deny")
  }

  @Test func genericStatusesAreBoundedButExistingEntriesCanUpdateAndClear() {
    let ui = ExtensionUIModel()
    let source = AppModel(restoreLastProjectOnLaunch: false)
    func status(_ key: String, _ text: Any?) {
      var event: PiRPCClient.JSON = ["id": "status", "method": "setStatus", "statusKey": key]
      event["statusText"] = text
      ui.handle(event, from: source)
    }
    for index in 0..<100 { status("key-\(index)", "value") }
    #expect(ui.statuses.count == ExtensionStatusLimits.maximumEntries)
    status("key-0", "updated")
    #expect(ui.statuses["key-0"] == "updated")
    status("key-0", 42)
    #expect(ui.statuses["key-0"] == "updated")
    status("key-0", String(repeating: "😀", count: ExtensionStatusLimits.maximumTextBytes))
    #expect(ui.statuses["key-0"] == "updated")
    status("key-0", nil)
    status("new", "ok")
    #expect(ui.statuses["new"] == "ok")
    #expect(ui.statuses.count == ExtensionStatusLimits.maximumEntries)
    ui.removeRequests(from: source)
    #expect(ui.statuses.isEmpty)
  }

  @Test func optionSearchPreservesWireValuesOrderAndDuplicates() {
    let options = ["Café Account", "Other", "CAFÉ account", "Café Account", "中文 😀"]
    let matches = ExtensionOptionSearch.filter(options, query: " cafe  ACCOUNT ")
    #expect(matches.map(\.id) == [0, 2, 3])
    #expect(matches.map(\.value) == [options[0], options[2], options[3]])
    #expect(ExtensionOptionSearch.filter(options, query: "中文 😀").map(\.id) == [4])
    #expect(ExtensionOptionSearch.filter(options, query: "  ").count == options.count)
    #expect(ExtensionOptionSearch.filter(options, query: "[.*]").isEmpty)
  }
}
