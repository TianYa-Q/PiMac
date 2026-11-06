import Foundation
import Testing

@testable import PiMacApp

@MainActor
struct ActivityContentMappingTests {
  @Test func contentUpdateTimeSurvivesProjectionAndModelMapping() throws {
    let started = "2026-10-11T00:00:00Z"
    let updated = "2026-10-11T00:02:00Z"
    let model = AppModel()
    model.currentSessionPath = "t3:thread"
    model.apply(
      T3V2Presentation.detail([
        "projection": [
          "thread": ["id": "thread"],
          "visibleTurnItems": [
            [
              "item": [
                "id": "thinking", "type": "reasoning", "text": "新思考",
                "startedAt": started, "updatedAt": updated,
              ]
            ],
            [
              "item": [
                "id": "tool", "type": "command_execution", "input": "pwd",
                "startedAt": started, "updatedAt": updated, "status": "running",
              ]
            ],
          ],
        ]
      ]))
    let entries = model.messages
    #expect(entries.count == 2)
    for entry in entries {
      #expect(entry.timestamp == T3DesktopClient.date(started))
      #expect(entry.contentUpdatedAt == T3DesktopClient.date(updated))
    }
  }

}
