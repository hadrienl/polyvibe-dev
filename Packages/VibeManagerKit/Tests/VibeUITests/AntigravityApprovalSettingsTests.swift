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
    let agyPreferences = InMemoryAgentApprovalPreferences()
    let codexPreferences = InMemoryCodexApprovalPreferences(mode: .autoReview)
    let model = AppModel(
      repository: StubRepository(sessions: []),
      layout: WorkspaceLayoutController(store: RecordingLayoutStore()),
      codexApprovalPreferences: codexPreferences, antigravityApprovalPreferences: agyPreferences)
    #expect(model.antigravityApprovalMode(for: agy) == .manual)
    model.setAntigravityApprovalMode(.autoReview, for: agy)
    #expect(agyPreferences.mode(for: agy) == .autoReview)
    #expect(model.antigravityApprovalMode(for: agy) == .autoReview)
    model.setAntigravityApprovalMode(.manual, for: agy)
    #expect(agyPreferences.mode(for: agy) == .manual)
    #expect(model.codexApprovalMode(for: codex) == .autoReview)
  }
}
