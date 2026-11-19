import Foundation
import VibeApplication
import VibeDomain

/// The bookmarks of each session's conversation (#567): `Bookmarks/<session-uuid>.json` next to
/// `sessions.json`, `{"version": 1, "entries": ["<entry id>", …]}`.
///
/// Written as the notes are — a temporary file moved over, `0600` in a `0700` folder — and kept
/// the same way: a file that cannot be read, or that a later build wrote, is never written over;
/// a file whose session is gone stays, for a store restored from its backup.
public actor FileConversationBookmarkStore: ConversationBookmarkStore {
  static let version = 1

  private struct File: Codable {
    var version: Int
    var entries: [String]
  }

  private let directory: URL

  public init(directory: URL = FileConversationBookmarkStore.defaultDirectory()) {
    self.directory = directory
  }

  /// `Bookmarks/` next to `sessions.json`.
  public static func defaultDirectory() -> URL {
    FileSessionRepository.defaultStoreURL().deletingLastPathComponent()
      .appendingPathComponent("Bookmarks", isDirectory: true)
  }

  public func bookmarks(for id: SessionID) throws -> Set<String> {
    try read(id) ?? []
  }

  public func save(_ entries: Set<String>, for id: SessionID) throws {
    // Read first: what cannot be read is not replaced.
    _ = try read(id)
    let url = fileURL(for: id)
    guard !entries.isEmpty else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(File(version: Self.version, entries: entries.sorted()))
    try AtomicFileWriter.write(data, to: url)
  }

  public nonisolated func fileURL(for id: SessionID) -> URL {
    directory.appendingPathComponent("\(id.rawValue.uuidString).json", isDirectory: false)
  }

  /// `nil` when the session has no bookmarks.
  private func read(_ id: SessionID) throws -> Set<String>? {
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url),
      let file = try? JSONDecoder().decode(File.self, from: data),
      file.version <= Self.version
    else { throw ConversationBookmarkError.unreadable }
    return Set(file.entries)
  }
}
