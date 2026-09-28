import Foundation
import Testing

@testable import PiMacApp

@Suite struct PiSettingsStoreTests {
  @Test func matchesEnabledModelsByFullOrBareGlobAndIgnoresThinkingSuffix() {
    let codex = PiModel(provider: "openai-codex", modelId: "gpt-5.6-sol", name: "GPT")
    let gemini = PiModel(provider: "antigravity", modelId: "gemini-3.8-flash", name: "Gemini")

    let preferences = PiModelPreferences(
      enabledModels: ["openai-codex/gpt-*:high", "gemini-3.?-flash"],
      thinkingLevels: [:]
    )

    #expect(preferences.includes(codex))
    #expect(preferences.includes(gemini))
  }

  @Test func globalThinkingDefaultPersistsWithoutOverwritingModelPreferences() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("settings.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      #"{"defaultThinkingLevel":"low","modelThinkingLevels":{"a/b":"high"},"theme":"dark"}"#.utf8
    )
    .write(to: url)

    let original = PiSettingsStore.loadModelPreferences(from: url)
    #expect(original.thinkingLevel(for: "a/b") == "high")
    #expect(original.thinkingLevel(for: "c/d") == "low")

    try PiSettingsStore.setDefaultThinkingLevel("xhigh", at: url)
    let updated = PiSettingsStore.loadModelPreferences(from: url)
    #expect(updated.thinkingLevel(for: "a/b") == "high")
    #expect(updated.thinkingLevel(for: "c/d") == "xhigh")
    let data = try Data(contentsOf: url)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["theme"] as? String == "dark")
  }

  @Test func missingGlobalThinkingSettingUsesPiDefault() {
    let preferences = PiModelPreferences(enabledModels: nil, thinkingLevels: [:])
    #expect(preferences.thinkingLevel(for: "a/b") == "medium")
  }

  @Test func missingScopeShowsAllModels() {
    let model = PiModel(provider: "anthropic", modelId: "claude", name: "Claude")
    #expect(PiModelPreferences(enabledModels: nil, thinkingLevels: [:]).includes(model))
    #expect(PiModelPreferences(enabledModels: [], thinkingLevels: [:]).includes(model))
  }
}
