import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
@Suite("Going on with a backup account at the limit (#600)", .timeLimit(.minutes(2)))
struct AccountFallbackWorkspaceTests {
  private static let stub = WorkspaceProvider()
  private static let other = WorkspaceProvider(id: "other", name: "Other Agent")
  private static let third = WorkspaceProvider(id: "third", name: "Third Agent")

  private let resetsAt = Date(timeIntervalSince1970: 1_900_000_000)

  /// A copy of the logs that is always there, and always made.
  private actor History: ConversationHandoverExporting {
    func availability(of _: WorkSession) -> ConversationHistoryAvailability {
      ConversationHistoryAvailability(includesLatest: true, isPartial: false)
    }
    func reserve(for _: WorkSession) -> ConversationHandover {
      ConversationHandover(index: URL(fileURLWithPath: "/copies/limit/history.md"), byteCount: 0)
    }
    func export(_: WorkSession, into reserved: ConversationHandover) -> ConversationHandover {
      ConversationHandover(index: reserved.index, byteCount: 2_048)
    }
    func discard(_: ConversationHandover) {}
    func copiesFolder(of _: WorkSession) -> URL? { nil }
  }

  /// A session running on `stub`, whose turn stopped on the limit.
  private func makeWorkspace(chain: [String], running: Bool = true) async throws -> (
    AppModel, WorkspaceSupervisor, WorkspaceRepository, WorkSession
  ) {
    let path = NSTemporaryDirectory().appending("vibe-fallback-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let session = WorkSession(
      name: "Refactor",
      initialPrompt: "Refactor the parser.",
      agent: SessionAgentConfiguration(providerID: "stub", resumeIdentifier: "conversation-1"),
      status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      closedAt: Date(timeIntervalSince1970: 1_700_000_000),
      repositories: [RepositoryContext(path: path)]
    )
    let supervisor = WorkspaceSupervisor()
    // Another session, the one the user is looking at.
    let elsewhere = WorkSession(
      name: "Elsewhere", agent: SessionAgentConfiguration(providerID: "other"), status: .closed,
      createdAt: Date(timeIntervalSince1970: 1_699_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      closedAt: Date(timeIntervalSince1970: 1_700_000_000),
      repositories: [RepositoryContext(path: path)])
    let repository = WorkspaceRepository(sessions: [session, elsewhere])
    let registry = WorkspaceRegistry(providers: [Self.stub, Self.other, Self.third])
    let launcher = SessionLauncher(
      supervisor: supervisor, repository: repository, agents: registry, viewportTimeout: .zero)
    let model = AppModel(
      repository: repository, agents: registry, launcher: launcher,
      conversationHandover: History())
    for id in chain { model.accountFallback.setIncluded(true, id) }
    await model.reload()
    if running {
      let plan = try await Self.stub.launchPlan(for: AgentLaunchRequest(workingDirectoryPath: path))
      await launcher.launch(session: session, plan: plan)
      await launcher.launch(session: elsewhere, plan: plan)
      await model.reload()
    }
    return (model, supervisor, repository, session)
  }

  @Test("The session goes on with the next account, handed its logs, the switch saying why")
  func movesToTheNextAccount() async throws {
    let (model, supervisor, repository, session) = try await makeWorkspace(chain: ["stub", "other"])
    let elsewhere = try #require(model.sessions.first { $0.id != session.id }?.id)
    model.select(elsewhere)
    await model.reload()
    #expect(model.selectedSessionID == elsewhere)

    await model.fallBack(
      session.id, from: "stub", limit: AccountLimit(resetsAt: resetsAt, measuredAt: Date()))

    #expect(model.switchFailure == nil)
    // Moved by itself: the user is not taken to it.
    #expect(model.selectedSessionID == elsewhere)
    let stored = try #require(await repository.session(id: session.id))
    #expect(stored.agent?.providerID == "other")
    let change = try #require(stored.agentHistory.last)
    #expect(change.cause == .accountLimit(resetsAt: resetsAt))
    #expect(change.handover == .conversationHistory(byteCount: 2_048))
    #expect(
      await supervisor.lastSpec?.arguments.contains { $0.contains("/copies/limit/history.md") }
        == true)
  }

