import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct StatusPresentationTests {
  @Test func savingUnchangedPathPreservesStatus() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.statusText = "已有状态"
    model.piPath = model.piPath
    #expect(model.statusText == "已有状态")
  }

  @Test func ordinaryStatusDoesNotShowProgress() {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.statusText = "已保存"
    #expect(!model.showsStatusProgress)
    model.isLoadingConfiguration = true
    #expect(model.showsStatusProgress)
    model.isLoadingConfiguration = false
    model.isStreaming = true
    #expect(model.showsStatusProgress)
  }

  @Test func replacementWithIdenticalTextCancelsOldTimer() async {
    let model = AppModel(restoreLastProjectOnLaunch: false)
    let old = model.showTransientStatus("已保存", duration: .seconds(60))
    model.statusText = "已保存"
    await old.value
    #expect(old.isCancelled)
    #expect(model.statusText == "已保存")
    await model.showTransientStatus("短暂提示", duration: .zero).value
    #expect(model.statusText.isEmpty)
  }

  @Test func changedPathNoticeExpiresWithoutClearingNewerStatus() async throws {
    let defaults = UserDefaults.standard
    let original = defaults.object(forKey: "piPath")
    defer {
      if let original {
        defaults.set(original, forKey: "piPath")
      } else {
        defaults.removeObject(forKey: "piPath")
      }
    }
    let model = AppModel(restoreLastProjectOnLaunch: false)
    model.piPath = "/tmp/pi-status-\(UUID().uuidString)"
    #expect(model.statusText.contains("路径已保存"))
    #expect(!model.showsStatusProgress)
    await model.transientStatusTask?.value
    #expect(model.statusText.isEmpty)

    model.piPath = "/tmp/pi-status-\(UUID().uuidString)"
    let timer = model.transientStatusTask
    model.statusText = "新的状态"
    await timer?.value
    #expect(model.statusText == "新的状态")
  }
}
