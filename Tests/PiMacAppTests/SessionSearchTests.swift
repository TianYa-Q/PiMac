import Foundation
import Testing

@testable import PiMacApp

struct SessionSearchTests {
  @Test func scopedTermsMatchOnlyTheirFieldsAndKeepUnknownPrefixesLiteral() {
    let query = SessionSearchQuery("TITLE:\"Cafe 项目\" text:修复 -text:秘密 -title:废弃")
    #expect(query.titleRequired == ["Cafe 项目"])
    #expect(query.textRequired == ["修复"])
    #expect(query.matches(title: "Café 项目", messages: ["已修复"]))
    #expect(!query.matches(title: "Cafe 项目 修复", messages: ["无关键词"]))
    #expect(!query.matches(title: "Cafe 项目", messages: ["修复秘密"]))
    #expect(!query.acceptsTitle("废弃 Cafe 项目"))
    #expect(SessionSearchQuery("file:main.swift").required == ["file:main.swift"])
    #expect(SessionSearchQuery("title: text: -title: -text:").isEmpty)
    #expect(!SessionSearchQuery("title:项目").needsMessages(for: "项目"))
    #expect(!SessionSearchQuery("title:项目 text:正文").needsMessages(for: "其他"))
  }

  @Test func scopedSearchUsesMessageSnippetsAndAvoidsReadingTitleOnlyResults() {
    let sessions = [
      SessionItem(path: "t3:one", title: "库存修复", modifiedAt: .now),
      SessionItem(path: "t3:two", title: "其他项目", modifiedAt: .now),
    ]
    let messages = ["t3:one": ["完成库存检查"], "t3:two": ["完成库存检查"]]
    #expect(SessionSearch.results(for: "title:库存", in: sessions).map(\.id) == ["t3:one"])
    let results = SessionSearch.results(
      for: "title:库存 text:检查", in: sessions, messagesByPath: messages)
    #expect(results.map(\.id) == ["t3:one"])
    #expect(results.first?.snippet == "完成库存检查")
    #expect(SessionSearch.results(for: "text:修复", in: sessions, messagesByPath: messages).isEmpty)
    #expect(SessionSearch.results(for: "-title:库存", in: sessions).map(\.id) == ["t3:two"])
  }

  @Test func queryGrammarSupportsPhrasesExclusionsAndUnicode() {
    let query = SessionSearchQuery("  café \"修复 库存\" -秘密  ")
    #expect(query.required == ["café", "修复 库存"])
    #expect(query.excluded == ["秘密"])
    #expect(query.matches(["Cafe 项目", "修复 库存已经完成"]))
    #expect(!query.matches(["Cafe 项目", "修复 库存秘密"]))
    #expect(!query.matches(["Cafe 项目", "修复另一项库存"]))
    #expect(SessionSearchQuery("\"未闭合 短语").required == ["未闭合 短语"])
    #expect(SessionSearchQuery("-秘密").matches(["公开记录"]))
    #expect(SessionSearchQuery(" - \"\" ").isEmpty)
  }

  @Test func combinesTitleAndMessagesAndExcludesContent() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let records: [[String: Any]] = [
      ["type": "message", "message": ["role": "user", "content": "修复 库存"]],
      ["type": "message", "message": ["role": "assistant", "content": "刷新成功"]],
    ]
    var data = Data()
    for record in records {
      data.append(try JSONSerialization.data(withJSONObject: record))
      data.append(Data("\n".utf8))
    }
    // Bad bytes in a separate record must not make all earlier messages unsearchable.
    data.append(Data([0xff, 0x0a]))
    try data.write(to: url)
    let session = SessionItem(path: url.path, title: "Cafe 项目", modifiedAt: .now)
    let results = SessionSearch.results(for: "café \"修复 库存\" 刷新", in: [session])
    #expect(results.count == 1)
    #expect(results.first?.snippet == "修复 库存")
    #expect(SessionSearch.results(for: "café -刷新", in: [session]).isEmpty)
    #expect(SessionSearch.results(for: "-秘密", in: [session]).count == 1)
  }

  @Test
  func searchesTitlesAndVisibleMessageTextButNotToolsOrDiscardedBranches() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func session(_ name: String, _ records: [[String: Any]]) throws -> SessionItem {
      let url = directory.appendingPathComponent(name + ".jsonl")
      let data = try records.reduce(into: Data()) { output, record in
        output.append(try JSONSerialization.data(withJSONObject: record))
        output.append(Data("\n".utf8))
      }
      try data.write(to: url)
      return SessionItem(path: url.path, title: name, modifiedAt: .now)
    }

    let first = try session(
      "项目记录",
      [
        [
          "type": "message", "id": "a", "parentId": NSNull(),
          "message": ["role": "user", "content": "请修复库存已变化提示"],
        ],
        [
          "type": "message", "id": "b", "parentId": "a",
          "message": ["role": "assistant", "content": "已经修复刷新顺序"],
        ],
        [
          "type": "message", "id": "discarded", "parentId": "a",
          "message": ["role": "assistant", "content": "废弃分支的秘密词"],
        ],
        [
          "type": "message", "id": "leaf", "parentId": "b",
          "message": ["role": "toolResult", "content": "工具输出的秘密词"],
        ],
      ])
    let second = try session("库存说明", [])
    let sessions = [first, second]
    #expect(SessionSearch.results(for: "库存", in: sessions).map(\.id) == sessions.map(\.id))
    #expect(SessionSearch.results(for: "刷新顺序", in: sessions).first?.snippet == "已经修复刷新顺序")
    #expect(SessionSearch.results(for: "秘密词", in: sessions).isEmpty)
    #expect(SessionSearch.results(for: "  ", in: sessions).isEmpty)
  }

  @Test
  func appendedMessagesInvalidateTheSearchIndex() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let session = SessionItem(path: url.path, title: "无匹配标题", modifiedAt: .now)
    func append(_ id: String, _ parentID: String?, _ content: String) throws {
      let record: [String: Any] = [
        "type": "message", "id": id, "parentId": parentID ?? NSNull() as Any,
        "message": ["role": "user", "content": content],
      ]
      let line = try JSONSerialization.data(withJSONObject: record) + Data("\n".utf8)
      if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
      } else {
        try line.write(to: url)
      }
    }
    try append("first", nil, "第一条记录")
    #expect(SessionSearch.results(for: "第二条", in: [session]).isEmpty)
    try append("second", "first", "第二条记录")
    #expect(SessionSearch.results(for: "第二条", in: [session]).first?.snippet == "第二条记录")
    #expect(SessionSearch.results(for: "第一条", in: [session]).count == 1)
  }
}
