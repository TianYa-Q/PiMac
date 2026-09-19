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
  private static let compactionExtensionSource = #"""
    import { readFileSync } from "node:fs";
    import { homedir } from "node:os";
    import { join } from "node:path";
    import { uuidv7 } from "@earendil-works/pi-ai";
    import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
    import { convertToLlm, serializeConversation } from "@earendil-works/pi-coding-agent";

    const configPath = join(homedir(), ".pi", "agent", "pi-mac-compaction.json");

    export default function (pi: ExtensionAPI) {
      pi.on("session_before_compact", async (event, ctx) => {
        let config: { provider?: string; modelId?: string };
        try {
          config = JSON.parse(readFileSync(configPath, "utf8"));
        } catch {
          return;
        }
        if (!config.provider || !config.modelId) return;
        const model = ctx.modelRegistry.find(config.provider, config.modelId);
        if (!model) return;

        const { preparation, signal, customInstructions } = event;
        const messages = [
          ...preparation.messagesToSummarize,
          ...preparation.turnPrefixMessages,
        ];
        const conversation = serializeConversation(convertToLlm(messages));
        const previous = preparation.previousSummary
          ? `\n<previous-summary>\n${preparation.previousSummary}\n</previous-summary>`
          : "";
        const focus = customInstructions ? `\nAdditional focus: ${customInstructions}` : "";
        const prompt = `Summarize the conversation as a context checkpoint for another LLM.
    Preserve goals, constraints, completed and ongoing work, decisions, exact file paths,
    function names, errors, blockers, and next steps. Use concise structured Markdown.${focus}
    <conversation>\n${conversation}\n</conversation>${previous}`;

        const response = await ctx.modelRegistry.complete(
          model,
          { messages: [{ role: "user", content: [{ type: "text", text: prompt }], timestamp: Date.now() }] },
          { maxTokens: Math.min(8192, model.maxTokens || 8192), signal, cacheRetention: "none", sessionId: uuidv7() },
        );
        let summary = response.content
          .filter((block): block is { type: "text"; text: string } => block.type === "text")
          .map((block) => block.text)
          .join("\n");
        if (!summary.trim()) return;

        const modified = new Set([
          ...preparation.fileOps.written,
          ...preparation.fileOps.edited,
        ]);
        const readFiles = [...preparation.fileOps.read].filter((path) => !modified.has(path)).sort();
        const modifiedFiles = [...modified].sort();
        if (readFiles.length) summary += `\n\n<read-files>\n${readFiles.join("\n")}\n</read-files>`;
        if (modifiedFiles.length) summary += `\n\n<modified-files>\n${modifiedFiles.join("\n")}\n</modified-files>`;

        return {
          compaction: {
            summary,
            firstKeptEntryId: preparation.firstKeptEntryId,
            tokensBefore: preparation.tokensBefore,
            usage: response.usage,
            details: {
              readFiles,
              modifiedFiles,
              compactionProvider: model.provider,
              compactionModelId: model.id,
            },
          },
        };
      });
    }
    """#

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

  static func compactionModelID() -> String? {
    guard let data = try? Data(contentsOf: compactionConfigURL),
      let config = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      let provider = config["provider"], let modelID = config["modelId"]
    else { return nil }
    return "\(provider)/\(modelID)"
  }

  static func installCompactionExtension() throws {
    let extensionsDirectory = globalURL.deletingLastPathComponent()
      .appendingPathComponent("extensions", isDirectory: true)
    try FileManager.default.createDirectory(
      at: extensionsDirectory,
      withIntermediateDirectories: true
    )
    try Data(compactionExtensionSource.utf8).write(
      to: compactionExtensionURL,
      options: .atomic
    )
  }

  static func setCompactionModel(_ model: PiModel?) throws {
    let fileManager = FileManager.default
    try installCompactionExtension()

    if let model {
      let config = ["provider": model.provider, "modelId": model.modelId]
      let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
      try data.write(to: compactionConfigURL, options: .atomic)
    } else if fileManager.fileExists(atPath: compactionConfigURL.path) {
      try fileManager.removeItem(at: compactionConfigURL)
    }
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

  private static var compactionConfigURL: URL {
    globalURL.deletingLastPathComponent().appendingPathComponent("pi-mac-compaction.json")
  }

  private static var compactionExtensionURL: URL {
    globalURL.deletingLastPathComponent()
      .appendingPathComponent("extensions/pi-mac-compaction-model.ts")
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
