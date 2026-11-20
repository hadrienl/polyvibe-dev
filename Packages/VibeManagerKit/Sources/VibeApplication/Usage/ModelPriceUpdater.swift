import Foundation

/// Fetches the public list of model prices: LiteLLM's, a public file. Nothing about the user is
/// sent with the request.
public protocol ModelPriceFetching: Sendable {
  func fetchPriceList() async throws -> Data
}

/// The list of prices kept on the Mac, and the copy shipped with the application.
public protocol ModelPriceStore: Sendable {
  /// The last list fetched, `nil` when none was ever kept or it cannot be read.
  func load() async -> ModelPriceList?
  func save(_ list: ModelPriceList) async throws
}

/// Keeps the prices the costs are computed with (#574): the list kept on the Mac, else the copy
/// shipped with the application, fetched again at most once a day.
///
/// A fetch that fails, or brings something that is not the list, changes nothing: the last good
/// list stays in use and on disk.
public actor ModelPriceUpdater {
  /// A list is fetched again once it is this old.
  public static let refreshInterval: TimeInterval = 24 * 3_600
  /// After a failed fetch — offline, a server down — the next waits this long.
  public static let retryInterval: TimeInterval = 3_600

  private let fetcher: any ModelPriceFetching
  private let store: any ModelPriceStore
  private let bundled: ModelPriceList?
  private let clock: any SessionClock
  private var kept: ModelPriceList?
  private var hasLoaded = false
  private var lastAttempt: Date?
  private var isFetching = false

  public init(
    fetcher: any ModelPriceFetching, store: any ModelPriceStore, bundled: ModelPriceList?,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.fetcher = fetcher
    self.store = store
    self.bundled = bundled
    self.clock = clock
  }

  /// The prices in use: the list kept on the Mac, or the shipped copy before any was fetched —
  /// whichever is the more recent.
  public func current() async -> ModelPriceList? {
    if !hasLoaded {
      kept = await store.load()
      hasLoaded = true
    }
    guard let kept else { return bundled }
    guard let bundled else { return kept }
    return bundled.fetchedAt > kept.fetchedAt ? bundled : kept
  }

  /// Fetches the list when the one in use is a day old, and keeps it. Answers whether the prices
  /// changed.
  @discardableResult
  public func updateIfDue() async -> Bool {
    let now = clock.now()
    let current = await current()
    if let current, now.timeIntervalSince(current.fetchedAt) < Self.refreshInterval {
      return false
    }
    if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retryInterval { return false }
    guard !isFetching else { return false }
    isFetching = true
    defer { isFetching = false }
    lastAttempt = now
    guard let data = try? await fetcher.fetchPriceList(),
      let list = try? ModelPriceList.parseLiteLLM(data, fetchedAt: clock.now())
    else { return false }
    kept = list
    try? await store.save(list)
    return true
  }
}
