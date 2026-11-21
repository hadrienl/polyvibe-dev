import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private let sonnet = ModelPrice(
  input: Decimal(3) / 1_000_000, cacheRead: Decimal(3) / 10_000_000,
  cacheWrite: Decimal(375) / 100_000_000, output: Decimal(15) / 1_000_000)

@Suite("Keeping the prices up to date (#574)")
struct ModelPriceUpdaterTests {
  private actor FakeFetcher: ModelPriceFetching {
    var answer: Result<Data, any Error>
    private(set) var calls = 0

    init(_ answer: Result<Data, any Error>) {
      self.answer = answer
    }

    func fetchPriceList() async throws -> Data {
      calls += 1
      // A download takes a while: another update may come meanwhile.
      for _ in 0..<20 { await Task.yield() }
      return try answer.get()
    }

    func answer(_ next: Result<Data, any Error>) {
      answer = next
    }
  }

  private actor MemoryStore: ModelPriceStore {
    var list: ModelPriceList?
    init(_ list: ModelPriceList? = nil) { self.list = list }
    func load() async -> ModelPriceList? { list }
    func save(_ list: ModelPriceList) async throws { self.list = list }
  }

  private final class Clock: SessionClock, @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { date }
  }

  private static let good = Data(
    #"{"claude-sonnet-4-5": {"mode": "chat", "input_cost_per_token": 3e-06, "output_cost_per_token": 1.5e-05}}"#
      .utf8)

  private static func listFetched(_ date: Date, model: String = "kept") -> ModelPriceList {
    ModelPriceList(fetchedAt: date, prices: [model: sonnet])
  }

  @Test("A list fetched less than a day ago is not fetched again")
  func noSecondFetchWithinADay() async {
    let clock = Clock()
    let fetcher = FakeFetcher(.success(Self.good))
    let store = MemoryStore(Self.listFetched(clock.date.addingTimeInterval(-3_600)))
    let updater = ModelPriceUpdater(fetcher: fetcher, store: store, bundled: nil, clock: clock)
    #expect(await !updater.updateIfDue())
    #expect(await fetcher.calls == 0)
    clock.date.addTimeInterval(ModelPriceUpdater.refreshInterval)
    #expect(await updater.updateIfDue())
    #expect(await fetcher.calls == 1)
    #expect(await updater.current()?.prices.keys.contains("claude-sonnet-4-5") == true)
    #expect(await store.list?.fetchedAt == clock.date)
    clock.date.addTimeInterval(3_600)
    #expect(await !updater.updateIfDue())
    #expect(await fetcher.calls == 1)
  }

  @Test("A failed fetch keeps the last list, and is not tried again at once")
  func failureKeepsTheCache() async {
    let clock = Clock()
    let old = Self.listFetched(
      clock.date.addingTimeInterval(-2 * ModelPriceUpdater.refreshInterval))
    let fetcher = FakeFetcher(.success(Data("{oops".utf8)))
    let store = MemoryStore(old)
    let updater = ModelPriceUpdater(fetcher: fetcher, store: store, bundled: nil, clock: clock)
    #expect(await !updater.updateIfDue())
    #expect(await updater.current() == old)
    #expect(await store.list == old)
    await fetcher.answer(.failure(URLError(.notConnectedToInternet)))
    clock.date.addTimeInterval(60)
    #expect(await !updater.updateIfDue())
    #expect(await fetcher.calls == 1)
    clock.date.addTimeInterval(ModelPriceUpdater.retryInterval)
    #expect(await !updater.updateIfDue())
    #expect(await fetcher.calls == 2)
    #expect(await updater.current() == old)
  }

  @Test("Without a list kept, the shipped copy is used, until a newer one is fetched")
  func bundledCopy() async {
    let clock = Clock()
    let bundled = Self.listFetched(clock.date.addingTimeInterval(-30 * 86_400), model: "bundled")
    let fetcher = FakeFetcher(.failure(URLError(.notConnectedToInternet)))
    let updater = ModelPriceUpdater(
      fetcher: fetcher, store: MemoryStore(), bundled: bundled, clock: clock)
    #expect(await !updater.updateIfDue())
    #expect(await updater.current() == bundled)
    // A kept list older than the copy of a newer build gives way to it.
    let older = MemoryStore(
      Self.listFetched(clock.date.addingTimeInterval(-60 * 86_400), model: "older"))
    let afterUpdate = ModelPriceUpdater(
      fetcher: fetcher, store: older, bundled: bundled, clock: clock)
    #expect(await afterUpdate.current() == bundled)
  }

  @Test("A list fetched this week is kept over a newer shipped copy, which only has six providers")
  func fetchedListPreferred() async {
    let clock = Clock()
    let fetched = Self.listFetched(clock.date.addingTimeInterval(-3 * 86_400), model: "fetched")
    let bundled = Self.listFetched(clock.date.addingTimeInterval(-86_400), model: "bundled")
    let fetcher = FakeFetcher(.failure(URLError(.notConnectedToInternet)))
    let updater = ModelPriceUpdater(
      fetcher: fetcher, store: MemoryStore(fetched), bundled: bundled, clock: clock)
    #expect(await updater.current() == fetched)
    // A week on, still not fetched again: the newer copy is worth more than it.
    clock.date.addTimeInterval(ModelPriceUpdater.fetchedPreference)
    #expect(await updater.current() == bundled)
  }

  @Test("Two updates at the same time fetch the list once")
  func oneFetchAtATime() async {
    let clock = Clock()
    let fetcher = FakeFetcher(.success(Self.good))
    let updater = ModelPriceUpdater(
      fetcher: fetcher, store: MemoryStore(), bundled: nil, clock: clock)
    async let first = updater.updateIfDue()
    async let second = updater.updateIfDue()
    let answers = await [first, second]
    #expect(answers.filter { $0 }.count == 1)
    #expect(await fetcher.calls == 1)
  }

  @Test("No list is fetched while tracking is off")
  func trackingOff() async {
    let fetcher = FakeFetcher(.success(Self.good))
    let tracking = InMemoryUsageTrackingStore(intervals: [
      UsageTrackingInterval(from: .distantPast, to: Date().addingTimeInterval(-60))
    ])
    let ledger = InMemoryUsageLedger()
    let service = UsageService(
      recorder: UsageRecorder(ledger: ledger, tracking: tracking), ledger: ledger,
      tracking: tracking, tokenStore: InMemoryTokenUsageStore(), reader: nil,
      prices: ModelPriceUpdater(fetcher: fetcher, store: MemoryStore(), bundled: nil))
    #expect(await !service.updatePricesIfDue())
    #expect(await fetcher.calls == 0)
  }
}
