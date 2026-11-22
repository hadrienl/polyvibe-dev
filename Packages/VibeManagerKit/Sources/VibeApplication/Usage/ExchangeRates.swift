import Foundation

/// The euro reference rates of the European Central Bank, to show costs in the currency chosen
/// (#599): prices are in US dollars, converted through the euro at the day's rate.
public struct ExchangeRates: Codable, Hashable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  /// The day the bank published them, as it writes it: `2026-11-21`.
  public let day: String
  public let fetchedAt: Date
  /// How much of each currency one euro buys. The euro itself is not listed.
  public let perEuro: [String: Decimal]

  public init(day: String, fetchedAt: Date, perEuro: [String: Decimal]) {
    version = Self.currentVersion
    self.day = day
    self.fetchedAt = fetchedAt
    self.perEuro = perEuro
  }

  /// What one US dollar is worth in `code`; `nil` when the bank does not publish it.
  public func perDollar(_ code: String) -> Decimal? {
    if code == "USD" { return 1 }
    guard let dollar = perEuro["USD"], dollar > 0 else { return nil }
    if code == "EUR" { return 1 / dollar }
    guard let rate = perEuro[code], rate > 0 else { return nil }
    return rate / dollar
  }

  public enum ParseError: Error, Hashable, Sendable {
    case notTheRates
  }

  /// `eurofxref-daily.xml`: one `Cube` with a `time`, holding a `Cube` per currency with its
  /// `rate`. A document without the day, without the dollar or with fewer than ten currencies is
  /// not the list, and is refused.
  public static func parseECB(_ data: Data, fetchedAt: Date) throws -> ExchangeRates {
    let reader = ECBReader()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = reader
    guard parser.parse(), let day = reader.day, reader.rates["USD"] != nil,
      reader.rates.count >= 10
    else { throw ParseError.notTheRates }
    return ExchangeRates(day: day, fetchedAt: fetchedAt, perEuro: reader.rates)
  }

  private final class ECBReader: NSObject, XMLParserDelegate {
    var day: String?
    var rates: [String: Decimal] = [:]

    func parser(
      _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
      qualifiedName: String?, attributes: [String: String] = [:]
    ) {
      guard element == "Cube" else { return }
      if let time = attributes["time"], time.count == 10 { day = time }
      guard let currency = attributes["currency"], currency.count == 3,
        currency.allSatisfy({ $0.isASCII && $0.isUppercase }),
        let text = attributes["rate"], let rate = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
        rate > 0, rates.count < 64
      else { return }
      rates[currency] = rate
    }
  }
}

/// The currencies a cost can be shown in: the dollar the prices are in, and those the bank
/// publishes that the application's languages use.
public enum CostCurrency {
  public static let codes = [
    "USD", "EUR", "GBP", "CHF", "JPY", "CNY", "KRW", "INR", "BRL", "PLN", "TRY", "SEK", "NOK",
    "DKK", "CZK", "CAD", "AUD", "MXN",
  ]

  /// The currency of the region when it is one of them, else the dollar.
  public static func defaultCode(for locale: Locale = .current) -> String {
    let code = locale.currency?.identifier ?? "USD"
    return codes.contains(code) ? code : "USD"
  }
}

public protocol ExchangeRateFetching: Sendable {
  func fetchRates() async throws -> Data
}

public protocol ExchangeRateStore: Sendable {
  func load() async -> ExchangeRates?
  func save(_ rates: ExchangeRates) async throws
}

/// Keeps the rates: the ones kept on the Mac, else the copy shipped with the application, fetched
/// again at most once a day — only when a currency other than the dollar is chosen. A fetch that
/// fails or brings something else changes nothing.
public actor ExchangeRateUpdater {
  public static let refreshInterval: TimeInterval = 24 * 3_600
  public static let retryInterval: TimeInterval = 3_600

  private let fetcher: any ExchangeRateFetching
  private let store: any ExchangeRateStore
  private let bundled: ExchangeRates?
  private let clock: any SessionClock
  private var kept: ExchangeRates?
  private var hasLoaded = false
  private var lastAttempt: Date?
  private var isFetching = false

  public init(
    fetcher: any ExchangeRateFetching, store: any ExchangeRateStore, bundled: ExchangeRates?,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.fetcher = fetcher
    self.store = store
    self.bundled = bundled
    self.clock = clock
  }

  public func current() async -> ExchangeRates? {
    if !hasLoaded {
      let loaded = await store.load()
      if !hasLoaded {
        kept = loaded
        hasLoaded = true
      }
    }
    guard let kept else { return bundled }
    guard let bundled else { return kept }
    return bundled.day > kept.day ? bundled : kept
  }

  @discardableResult
  public func updateIfDue() async -> Bool {
    let now = clock.now()
    if let current = await current(), now.timeIntervalSince(current.fetchedAt) < Self.refreshInterval
    {
      return false
    }
    if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retryInterval { return false }
    guard !isFetching else { return false }
    isFetching = true
    defer { isFetching = false }
    lastAttempt = now
    guard let data = try? await fetcher.fetchRates(),
      let rates = try? ExchangeRates.parseECB(data, fetchedAt: clock.now())
    else { return false }
    kept = rates
    hasLoaded = true
    try? await store.save(rates)
    return true
  }
}
