import CompanionCore
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@Suite("The quotas a phone watches (#630)", .timeLimit(.minutes(1)))
@MainActor
struct CompanionQuotaFeedTests {
  private typealias Fixed = QuotaModelTests.Fixed
  private let now = Date(timeIntervalSince1970: 1_795_360_000)

  private func quota(_ share: Double) -> AccountQuotaReading {
    .measured(
      AccountQuota(
        windows: [
          QuotaWindow(id: "primary", kind: .minutes(300), usedFraction: share, resetsAt: now)
        ], plan: "plus", measuredAt: now))
  }

  /// A usage model of two accounts, and what each phone was sent.
  private final class Fixture {
    let usage: UsageModel
    let codex: Fixed
    let claude: Fixed
    var sent: [String: [RemoteQuotas]] = [:]
    var feed: CompanionQuotaFeed!

    @MainActor
    init(codex: AccountQuotaReading, claude: AccountQuotaReading) {
      usage = StatusBarUsage.usage(of: SessionID())
      self.codex = Fixed(codex)
      self.claude = Fixed(claude)
      usage.quotas.connect(accounts: [
        (QuotaModel.Account(id: "codex", name: "Codex", symbolName: "c"), self.codex),
        (QuotaModel.Account(id: "claude-code", name: "Claude Code", symbolName: "c"), self.claude),
      ])
      feed = CompanionQuotaFeed(usage: usage) { [unowned self] peer, quotas in
        self.sent[peer, default: []].append(quotas)
      }
    }

    /// Waits for what `peer` was sent last to say so: the readings answer on their own time.
    @MainActor
    func last(_ peer: String, until condition: (RemoteQuotas) -> Bool) async -> RemoteQuotas {
      while true {
        if let last = sent[peer]?.last, condition(last) { return last }
        await Task.yield()
      }
    }
  }

  @Test("The sheet asks every account at once, as the popover does, and stops with the phone")
  func sheet() async throws {
    let fixture = Fixture(codex: quota(0.44), claude: .unavailable(.signedOut))
    fixture.feed.watch(.sheet, for: "phone")
    // At once, before any answer.
    #expect(fixture.sent["phone"]?.count == 1)
    let quotas = await fixture.last("phone") { quotas in
      quotas.accounts.allSatisfy { !$0.isAsking && ($0.measuredAt != nil || $0.unavailable != nil) }
    }
    #expect(quotas.isTrackingOn)
    #expect(quotas.accounts.map(\.id) == ["codex", "claude-code"])
    let codex = try #require(quotas.accounts.first)
    #expect(codex.plan == "plus")
    #expect(codex.measuredAt == now)
    #expect(
      codex.windows == [
        RemoteQuotaWindow(id: "primary", kind: .minutes(300), usedFraction: 0.44, resetsAt: now)
      ])
    #expect(quotas.accounts.last?.unavailable == .signedOut)
    #expect(fixture.codex.calls == 1)
    #expect(fixture.claude.calls == 1)
    #expect(fixture.usage.quotas.watched == nil)

    // A second phone on its sheet within thirty seconds: the CLIs are not asked again.
    fixture.feed.watch(.sheet, for: "ipad")
    #expect(fixture.sent["ipad"]?.last == quotas)
    await fixture.usage.quotas.refresh()
    #expect(fixture.codex.calls == 1)

    fixture.feed.stop("phone")
    #expect(fixture.usage.quotas.watched == nil)
    fixture.feed.watch(nil, for: "ipad")
    #expect(fixture.usage.quotas.watched == [])
  }

  @Test("The list follows the dial: the accounts used in the last day alone")
  func gauge() async {
    let fixture = Fixture(codex: quota(0.86), claude: quota(0.1))
    fixture.usage.quotas.recentlyUsed = { ["codex"] }
    fixture.feed.watch(.gauge, for: "phone")
    #expect(fixture.usage.quotas.followers.count == 1)
    let quotas = await fixture.last("phone") { $0.accounts.first?.measuredAt != nil }
    #expect(quotas.gauge(at: now.addingTimeInterval(-60)).level == .near)
    #expect(fixture.claude.calls == 0)
    #expect(quotas.accounts.last?.measuredAt == nil)

    // The sheet opens over the list, then closes: the follow comes back, and goes with the phone.
    fixture.feed.watch(.sheet, for: "phone")
    #expect(fixture.usage.quotas.followers.isEmpty)
    fixture.feed.watch(.gauge, for: "phone")
    #expect(fixture.usage.quotas.followers.count == 1)
    #expect(fixture.usage.quotas.watched == [])
    fixture.feed.stop("phone")
    #expect(fixture.usage.quotas.followers.isEmpty)
  }

  @Test("The phone's dial turns orange and red where the Mac's does")
  func sameThresholds() {
    #expect(RemoteQuotaGauge.nearThreshold == QuotaGauge.nearThreshold)
    for share in stride(from: 0.0, through: 1.2, by: 0.01) {
      let mac: RemoteQuotaGauge.Level =
        switch QuotaGauge.level(for: share) {
        case .normal: .normal
        case .near: .near
        case .reached: .reached
        case .unknown: .unknown
        }
      #expect(RemoteQuotaGauge.level(for: share) == mac, "at \(share)")
    }
  }

  @Test("Used or left follows the Mac's setting, and a change is sent at once")
  func display() async {
    let fixture = Fixture(codex: quota(0.5), claude: quota(0.5))
    fixture.feed.watch(.gauge, for: "phone")
    #expect(fixture.sent["phone"]?.last?.showsRemaining == false)
    fixture.usage.quotas.display = .remaining
    let quotas = await fixture.last("phone") { $0.showsRemaining }
    #expect(quotas.currency == fixture.usage.conversion.code)
  }
}
