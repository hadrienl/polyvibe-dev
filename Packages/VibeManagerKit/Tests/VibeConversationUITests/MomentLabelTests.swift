import Testing
import VibeLocalizationTesting

/// The key moments' words in French, read from the catalog with the same interpolations as the
/// code: a key spelled otherwise would show in English (#572).
@Suite("The key moments, in French")
struct MomentLabelTests {
  private func french(_ value: String.LocalizationValue) -> String {
    Localization.string(value, module: "VibeConversationUI", in: "fr")
  }

  @Test("What happened, the tests' outcome agreeing with their number")
  func labels() {
    let subject = "fix(cart): round VAT per line"
    #expect(french("Commit “\(subject)”") == "Commit « fix(cart): round VAT per line »")
    let label = "#48"
    #expect(french("Pull request \(label) opened") == "PR #48 ouverte")
    let failed = 1
    let total = 17
    #expect(french("\(failed) of \(total) failed") == "1 sur 17 en échec")
    #expect(french("\(1) passed") == "1 réussi")
    #expect(french("\(13) passed") == "13 réussis")
  }

  @Test("The filters say how many moments a kind has, or that it is hidden")
  func filters() {
    #expect(french("\(4) moments") == "4 moments")
    #expect(french("\(1) moments") == "1 moment")
    #expect(french("Hidden") == "Masqués")
    #expect(french("Tickets and Pull Requests") == "Tickets et PR")
  }
}
