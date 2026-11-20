import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

/// Hands each session the events the test queues, once, and moves its cursor.
actor QueuedJournalReader: SessionJournalReading {
  private var queued: [SessionID: [(String, TranscriptEvent)]] = [:]
  private(set) var readCount = 0

  func queue(_ id: SessionID, _ events: [TranscriptEvent], provider: String = "claude-code") {
    queued[id, default: []] += events.map { (provider, $0) }
  }

  func read(_ session: WorkSession, from cursors: [String: TranscriptCursor]) -> TranscriptReading {
    readCount += 1
    let events = queued.removeValue(forKey: session.id) ?? []
    var cursors = cursors
    let path = "/t/\(session.id).jsonl"
    cursors[path, default: TranscriptCursor()].offset += UInt64(events.count)
    return TranscriptReading(events: events, cursors: cursors, foundTranscript: true)
  }

  func transcriptDirectories(for session: WorkSession) -> [String] { ["/t"] }
}

/// The store the monitor asks, when a session it follows has not named its conversation yet.
actor OneSessionRepository: SessionRepository {
  var stored: WorkSession
  init(_ session: WorkSession) { stored = session }
  func set(_ session: WorkSession) { stored = session }
  func sessions() -> [WorkSession] { [stored] }
  func session(id: SessionID) -> WorkSession? { stored.id == id ? stored : nil }
  func save(_ session: WorkSession) { stored = session }
}

struct NoRepositories: RepositoryIdentityResolving {
  func identity(ofDirectory path: String) async -> RepositoryIdentity? { nil }
}

@Suite("Keeping the journal of every active session")
struct SessionJournalMonitorTests {
  private let fast = SessionJournalMonitor.Timing(
    readDelay: .milliseconds(10), saveDelay: .milliseconds(10))

  private func session(_ provider: String = "claude-code", status: SessionStatus = .active)
    -> WorkSession
  {
    WorkSession(
      name: "S", agent: SessionAgentConfiguration(providerID: provider, resumeIdentifier: "abc"),
      status: status)
  }

  private func turn(_ prompt: String) -> [TranscriptEvent] {
    [
      .prompt(prompt, at: nil),
      .toolCall(
        TranscriptToolCall(name: "Bash", command: "git status", summary: "Bash: git status")),
      .agentText("Done.", at: nil),
      .turnEnded(at: Date()),
    ]
  }

  private func make(
    reader: QueuedJournalReader,
    store: InMemorySessionJournalStore = InMemorySessionJournalStore(),
    events: ManualFileChanges? = nil, timing: SessionJournalMonitor.Timing? = nil
  ) -> SessionJournalMonitor {
    SessionJournalMonitor(
      store: store, reader: reader, repositories: NoRepositories(), events: events,
      timing: timing ?? fast)
  }

  private func closed(_ session: WorkSession) -> WorkSession {
    WorkSession(
      id: session.id, name: "S", agent: session.agent, status: .closed,
      createdAt: session.createdAt)
  }

  @Test("Resources are listed as the transcript names them, and kept")
  func resources() async throws {
    let reader = QueuedJournalReader()
    let store = InMemorySessionJournalStore()
    let monitor = make(reader: reader, store: store)
    let session = session()
    await reader.queue(session.id, [.prompt("see https://gitlab.com/g/p/-/issues/4", at: nil)])
    await monitor.track([session])
    #expect(await eventually { await monitor.journal(for: session.id)?.resources.count == 1 })
    #expect(await eventually { await store.journal(for: session.id)?.resources.count == 1 })
    await monitor.stop()
  }

  @Test("No summary is written any more: a turn that ends adds no line, old lines are kept (#572)")
  func noSummary() async throws {
    let reader = QueuedJournalReader()
    let old = JournalEntry(text: "Reviewed the PR", at: Date(), providerID: "claude-code")
    let session = session()
    let store = InMemorySessionJournalStore(journals: [session.id: SessionJournal(entries: [old])])
    let monitor = make(reader: reader, store: store)
    await reader.queue(session.id, turn("Review https://github.com/o/r/pull/3"))
    await monitor.track([session])
    #expect(await eventually { await monitor.journal(for: session.id)?.resources.count == 1 })
    try await Task.sleep(for: .milliseconds(100))
    #expect(await monitor.journal(for: session.id)?.entries == [old])
    await monitor.stop()
  }

