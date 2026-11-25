import CompanionCore
import Foundation
import Testing

@Suite("The Mac's quotas, on the phone (#630)")
struct RemoteQuotasTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func account(
    _ id: String, _ shares: Double..., resetsAt: Date? = nil, cost: RemoteQuotaCost? = nil
  ) -> RemoteQuotaAccount {
    RemoteQuotaAccount(
      id: id, name: id, measuredAt: now,
      windows: shares.enumerated().map {
        RemoteQuotaWindow(
          id: "w\($0.offset)", kind: .weekly, usedFraction: $0.element, resetsAt: resetsAt)
      }, cost: cost)
  }

  @Test("Every kind of window and account goes over the channel and comes back as it was")
  func roundTrip() throws {
    let quotas = RemoteQuotas(
      isTrackingOn: true, showsRemaining: true, currency: "EUR",
      accounts: [
        RemoteQuotaAccount(
          id: "claude-code", name: "Claude Code", plan: "max",
          usageURL: URL(string: "https://claude.ai/settings/usage"), measuredAt: now,
          windows: [
            RemoteQuotaWindow(id: "s", kind: .session, usedFraction: 0.34, resetsAt: now),
            RemoteQuotaWindow(id: "m", kind: .minutes(300), usedFraction: 0.44, resetsAt: nil),
            RemoteQuotaWindow(id: "w", kind: .weekly, usedFraction: 0.6, resetsAt: nil),
            RemoteQuotaWindow(id: "o", kind: .weeklyModel("Opus"), usedFraction: 0.82, resetsAt: nil),
            RemoteQuotaWindow(id: "g", kind: .group("Gemini Models"), usedFraction: 1, resetsAt: nil),
          ],
          cost: RemoteQuotaCost(
            amount: Decimal(string: "127.43")!, hasPrice: true, leavesOutUnpriced: true)),
        RemoteQuotaAccount(id: "codex", name: "Codex", isAsking: true, unavailable: .signedOut),
      ])
    let messages: [RemoteMessage] = [
      .watchQuotas(.gauge), .watchQuotas(.sheet), .watchQuotas(nil), .quotas(quotas),
    ]
    var decoder = RemoteFrame.Decoder()
    let decoded = try decoder.append(messages.map(RemoteFrame.encode).reduce(Data(), +))
    #expect(decoded == messages)
  }

  @Test("Only a Mac of protocol 4 is asked for quotas")
  func protocolVersion() {
    #expect(!CompanionRemote.takesQuotas(nil))
    #expect(!CompanionRemote.takesQuotas(3))
    #expect(CompanionRemote.takesQuotas(CompanionRemote.protocolVersion))
  }

  @Test("The dial follows the window nearest its limit, every account together")
  func gauge() {
    let reset = now.addingTimeInterval(3_600)
    let quotas = RemoteQuotas(
      isTrackingOn: true, showsRemaining: false, currency: "USD",
      accounts: [account("codex", 0.3, 0.85), account("claude-code", 0.1)])
    #expect(quotas.gauge(at: now) == RemoteQuotaGauge(level: .near, usedFraction: 0.85))
    #expect(quotas.blocked(at: now).isEmpty)

    let spent = RemoteQuotas(
      isTrackingOn: true, showsRemaining: false, currency: "USD",
      accounts: [account("antigravity", 1, resetsAt: reset)])
    #expect(spent.gauge(at: now).level == .reached)
    #expect(spent.blocked(at: now).map(\.account.id) == ["antigravity"])
    // Come back since it was read: its share no longer counts.
    #expect(spent.gauge(at: reset.addingTimeInterval(1)) == .unknown)
    #expect(spent.blocked(at: reset.addingTimeInterval(1)).isEmpty)

    var off = quotas
    off.isTrackingOn = false
    #expect(off.gauge(at: now) == .unknown)
    #expect(
      RemoteQuotas(isTrackingOn: true, showsRemaining: false, currency: "USD", accounts: [])
        .gauge(at: now) == .unknown)
  }

  @Test("Green under four fifths, orange from 80 % to 99 %, red at the limit; the needle as shown")
  func levels() {
    #expect(RemoteQuotaGauge.level(for: 0.79) == .normal)
    #expect(RemoteQuotaGauge.level(for: 0.80) == .near)
    #expect(RemoteQuotaGauge.level(for: 0.99) == .near)
    #expect(RemoteQuotaGauge.level(for: 1) == .reached)
    let gauge = RemoteQuotaGauge(level: .near, usedFraction: 0.82)
    #expect(gauge.needle(showsRemaining: false) == 0.82)
    #expect(abs(gauge.needle(showsRemaining: true) - 0.18) < 0.0001)
    #expect(RemoteQuotaGauge.unknown.needle(showsRemaining: false) == 0)
  }

  @Test("The total adds the accounts that have a price, and says when models were left out")
  func total() {
    let priced = RemoteQuotaCost(amount: 127, hasPrice: true, leavesOutUnpriced: false)
    let partly = RemoteQuotaCost(amount: 41, hasPrice: true, leavesOutUnpriced: true)
    let unpriced = RemoteQuotaCost(amount: 0, hasPrice: false, leavesOutUnpriced: true)
    let quotas = RemoteQuotas(
      isTrackingOn: true, showsRemaining: false, currency: "EUR",
      accounts: [
        account("a", cost: priced), account("b", cost: partly), account("c", cost: unpriced),
        account("d"),
      ])
    #expect(quotas.totalCost == 168)
    #expect(quotas.leavesOutUnpriced)
    let none = RemoteQuotas(
      isTrackingOn: true, showsRemaining: false, currency: "EUR",
      accounts: [account("c", cost: unpriced), account("d")])
    #expect(none.totalCost == nil)
  }
}
