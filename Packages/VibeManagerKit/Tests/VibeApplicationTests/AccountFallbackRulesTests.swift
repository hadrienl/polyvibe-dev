import Foundation
import Testing

@testable import VibeApplication

@Suite("When a session goes on with a backup account (#600)")
struct AccountFallbackRulesTests {
  private let now = Date(timeIntervalSince1970: 1_795_000_000)

  private func window(
    _ kind: QuotaWindow.Kind, used: Double, resetsIn seconds: TimeInterval?
  ) -> QuotaWindow {
    QuotaWindow(
      id: "\(kind)", kind: kind, usedFraction: used,
      resetsAt: seconds.map { now.addingTimeInterval($0) })
  }

  private func quota(_ windows: QuotaWindow...) -> AccountQuota {
    AccountQuota(windows: windows, measuredAt: now)
  }

  // MARK: - The limit

  @Test("A spent window that lifts in hours is the account's limit, until its reset")
  func spentWindowIsALimit() throws {
    let limit = try #require(
      AccountFallbackRules.limit(
        of: quota(
          window(.minutes(300), used: 0.4, resetsIn: 3_600),
          window(.minutes(10_080), used: 1, resetsIn: 3 * 86_400)),
        at: now))
    #expect(limit.resetsAt == now.addingTimeInterval(3 * 86_400))
    #expect(limit.holds(at: now))
    #expect(!limit.holds(at: now.addingTimeInterval(3 * 86_400)))
  }

  @Test("A limit lifts only once every spent window is back")
  func latestResetOfTheSpentWindows() throws {
    let limit = try #require(
      AccountFallbackRules.limit(
        of: quota(
          window(.session, used: 1, resetsIn: 7_200),
          window(.weekly, used: 1, resetsIn: 86_400)),
        at: now))
    #expect(limit.resetsAt == now.addingTimeInterval(86_400))
  }

  @Test("A window without its reset gives a limit whose end is unknown, believed for a while")
  func unknownReset() throws {
    let limit = try #require(
      AccountFallbackRules.limit(of: quota(window(.session, used: 1, resetsIn: nil)), at: now))
    #expect(limit.resetsAt == nil)
    // Believed for ten minutes, then asked again.
    #expect(limit.holds(at: now.addingTimeInterval(9 * 60)))
    #expect(!limit.holds(at: now.addingTimeInterval(11 * 60)))
  }

  @Test("No window spent, a limit that lifts within a quarter of an hour, or one already reset: no limit")
  func passingStatesAreNoLimit() {
    #expect(AccountFallbackRules.limit(of: nil, at: now) == nil)
    #expect(
      AccountFallbackRules.limit(of: quota(window(.session, used: 0.99, resetsIn: 600)), at: now)
        == nil)
    #expect(
      AccountFallbackRules.limit(of: quota(window(.session, used: 1, resetsIn: 10 * 60)), at: now)
        == nil)
    #expect(
      AccountFallbackRules.limit(of: quota(window(.session, used: 1, resetsIn: -60)), at: now)
        == nil)
  }

  @Test("One model's week spent is not the account's limit")
  func oneModelIsNotTheAccount() {
    #expect(
      AccountFallbackRules.limit(
        of: quota(
          window(.session, used: 0.2, resetsIn: 3_600),
          window(.weeklyModel("Fable"), used: 1, resetsIn: 86_400)),
        at: now) == nil)
  }

  @Test("Antigravity's groups: one spent among others is no limit, every one spent is")
  func groupsCountTogether() throws {
    #expect(
      AccountFallbackRules.limit(
        of: quota(
          window(.group("Gemini Models"), used: 1, resetsIn: 86_400),
          window(.group("Claude and GPT models"), used: 0, resetsIn: 2 * 86_400)),
        at: now) == nil)
    let limit = try #require(
      AccountFallbackRules.limit(
        of: quota(
          window(.group("Gemini Models"), used: 1, resetsIn: 86_400),
          window(.group("Claude and GPT models"), used: 1, resetsIn: 2 * 86_400)),
        at: now))
    #expect(limit.resetsAt == now.addingTimeInterval(2 * 86_400))
  }

  // MARK: - The refusal

  @Test("A conversation that ends on the provider's refusal at a limit, the turn begun or not")
  func endsOnLimitError() {
    let prompt = ConversationEntry(id: "1", content: .userPrompt("Fix it", attachments: []))
    let answer = ConversationEntry(id: "2", content: .agentText("On it."))
    let error = ConversationEntry(
      id: "3", content: .notice(.error("You've hit your limit · resets 3pm")))
    let information = ConversationEntry(id: "4", content: .notice(.information("Resets at 3pm")))
    #expect(AccountFallbackRules.endsOnLimitError([prompt, error]))
    #expect(AccountFallbackRules.endsOnLimitError([prompt, answer, error, information]))
    #expect(!AccountFallbackRules.endsOnLimitError([prompt, error, answer]))
    #expect(!AccountFallbackRules.endsOnLimitError([prompt, answer]))
    #expect(!AccountFallbackRules.endsOnLimitError([]))
    let agy = ConversationEntry(
      id: "5",
      content: .notice(.error("API error (attempt 3): RESOURCE_EXHAUSTED (code 429): capacity")))
    #expect(AccountFallbackRules.endsOnLimitError([prompt, agy]))
  }

  @Test("An error that says nothing of a limit is no refusal at one")
  func otherErrors() {
    for text in ["Prompt is too long", "API Error: 529 Overloaded", "Connection reset"] {
      let entries = [ConversationEntry(id: "1", content: .notice(.error(text)))]
      #expect(!AccountFallbackRules.endsOnLimitError(entries))
    }
  }

  // MARK: - The chain

  @Test("The other accounts of the chain, by priority from the top; none outside the chain")
  func candidates() {
    let chain = ["claude-code", "codex", "antigravity"]
    #expect(
      AccountFallbackRules.candidates(besides: "claude-code", in: chain) == ["codex", "antigravity"])
    // An account above the session's comes first: it may have its quota back.
    #expect(
      AccountFallbackRules.candidates(besides: "antigravity", in: chain) == ["claude-code", "codex"])
    #expect(AccountFallbackRules.candidates(besides: "account-prisme", in: chain).isEmpty)
    #expect(AccountFallbackRules.candidates(besides: "codex", in: ["codex"]).isEmpty)
  }
}
