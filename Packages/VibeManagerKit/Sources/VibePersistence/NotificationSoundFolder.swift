import Foundation
import VibeApplication

/// `~/Library/Sounds`, where the notifications of an application outside a sandbox find the
/// sounds they play (#393). One file of the application's at a time, named after it and the
/// sound: "Polyvibe – Chime.wav". It also appears among the alert sounds of System Settings.
/// A copy of the application under another name — a test build — keeps its own file, and leaves
/// the others alone.
public struct NotificationSoundFolder: NotificationSoundInstalling {
  private let prefix: String
  private let formerPrefixes: [String]
  private let directory: URL

  /// - Parameters:
  ///   - applicationName: the bundle's name, which the file's starts with.
  ///   - formerApplicationNames: the names the application had before, whose file it removes
  ///     like its own: "Vibe Manager – Chime.wav" is left over once Vibe Manager became Polyvibe.
  public init(
    applicationName: String,
    formerApplicationNames: [String] = [],
    directory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Sounds", isDirectory: true)
  ) {
    prefix = "\(applicationName) – "
    formerPrefixes = formerApplicationNames.map { "\($0) – " }
    self.directory = directory
  }

  /// The names the release had before: only the release removes their file, never a test build,
  /// which leaves alone the sound of another copy the user may still run.
  public static func formerNames(of applicationName: String) -> [String] {
    applicationName == "Polyvibe" ? ["Vibe Manager"] : []
  }

  public func install(_ source: URL, name: String) throws -> String {
    let fileManager = FileManager.default
    let safe = fileName(name, extension: source.pathExtension)
    let destination = directory.appendingPathComponent(safe)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    // The same sound already there is left alone; another one under the same name is replaced.
    if fileManager.contentsEqual(atPath: source.path, andPath: destination.path) {
      removeOthers(keeping: safe)
      return safe
    }
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
    // Whatever fails, no copy is left behind: the folder is the user's.
    defer { try? fileManager.removeItem(at: temporary) }
    try fileManager.copyItem(at: source, to: temporary)
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try fileManager.moveItem(at: temporary, to: destination)
    }
    removeOthers(keeping: safe)
    return safe
  }

  public func clear() {
    removeOthers(keeping: nil)
  }

  private func removeOthers(keeping kept: String?) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    let prefixes = [prefix] + formerPrefixes
    for name in names where prefixes.contains(where: name.hasPrefix) && name != kept {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  /// The sound's name, without what a file name cannot hold: separators, control or format
  /// characters, and more bytes than APFS takes.
  func fileName(_ name: String, extension pathExtension: String) -> String {
    let cleaned = name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
    let base = AlertSoundRules.prefix(
      String(
        AlertSoundRules.visible(String(cleaned)).trimmingCharacters(in: .whitespaces).prefix(60)),
      bytes: AlertSoundRules.maximumNameBytes)
    let ext = pathExtension.isEmpty ? "wav" : pathExtension
    return "\(prefix)\(base.isEmpty ? "Sound" : base).\(ext)"
  }
}
