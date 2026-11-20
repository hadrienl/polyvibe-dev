import Foundation

/// One line of a session's summary: a short action, in the past tense, as the agent's own CLI
/// wrote it. None is written any more (#572): those written before are still read, for the search
/// and the archives.
public struct JournalEntry: Hashable, Codable, Sendable, Identifiable {
  public let id: UUID
  /// Empty for the entry that stands for older entries folded away.
  public let text: String
  /// When the turn it describes ended.
  public let at: Date
  /// The agent whose turn it describes.
  public let providerID: String?
  /// How many older entries this one stands for, when the journal outgrew its bound.
  public let foldedCount: Int?

  public init(
    id: UUID = UUID(), text: String, at: Date, providerID: String?, foldedCount: Int? = nil
  ) {
    self.id = id
    self.text = text
    self.at = at
    self.providerID = providerID
    self.foldedCount = foldedCount
  }
}

/// Where the reading of one transcript file stopped.
public struct TranscriptCursor: Hashable, Codable, Sendable {
  /// Bytes read, up to the last complete line.
  public var offset: UInt64
  /// The file it was, so that a file replaced by another of the same name is read from the start.
  public var inode: UInt64?

  public init(offset: UInt64 = 0, inode: UInt64? = nil) {
    self.offset = offset
    self.inode = inode
  }
}

/// What a session did, kept apart from the session store (#36): the tickets, requests, branches
/// and worktrees it used, and where the reading of its transcripts stopped. The lines of summary
/// written until #572 are still read; keys of the summary a journal of then holds besides are
/// left aside.
public struct SessionJournal: Hashable, Codable, Sendable {
  public static let schemaVersion = 1
  /// Past this, resources are counted and no longer kept.
  public static let resourceLimit = 1_000

  public var schema: Int
  /// Written before #572, read only.
  public var entries: [JournalEntry]
  public var resources: [SessionResource]
  /// Resources seen past `resourceLimit`.
  public var overflowResourceCount: Int
  /// By transcript file path.
  public var cursors: [String: TranscriptCursor]

  public init(
    entries: [JournalEntry] = [],
    resources: [SessionResource] = [],
    overflowResourceCount: Int = 0,
    cursors: [String: TranscriptCursor] = [:]
  ) {
    schema = Self.schemaVersion
    self.entries = entries
    self.resources = resources
    self.overflowResourceCount = overflowResourceCount
    self.cursors = cursors
  }

  // MARK: - Resources

  /// Adds what was seen, in the order it was first seen. A resource seen again is merged into the
  /// one already listed, in place.
  ///
  /// - Returns: whether anything changed.
  @discardableResult
  public mutating func record(_ sightings: [SessionResource]) -> Bool {
    var changed = false
    var positions = Dictionary(
      resources.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: { a, _ in a })
    for sighting in sightings {
      if let index = positions[sighting.key] {
        let merged = resources[index].merging(sighting)
        if merged != resources[index] {
          resources[index] = merged
          changed = true
        }
      } else if resources.count < Self.resourceLimit {
        positions[sighting.key] = resources.count
        resources.append(sighting)
        changed = true
      } else {
        overflowResourceCount += 1
        changed = true
      }
    }
    return changed
  }
}