  @Test("An account higher in priority that has its quota back comes before those below")
  func goesBackUpTheChain() async throws {
    // `other` comes first, the session runs on `stub`, and `third` is free below it.
    let (model, _, repository, session) = try await makeWorkspace(
      chain: ["other", "stub", "third"])
    // Once at its limit, its reset passed since.
    model.limitedAccounts["other"] = AccountLimit(
      resetsAt: Date().addingTimeInterval(-60), measuredAt: Date().addingTimeInterval(-86_400))

    await model.fallBack(
      session.id, from: "stub", limit: AccountLimit(resetsAt: resetsAt, measuredAt: Date()))

    let stored = try #require(await repository.session(id: session.id))
    #expect(stored.agent?.providerID == "other")
    #expect(stored.agentHistory.last?.cause == .accountLimit(resetsAt: resetsAt))
  }

  @Test("An account known at its limit is passed over: with none left, the session stays")
  func limitedAccountsArePassedOver() async throws {
    let (model, supervisor, repository, session) = try await makeWorkspace(chain: ["stub", "other"])
    model.limitedAccounts["other"] = AccountLimit(
      resetsAt: Date().addingTimeInterval(3_600), measuredAt: Date())

    await model.fallBack(
      session.id, from: "stub", limit: AccountLimit(resetsAt: resetsAt, measuredAt: Date()))

    let stored = try #require(await repository.session(id: session.id))
    #expect(stored.agent?.providerID == "stub")
    #expect(stored.agentHistory.isEmpty)
    // Only the launches of the setup: the session's agent was not stopped and started again.
    #expect(await supervisor.startCount == 2)
  }

  @Test("A session the user closed meanwhile is not started again on the next account")
  func closedSessionStays() async throws {
    let (model, supervisor, repository, session) = try await makeWorkspace(
      chain: ["stub", "other"], running: false)

    await model.fallBack(
      session.id, from: "stub", limit: AccountLimit(resetsAt: resetsAt, measuredAt: Date()))

    let stored = try #require(await repository.session(id: session.id))
    #expect(stored.agent?.providerID == "stub")
    #expect(await supervisor.startCount == 0)
  }

  @Test("A session on an account left out of the chain stays on it")
  func accountOutOfTheChainStays() async throws {
    let (model, _, repository, session) = try await makeWorkspace(chain: ["other"])

    await model.fallBack(
      session.id, from: "stub", limit: AccountLimit(resetsAt: resetsAt, measuredAt: Date()))

    let stored = try #require(await repository.session(id: session.id))
    #expect(stored.agent?.providerID == "stub")
  }

  @Test("The chain keeps its order, moves an account a place at a time, and is kept")
  func chainModel() throws {
    let suite = "vibe-fallback-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let chain = AccountFallbackModel(defaults: defaults)
    #expect(!chain.isActive)
    chain.setIncluded(true, "claude-code")
    #expect(!chain.isActive)
    chain.setIncluded(true, "codex")
    chain.setIncluded(true, "antigravity")
    chain.setIncluded(true, "codex")
    #expect(chain.chain == ["claude-code", "codex", "antigravity"])
    let all = ["claude-code", "codex", "antigravity"]
    chain.move("antigravity", by: -1, among: all)
    chain.move("claude-code", by: -1, among: all)
    #expect(chain.chain == ["claude-code", "antigravity", "codex"])
    // An account no longer plugged in is stepped over, not swapped with.
    chain.move("codex", by: -1, among: ["claude-code", "codex"])
    #expect(chain.chain == ["codex", "antigravity", "claude-code"])
    chain.move("codex", by: 1, among: all)
    chain.move("codex", by: 1, among: all)
    chain.move("codex", by: 1, among: all)
    #expect(chain.chain == ["antigravity", "claude-code", "codex"])
    chain.setIncluded(false, "antigravity")
    #expect(chain.isActive)
    #expect(chain.shown(among: ["codex"]) == ["codex"])
    #expect(AccountFallbackModel(defaults: defaults).chain == ["claude-code", "codex"])
  }
}
