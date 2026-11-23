import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

/// What Claude Code's aliases stand for, read from its settings (#575).
@Suite("Claude Code's aliases, as its settings configure them")
struct ClaudeCodeModelAliasesTests {
  private func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-claude-aliases-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func settings(_ json: String, in folder: URL, named name: String) throws -> URL {
    let file = folder.appendingPathComponent(name)
    try Data(json.utf8).write(to: file)
    return file
  }

  @Test("An alias set in the settings names that model; one set nowhere is the catalogue's")
  func configuredAlias() throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let user = try settings(
      #"{"env": {"ANTHROPIC_DEFAULT_OPUS_MODEL": " claude-opus-5 ", "OTHER": 1}}"#, in: folder,
      named: "settings.json")

    let aliases = ClaudeCodeModelAliases(settingsFiles: [user]).aliases()

    #expect(aliases == ["opus": .model("claude-opus-5")])
  }

  @Test("The managed settings win over the user's")
  func managedWins() throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let managed = try settings(
      #"{"env": {"ANTHROPIC_DEFAULT_SONNET_MODEL": "managed-sonnet"}}"#, in: folder,
      named: "managed.json")
    let user = try settings(
      """
      {"env": {"ANTHROPIC_DEFAULT_SONNET_MODEL": "user-sonnet",
               "ANTHROPIC_DEFAULT_HAIKU_MODEL": "user-haiku"}}
      """, in: folder, named: "settings.json")

    let aliases = ClaudeCodeModelAliases(settingsFiles: [managed, user]).aliases()

    #expect(aliases == ["sonnet": .model("managed-sonnet"), "haiku": .model("user-haiku")])
  }

  @Test("On a cloud provider, an alias set nowhere cannot be named; one set is still its model")
  func cloudAliasesAreUnknown() throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let user = try settings(
      #"{"env": {"CLAUDE_CODE_USE_BEDROCK": "1", "ANTHROPIC_DEFAULT_HAIKU_MODEL": "eu.haiku"}}"#,
      in: folder, named: "settings.json")

    let aliases = ClaudeCodeModelAliases(settingsFiles: [user]).aliases()

    #expect(aliases == ["opus": .unknown, "sonnet": .unknown, "haiku": .model("eu.haiku")])
  }

  @Test("A missing, empty or malformed settings file configures nothing")
  func unreadableSettings() throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let empty = try settings("", in: folder, named: "empty.json")
    let malformed = try settings("{not json", in: folder, named: "malformed.json")
    let missing = folder.appendingPathComponent("missing.json")

    let aliases = ClaudeCodeModelAliases(settingsFiles: [missing, empty, malformed]).aliases()

    #expect(aliases.isEmpty)
  }
}
