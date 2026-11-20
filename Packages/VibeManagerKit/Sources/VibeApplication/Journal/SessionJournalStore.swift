import Foundation
import VibeDomain

public enum SessionJournalStoreError: Error, Hashable, Sendable {
  /// The file is there and cannot be read. It is never written over.
  case unreadable
  case cannotWrite(String)
}

/// Where each session's journal is kept, one file per session, apart from the session store
/// (#36): it is written as the transcripts name resources, and a session archived must keep it.
public protocol SessionJournalStore: Sendable {
  /// `nil` when the session has none.
  func journal(for id: SessionID) async throws -> SessionJournal?
  func save(_ journal: SessionJournal, for id: SessionID) async throws
}

/// Journals kept in memory, for tests and previews.
public actor InMemorySessionJournalStore: SessionJournalStore {
  private var storage: [SessionID: SessionJournal]
  public private(set) var saveCount = 0

  public init(journals: [SessionID: SessionJournal] = [:]) {
    storage = journals
  }

  public func journal(for id: SessionID) -> SessionJournal? {
    storage[id]
  }

  public func save(_ journal: SessionJournal, for id: SessionID) {
    saveCount += 1
    storage[id] = journal
  }
}
