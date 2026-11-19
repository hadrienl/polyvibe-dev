import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@Suite("The bookmarks of each conversation, one file per session (#567)")
struct FileConversationBookmarkStoreTests {
  private func directory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-bookmarks-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("Bookmarks", isDirectory: true)
  }

  private func mode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
  }

  @Test("Bookmarks saved are read back, in a file only the owner can open")
  func roundTrip() async throws {
    let root = directory()
    let store = FileConversationBookmarkStore(directory: root)
    let id = SessionID()
    try await store.save(["b", "a"], for: id)
    #expect(try await store.bookmarks(for: id) == ["a", "b"])
    let url = store.fileURL(for: id)
    #expect(url.lastPathComponent == "\(id.rawValue.uuidString).json")
    #expect(try mode(of: url) == 0o600)
    #expect(try mode(of: root) == 0o700)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text == #"{"entries":["a","b"],"version":1}"#)
  }

  @Test("A session without bookmarks has none, and its last one removed leaves no file")
  func empty() async throws {
    let store = FileConversationBookmarkStore(directory: directory())
    let id = SessionID()
    #expect(try await store.bookmarks(for: id).isEmpty)
    try await store.save(["a"], for: id)
    try await store.save([], for: id)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: id).path))
    #expect(try await store.bookmarks(for: id).isEmpty)
  }

  @Test("Each session keeps its own")
  func perSession() async throws {
    let store = FileConversationBookmarkStore(directory: directory())
    let first = SessionID()
    let second = SessionID()
    try await store.save(["a"], for: first)
    try await store.save(["b"], for: second)
    #expect(try await store.bookmarks(for: first) == ["a"])
    #expect(try await store.bookmarks(for: second) == ["b"])
  }

  @Test(
    "A file that cannot be read, or that a later build wrote, is said so and never written over",
    arguments: ["not json", #"{"version":2,"entries":["a"]}"#])
  func unreadable(content: String) async throws {
    let store = FileConversationBookmarkStore(directory: directory())
    let id = SessionID()
    try await store.save(["kept"], for: id)
    let url = store.fileURL(for: id)
    try Data(content.utf8).write(to: url)
    await #expect(throws: ConversationBookmarkError.unreadable) {
      try await store.bookmarks(for: id)
    }
    await #expect(throws: ConversationBookmarkError.unreadable) {
      try await store.save(["new"], for: id)
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == content)
  }
}
