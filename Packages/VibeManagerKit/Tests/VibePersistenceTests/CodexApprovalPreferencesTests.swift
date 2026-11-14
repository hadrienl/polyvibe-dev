import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibePersistence

@MainActor
@Suite("Codex approval preferences")
struct CodexApprovalPreferencesTests {
  @Test("Manual by default, a choice persists and can be turned off")
  func persistence() throws {
    let suite = "codex-approval-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = UserDefaultsCodexApprovalPreferences(suiteName: suite)
    let codex = AgentProviderID("codex")
    #expect(preferences.mode(for: codex) == .manual)
    preferences.setMode(.autoReview, for: codex)
    #expect(UserDefaultsCodexApprovalPreferences(suiteName: suite).mode(for: codex) == .autoReview)
    let account = AgentProviderID("account.codex-test")
    #expect(preferences.mode(for: account) == .manual)
    preferences.setMode(.autoReview, for: account)
    preferences.setMode(.manual, for: codex)
    #expect(UserDefaultsCodexApprovalPreferences(suiteName: suite).mode(for: codex) == .manual)
    #expect(
      UserDefaultsCodexApprovalPreferences(suiteName: suite).mode(for: account) == .autoReview)
  }

  @Test(
    "Antigravity persists independently, keeps old configurations manual and tolerates unknown values"
  )
  func antigravityPersistence() throws {
    let suite = "antigravity-approval-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let agy = AgentProviderID("antigravity")
    let codex = AgentProviderID("codex")
    let preferences = UserDefaultsAgentApprovalPreferences(
      suiteName: suite, namespace: "antigravity")
    let codexPreferences = UserDefaultsCodexApprovalPreferences(suiteName: suite)
    #expect(preferences.mode(for: agy) == .manual)
    codexPreferences.setMode(.autoReview, for: codex)
    #expect(preferences.mode(for: agy) == .manual)
    preferences.setMode(.autoReview, for: agy)
    let reloaded = UserDefaultsAgentApprovalPreferences(suiteName: suite, namespace: "antigravity")
    #expect(reloaded.mode(for: agy) == .autoReview)
    #expect(reloaded.mode(for: AgentProviderID("account.future-agy")) == .manual)
    reloaded.setMode(.manual, for: agy)
    #expect(preferences.mode(for: agy) == .manual)
    #expect(codexPreferences.mode(for: codex) == .autoReview)
    defaults.set("future-mode", forKey: "antigravity.approvalMode.antigravity.v1")
    #expect(preferences.mode(for: agy) == .manual)
    // #543's keys and raw values must survive the shared-type extraction unchanged.
    #expect(defaults.string(forKey: "codex.approvalMode.codex.v1") == "autoReview")
  }

  @Test("Existing endpoints stay manual; an endpoint's auto mode survives a round trip")
  func endpointMigration() throws {
    let endpoint = Endpoint(
      name: "Codex endpoint", baseURL: "http://localhost/v1", wireProtocol: .responses,
      codexApprovalMode: .autoReview)
    let encoded = try JSONEncoder().encode(endpoint)
    #expect(try JSONDecoder().decode(Endpoint.self, from: encoded).codexApprovalMode == .autoReview)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "codexApprovalMode")
    let old = try JSONSerialization.data(withJSONObject: legacy)
    #expect(try JSONDecoder().decode(Endpoint.self, from: old).codexApprovalMode == .manual)
  }
}
