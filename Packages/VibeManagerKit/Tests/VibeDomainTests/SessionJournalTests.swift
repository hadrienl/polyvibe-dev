import Foundation
import Testing

@testable import VibeDomain

@Suite("The journal of a session")
struct SessionJournalTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func resource(
    _ key: String, _ kind: SessionResource.Kind = .issue, label: String = "#1",
    _ involvement: SessionResource.Involvement = .viewed, at offset: TimeInterval = 0
  ) -> SessionResource {
    SessionResource(
      key: key, kind: kind, label: label, context: "o/r",
      target: .web(URL(string: "https://github.com/o/r/issues/1")!), involvement: involvement,
      firstSeenAt: start.addingTimeInterval(offset))
  }

  @Test("Resources are kept once, in the order they were first seen")
  func deduplication() {
    var journal = SessionJournal()
    journal.record([resource("a"), resource("b"), resource("a", at: 60)])
    #expect(journal.resources.map(\.key) == ["a", "b"])
    #expect(journal.resources[0].firstSeenAt == start)
    #expect(journal.resources[0].lastSeenAt == start.addingTimeInterval(60))
  }

  @Test("Involvement only ever rises: a request created then viewed stays created")
  func involvementRises() {
    var journal = SessionJournal()
    journal.record([resource("a", .pullRequest, .created)])
    journal.record([resource("a", .pullRequest, .viewed)])
    #expect(journal.resources.first?.involvement == .created)
  }

  @Test("On GitHub, a number first seen as an issue that is a pull request becomes one")
  func pullRequestWins() {
    var journal = SessionJournal()
    journal.record([resource("github:x#62", .issue, label: "#62")])
    var request = resource("github:x#62", .pullRequest, label: "#62")
    request.target = .web(URL(string: "https://github.com/o/r/pull/62")!)
    journal.record([request])
    #expect(journal.resources.first?.kind == .pullRequest)
    #expect(journal.resources.first?.target == request.target)
  }

  @Test("Past the bound, resources are no longer kept")
  func resourceBound() {
    var journal = SessionJournal()
    let filled = journal.record((0..<SessionJournal.resourceLimit).map { resource("k\($0)") })
    let past = journal.record([resource("past")])
    #expect(filled)
    #expect(!past)
    #expect(journal.resources.count == SessionJournal.resourceLimit)
  }

  @Test("A journal survives a round trip through JSON")
  func codable() throws {
    var journal = SessionJournal()
    journal.record([resource("a", .branch, label: "x")])
    journal.resources[0].target = .branch(repositoryPath: "/r", webURL: nil)
    journal.entries = [JournalEntry(text: "Pushed", at: start)]
    journal.cursors["/t.jsonl"] = TranscriptCursor(offset: 12, inode: 3)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionJournal.self, from: encoder.encode(journal))
    #expect(decoded == journal)
  }

  /// A journal as the builds before #572 decode it: these keys required.
  private struct EarlierJournal: Decodable {
    enum Summary: Decodable {
      case ready
    }
    let resources: [SessionResource]
    let cursors: [String: TranscriptCursor]
    let pending: [String]
    let summary: Summary
    let hasEndedTurn: Bool
  }

  @Test("A journal written now is read by the builds before #572, nothing left to summarize")
  func readByEarlierBuilds() throws {
    var journal = SessionJournal(cursors: ["/t.jsonl": TranscriptCursor(offset: 12)])
    journal.record([resource("a")])
    let data = try JSONEncoder().encode(journal)
    let earlier = try JSONDecoder().decode(EarlierJournal.self, from: data)
    #expect(earlier.resources.map(\.key) == ["a"])
    #expect(earlier.cursors["/t.jsonl"]?.offset == 12)
    #expect(earlier.pending.isEmpty)
    #expect(!earlier.hasEndedTurn)
    #expect(try JSONDecoder().decode(SessionJournal.self, from: data) == journal)
  }

  @Test("A journal written while summaries were made is read: its lines kept, the rest left aside")
  func journalOfBefore() throws {
    // As #36 wrote it, with turns waiting and the state of the summary.
    let json = """
      {"schema":1,"entries":[{"id":"0B3C8E59-0F3F-4F63-9C3B-2E8C7A5D9B11","text":"Pushed the branch",\
      "at":"2027-01-15T08:00:00Z","providerID":"claude-code"}],"resources":[],\
      "overflowResourceCount":0,"cursors":{"/t.jsonl":{"offset":12}},\
      "pending":[{"id":"6D1C9A1E-1B6B-4F0A-8B9E-6D5F2E3A4B7C","prompts":["fix"],"actions":[],\
      "omittedActions":0}],"summary":{"failed":{"at":"2027-01-15T08:00:00Z","attempts":2}},\
      "hasEndedTurn":true,"summarizedAt":"2027-01-15T08:00:00Z"}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let journal = try decoder.decode(SessionJournal.self, from: Data(json.utf8))
    #expect(journal.entries.map(\.text) == ["Pushed the branch"])
    #expect(journal.cursors["/t.jsonl"]?.offset == 12)
  }
}
