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

  @Test("Each popover watches its own accounts, and stops its own watch")
  func watches() {
    let model = QuotaModel(watchInterval: .seconds(3_600))
    model.connect(accounts: [
      (QuotaModel.Account(id: "claude-code", name: "Claude Code", symbolName: "c"), Fixed(quota())),
      (QuotaModel.Account(id: "codex", name: "Codex", symbolName: "c"), Fixed(quota())),
      (QuotaModel.Account(id: "antigravity", name: "Antigravity", symbolName: "s"), Fixed(quota())),
    ])
    // A session's popover: its account alone, every minute.
    let session = model.startWatching(["codex"])
    #expect(model.watched == ["codex"])
    // The Quotas popover opened beside it: every account.
    let all = model.startWatching()
    #expect(model.watched == nil)
    model.stopWatching(all)
    #expect(model.watched == ["codex"])
    // The same watch stopped twice changes nothing more.
    model.stopWatching(all)
    #expect(model.watched == ["codex"])
    model.stopWatching(session)
    #expect(model.watched == [])
  }

  /// A reading that answers once released.
  final class Held: AgentQuotaReporting, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private let lock = NSLock()
    let reading: AccountQuotaReading
    init(_ reading: AccountQuotaReading) { self.reading = reading }
    func readQuota() async -> AccountQuotaReading {
      await withCheckedContinuation { continuation in
        let now = lock.withLock {
          if released { return true }
          self.continuation = continuation
          return false
        }
        if now { continuation.resume() }
      }
      return reading
    }
    func release() {
      let waiting = lock.withLock {
        released = true
        defer { continuation = nil }
        return continuation
      }
      waiting?.resume()
    }
    var quotaPageURL: URL? { nil }
  }

  @Test("Tracking turned off while an account is asked: its answer is not kept")
  func trackingOffMeanwhile() async {
    let model = QuotaModel()
    let held = Held(quota(0.5))
    model.connect(accounts: [
      (QuotaModel.Account(id: "codex", name: "Codex", symbolName: "c"), held)
    ])
    let asking = Task { await model.refresh() }
    while model.asking.isEmpty { await Task.yield() }
    var tracking = true
    model.isTrackingEnabled = { tracking }
    tracking = false
    await model.trackingChanged(false)
    held.release()
    await asking.value
    #expect(model.entry(for: "codex") == nil)
    #expect(model.asking.isEmpty)
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
    // A window whose CLI gave no length is not “0 minutes”.
    let unknown = QuotaWindow(id: "primary", kind: .minutes(0), usedFraction: 0.1, resetsAt: nil)
    #expect(QuotaPresentation.name(of: unknown, locale: english) == "Usage limit")
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

@Suite("Costs in the currency chosen")
struct CostConversionTests {
  private let french = Locale(identifier: "fr_FR")

  @Test("A cost is converted at the rate known, and stays in dollars without one")
  func converted() throws {
    let rates = ExchangeRates(
      day: "2026-11-20", fetchedAt: Date(), perEuro: ["USD": Decimal(string: "1.25")!])
    let euro = CostConversion.make(code: "EUR", rates: rates)
    #expect(euro.code == "EUR")
    #expect(euro.perDollar == Decimal(string: "0.8"))
    #expect(UsagePresentation.cost(10, locale: french, conversion: euro) == "≈ 8,00\u{a0}€")
    #expect(CostConversion.make(code: "JPY", rates: rates) == .dollar)
    #expect(CostConversion.make(code: "EUR", rates: nil) == .dollar)
    #expect(UsagePresentation.cost(10, locale: french, conversion: .dollar).hasPrefix("≈ 10,00"))
    // Below a cent once converted: never a zero.
    #expect(
      UsagePresentation.cost(Decimal(string: "0.005")!, locale: french, conversion: euro)
        .hasPrefix("< 0,01"))
    let note = try #require(
      UsagePresentation.conversionNote(euro, locale: Locale(identifier: "en_US")))
    #expect(note.contains("2026-11-20"))
    #expect(UsagePresentation.conversionNote(.dollar) == nil)
  }
}
