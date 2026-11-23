import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// An agent is named as people know it, never by its identifier while its provider is known
/// (#247): the sidebar, the Agent filter, the inspector, an archived session and VoiceOver.
@Suite("An agent's readable name")
struct AgentNamingTests {
  private let names = ["claude-code": "Claude Code", "codex": "Codex"]

  @Test("A known agent reads by its name, its model after it")
  func known() {
    let agent = SessionAgentConfiguration(providerID: "claude-code", modelID: "sonnet")
    #expect(AgentNaming.name(of: "claude-code", names: names) == "Claude Code")
    let labels = AgentLabels(names: names)
    #expect(labels.label(agent) == "Claude Code · sonnet")
    #expect(labels.label(SessionAgentConfiguration(providerID: "codex")) == "Codex")
  }

  @Test("An agent no longer detected keeps its identifier: there is no other name for it")
  func unknown() {
    #expect(AgentNaming.name(of: "gone", names: names) == "gone")
  }

  @Test("VoiceOver hears the agent's name, not its identifier")
  func spoken() {
    let session = WorkSession(
      name: "Refactor the supervisor",
      agent: SessionAgentConfiguration(providerID: "claude-code", modelID: "sonnet"))
    let status = SessionStatusPresentation.make(session: session, paneStatus: .running)
    #expect(
      SessionStatusPresentation.accessibilityLabel(
        for: session, status: status, labels: AgentLabels(names: names))
        == "Refactor the supervisor, Claude Code sonnet, Idle")
  }

  @Test("The sidebar names a model as the status bar does: by its catalogue, an alias resolved")
  func oneLabelEverywhere() async {
    let provider = WorkspaceProvider(
      catalog: [AgentModel(id: "stub-opus-2", displayName: "Opus 2", shortName: "Opus")])
    let session = WorkSession(
      name: "Refactor the supervisor",
      agent: SessionAgentConfiguration(providerID: "stub", modelID: "opus"))
    let repository = WorkspaceRepository(sessions: [session])
    let registry = WorkspaceRegistry(providers: [provider])
    let model = AppModel(
      repository: repository, agents: registry,
      launcher: SessionLauncher(
        supervisor: WorkspaceSupervisor(), repository: repository, agents: registry,
        viewportTimeout: .zero))
    await model.reload()
    await model.refreshAgents()

    let agent = session.agent!
    #expect(model.agentLabels.label(agent) == "\(provider.descriptor.displayName) · Opus 2")
    let status = SessionStatusPresentation.make(session: session, paneStatus: .running)
    #expect(
      SessionStatusPresentation.accessibilityLabel(
        for: session, status: status, labels: model.agentLabels)
        == "Refactor the supervisor, \(provider.descriptor.displayName) Opus 2, Idle")
  }
}
