import Foundation
import VibeApplication

/// The euro reference rates, kept beside the prices (#599):
///
/// ```
/// Prices/                  0700
///   exchange-rates.json    0600, { "version": 1, "day": …, "fetchedAt": …, "perEuro": {…} }
/// ```
public actor FileExchangeRateStore: ExchangeRateStore {
  private let url: URL

  public init(directory: URL) {
    url = directory.appendingPathComponent("exchange-rates.json", isDirectory: false)
  }

  public func load() async -> ExchangeRates? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return Self.decode(data)
  }

  public func save(_ rates: ExchangeRates) async throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try AtomicFileWriter.write(try encoder.encode(rates), to: url)
  }

  static func decode(_ data: Data) -> ExchangeRates? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let rates = try? decoder.decode(ExchangeRates.self, from: data),
      rates.version == ExchangeRates.currentVersion, rates.perEuro["USD"] != nil
    else { return nil }
    return rates
  }

  /// The copy shipped with the application, for a first launch offline.
  public static func bundled() -> ExchangeRates? {
    guard let url = Bundle.module.url(forResource: "exchange-rates", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return decode(data)
  }
}

/// Fetches the European Central Bank's daily reference rates with a plain `GET`, the way the
/// prices are fetched: no cookie, no cache, a generic `User-Agent` — nothing about the user.
public struct URLSessionExchangeRateFetcher: ExchangeRateFetching {
  public static let source = URL(
    string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

  private let fetcher: URLSessionModelPriceFetcher

  public init(url: URL = URLSessionExchangeRateFetcher.source) {
    // The file weighs about 2 KB.
    fetcher = URLSessionModelPriceFetcher(url: url, maximumSize: 256 * 1024)
  }

  public func fetchRates() async throws -> Data {
    try await fetcher.fetchPriceList()
  }
}
