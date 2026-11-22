import Foundation
import VibeDomain

/// What a session's repositories say, read at one moment: the branches its agent worked on, and
/// the `git status` of each of them.
public struct SessionGitReading: Sendable {
  public let branches: SessionBranchReport
  /// By `RepositoryBranchReport.path`. A repository that could not be read is missing.
  public let statuses: [String: WorkingTreeStatus]

  public init(branches: SessionBranchReport, statuses: [String: WorkingTreeStatus] = [:]) {
    self.branches = branches
    self.statuses = statuses
  }
}

/// Reads a session's repositories when something needs them, and only then (#578).
///
/// Nothing watches a repository: the handover summary reads its branches and their status when
/// its sheet opens, the request palette the branch of a session when one of its requests arrives.
public struct ReadSessionGit: Sendable {
  /// As many entries as `git status` keeps; every one of them is counted anyway.
  public static let statusLimit = 5_000

  private let branches: ReadSessionBranchReport
  private let statuses: (any RepositoryStatusReading)?

  public init(branches: ReadSessionBranchReport, statuses: (any RepositoryStatusReading)? = nil) {
    self.branches = branches
    self.statuses = statuses
  }

  public func callAsFunction(for session: WorkSession) async -> SessionGitReading {
    let report = await branches(for: session, forced: true)
    guard let statuses else { return SessionGitReading(branches: report) }
    var read: [String: WorkingTreeStatus] = [:]
    for repository in report.repositories {
      if case .success(let status) = await statuses.status(
        atPath: repository.path, limit: Self.statusLimit)
      {
        read[repository.path] = status
      }
    }
    return SessionGitReading(branches: report, statuses: read)
  }

  /// The branch checked out at `path`, or nil when it cannot be read or none is.
  public func branch(atPath path: String) async -> String? {
    guard let statuses, case .success(let status) = await statuses.status(atPath: path, limit: 0)
    else { return nil }
    return status.branch.branchName
  }
}
