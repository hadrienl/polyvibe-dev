import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("The handover summary reads Git when its sheet opens", .timeLimit(.minutes(2)))
struct HandoverGitTests {
  private static let stub = WorkspaceProvider(catalog: [AgentModel(id: "fast", displayName: "Fast")]
  )
  private static let other = WorkspaceProvider(
    id: "other", name: "Other Agent", catalog: [AgentModel(id: "o1", displayName: "O1")])

  private let subject = WorkSession(
    name: "Parser",
    agent: SessionAgentConfiguration(providerID: "stub", modelID: "fast"),
    status: .closed,
    createdAt: Date(timeIntervalSince1970: 1_699_000_000),
    updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
    closedAt: Date(timeIntervalSince1970: 1_700_000_000),
    repositories: [RepositoryContext(path: "/work/app")]
  )

  private func makeModel(statuses: CountingStatuses) async -> AppModel {
    let repository = WorkspaceRepository(sessions: [subject])
    let registry = WorkspaceRegistry(providers: [Self.stub, Self.other])
    let model = AppModel(
      repository: repository, agents: registry,
      launcher: SessionLauncher(
        supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
        viewportTimeout: .zero),
      gitReader: ReadSessionGit(
        branches: ReadSessionBranchReport(reader: DetachedHead()), statuses: statuses))
    await model.reload()
    return model
  }

  @Test("Nothing is read until the sheet opens; then the summary says branch, files and rebase")
  func readWhenTheSheetOpens() async throws {
    let statuses = CountingStatuses()
    let model = await makeModel(statuses: statuses)
    model.select(subject.id)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await statuses.reads == 0)

    model.beginAgentSwitch(subject.id)
    let sheet = try #require(model.pendingSwitch)
    await sheet.load()
    await sheet.select(agent: "other")

    await waitUntil("the summary is rebuilt from what Git said") {
      sheet.summaryText.contains("branch fix/parser")
    }
    #expect(
      sheet.summaryText.contains(
        "- app — /work/app, branch fix/parser, 3 uncommitted files (1 in conflict), a rebase in progress"
      ))
    #expect(await statuses.reads == 1)
  }

  @Test("A sheet opened again reads Git again: nothing is kept from the last time")
  func readAgain() async throws {
    let statuses = CountingStatuses()
    let model = await makeModel(statuses: statuses)

    model.beginAgentSwitch(subject.id)
    await waitUntil("the first reading") { model.switchGitReading != nil }
    model.cancelAgentSwitch()
    model.beginAgentSwitch(subject.id)
    #expect(model.switchGitReading == nil)
    await waitUntil("the second reading") { model.switchGitReading != nil }

    #expect(await statuses.reads == 2)
  }

  @Test("A request reads the branch of its session once, and the palette shows it")
  func requestBranch() async throws {
    let statuses = CountingStatuses()
    let model = await makeModel(statuses: statuses)

    model.readBranches(of: [subject])
    await waitUntil("the branch is read") { model.branch(of: subject) == "fix/parser" }
    #expect(await statuses.reads == 1)
  }
}

/// A repository whose `HEAD` is detached: the report names no branch, `git status` does.
private actor DetachedHead: RepositoryActivityReading {
  func head(atPath path: String) -> RepositoryHead? { RepositoryHead(checkedOutBranch: nil) }
  func repositoryRoot(containing path: String) -> String? { path }
  func reflog(atPath path: String, since date: Date) -> [ReflogEntry] { [] }
  func hasUncommittedChanges(atPath path: String, since date: Date) -> Bool { true }
}

/// `fix/parser`, mid-rebase, with a staged, an untracked and a conflicted file.
private actor CountingStatuses: RepositoryStatusReading {
  private(set) var reads = 0

  func status(atPath path: String, limit: Int) async -> Result<
    WorkingTreeStatus, RepositoryStatusIssue
  > {
    reads += 1
    return .success(
      WorkingTreeStatus(
        repositoryPath: path, branch: BranchStatus(branchName: "fix/parser"),
        operation: .rebasing, entries: [],
        counts: WorkingTreeCounts(staged: 1, untracked: 1, conflicted: 1), observedAt: Date()))
  }

  func gitDirectories(atPath path: String) async -> Result<GitDirectories, RepositoryStatusIssue> {
    .success(GitDirectories(gitDirectory: path + "/.git", commonDirectory: path + "/.git"))
  }
}
