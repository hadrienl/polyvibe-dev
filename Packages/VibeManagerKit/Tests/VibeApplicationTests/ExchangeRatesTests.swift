import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

@Suite("The European Central Bank's rates, for costs in another currency")
struct ExchangeRatesTests {
  /// `eurofxref-daily.xml` as the bank served it on 2026-11-20, cut to its first currencies.
  static let daily = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
      <gesmes:subject>Reference rates</gesmes:subject>
      <Cube>
        <Cube time='2026-11-20'>
          <Cube currency='USD' rate='1.0990'/>
          <Cube currency='JPY' rate='174.35'/>
          <Cube currency='CZK' rate='24.469'/>
          <Cube currency='DKK' rate='7.4746'/>
          <Cube currency='GBP' rate='0.83735'/>
          <Cube currency='HUF' rate='373.55'/>
          <Cube currency='PLN' rate='4.2215'/>
          <Cube currency='SEK' rate='10.9875'/>
          <Cube currency='CHF' rate='0.9301'/>
          <Cube currency='NOK' rate='11.495'/>
          <Cube currency='bad' rate='1'/>
          <Cube currency='TRY' rate='-3'/>
        </Cube>
      </Cube>
    </gesmes:Envelope>
    """

  private let fetchedAt = Date(timeIntervalSince1970: 1_795_000_000)

  @Test("The day and each rate are read; what is not a currency and a rate is left out")
  func parse() throws {
    let rates = try ExchangeRates.parseECB(Data(Self.daily.utf8), fetchedAt: fetchedAt)
    #expect(rates.day == "2026-11-20")
    #expect(rates.perEuro.count == 10)
    #expect(rates.perEuro["USD"] == Decimal(string: "1.0990"))
    #expect(rates.perEuro["TRY"] == nil)
    #expect(rates.perDollar("USD") == 1)
    let euro = try #require(rates.perDollar("EUR"))
    #expect(abs(NSDecimalNumber(decimal: euro).doubleValue - 1 / 1.099) < 0.000_001)
    let pound = try #require(rates.perDollar("GBP"))
    #expect(abs(NSDecimalNumber(decimal: pound).doubleValue - 0.83735 / 1.099) < 0.000_001)
    #expect(rates.perDollar("XXX") == nil)
  }

  @Test("A document without the dollar, the day or enough currencies is not the list")
  func refused() {
    #expect(throws: ExchangeRates.ParseError.self) {
      try ExchangeRates.parseECB(
        Data(Self.daily.replacingOccurrences(of: "'USD'", with: "'XYZ'").utf8),
        fetchedAt: fetchedAt)
    }
    #expect(throws: ExchangeRates.ParseError.self) {
      try ExchangeRates.parseECB(
        Data(Self.daily.replacingOccurrences(of: "time='2026-11-20'", with: "").utf8),
        fetchedAt: fetchedAt)
    }
    #expect(throws: ExchangeRates.ParseError.self) {
      try ExchangeRates.parseECB(Data("<html>Maintenance</html>".utf8), fetchedAt: fetchedAt)
    }
  }

  @Test("A currency of the region is the default when covered, else the dollar")
  func defaultCurrency() {
    #expect(CostCurrency.defaultCode(for: Locale(identifier: "fr_FR")) == "EUR")
    #expect(CostCurrency.defaultCode(for: Locale(identifier: "de_CH")) == "CHF")
    #expect(CostCurrency.defaultCode(for: Locale(identifier: "es_AR")) == "USD")
  }

  actor Fetcher: ExchangeRateFetching {
    var answer: Data
    var calls = 0
    init(_ answer: Data) { self.answer = answer }
    func fetchRates() async throws -> Data {
      calls += 1
      return answer
    }
    func set(_ data: Data) { answer = data }
  }

  actor Store: ExchangeRateStore {
    var saved: ExchangeRates?
    func load() async -> ExchangeRates? { saved }
    func save(_ rates: ExchangeRates) async throws { saved = rates }
  }

  struct Clock: SessionClock {
    let date: Date
    func now() -> Date { date }
  }

  @Test("Fetched once a day; a broken answer keeps the last good rates")
  func updater() async throws {
    let fetcher = Fetcher(Data(Self.daily.utf8))
    let store = Store()
    let updater = ExchangeRateUpdater(
      fetcher: fetcher, store: store, bundled: nil, clock: Clock(date: fetchedAt))
    #expect(await updater.updateIfDue())
    #expect(await updater.updateIfDue() == false)
    #expect(await fetcher.calls == 1)
    #expect(await store.saved?.day == "2026-11-20")

    await fetcher.set(Data("<html/>".utf8))
    let later = ExchangeRateUpdater(
      fetcher: fetcher, store: store, bundled: nil,
      clock: Clock(date: fetchedAt.addingTimeInterval(2 * 86_400)))
    #expect(await later.updateIfDue() == false)
    #expect(await later.current()?.day == "2026-11-20")
  }
}

@Suite("Each account's last thirty days at public prices")
struct AccountCostsTests {
  struct Clock: SessionClock {
    let date: Date
    func now() -> Date { date }
  }

  actor Prices: ModelPriceStore {
    let list: ModelPriceList
    init(_ list: ModelPriceList) { self.list = list }
    func load() async -> ModelPriceList? { list }
    func save(_: ModelPriceList) async throws {
      // Nothing to keep: the list is the one the test gave.
    }
  }

  struct NoFetch: ModelPriceFetching {
    func fetchPriceList() async throws -> Data { throw CancellationError() }
  }

  @Test("Thirty days, today included, by account; a model without a price is said, not counted")
  func rolling() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 12)))
    func day(_ offset: Int) -> LocalDay {
      LocalDay(calendar.date(byAdding: .day, value: -offset, to: now)!, calendar: calendar)
    }
    let session = SessionID()
    func file(_ provider: String, _ tallies: [TokenUsageFile.Tally]) -> TokenUsageFile {
      TokenUsageFile(sessionID: session, providerID: provider, tallies: tallies)
    }
    let million = TokenCounts(input: 1_000_000)
    let snapshot = TokenUsageSnapshot(files: [
      "a": file(
        "codex",
        [
          .init(model: "gpt-x", day: day(0), tokens: million, responses: 1),
          .init(model: "gpt-x", day: day(29), tokens: million, responses: 1),
          .init(model: "gpt-x", day: day(30), tokens: million, responses: 1),
        ]),
      "b": file(
        "account.1",
        [
          .init(model: "gpt-x", day: day(3), tokens: million, responses: 1),
          .init(model: "mystery", day: day(3), tokens: million, responses: 1),
        ]),
    ])
    let store = InMemoryTokenUsageStore(snapshot: snapshot)
    let ledger = InMemoryUsageLedger()
    let tracking = InMemoryUsageTrackingStore()
    let list = ModelPriceList(
      fetchedAt: now,
      prices: [
        "gpt-x": ModelPrice(
          input: Decimal(string: "0.000002")!, cacheRead: 0, cacheWrite: 0, output: 0)
      ])
    let service = UsageService(
      recorder: UsageRecorder(ledger: ledger, tracking: tracking), ledger: ledger,
      tracking: tracking, tokenStore: store, reader: nil,
      prices: ModelPriceUpdater(
        fetcher: NoFetch(), store: Prices(list), bundled: nil, clock: Clock(date: now)),
      clock: Clock(date: now))

    let costs = await service.accountCosts(days: 30, calendar: calendar)

    #expect(costs["codex"]?.total == 4)
    #expect(costs["account.1"]?.total == 2)
    #expect(costs["account.1"]?.unpriced.map(\.model) == ["mystery"])
  }
}