  @Test("A session that stops is read one last time, and its journal written")
  func lastReading() async throws {
    let reader = QueuedJournalReader()
    let store = InMemorySessionJournalStore()
    let timing = SessionJournalMonitor.Timing(
      readDelay: .milliseconds(10), saveDelay: .seconds(60))
    let monitor = make(reader: reader, store: store, timing: timing)
    let session = session()
    await monitor.track([session])
    #expect(await eventually { await reader.readCount >= 1 })
    await reader.queue(session.id, [.prompt("https://github.com/o/r/issues/5", at: nil)])
    await monitor.track([closed(session)])
    #expect(await eventually { await store.journal(for: session.id)?.resources.count == 1 })
    await monitor.stop()
  }

  @Test("A session restarted while it is read a last time stays followed")
  func restartedWhileFinishing() async throws {
    let reader = QueuedJournalReader()
    let monitor = make(reader: reader)
    let session = session()
    await reader.queue(session.id, [.prompt("half done", at: nil)])
    await monitor.track([session])
    #expect(await eventually { await reader.readCount >= 1 })
    await monitor.track([closed(session)])
    await monitor.track([session])
    await reader.queue(session.id, [.prompt("https://github.com/o/r/issues/5", at: nil)])
    await monitor.refresh()
    #expect(await eventually { await monitor.journal(for: session.id)?.resources.count == 1 })
    await monitor.stop()
  }

  @Test("A session that stops is let go once finished: no more reads")
  func stoppedIsDropped() async throws {
    let reader = QueuedJournalReader()
    let monitor = make(reader: reader)
    let session = session()
    await reader.queue(session.id, [.prompt("half done", at: nil)])
    await monitor.track([session])
    #expect(await eventually { await reader.readCount >= 1 })
    await monitor.track([closed(session)])
    #expect(await eventually { await reader.readCount >= 2 })
    try await Task.sleep(for: .milliseconds(200))
    let reads = await reader.readCount
    await monitor.track([closed(session)])
    await monitor.refresh()
    try await Task.sleep(for: .milliseconds(200))
    #expect(await reader.readCount == reads)
    await monitor.stop()
  }

  @Test("The journal is found again by a new monitor: nothing read twice, nothing lost")
  func relaunch() async throws {
    let reader = QueuedJournalReader()
    let store = InMemorySessionJournalStore()
    let session = session()
    let first = make(reader: reader, store: store)
    await reader.queue(session.id, turn("https://github.com/o/r/issues/1"))
    await first.track([session])
    #expect(await eventually { await first.journal(for: session.id)?.resources.count == 1 })
    await first.stop()
    let second = make(reader: reader, store: store)
    await second.track([session])
    let journal = await second.journal(for: session.id)
    #expect(journal?.resources.count == 1)
    #expect(journal?.cursors["/t/\(session.id).jsonl"]?.offset == 4)
    await second.stop()
  }

  @Test("A session started before its agent named its conversation is watched and read anyway")
  func conversationNamedLater() async throws {
    let reader = QueuedJournalReader()
    let events = ManualFileChanges()
    let unnamed = WorkSession(
      name: "S", agent: SessionAgentConfiguration(providerID: "claude-code"), status: .active)
    let repository = OneSessionRepository(unnamed)
    let monitor = SessionJournalMonitor(
      store: InMemorySessionJournalStore(), reader: reader, repositories: NoRepositories(),
      events: events, repository: repository, timing: fast)
    await monitor.track([unnamed])
    #expect(await eventually { events.watchedPaths == ["/t"] })
    // The CLI names its conversation in the store, then writes.
    await repository.set(
      WorkSession(
        id: unnamed.id, name: "S",
        agent: SessionAgentConfiguration(providerID: "claude-code", resumeIdentifier: "abc"),
        status: .active, createdAt: unnamed.createdAt))
    await reader.queue(unnamed.id, [.prompt("https://github.com/o/r/issues/2", at: nil)])
    events.send(.changed(["/t/x/abc.jsonl"]))
    #expect(await eventually { await monitor.journal(for: unnamed.id)?.resources.count == 1 })
    await monitor.stop()
  }

  @Test("A transcript that moved is read for the session it belongs to")
  func watch() async throws {
    let reader = QueuedJournalReader()
    let events = ManualFileChanges()
    let monitor = make(reader: reader, events: events)
    let session = session()
    await monitor.track([session])
    #expect(await eventually { events.watchedPaths == ["/t"] })
    #expect(await eventually { await reader.readCount >= 1 })
    let before = await reader.readCount
    await reader.queue(session.id, [.prompt("https://github.com/o/r/issues/8", at: nil)])
    events.send(.changed(["/t/other.jsonl"]))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await reader.readCount == before)
    events.send(.changed(["/t/x/abc.jsonl"]))
    #expect(await eventually { await monitor.journal(for: session.id)?.resources.count == 1 })
    await monitor.stop()
  }
}
