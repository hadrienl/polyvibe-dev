import Foundation
import VibeApplication
import VibeDomain

/// A repository reader that answers from a table and counts what it is asked.
actor ScriptedStatusReader: RepositoryStatusReading {
  private var answers: [String: Result<WorkingTreeStatus, RepositoryStatusIssue>] = [:]
  private var reads: [String: Int] = [:]

  func answer(_ path: String, with result: Result<WorkingTreeStatus, RepositoryStatusIssue>) {
    answers[path] = result
  }

  func readCount(_ path: String) -> Int { reads[path] ?? 0 }

  func status(atPath path: String, limit: Int) async -> Result<
    WorkingTreeStatus, RepositoryStatusIssue
  > {
    reads[path, default: 0] += 1
    return answers[path] ?? .success(.sample(path, entries: []))
  }

  func gitDirectories(atPath path: String) async -> Result<GitDirectories, RepositoryStatusIssue> {
    .success(GitDirectories(gitDirectory: path + "/.git", commonDirectory: path + "/.git"))
  }
}

/// File system events sent by hand, to every stream open at the time.
final class ManualFileChanges: FileChangeObserving, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<FileChangeSignal>.Continuation] = [:]
  private var watched: [[String]] = []

  var watchedPaths: [String] { lock.withLock { watched.last ?? [] } }
  var openStreams: Int { lock.withLock { continuations.count } }

  func signals(for paths: [String]) -> AsyncStream<FileChangeSignal> {
    let (stream, continuation) = AsyncStream.makeStream(of: FileChangeSignal.self)
    let id = UUID()
    lock.withLock {
      continuations[id] = continuation
      watched.append(paths)
    }
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      self.lock.withLock { self.continuations[id] = nil }
    }
    return stream
  }

  func send(_ signal: FileChangeSignal) {
    let all = lock.withLock { Array(continuations.values) }
    for continuation in all { continuation.yield(signal) }
  }
}

/// Waits for a condition that an actor elsewhere will make true, and fails after `timeout`: the
/// one wait of these tests.
///
/// The timeout is only ever reached by a test that fails: a loaded CI runner may take seconds to
/// schedule what takes milliseconds here, which is why it is a minute. It counts only the time this
/// wait was given to run: when the runner stalls every task for seconds — tests that block their
/// thread take the whole cooperative pool — the work awaited is stalled too, and a wall-clock
/// deadline would pass without it ever having had a chance. A cancelled test stops waiting.
func eventually(
  timeout: Duration = .seconds(60),
  _ condition: @Sendable () async -> Bool
) async -> Bool {
  let poll = Duration.milliseconds(10)
  var waited = Duration.zero
  while waited < timeout {
    if await condition() { return true }
    let asleep = ContinuousClock.now
    do {
      try await Task.sleep(for: poll)
    } catch {
      return await condition()
    }
    // Woken much later than asked: the runner stalled; that time is not counted.
    waited += min(ContinuousClock.now - asleep, poll * 5)
  }
  return await condition()
}

extension WorkingTreeStatus {
  static func sample(
    _ path: String, entries: [WorkingTreeEntry], lock: IndexLock? = nil,
    observedAt: Date = Date()
  ) -> WorkingTreeStatus {
    var counts = WorkingTreeCounts()
    for entry in entries {
      switch entry.kind {
      case .untracked, .untrackedDirectory: counts.untracked += 1
      case .conflicted: counts.conflicted += 1
      default:
        if entry.isStaged { counts.staged += 1 }
        if entry.isUnstaged { counts.unstaged += 1 }
      }
    }
    return WorkingTreeStatus(
      repositoryPath: path,
      branch: BranchStatus(headRevision: "abc", branchName: "main"),
      entries: entries,
      counts: counts,
      indexLock: lock,
      observedAt: observedAt
    )
  }
}
