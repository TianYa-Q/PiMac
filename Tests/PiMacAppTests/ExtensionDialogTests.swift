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
      ui.handle(["id": "request-\(index)", "method": "select"], from: source)
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
