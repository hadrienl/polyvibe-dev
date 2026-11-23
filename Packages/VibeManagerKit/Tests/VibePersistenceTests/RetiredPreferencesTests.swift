import Foundation
import Testing

@testable import VibePersistence

@Suite("Preferences whose screens are gone")
struct RetiredPreferencesTests {
  @Test("Their keys are taken out at launch, and the others stay")
  func removed() throws {
    let suite = "vibe.manager.tests.\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set("com.microsoft.VSCode", forKey: "inspector.fileOpening.editor.v1")
    defaults.set(true, forKey: "journal.summaries.enabled.v1")
    defaults.set(3, forKey: "coordination.maximumRunningChildren.v1")

    RetiredPreferences.remove(suiteName: suite)
    RetiredPreferences.remove(suiteName: suite)

    for key in RetiredPreferences.keys { #expect(defaults.object(forKey: key) == nil) }
    #expect(defaults.integer(forKey: "coordination.maximumRunningChildren.v1") == 3)
  }
}
