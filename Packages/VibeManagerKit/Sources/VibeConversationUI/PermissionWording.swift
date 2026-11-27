import Foundation
import VibeApplication

/// What "always allow" allows, in words: shared by the conversation's card and the palette, which
/// offer the same answers (#541).
public enum PermissionWording {
  /// Its rules and how long they last.
  public static func alwaysAllowTitle(_ allow: AgentAlwaysAllow) -> LocalizedStringResource {
    let rules = allow.rules.map(ruleDescription).joined(separator: ", ")
    switch allow.scope {
    case .session:
      return LocalizedStringResource(
        "Always allow \(rules) for this session", bundle: .module,
        comment: "A button answering an agent's permission. The argument lists what is allowed.")
    case .project:
      return LocalizedStringResource(
        "Always allow \(rules) in this project", bundle: .module,
        comment: "A button answering an agent's permission. The argument lists what is allowed.")
    case .user:
      return LocalizedStringResource(
        "Always allow \(rules) everywhere", bundle: .module,
        comment: "A button answering an agent's permission. The argument lists what is allowed.")
    }
  }

  static func ruleDescription(_ rule: AgentAlwaysAllow.Rule) -> String {
    switch rule {
    case .directories(let folders):
      let names = folders.map { URL(fileURLWithPath: $0).lastPathComponent }
      return String(
        localized: LocalizedStringResource(
          "access to \(names.joined(separator: ", "))", bundle: .module,
          comment: "What always allowing grants: access to these folders."))
    case .toolRule(let tool, let content):
      return DisplaySafeText.visible(content.map { "\(tool)(\($0))" } ?? tool)
    case .mode(let mode):
      return mode == "acceptEdits"
        ? String(
          localized: LocalizedStringResource(
            "file edits", bundle: .module,
            comment: "What always allowing grants: the agent's file edits, accepted as they come."))
        : DisplaySafeText.visible(mode)
    case .commandPrefix:
      return String(
        localized: LocalizedStringResource(
          "commands starting the same way", bundle: .module,
          comment: "What always allowing grants: commands with the same beginning."))
    case .commandsStartingWith(let prefix):
      let prefix = DisplaySafeText.visible(prefix)
      return String(
        localized: LocalizedStringResource(
          "commands starting with “\(prefix)”", bundle: .module,
          comment:
            "What always allowing grants: commands that start with these words, as the agent's dialog names them (`ls`, `git status`)."
        ))
    case .files:
      return String(
        localized: LocalizedStringResource(
          "changes to these files", bundle: .module,
          comment: "What always allowing grants: further changes to the same files."))
    }
  }
}
