import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@MainActor
struct AntigravityApprovalSettingsTests {
  @Test("Settings read and write the same Antigravity preference consumed by the provider")
  func independentChoice() {
    let agy = AgentProviderID("antigravity")
    let codex = AgentProviderID("codex")
    let preferences = InMemoryAgentApprovalPreferences(mode: .autoReview, provider: codex)
    let model = AppModel(
      repository: StubRepository(sessions: []),
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()),
      approvalPreferences: preferences)
    #expect(model.approvalMode(for: agy) == .manual)
    model.setApprovalMode(.autoReview, for: agy)
    #expect(preferences.mode(for: agy) == .autoReview)
    #expect(model.approvalMode(for: agy) == .autoReview)
    model.setApprovalMode(.manual, for: agy)
    #expect(preferences.mode(for: agy) == .manual)
    #expect(model.approvalMode(for: codex) == .autoReview)
  }
}
