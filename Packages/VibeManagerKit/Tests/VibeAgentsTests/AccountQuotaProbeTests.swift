import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

/// The answers of the three CLIs, as codex-cli 0.169.0, claude 2.1.330 and agy 1.5.14 wrote them
/// on 2026-11-22, cut down to what matters (#599).
@Suite("Reading each account's quota")
struct AccountQuotaProbeTests {
  private let now = Date(timeIntervalSince1970: 1_795_360_000)

  @Test("Claude Code: the session, the week and the week of a model, in hundredths")
  func claude() throws {
    let output = """
      {"type":"system","subtype":"init","cwd":"/tmp","apiKeySource":"none"}
      {"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"Current session: 5% used"}]},"usage_report":{"session":{"total_cost_usd":0},"rate_limits":{"limits":[{"kind":"session","group":"session","percent":5,"resets_at":"2026-11-22T19:50:00.106210+00:00","scope":null,"severity":"normal","is_active":true},{"kind":"weekly_all","group":"weekly","percent":2,"resets_at":"2026-11-28T03:00:00.106256+00:00","scope":null},{"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":"2026-11-28T03:00:00+00:00","scope":{"model":{"display_name":"Fable"},"surface":null}},{"kind":"future_kind","percent":50}],"extra_usage":{"is_enabled":true,"currency":"EUR"}}},"local_command_run":{"command":"usage","args":"secret"}}
      {"type":"result","subtype":"success","num_turns":0,"total_cost_usd":0}
      """
    let quota = try #require(AccountQuotaProbe.claude(Data(output.utf8), now: now).quota)
    #expect(quota.windows.map(\.kind) == [.session, .weekly, .weeklyModel("Fable")])
    #expect(quota.windows[0].usedFraction == 0.05)
    #expect(
      quota.windows[0].resetsAt
        == ISO8601DateFormatter().date(from: "2026-11-22T19:50:00Z"))
    #expect(quota.windows[2].resetsAt != nil)
    #expect(quota.measuredAt == now)
  }

  @Test("Claude Code: a spent session leaves the limits out of the report; its text is read")
  func claudeText() throws {
    // A Max account whose session was spent, on 2026-11-22: `limits` is null.
    let output = #"""
      {"type":"system","subtype":"init","cwd":"/tmp","apiKeySource":"none"}
      {"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"You are currently using your subscription to power your Claude Code usage\n\nCurrent session: 100% used · resets Nov 22 at 11:09pm (Europe/Paris)\nCurrent week (all models): 41% used · resets Nov 25 at 12:59pm (Europe/Paris)\nCurrent week (Fable): 7% used\n\nLast 24h · 1266 requests · 11 sessions\n  72%  Start fresh when you switch tasks"}]},"usage_report":{"session":{"total_cost_usd":0},"rate_limits":{"limits":null,"extra_usage":{"is_enabled":false,"currency":"EUR"}}}}
      {"type":"result","subtype":"success","num_turns":0,"total_cost_usd":0}
      """#
    let november = try #require(ISO8601DateFormatter().date(from: "2026-11-22T12:00:00Z"))
    let quota = try #require(AccountQuotaProbe.claude(Data(output.utf8), now: november).quota)
    #expect(quota.windows.map(\.kind) == [.session, .weekly, .weeklyModel("Fable")])
    #expect(quota.windows.map(\.usedFraction) == [1, 0.41, 0.07])
    // 23:09 in Paris is 22:09 UTC in November.
    #expect(quota.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-11-22T22:09:00Z"))
    #expect(quota.windows[1].resetsAt == ISO8601DateFormatter().date(from: "2026-11-25T11:59:00Z"))
    #expect(quota.windows[2].resetsAt == nil)
  }

  @Test(
    "A reset without a day is today's, or tomorrow's once past; a date long past is next year's")
  func claudeTextDates() throws {
    let november = try #require(ISO8601DateFormatter().date(from: "2026-11-22T12:00:00Z"))
    #expect(
      AccountQuotaProbe.textDate("9am (UTC)", now: november)
        == ISO8601DateFormatter().date(from: "2026-11-23T09:00:00Z"))
    #expect(
      AccountQuotaProbe.textDate("3:30pm (UTC)", now: november)
        == ISO8601DateFormatter().date(from: "2026-11-22T15:30:00Z"))
    #expect(
      AccountQuotaProbe.textDate("Jan 2 at 1am (UTC)", now: november)
        == ISO8601DateFormatter().date(from: "2027-01-02T01:00:00Z"))
    #expect(AccountQuotaProbe.textDate("someday", now: november) == nil)
  }

  @Test("Claude Code: an API key has no limits, a signed-out CLI says so, anything else is unread")
  func claudeUnavailable() {
    let apiKey = #"{"type":"assistant","usage_report":{"session":{},"rate_limits":null}}"#
    #expect(
      AccountQuotaProbe.claude(Data(apiKey.utf8), now: now) == .unavailable(.notReportedByAgent))
    let signedOut =
      #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#
    #expect(AccountQuotaProbe.claude(Data(signedOut.utf8), now: now) == .unavailable(.signedOut))
    #expect(AccountQuotaProbe.claude(Data("garbage".utf8), now: now) == .unavailable(.unrecognized))
  }

  @Test("Codex: five hours and a week, from the app-server's result, with the plan")
  func codex() throws {
    let result = """
      {"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","primary":{"usedPercent":33,"windowDurationMins":300,"resetsAt":1795385821},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1795972621},"credits":{"hasCredits":false},"planType":"plus"},"accountId":"07352c1a-6b82-4af8-81ec-0c94c20447da","rateLimitResetCredits":{"availableCount":3}}
      """
    let quota = try #require(AccountQuotaProbe.codex(Data(result.utf8), now: now).quota)
    #expect(quota.windows.map(\.kind) == [.minutes(300), .weekly])
    #expect(quota.windows[0].usedFraction == 0.33)
    #expect(quota.windows[1].isExhausted)
    #expect(quota.windows[0].resetsAt == Date(timeIntervalSince1970: 1_795_385_821))
    #expect(quota.plan == "plus")
    #expect(quota.mostUsed(at: now)?.id == "secondary")
    // Once the week has come back, its share says nothing: the five hours are the nearest.
    #expect(quota.mostUsed(at: Date(timeIntervalSince1970: 1_795_980_000)) == nil)
  }

  @Test("Codex: null windows are no windows, and a sign-in error is told apart from a failure")
  func codexUnavailable() {
    let empty = #"{"rateLimits":{"limitId":"premium","primary":null,"secondary":null}}"#
    #expect(AccountQuotaProbe.codex(Data(empty.utf8), now: now) == .unavailable(.unrecognized))
    #expect(
      AccountQuotaProbe.codexFailure(CodexHookTrustError.serverFailed("authentication required"))
        == .unavailable(.signedOut))
    #expect(AccountQuotaProbe.codexFailure(CodexHookTrustError.timedOut) == .unavailable(.failed))
  }

  @Test("Antigravity: each bucket of each group, its share left turned into a share used")
  func antigravity() throws {
    let output = """
      {"conversation_id":"","status":"SUCCESS","response":"Gemini Models\\tWeekly Limit Remaining\\t0%","num_turns":0,"command":{"name":"usage","data":{"description":"secret","groups":[{"name":"Gemini Models","description":"Models within this group: Gemini 3.8 Flash","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0,"reset_time":"2026-11-28T12:39:21Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":0.75,"reset_time":"2026-11-29T17:49:47Z"}]}]}}}
      """
    let quota = try #require(AccountQuotaProbe.antigravity(Data(output.utf8), now: now).quota)
    #expect(
      quota.windows.map(\.kind) == [.group("Gemini Models"), .group("Claude and GPT models")])
    #expect(quota.windows[0].isExhausted)
    #expect(quota.windows[1].usedFraction == 0.25)
    #expect(quota.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-11-28T12:39:21Z"))
  }

  @Test("Antigravity: no groups is unread, a sign-in request is signed out")
  func antigravityUnavailable() {
    #expect(
      AccountQuotaProbe.antigravity(Data(#"{"status":"SUCCESS"}"#.utf8), now: now)
        == .unavailable(.unrecognized))
    #expect(
      AccountQuotaProbe.antigravity(Data("Please sign in to continue".utf8), now: now)
        == .unavailable(.signedOut))
  }

  @Test("A share is kept between 0 and 1, whatever the CLI writes")
  func clamped() {
    #expect(QuotaWindow(id: "a", kind: .weekly, usedFraction: 1.4, resetsAt: nil).usedFraction == 1)
    #expect(QuotaWindow(id: "a", kind: .weekly, usedFraction: -1, resetsAt: nil).usedFraction == 0)
    #expect(
      QuotaWindow(id: "a", kind: .weekly, usedFraction: .nan, resetsAt: nil).usedFraction == 0)
  }

  /// Only what the quota needs is declared: a text, an identifier or a credit is never decoded.
  @Test("The decoded types declare only shares, windows, dates, a plan and names")
  func declaredFields() {
    func labels(_ value: Any) -> [String] { Mirror(reflecting: value).children.compactMap(\.label) }
    #expect(
      labels(CodexQuotaResult.Window(usedPercent: 0, windowDurationMins: 0, resetsAt: 0))
        == ["usedPercent", "windowDurationMins", "resetsAt"])
    #expect(
      labels(CodexQuotaResult.Limits(primary: nil, secondary: nil, planType: nil))
        == ["primary", "secondary", "planType"])
    #expect(labels(CodexQuotaResult(rateLimits: nil)) == ["rateLimits"])
    #expect(labels(ClaudeQuotaLine(usageReport: nil)) == ["usageReport"])
    #expect(
      labels(ClaudeQuotaLine.Limit(kind: nil, percent: nil, resetsAt: nil, scope: nil))
        == ["kind", "percent", "resetsAt", "scope"])
    #expect(
      labels(AntigravityQuotaAnswer.Bucket(id: nil, remainingFraction: nil, resetTime: nil))
        == ["id", "remainingFraction", "resetTime"])
    #expect(labels(AntigravityQuotaAnswer.Group(name: nil, buckets: nil)) == ["name", "buckets"])
  }
}

@Suite("The last quota of each account")
struct AccountQuotaServiceTests {
  final class Counter: AgentQuotaReporting, @unchecked Sendable {
    var calls = 0
    var reading: AccountQuotaReading
    init(_ reading: AccountQuotaReading) { self.reading = reading }
    var quotaPageURL: URL? { nil }
    func readQuota() async -> AccountQuotaReading {
      calls += 1
      return reading
    }
  }

  @Test("An account is not asked twice in thirty seconds; a failure keeps the last figures")
  func throttled() async {
    nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 0)
    let service = AccountQuotaService(minimumInterval: 30, now: { clock })
    let measured = AccountQuotaReading.measured(
      AccountQuota(
        windows: [QuotaWindow(id: "w", kind: .weekly, usedFraction: 0.5, resetsAt: nil)],
        measuredAt: clock))
    let reporter = Counter(measured)
    await service.refresh("codex", with: reporter)
    await service.refresh("codex", with: reporter)
    #expect(reporter.calls == 1)
    clock = clock.addingTimeInterval(31)
    reporter.reading = .unavailable(.failed)
    let entry = await service.refresh("codex", with: reporter)
    #expect(reporter.calls == 2)
    #expect(entry.reading == measured)
    reporter.reading = .unavailable(.signedOut)
    clock = clock.addingTimeInterval(31)
    #expect(await service.refresh("codex", with: reporter).reading == .unavailable(.signedOut))
  }
}
