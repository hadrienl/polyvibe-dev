import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
struct InteractionRecoveryTests {
  @Test("A failed answer selects its own session and switches its saved presentation to terminal")
  func opensFailedSession() async throws {
    let first = WorkSession(name: "Current", agent: SessionAgentConfiguration(providerID: "stub"))
    let failed = WorkSession(name: "Failed", agent: SessionAgentConfiguration(providerID: "stub"))
    let request = AgentRequest(
      id: AgentRequestID(sessionID: failed.id, key: "recovery"), receivedAt: Date(),
      kind: .approval,
      content: .permission(AgentToolPermission(tool: .shell, toolName: "Bash", subject: "ls")),
      reference: AgentToolReference(tool: "Bash", subject: "ls"), isShown: true)
    let tracker = TrackAgentActivity(logs: RecoveryLogs(), store: RecoveryState(request: request))
    await tracker.processAdopted(failed.id, decoder: RecoveryDecoder())
    let answer = AnswerAgentRequest(
      tracker: tracker,
      write: { _, _ in
        Issue.record("An unreadable dialog must not receive keys")
        return true
      }, screen: { _ in "unrecognized dialog" })
    let model = AppModel(
      repository: WorkspaceRepository(sessions: [first, failed]),
      agents: WorkspaceRegistry(providers: [WorkspaceProvider()]), answerRequest: answer)
    await model.load()
    model.select(first.id)
    model.setPresentation(.conversation, of: failed.id)
    #expect(
      model.layout.presentation(
        of: failed.id, default: model.conversations.appearance.defaultPresentation) == .conversation
    )
    #expect(await model.answer(.allowOnce, to: request.id) == false)
    #expect(model.selectedSessionID == failed.id)
    #expect(
      model.layout.presentation(
        of: failed.id, default: model.conversations.appearance.defaultPresentation) == .terminal)
    #expect(model.requestOutcome?.outcome == .notOnScreen)
    #expect(await tracker.isFirstRequest(request.id))
  }
}

private struct RecoveryDecoder: AgentSignalDecoding {
  let approvalAnswerKeys: Set<[UInt8]> = []
  var answerKeymap: (any AgentAnswerKeymap)? { RecoveryKeymap() }
  func signal(for event: AgentActivityEvent) -> AgentSignal? { nil }
}

private struct RecoveryKeymap: AgentAnswerKeymap {
  func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> { [.allowOnce] }
  func keystrokes(
    for answer: AgentAnswer, to content: AgentRequestContent, screen: AgentDialogScreen?
  ) -> [[UInt8]]? { nil }
}

private struct RecoveryState: AgentActivityStateStore {
  let request: AgentRequest
  func read() async -> [SessionID: PersistedAgentActivity] {
    [
      request.id.sessionID: PersistedAgentActivity(
        activity: .awaitingUser(.approval), isConfirmed: true, requests: [request])
    ]
  }
  func write(_ activities: [SessionID: PersistedAgentActivity]) async {}
}

private struct RecoveryLogs: AgentActivityLogStore {
  func prepareLog(for id: SessionID) async throws -> URL {
    URL(fileURLWithPath: "/tmp/recovery-test.log")
  }
  func existingLog(for id: SessionID) async -> URL? {
    URL(fileURLWithPath: "/tmp/recovery-test.log")
  }
  func events(for id: SessionID, from position: AgentActivityLogPosition?) async -> AsyncStream<
    (AgentActivityEvent, AgentActivityLogPosition)
  > {
    AsyncStream { $0.finish() }
  }
  func end(for id: SessionID) async -> AgentActivityLogPosition? { nil }
  func removeLog(for id: SessionID) async {}
}
