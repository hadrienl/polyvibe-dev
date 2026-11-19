import Foundation
import VibeDomain

/// Where each session's bookmarks are kept (#567): the entries the user marked in its
/// conversation, by identifier. Nothing of them goes to the agent nor into its transcript.
public protocol ConversationBookmarkStore: Sendable {
  /// The entries marked in the session; empty when it has none.
  ///
  /// Throws when its bookmarks exist but cannot be read: they are then never written over.
  func bookmarks(for id: SessionID) async throws -> Set<String>
  /// Writes `entries` in place of the session's bookmarks; none left removes them.
  func save(_ entries: Set<String>, for id: SessionID) async throws
}

public enum ConversationBookmarkError: Error, Equatable, Sendable {
  /// The file holds something this build cannot read: kept as it is.
  case unreadable
}

/// A store that keeps nothing, for a workspace assembled without one.
public struct NoConversationBookmarks: ConversationBookmarkStore {
  public init() {}
  public func bookmarks(for id: SessionID) async throws -> Set<String> { [] }
  public func save(_ entries: Set<String>, for id: SessionID) async throws {}
}

/// Bookmarks kept in memory, for tests and previews.
public actor InMemoryConversationBookmarkStore: ConversationBookmarkStore {
  private var storage: [SessionID: Set<String>]
  public private(set) var saveCount = 0

  public init(bookmarks: [SessionID: Set<String>] = [:]) {
    storage = bookmarks
  }

  public func bookmarks(for id: SessionID) -> Set<String> {
    storage[id] ?? []
  }

  public func save(_ entries: Set<String>, for id: SessionID) {
    saveCount += 1
    storage[id] = entries.isEmpty ? nil : entries
  }
}

/// Which blocks of a conversation hold a bookmark, and the way from one to the next (#567).
///
/// A bookmark names an entry, never a block: a group of tools is named after its first call, and
/// comes apart when tool calls stop being grouped. The entry stays the same either way, so that
/// the bookmark finds its block whatever the settings.
public enum ConversationBookmarks {
  /// The entries a block shows, in their order.
  public static func entryIDs(of block: ConversationBlock) -> [String] {
    switch block {
    case .entry(let entry): return [entry.id]
    case .toolGroup(_, let entries), .subagentGroup(_, let entries): return entries.map(\.id)
    }
  }

  public static func isMarked(_ block: ConversationBlock, in bookmarks: Set<String>) -> Bool {
    !bookmarks.isEmpty && entryIDs(of: block).contains(where: bookmarks.contains)
  }

  /// The bookmarks once the block is toggled: every entry of it unmarked when one is, its first
  /// marked otherwise.
  public static func toggled(_ bookmarks: Set<String>, on block: ConversationBlock) -> Set<String>
  {
    let entries = entryIDs(of: block)
    if entries.contains(where: bookmarks.contains) {
      return bookmarks.subtracting(entries)
    }
    guard let first = entries.first else { return bookmarks }
    return bookmarks.union([first])
  }

  /// The indices of the blocks that hold a bookmark, in the conversation's order. An entry no
  /// longer shown marks nothing, and is kept: it may come back.
  public static func markedIndices(in blocks: [ConversationBlock], bookmarks: Set<String>)
    -> [Int]
  {
    guard !bookmarks.isEmpty else { return [] }
    return blocks.indices.filter { isMarked(blocks[$0], in: bookmarks) }
  }

  /// How far into a block the top of the view may be and still stand at its start: the view a
  /// bookmark brings up puts the block there, give or take a fraction of a line.
  public static let startTolerance = 8.0

  /// The marked block after the one at the top of the view.
  ///
  /// - Parameters:
  ///   - index: the block at the top of the view.
  ///   - marked: the marked blocks, in order.
  public static func next(after index: Int, in marked: [Int]) -> Int? {
    marked.first { $0 > index }
  }

  /// The marked block before the top of the view: the one at the top itself when the view has
  /// gone past its start, the one before otherwise.
  ///
  /// - Parameter offset: how far into the block at `index` the top of the view is, in points.
  public static func previous(before index: Int, offset: Double, in marked: [Int]) -> Int? {
    if offset > startTolerance, marked.contains(index) { return index }
    return marked.last { $0 < index }
  }
}
