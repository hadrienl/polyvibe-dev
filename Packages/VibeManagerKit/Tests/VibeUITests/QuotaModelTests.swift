import Foundation
import Testing
import VibeApplication

@testable import VibeUI

@Suite("Quotas: the gauge, the words and the accounts")
@MainActor
struct QuotaModelTests {
  private let now = Date(timeIntervalSince1970: 1_795_360_000)
  private let english = Locale(identifier: "en_US")

  final class Fixed: AgentQuotaReporting, @unchecked Sendable {
    let reading: AccountQuotaReading
    var calls = 0
    init(_ reading: AccountQuotaReading) { self.reading = reading }
    func readQuota() async -> AccountQuotaReading {
      calls += 1
      return reading
    }
    var quotaPageURL: URL? { nil }
  }

  private func quota(_ shares: Double..., resetsAt: Date? = nil) -> AccountQuotaReading {
    .measured(
      AccountQuota(
        windows: shares.enumerated().map {
          QuotaWindow(
            id: "w\($0.offset)", kind: .weekly, usedFraction: $0.element, resetsAt: resetsAt)
        }, measuredAt: now))
  }

  @Test("Green under four fifths, orange from 80 % to 99 %, red at the limit")
  func levels() {
    #expect(QuotaGauge.level(for: 0.79) == .normal)
    #expect(QuotaGauge.level(for: 0.80) == .near)
    #expect(QuotaGauge.level(for: 0.99) == .near)
    #expect(QuotaGauge.level(for: 1) == .reached)
    let gauge = QuotaGauge(level: .near, usedFraction: 0.82)
    #expect(gauge.needle(.used) == 0.82)
    #expect(abs(gauge.needle(.remaining) - 0.18) < 0.0001)
    #expect(QuotaGauge(level: .unknown, usedFraction: nil).needle(.used) == 0)
  }

  @Test("The gauge follows the window nearest its limit, every account together")
  func gauge() async {
    let model = QuotaModel()
    let codex = Fixed(quota(0.3, 0.85))
    let claude = Fixed(quota(0.1))
    model.connect(accounts: [
      (QuotaModel.Account(id: "codex", name: "Codex", symbolName: "c"), codex),
      (QuotaModel.Account(id: "claude-code", name: "Claude Code", symbolName: "c"), claude),
    ])
    #expect(model.gauge(at: now).level == .unknown)
    await model.refresh()
    #expect(model.gauge(at: now) == QuotaGauge(level: .near, usedFraction: 0.85))
    #expect(model.blocked(at: now).isEmpty)
    // Asked again within thirty seconds: the CLI is not.
    await model.refresh()
    #expect(codex.calls == 1)
  }

  @Test("A spent window is blocked until it comes back; tracking off shows and asks nothing")
  func blockedAndTrackingOff() async {
    let model = QuotaModel()
    let reset = now.addingTimeInterval(3_600)
    let agy = Fixed(quota(1, resetsAt: reset))
    model.connect(accounts: [
      (QuotaModel.Account(id: "antigravity", name: "Antigravity", symbolName: "s"), agy)
    ])
    await model.refresh()
    #expect(model.blocked(at: now).map(\.0.id) == ["antigravity"])
    #expect(model.gauge(at: now).level == .reached)
    #expect(model.blocked(at: reset.addingTimeInterval(1)).isEmpty)
    #expect(model.gauge(at: reset.addingTimeInterval(1)).level == .unknown)

    let off = QuotaModel()
    off.isTrackingEnabled = { false }
    let probe = Fixed(quota(0.5))
    off.connect(accounts: [(QuotaModel.Account(id: "codex", name: "Codex", symbolName: "c"), probe)]
    )
    await off.refresh()
    #expect(probe.calls == 0)
    #expect(off.gauge(at: now).level == .unknown)
  }

  @Test("Used or left is kept, the same for every agent")
  func display() throws {
    let defaults = try #require(UserDefaults(suiteName: "QuotaModelTests-\(UUID().uuidString)"))
    let model = QuotaModel(defaults: defaults)
    #expect(model.display == .used)
    model.display = .remaining
    #expect(QuotaModel(defaults: defaults).display == .remaining)
  }

  @Test("The words of a window, in both displays, before and after it resets")
  func words() {
    let window = QuotaWindow(
      id: "primary", kind: .minutes(300), usedFraction: 0.82,
      resetsAt: now.addingTimeInterval(2 * 3_600))
    #expect(QuotaPresentation.name(of: window, locale: english) == "5 hours")
    #expect(QuotaPresentation.share(of: window, display: .used, locale: english) == "82% used")
    #expect(QuotaPresentation.share(of: window, display: .remaining, locale: english) == "18% left")
    #expect(
      QuotaPresentation.reset(of: window, now: now, locale: english)?.hasPrefix("resets ") == true)
    #expect(
      QuotaPresentation.reset(of: window, now: now.addingTimeInterval(3 * 3_600), locale: english)
        == "reset since")
    #expect(
      QuotaPresentation.name(
        of: QuotaWindow(id: "s", kind: .weeklyModel("Fable"), usedFraction: 0, resetsAt: nil),
        locale: english) == "Week · Fable")
    #expect(
      QuotaPresentation.age(of: now, now: now.addingTimeInterval(10), locale: english) == "just now"
    )
    let spoken = QuotaPresentation.spoken(
      window, account: "Codex", display: .used, now: now, locale: english)
    #expect(spoken.hasPrefix("Codex, 5 hours, 82% used, resets "))
  }
}
