import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Reading the branches of the session on screen", .timeLimit(.minutes(2)))
struct BranchReportWatchTests {
  private let api = WorkSession(
    name: "API",
    updatedAt: Date(timeIntervalSince1970: 2_000),
    repositories: [RepositoryContext(path: "/work/api")]
  )
  private let web = WorkSession(
    name: "Web",
    updatedAt: Date(timeIntervalSince1970: 1_000),
    repositories: [RepositoryContext(path: "/work/web")]
  )

  private func makeModel(
    reader: CountingReader, monitor: RepositoryStatusMonitor? = nil
  ) -> AppModel {
    AppModel(
      repository: WatchRepository(values: [api, web]),
      branchReader: ReadSessionBranchReport(reader: reader),
      repositoryStatus: monitor
    )
  }

  @Test("Only the selected session is read, and nothing is read again on a timer")
  func onlyTheSessionOnScreen() async throws {
    let reader = CountingReader()
    let model = makeModel(reader: reader)
    await model.load()
    model.select(api.id)
    await model.refreshBranchReport()
    try await Task.sleep(for: .milliseconds(150))

    #expect(await reader.reads(of: "/work/web") == 0)
    let settled = await reader.reads(of: "/work/api")
    #expect(model.branchReport(for: api.id)?.repositories.first?.checkedOutBranch == "main")
    try await Task.sleep(for: .milliseconds(300))
    #expect(await reader.reads(of: "/work/api") == settled)

    model.select(web.id)
    await waitUntil("the other session's report is read") {
      await reader.reads(of: "/work/web") >= 1
    }
  }

  @Test("The repositories of the report are watched, and what the disk says lands in the model")
  func statusesReachTheModel() async throws {
    let reader = CountingReader()
    let events = HandFileChanges()
    let monitor = RepositoryStatusMonitor(reader: CleanStatusReader(), events: events)
    let model = makeModel(reader: reader, monitor: monitor)
    await model.load()
    model.select(api.id)

    await waitUntil("the repository of the session on screen is read") {
      model.repositoryStatus(for: api.id, path: "/work/api")?.phase == .fresh
    }
    let before = await reader.reads(of: "/work/api")

    // A branch moved: the report is read again, without any timer.
    events.send(.changed(["/work/api/.git/refs/heads/main"]))
    await waitUntil("a branch that moved on disk has the report read again") {
      await reader.reads(of: "/work/api") > before
    }

    // Another session on screen: the first one's repository is no longer watched.
    model.select(web.id)
    await waitUntil("the session left is no longer watched") {
      model.repositoryStatus(for: api.id, path: "/work/api")?.phase == .unobserved
    }
    await waitUntil("the repository of the new session on screen is read") {
      model.repositoryStatus(for: web.id, path: "/work/web")?.phase == .fresh
    }
    await model.stopWatchingRepositories()
  }

  @Test("A reading that finds nothing new runs no Git and leaves the report as it was")
  func nothingNew() async throws {
    let reader = CountingReader(fingerprinted: true)
    let model = makeModel(reader: reader)
    await model.load()
    model.select(api.id)
    await model.refreshBranchReport()
    let report = try #require(model.branchReport(for: api.id))
    let reads = await reader.reads(of: "/work/api")

    // The agent writing: the transcript grows, and the report is read again each time.
    for _ in 0..<20 { await model.readBranches(of: api.id) }

    #expect(await reader.reads(of: "/work/api") == reads)
    #expect(model.branchReport(for: api.id)?.readAt == report.readAt)
    #expect(try #require(model.branchReportCheckedAt(for: api.id)) >= report.readAt)

    // Asked for by the user: everything is read again.
    await model.refreshBranchReport()
    #expect(await reader.reads(of: "/work/api") == reads + 1)
  }

  @Test("Without Git there is no report at all")
  func noReportWithoutGit() async {
    let model = AppModel(repository: WatchRepository(values: [api]))
    await model.load()

    #expect(model.branchReport(for: api.id) == nil)
  }
}

private actor CountingReader: RepositoryActivityReading {
  private var counts: [String: Int] = [:]
  private let fingerprinted: Bool

  init(fingerprinted: Bool = false) {
    self.fingerprinted = fingerprinted
  }

  func referenceFingerprint(atPath path: String) -> ReferenceFingerprint? {
    fingerprinted ? ReferenceFingerprint(stamps: [:]) : nil
  }

  func reads(of path: String) -> Int { counts[path] ?? 0 }

  func head(atPath path: String) -> RepositoryHead? {
    counts[path, default: 0] += 1
    return RepositoryHead(checkedOutBranch: "main")
  }

  func repositoryRoot(containing path: String) -> String? { path }

  func reflog(atPath path: String, since date: Date) -> [ReflogEntry] { [] }

  func hasUncommittedChanges(atPath path: String, since date: Date) -> Bool { false }
}

private struct CleanStatusReader: RepositoryStatusReading {
  func status(atPath path: String, limit: Int) async -> Result<
    WorkingTreeStatus, RepositoryStatusIssue
  > {
    .success(
      WorkingTreeStatus(
        repositoryPath: path, branch: BranchStatus(branchName: "main"), entries: [],
        counts: WorkingTreeCounts(), observedAt: Date()))
  }

  func gitDirectories(atPath path: String) async -> Result<GitDirectories, RepositoryStatusIssue> {
    .success(GitDirectories(gitDirectory: path + "/.git", commonDirectory: path + "/.git"))
  }

}

private final class HandFileChanges: FileChangeObserving, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [AsyncStream<FileChangeSignal>.Continuation] = []

  func signals(for paths: [String]) -> AsyncStream<FileChangeSignal> {
    let (stream, continuation) = AsyncStream.makeStream(of: FileChangeSignal.self)
    lock.withLock { continuations.append(continuation) }
    return stream
  }

  func send(_ signal: FileChangeSignal) {
    for continuation in lock.withLock({ continuations }) { continuation.yield(signal) }
  }
}

private actor WatchRepository: SessionRepository {
  private let values: [WorkSession]

  init(values: [WorkSession]) {
    self.values = values
  }

  func sessions() -> [WorkSession] { values }
  func session(id: SessionID) -> WorkSession? { values.first { $0.id == id } }
  func save(_: WorkSession) {}
}
