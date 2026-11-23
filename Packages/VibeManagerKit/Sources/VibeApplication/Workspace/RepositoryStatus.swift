import Foundation
import VibeDomain

/// Where Git keeps a repository's own state, and the state its worktrees share.
///
/// Both matter to whoever watches it: a commit made in a linked worktree touches nothing inside
/// the worktree, only its `git-dir` — which lives under the clone's `git-common-dir`.
public struct GitDirectories: Hashable, Sendable {
  public let gitDirectory: String
  public let commonDirectory: String

  public init(gitDirectory: String, commonDirectory: String) {
    self.gitDirectory = gitDirectory
    self.commonDirectory = commonDirectory
  }
}

/// A repository, read. Implemented over `GitCommandRunner` by `GitStatusReader`.
public protocol RepositoryStatusReading: Sendable {
  /// `git status`, at most `limit` entries kept and every one of them counted.
  func status(atPath path: String, limit: Int) async -> Result<
    WorkingTreeStatus, RepositoryStatusIssue
  >
  func gitDirectories(atPath path: String) async -> Result<GitDirectories, RepositoryStatusIssue>
  /// The branch checked out, nil when none is or it cannot be read: what the request palette
  /// shows, without a whole `git status`.
  func branchName(atPath path: String) async -> String?
}

extension RepositoryStatusReading {
  public func branchName(atPath path: String) async -> String? {
    guard case .success(let status) = await status(atPath: path, limit: 0) else { return nil }
    return status.branch.branchName
  }
}

/// What the file system says about the folders being watched — never what changed in them, only
/// that something may have.
public enum FileChangeSignal: Hashable, Sendable {
  /// Paths that moved, files or folders, as the system reported them.
  case changed([String])
  /// Events were dropped: everything watched has to be read again.
  case mustRescan
  /// A watched folder was moved or deleted.
  case rootChanged(String)
}

/// Watches folders. Implemented with FSEvents by `FSEventsFileChangeObserver`.
public protocol FileChangeObserving: Sendable {
  /// A stream that watches `paths` until it is no longer iterated.
  func signals(for paths: [String]) -> AsyncStream<FileChangeSignal>
}

/// Why a repository could not be read.
public enum RepositoryStatusIssue: Error, Hashable, Sendable {
  case missing(path: String)
  case notARepository(path: String)
  case locked(lockPath: String, since: Date)
  case permissionDenied(path: String)
  case unsafeRepository(path: String)
  case gitUnavailable(GitUnavailable)
  case timedOut(after: Duration)
  case failed(summary: String)

  /// Reads a refusal from Git. The runner runs Git in English whatever the user's region, so these
  /// sentences are the same on every Mac.
  public static func classify(errorOutput: String, path: String) -> RepositoryStatusIssue {
    let text = errorOutput.lowercased()
    if text.contains("dubious ownership") {
      return .unsafeRepository(path: path)
    }
    if text.contains("not a git repository") {
      return .notARepository(path: path)
    }
    if text.contains("permission denied") || text.contains("operation not permitted") {
      return .permissionDenied(path: path)
    }
    if text.contains("no such file or directory") || text.contains("cannot change to") {
      return .missing(path: path)
    }
    let firstLine =
      errorOutput
      .split(separator: "\n", omittingEmptySubsequences: true)
      .first
      .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    return .failed(summary: firstLine)
  }
}
