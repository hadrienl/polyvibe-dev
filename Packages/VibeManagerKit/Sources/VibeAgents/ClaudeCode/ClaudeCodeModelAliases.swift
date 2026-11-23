import Foundation
import VibeApplication

/// What Claude Code's aliases — `opus`, `sonnet`, `haiku` — stand for, as it is configured (#575).
///
/// The application starts the CLI with an environment reduced to a few keys
/// (`AgentEnvironmentPolicy`): what reaches it of a model's configuration is what its own settings
/// files set in their `env`, the managed settings over the user's. An alias set there names that
/// model. On Bedrock, Vertex or Foundry the aliases name the cloud's own identifiers, which nothing
/// here can read: they are left as they are rather than named after a model of the catalogue. An
/// alias set nowhere is the CLI's own default, the newest model of its family the catalogue lists.
///
/// A project's own settings, in the session's folder, may set them too: they are not read, so a
/// project that does is named after the user's configuration.
public struct ClaudeCodeModelAliases: Sendable {
  /// Each alias, and the variable that sets the model it stands for.
  static let variables = [
    "opus": "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "sonnet": "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "haiku": "ANTHROPIC_DEFAULT_HAIKU_MODEL",
  ]
  /// The variables that move the CLI onto a cloud provider, whose identifiers are its own.
  static let cloudVariables = [
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
  ]
  static let maximumSettingsByteCount = 1024 * 1024
  /// Where an administrator's settings live on macOS: they win over the user's.
  static let managedSettings = URL(
    fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")

  /// The settings files read, the one that wins first.
  let settingsFiles: [URL]

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.init(
      settingsFiles: [
        Self.managedSettings,
        ClaudeCodeHome.directory(environment: environment)
          .appendingPathComponent("settings.json", isDirectory: false),
      ])
  }

  init(settingsFiles: [URL]) {
    self.settingsFiles = settingsFiles
  }

  public func aliases() -> [String: AgentModelAlias] {
    // The first file that sets a variable wins.
    var environment: [String: String] = [:]
    for file in settingsFiles {
      environment.merge(Self.environment(in: file)) { winner, _ in winner }
    }
    let onCloud = Self.cloudVariables.contains { Self.isTrue(environment[$0]) }
    var aliases: [String: AgentModelAlias] = [:]
    for (alias, variable) in Self.variables {
      let configured = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let configured, !configured.isEmpty {
        aliases[alias] = .model(configured)
      } else if onCloud {
        aliases[alias] = .unknown
      }
    }
    return aliases
  }

  /// The `env` of a settings file: its strings, the rest ignored. Nothing when it cannot be read.
  private static func environment(in file: URL) -> [String: String] {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      let size = attributes[.size] as? NSNumber,
      size.intValue > 0, size.intValue <= maximumSettingsByteCount,
      let data = try? Data(contentsOf: file),
      let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let environment = settings["env"] as? [String: Any]
    else { return [:] }
    return environment.compactMapValues { value in
      switch value {
      case let string as String: return string
      case let number as NSNumber: return number.stringValue
      default: return nil
      }
    }
  }

  /// How the CLI reads a flag: `1`, `true` or `yes`, whatever the case.
  private static func isTrue(_ value: String?) -> Bool {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
      return false
    }
    return ["1", "true", "yes"].contains(value)
  }
}
