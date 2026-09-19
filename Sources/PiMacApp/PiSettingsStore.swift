import Foundation

/// The subset of Pi's global settings that the native model picker manages.
struct PiModelPreferences {
  var enabledModels: [String]?
  var thinkingLevels: [String: String]

  func includes(_ model: PiModel) -> Bool {
    guard let enabledModels, !enabledModels.isEmpty else { return true }
    return enabledModels.contains { pattern in
      let pattern = Self.modelPattern(from: pattern)
      return Self.glob(pattern, matches: model.id) || Self.glob(pattern, matches: model.modelId)
    }
  }

  private static func modelPattern(from value: String) -> String {
    let levels = Set(["off", "minimal", "low", "medium", "high", "xhigh", "max"])
    guard let colon = value.lastIndex(of: ":"),
      levels.contains(String(value[value.index(after: colon)...]))
    else { return value }
    return String(value[..<colon])
  }

  private static func glob(_ pattern: String, matches value: String) -> Bool {
    var expression = "^"
    var index = pattern.startIndex
    while index < pattern.endIndex {
      let character = pattern[index]
      if character == "*" {
        expression += ".*"
      } else if character == "?" {
        expression += "."
      } else {
        expression += NSRegularExpression.escapedPattern(for: String(character))
      }
      index = pattern.index(after: index)
    }
    expression += "$"
    return value.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
  }
}

enum PiSettingsStore {
  static var globalURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".pi/agent/settings.json")
  }

  static func loadModelPreferences() -> PiModelPreferences {
    let settings = loadJSON()
    let rawLevels = settings["modelThinkingLevels"] as? [String: Any] ?? [:]
    let levels = rawLevels.compactMapValues { $0 as? String }
    return PiModelPreferences(
      enabledModels: settings["enabledModels"] as? [String],
      thinkingLevels: levels
    )
  }

  static func setEnabledModelIDs(_ ids: [String]) throws {
    var settings = loadJSON()
    settings["enabledModels"] = ids
    try saveJSON(settings)
  }

  static func setThinkingLevel(_ level: String?, for modelID: String) throws {
    var settings = loadJSON()
    var levels = (settings["modelThinkingLevels"] as? [String: Any]) ?? [:]
    if let level {
      levels[modelID] = level
    } else {
      levels.removeValue(forKey: modelID)
    }
    if levels.isEmpty {
      settings.removeValue(forKey: "modelThinkingLevels")
    } else {
      settings["modelThinkingLevels"] = levels
    }
    try saveJSON(settings)
  }

  private static func loadJSON() -> [String: Any] {
    guard let data = try? Data(contentsOf: globalURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
  }

  private static func saveJSON(_ settings: [String: Any]) throws {
    let directory = globalURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: settings,
      options: [.prettyPrinted, .sortedKeys]
    )
    var terminated = data
    terminated.append(0x0A)
    try terminated.write(to: globalURL, options: .atomic)
  }
}
