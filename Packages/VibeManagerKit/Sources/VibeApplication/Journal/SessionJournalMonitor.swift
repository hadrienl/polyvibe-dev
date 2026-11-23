import Foundation
import VibeDomain

/// A session's journal changed.
public struct SessionJournalUpdate: Hashable, Sendable {
  public let sessionID: SessionID
  public let journal: SessionJournal

  public init(sessionID: SessionID, journal: SessionJournal) {
    self.sessionID = sessionID
    self.journal = journal
  }
}

/// Keeps the journal of every active session (#36): the resources as soon as a line names them.
/// No summary is written any more (#572): the conversation's key moments say what happened.
///
/// Every active session, not only the one on screen, through one watch of the agents' transcript
/// folders, comparing the names of what moved with the sessions followed. Only the files that grew
/// are read, from where they were left.
///
/// Nothing here goes through the terminal, the terminal host or the main thread: only a changed
/// journal is published.
public actor SessionJournalMonitor {
  public struct Timing: Sendable {
    /// Events of the file system gathered before reading.
    public var readDelay: Duration
    /// Changes gathered before the journal is written.
    public var saveDelay: Duration

    public init(readDelay: Duration = .milliseconds(500), saveDelay: Duration = .seconds(2)) {
      self.readDelay = readDelay
      self.saveDelay = saveDelay
    }
  }

  private struct Followed {
    var session: WorkSession
    var journal: SessionJournal
    /// Still in the store's active sessions; false once it stopped, true again if it restarts.
    var isActive = true
    var isReading = false
    var readAgain = false
    var pendingSave: Task<Void, Never>?
  }

  private let store: any SessionJournalStore
  private let reader: any SessionJournalReading
  private let resolution: ResourceResolution
  private let events: (any FileChangeObserving)?
  private let repository: (any SessionRepository)?
  private let timing: Timing
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void

  private var followed: [SessionID: Followed] = [:]
  /// Sessions no longer active, being read one last time.
  private var finishing: [SessionID: Task<Void, Never>] = [:]
  private var continuations: [UUID: AsyncStream<SessionJournalUpdate>.Continuation] = [:]
  private var watchedDirectories: [String] = []
  private var watchTask: Task<Void, Never>?
  private var pendingReads: Set<SessionID> = []
  private var readTask: Task<Void, Never>?
  private var isStopped = false

  public init(
    store: any SessionJournalStore,
    reader: any SessionJournalReading,
    repositories: any RepositoryIdentityResolving,
    events: (any FileChangeObserving)? = nil,
    repository: (any SessionRepository)? = nil,
    timing: Timing = Timing(),
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.store = store
    self.reader = reader
    resolution = ResourceResolution(repositories: repositories)
    self.events = events
    self.repository = repository
    self.timing = timing
    self.now = now
    self.sleep = sleep
  }

  // MARK: - Subscribing

  public func updates() -> AsyncStream<SessionJournalUpdate> {
    let (stream, continuation) = AsyncStream.makeStream(of: SessionJournalUpdate.self)
    let key = UUID()
    continuations[key] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.unsubscribe(key) }
    }
    return stream
  }

  private func unsubscribe(_ key: UUID) {
    continuations[key] = nil
  }

  private func publish(_ id: SessionID) {
    guard let state = followed[id] else { return }
    let update = SessionJournalUpdate(sessionID: id, journal: state.journal)
    for continuation in continuations.values { continuation.yield(update) }
  }

  // MARK: - Reading a journal

  /// The journal of any session, active or archived. `nil` when it has none.
  public func journal(for id: SessionID) async -> SessionJournal? {
    if let state = followed[id] { return state.journal }
    return try? await store.journal(for: id)
  }

  // MARK: - Which sessions

  /// The sessions as the store has them now. The active ones are followed; one that stopped being
  /// active is read a last time.
  public func track(_ sessions: [WorkSession]) async {
    guard !isStopped else { return }
    let active = sessions.filter { $0.status == .active }
    let activeIDs = Set(active.map(\.id))
    for id in followed.keys where !activeIDs.contains(id) {
      followed[id]?.isActive = false
      finish(id)
    }
    for session in active {
      if var state = followed[session.id] {
        state.session = session
        state.isActive = true
        followed[session.id] = state
        continue
      }
      let journal = (try? await store.journal(for: session.id)) ?? SessionJournal()
      guard followed[session.id] == nil, !isStopped else { continue }
      followed[session.id] = Followed(session: session, journal: journal)
      publish(session.id)
      requestRead(session.id)
    }
    await refreshWatch()
  }

  /// Reads everything once more: the application came back to the front, events may have been
  /// missed.
  public func refresh() {
    for id in followed.keys { requestRead(id) }
  }

  /// Stops for good: what changed is written.
  public func stop() async {
    isStopped = true
    watchTask?.cancel()
    watchTask = nil
    readTask?.cancel()
    for (id, state) in followed {
      state.pendingSave?.cancel()
      try? await store.save(state.journal, for: id)
    }
    for task in finishing.values { task.cancel() }
    for continuation in continuations.values { continuation.finish() }
    continuations = [:]
  }

  // MARK: - Watching the transcripts

  private func refreshWatch() async {
    guard let events, !isStopped else { return }
    var directories: [String] = []
    for state in followed.values {
      for directory in await reader.transcriptDirectories(for: state.session)
      where !directories.contains(directory) {
        directories.append(directory)
      }
    }
    directories.sort()
    guard directories != watchedDirectories, !isStopped else { return }
    watchedDirectories = directories
    watchTask?.cancel()
    watchTask = nil
    guard !directories.isEmpty else { return }
    let stream = events.signals(for: directories)
    watchTask = Task { [weak self] in
      for await signal in stream {
        guard let self else { return }
        await self.filesChanged(signal)
      }
    }
  }

  private func filesChanged(_ signal: FileChangeSignal) {
    switch signal {
    case .changed(let paths):
      for (id, state) in followed {
        let identifiers = state.session.conversations.compactMap(\.resumeIdentifier).filter {
          !$0.isEmpty
        }
        // A session whose agent has not said its conversation yet may be the one writing.
        if !Self.namesItsConversation(state.session)
          || paths.contains(where: { path in identifiers.contains { path.contains($0) } })
        {
          requestRead(id)
        }
      }
    case .mustRescan, .rootChanged:
      for id in followed.keys { requestRead(id) }
    }
  }

  /// Gathers the reads asked for in a short while into one.
  private func requestRead(_ id: SessionID) {
    pendingReads.insert(id)
    guard readTask == nil, !isStopped else { return }
    readTask = Task { [weak self, sleep, timing] in
      try? await sleep(timing.readDelay)
      await self?.readPending()
    }
  }

  private func readPending() async {
    readTask = nil
    let ids = pendingReads
    pendingReads = []
    for id in ids where !Task.isCancelled {
      await read(id)
    }
  }

  // MARK: - Reading the transcripts

  /// Reads what the session's transcripts gained, and takes the resources out of it. One reading
  /// of a session at a time.
  private func read(_ id: SessionID) async {
    guard var state = followed[id] else { return }
    if state.isReading {
      followed[id]?.readAgain = true
      return
    }
    followed[id]?.isReading = true
    defer { followed[id]?.isReading = false }

    // A session whose agent has not named its conversation in the store yet, as this monitor was
    // handed it: the store may know by now.
    if !Self.namesItsConversation(state.session), let repository,
      let fresh = try? await repository.session(id: id)
    {
      state.session = fresh
      followed[id]?.session = fresh
    }

    repeat {
      followed[id]?.readAgain = false
      guard let current = followed[id] else { return }
      let reading = await reader.read(current.session, from: current.journal.cursors)
      let date = now()
      var sightings: [ResourceSighting] = []
      for event in reading.events {
        sightings += ResourceRecognizer.sightings(in: event, now: date)
      }
      let resources = await resolution.resources(for: sightings)
      guard var latest = followed[id] else { return }
      let before = latest.journal
      latest.journal.cursors = reading.cursors
      latest.journal.record(resources)
      followed[id] = latest
      if latest.journal != before {
        scheduleSave(id)
        if latest.journal.resources != before.resources { publish(id) }
      }
    } while followed[id]?.readAgain == true
  }

  /// Whether the store already says which conversation the session's current agent writes.
  static func namesItsConversation(_ session: WorkSession) -> Bool {
    !(session.agent?.resumeIdentifier?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
  }

  // MARK: - A session that stopped

  private func finish(_ id: SessionID) {
    guard followed[id] != nil, finishing[id] == nil else { return }
    finishing[id] = Task { [weak self] in
      await self?.finishNow(id)
    }
  }

  private func finishNow(_ id: SessionID) async {
    defer { finishing[id] = nil }
    // A reading under way when the session stopped is waited for: its last lines belong in the
    // journal.
    while followed[id]?.isReading == true {
      try? await Task.sleep(for: .milliseconds(20))
    }
    await read(id)
    guard let final = followed[id] else { return }
    final.pendingSave?.cancel()
    try? await store.save(final.journal, for: id)
    // Made active again while it was being finished — restarted: it stays followed.
    if final.isActive {
      requestRead(id)
      return
    }
    followed[id] = nil
    await refreshWatch()
  }

  // MARK: - Writing

  private func scheduleSave(_ id: SessionID) {
    guard var state = followed[id] else { return }
    state.pendingSave?.cancel()
    let delay = timing.saveDelay
    state.pendingSave = Task { [weak self, sleep] in
      do { try await sleep(delay) } catch { return }
      await self?.save(id)
    }
    followed[id] = state
  }

  private func save(_ id: SessionID) async {
    guard let state = followed[id] else { return }
    followed[id]?.pendingSave = nil
    try? await store.save(state.journal, for: id)
  }
}
