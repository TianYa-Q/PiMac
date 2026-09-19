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

  @Test func missingScopeShowsAllModels() {
    let model = PiModel(provider: "anthropic", modelId: "claude", name: "Claude")
    #expect(PiModelPreferences(enabledModels: nil, thinkingLevels: [:]).includes(model))
    #expect(PiModelPreferences(enabledModels: [], thinkingLevels: [:]).includes(model))
  }
}
