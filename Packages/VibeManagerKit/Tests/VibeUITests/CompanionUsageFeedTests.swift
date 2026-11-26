import CompanionCore
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

@Suite("The usage a phone follows (#631)", .timeLimit(.minutes(1)))
@MainActor
struct CompanionUsageFeedTests {
  @MainActor
  private final class Fixture {
    let parent = WorkSession(name: "Parent", coordination: .coordinator)
    var child: WorkSession
    let tracking = Tracking()
    let usage: UsageModel
    var sent: [String: [RemoteSessionUsage]] = [:]
    var feed: CompanionUsageFeed!

    init() {
      child = WorkSession(name: "Tests", coordination: .child(of: parent.id))
      usage = StatusBarUsage.usage(
        of: parent.id, tracking: tracking,
        rates: ExchangeRateUpdater(
          fetcher: Rates(), store: Rates(),
          bundled: ExchangeRates(
            day: "2026-11-25", fetchedAt: .now,
            perEuro: ["USD": 2, "EUR": 1, "JPY": 200])))
      usage.connect(sessions: { [unowned self] in [self.parent, self.child] })
      feed = CompanionUsageFeed(
        usage: usage, sessions: { [unowned self] in [self.parent, self.child] },
        agentNames: { ["claude-code": "Claude Code"] }
      ) { [unowned self] peer, value in self.sent[peer, default: []].append(value) }
    }

    func last(_ peer: String, until predicate: (RemoteSessionUsage) -> Bool) async throws
      -> RemoteSessionUsage
    {
      while true {
        try Task.checkCancellation()
        if let value = sent[peer]?.last, predicate(value) { return value }
        await Task.yield()
      }
    }
  }

  @Test("Showing reads the session and children; changing and leaving release each watch")
  func lifecycle() async throws {
    let f = Fixture()
    f.feed.follow(f.parent.id, for: "phone")
    let value = try await f.last("phone") { $0.tokens != nil && $0.family != nil }
    #expect(value.tokens == 10_220_000)
    #expect(value.models.first?.providerName == "Claude Code")
    #expect(value.cost?.amount == 3200 * f.usage.conversion.perDollar)
    #expect(value.family?.cost == value.cost)
    #expect(value.family?.children.map(\.name) == ["Tests"])
    // A phone leaving must not stop the Mac's own watch, or another phone's.
    f.usage.startWatching(f.parent.id)
    f.feed.follow(f.parent.id, for: "ipad")
    f.feed.follow(f.child.id, for: "phone")
    #expect(f.sent["phone"]?.last?.sessionID == f.child.id.rawValue.uuidString)
    f.feed.stop("phone")
    f.feed.stop("ipad")
    await f.usage.refresh()
    #expect(f.usage.familyUsage[f.parent.id] != nil)
    f.usage.stopWatching(f.parent.id)
    await f.usage.refresh()
    #expect(f.usage.sessionUsage.isEmpty)
    #expect(f.usage.familyUsage.isEmpty)
    let count = f.sent["phone"]?.count
    await f.usage.refresh()
    #expect(f.sent["phone"]?.count == count)
  }

  @Test("Unchanged figures are not sent twice, a new currency is sent, tracking off clears data")
  func changes() async throws {
    let f = Fixture()
    f.feed.follow(f.parent.id, for: "phone")
    _ = try await f.last("phone") { $0.cost != nil }
    // Drain observation changes by waiting for the final family figures.
    _ = try await f.last("phone") { $0.family != nil }
    await f.usage.refresh()
    let count = f.sent["phone"]?.count
    await f.usage.refresh()
    #expect(f.sent["phone"]?.count == count)
    f.usage.currencyCode = "JPY"
    let converted = try await f.last("phone") { $0.currency == "JPY" }
    #expect(converted.cost?.amount == 3200 * f.usage.conversion.perDollar)
    await f.usage.setTracking(false)
    let cleared = try await f.last("phone") { !$0.isTrackingOn }
    #expect(!cleared.hasFigures)
    #expect(cleared.cost == nil)
    #expect(cleared.family == nil)
    f.feed.stop("phone")
  }

  private struct Rates: ExchangeRateFetching, ExchangeRateStore {
    func fetchRates() async throws -> Data { throw CancellationError() }
    func load() async -> ExchangeRates? { nil }
    func save(_ rates: ExchangeRates) async throws {}
  }

  private actor Tracking: UsageTrackingStore {
    var values = [UsageTrackingInterval(from: Date().addingTimeInterval(-86_400))]
    func intervals() async -> [UsageTrackingInterval] { values }
    func save(_ values: [UsageTrackingInterval]) async throws { self.values = values }
  }
}
