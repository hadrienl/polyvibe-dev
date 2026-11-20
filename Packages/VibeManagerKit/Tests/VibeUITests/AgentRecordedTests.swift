import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// The identifier an agent's launch records reaches the list on screen at once (#574). The capture
/// writes it straight to the store; the list learnt it at its next reload, which may not come for
/// as long as the session is all that changes — and the usage, read from the list, showed “No
/// transcript found” beside a conversation full of answers.
@MainActor
@Suite("A conversation recorded at launch, in the list at once", .timeLimit(.minutes(1)))
struct AgentRecordedTests {
  private func launched(recording identifier: String?) async throws -> (AppModel, WorkSession) {
    let path = NSTemporaryDirectory().appending("vibe-recorded-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    let subject = WorkSession(
      name: "Recorded", agent: SessionAgentConfiguration(providerID: "stub"), status: .active,
      createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1),
      repositories: [RepositoryContext(path: path)])
    var provider = WorkspaceProvider()
    provider.recordedIdentifier = identifier
    let repository = WorkspaceRepository(sessions: [subject])
    let registry = WorkspaceRegistry(providers: [provider])
    let launcher = SessionLauncher(
      supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
      viewportTimeout: .zero)
    let model = AppModel(repository: repository, agents: registry, launcher: launcher)
    await model.load()
    let plan = try await provider.launchPlan(
      for: AgentLaunchRequest(workingDirectoryPath: path))
    await launcher.launch(session: subject, plan: plan)
    return (model, subject)
  }

  private func waitUntil(_ condition: () -> Bool) async {
    // A state is waited for, not a deadline: the bound only stops a test that would hang.
    for _ in 0..<2000 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test("The identifier the launch records is in the list, without a reload")
  func identifierInTheList() async throws {
    let (model, subject) = try await launched(recording: "conversation-1")
    await waitUntil { model.session(withID: subject.id)?.agent?.resumeIdentifier != nil }
    #expect(model.session(withID: subject.id)?.agent?.resumeIdentifier == "conversation-1")
    #expect(model.session(withID: subject.id)?.conversations.count == 1)
  }

  @Test("A record for an agent the session no longer runs changes nothing in the list")
  func otherAgent() async {
    let listed = WorkSession(name: "Switched", agent: SessionAgentConfiguration(providerID: "stub"))
    let model = AppModel(
      repository: WorkspaceRepository(sessions: [listed]),
      agents: WorkspaceRegistry(providers: [WorkspaceProvider()]))
    await model.load()
    var stored = listed
    stored.agent = SessionAgentConfiguration(providerID: "codex", resumeIdentifier: "elsewhere")
    model.showAgent(of: stored)
    #expect(model.session(withID: listed.id)?.agent?.providerID == "stub")
    #expect(model.session(withID: listed.id)?.agent?.resumeIdentifier == nil)
  }
}
