import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// Agents known by their availability alone: the companion's proposal reads nothing else.
private struct AvailabilityRegistry: AgentProviderResolving {
  var states: [String: AgentAvailabilityState]

  func descriptors() async -> [AgentDescriptor] { [] }

  func provider(id _: AgentProviderID) async -> (any AgentProvider)? { nil }

  func availabilities(forceRefresh _: Bool) async -> [AgentProviderID: AgentAvailability] {
    states.reduce(into: [:]) { result, entry in
      let id = AgentProviderID(entry.key)
      result[id] = AgentAvailability(
        state: entry.value, installation: nil,
        diagnostic: AgentDiagnostic(
          providerID: id, providerName: entry.key, state: entry.value, summary: entry.key,
          probedAt: Date(timeIntervalSince1970: 0), remediations: []))
    }
  }
}

@MainActor
@Suite("The agent the phone's new session proposes for a folder (#634)", .timeLimit(.minutes(2)))
struct CompanionFolderAgentTests {
  private func session(_ agent: String, in folder: String, at seconds: TimeInterval)
    -> WorkSession
  {
    SessionDraft(
      name: "Session", initialPrompt: "", providerID: agent, workingDirectoryPath: folder
    ).session(createdAt: Date(timeIntervalSince1970: seconds))
  }

  @Test("Each folder gets the agent of its last session, as the Mac's sheet proposes it")
  func folderAgents() async {
    let model = AppModel(
      repository: HistoryRepository(values: [
        session("codex", in: "/work/api", at: 1), session("claude-code", in: "/work/web", at: 2),
      ]),
      agents: AvailabilityRegistry(states: ["codex": .available, "claude-code": .unauthenticated]),
      recentFolderStore: InMemoryRecentFolderStore())
    await model.load()

    let agents = await model.companionAgents(forFolders: ["/work/api", "/work/web", "/work/new"])

    #expect(agents == ["/work/api": "codex", "/work/web": "claude-code"])
  }

  @Test("An agent that can no longer run is not proposed, nor one the Mac no longer has")
  func unusableAgentsAreSkipped() async {
    let model = AppModel(
      repository: HistoryRepository(values: [
        session("codex", in: "/work/api", at: 1), session("gone", in: "/work/web", at: 2),
      ]),
      agents: AvailabilityRegistry(states: ["codex": .notFound]),
      recentFolderStore: InMemoryRecentFolderStore())
    await model.load()

    #expect(await model.companionAgents(forFolders: ["/work/api", "/work/web"]).isEmpty)
  }

  @Test("Without agents, no folder proposes one")
  func noRegistry() async {
    let model = AppModel(
      repository: HistoryRepository(values: [session("codex", in: "/work/api", at: 1)]),
      recentFolderStore: InMemoryRecentFolderStore())
    await model.load()

    #expect(await model.companionAgents(forFolders: ["/work/api"]).isEmpty)
  }
}
