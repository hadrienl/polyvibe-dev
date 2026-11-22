import Foundation
import Testing
import VibeApplication
import VibeDomain

@Suite("Reading a session's Git when something needs it")
struct ReadSessionGitTests {
  private let session = WorkSession(
    name: "Audit",
    repositories: [RepositoryContext(path: "/work/app"), RepositoryContext(path: "/work/docs")])

  @Test("Each repository of the report has its status read once, and one that fails is left out")
  func statuses() async {
    let activity = MainEverywhere()
    let statuses = ScriptedStatusReader()
    await statuses.answer("/work/docs", with: .failure(.notARepository(path: "/work/docs")))
    let read = ReadSessionGit(
      branches: ReadSessionBranchReport(reader: activity), statuses: statuses)

    let reading = await read(for: session)

    #expect(reading.branches.repositories.map(\.path) == ["/work/app", "/work/docs"])
    #expect(reading.statuses["/work/app"]?.branch.branchName == "main")
    #expect(reading.statuses["/work/docs"] == nil)
    #expect(await statuses.readCount("/work/app") == 1)
    #expect(await statuses.readCount("/work/docs") == 1)
  }

  @Test("Nothing is read before it is asked, and each reading goes back to Git")
  func onDemand() async {
    let activity = MainEverywhere()
    let statuses = ScriptedStatusReader()
    let read = ReadSessionGit(
      branches: ReadSessionBranchReport(reader: activity), statuses: statuses)
    #expect(await statuses.readCount("/work/app") == 0)

    _ = await read(for: session)
    _ = await read(for: session)

    #expect(await statuses.readCount("/work/app") == 2)
    #expect(await activity.heads == 4)
  }

  @Test("The branch of a folder, or nothing when Git cannot say")
  func branch() async {
    let statuses = ScriptedStatusReader()
    await statuses.answer("/gone", with: .failure(.missing(path: "/gone")))
    let read = ReadSessionGit(
      branches: ReadSessionBranchReport(reader: MainEverywhere()), statuses: statuses)

    #expect(await read.branch(atPath: "/work/app") == "main")
    #expect(await read.branch(atPath: "/gone") == nil)
  }
}

/// Every folder is the root of a repository on `main`.
private actor MainEverywhere: RepositoryActivityReading {
  private(set) var heads = 0

  func referenceFingerprint(atPath path: String) -> ReferenceFingerprint? { nil }

  func head(atPath path: String) -> RepositoryHead? {
    heads += 1
    return RepositoryHead(checkedOutBranch: "main")
  }

  func repositoryRoot(containing path: String) -> String? { path }

  func reflog(atPath path: String, since date: Date) -> [ReflogEntry] { [] }

  func hasUncommittedChanges(atPath path: String, since date: Date) -> Bool { false }
}
