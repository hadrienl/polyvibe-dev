import Foundation
import VibeDomain

/// What the interface reads usage through: the journal of runs, the tokens the transcripts
/// reported, and the tracking switch. The one request it makes is for the public list of model
/// prices (#574): nothing about the user or the sessions is sent.
public actor UsageService {
  public nonisolated let recorder: UsageRecorder
  private let ledger: any UsageLedger
  private let tracking: any UsageTrackingStore
  private let tokenStore: any TokenUsageStore
  private let reader: (any TokenUsageReading)?
  private let contextReader: (any ContextWindowReading)?
  private let prices: ModelPriceUpdater?
  private let rates: ExchangeRateUpdater?
  private let clock: any SessionClock

  /// Where each current conversation's transcript was left, for its context (#407). In memory
  /// only: the context is a value of the moment, not a counter.
  private var contextFiles: [String: ContextWindowFile] = [:]

  private var snapshot: TokenUsageSnapshot?
  private var isRefreshing = false
  /// Bumped by a clear and by the tracking switch: a reading started before either is dropped,
  /// or it would put back what was just erased, or count what was just switched off.
  private var generation = 0
  /// Clears and switches under way: no reading starts while one is, or it would read what they
  /// are about to erase and save it once they are done.
  private var changesUnderWay = 0

  public init(
    recorder: UsageRecorder,
    ledger: any UsageLedger,
    tracking: any UsageTrackingStore,
    tokenStore: any TokenUsageStore,
    reader: (any TokenUsageReading)?,
    contextReader: (any ContextWindowReading)? = nil,
    prices: ModelPriceUpdater? = nil,
    rates: ExchangeRateUpdater? = nil,
    clock: any SessionClock = SystemSessionClock()
  ) {
    self.contextReader = contextReader
    self.prices = prices
    self.rates = rates
    self.recorder = recorder
    self.ledger = ledger
    self.tracking = tracking
    self.tokenStore = tokenStore
    self.reader = reader
    self.clock = clock
  }

  /// Reads what the transcripts of these sessions added since the last time. Does nothing while
  /// tracking is off: an agent's usage during that time is not the application's to read.
  @discardableResult
  public func refreshTokens(for sessions: [WorkSession]) async -> Bool {
    // A copy that only reads leaves the tokens to the one that holds the data.
    guard let reader, !isRefreshing, changesUnderWay == 0, await !recorder.isReadOnly(),
      await recorder.isTracking()
    else { return false }
    isRefreshing = true
    defer { isRefreshing = false }
    let started = generation
    let current = await loadedSnapshot()
    let intervals = await tracking.intervals()
    let next = await reader.refresh(sessions, from: current, isTracked: { intervals.tracks($0) })
    guard generation == started, next != current else { return false }
    snapshot = next
    try? await tokenStore.save(next)
    return true
  }

  /// The context of the session's current conversation, read from what its transcript added
  /// since the last time. `nil` while tracking is off — no transcript is read then — and when
  /// no answer of it was read.
  public func contextWindow(for session: WorkSession) async -> ContextWindowUsage? {
    guard let contextReader, let conversation = session.agent,
      let identifier = conversation.resumeIdentifier, !identifier.isEmpty,
      await recorder.isTracking()
    else { return nil }
    let key = "\(session.id)|\(conversation.providerID)|\(identifier)"
    guard
      let file = await contextReader.readContext(
        of: conversation, session: session, from: contextFiles[key])
    else { return nil }
    contextFiles[key] = file
    guard var usage = file.usage else { return nil }
    // A compaction read after the last answer is said at once; its figure follows at the next.
    if let compaction = file.compaction { usage.lastCompaction = compaction }
    return usage
  }

  /// Fetches the public prices again when they are a day old. Not while tracking is off — the
  /// cost is part of what is tracked — nor from a copy that only reads the data.
  @discardableResult
  public func updatePricesIfDue() async -> Bool {
    guard let prices, await !recorder.isReadOnly(), await recorder.isTracking() else {
      return false
    }
    return await prices.updateIfDue()
  }

  /// Fetches the bank's rates again when they are a day old (#599): only for a currency other
  /// than the dollar, and not while tracking is off nor from a copy that only reads.
  @discardableResult
  public func updateRatesIfDue(currency: String) async -> Bool {
    guard currency != "USD", let rates, await !recorder.isReadOnly(), await recorder.isTracking()
    else { return false }
    return await rates.updateIfDue()
  }

  /// The rates in use, those kept or the copy shipped with the application.
  public func exchangeRates() async -> ExchangeRates? {
    await rates?.current()
  }

  /// What each account's tokens of the last `days` days, today included, would have cost at
  /// public prices (#599), by the agent's identifier: `claude-code`, `codex`, `account.<uuid>`.
  /// A rolling window, not the calendar month; a model without a price is said, never counted.
  public func accountCosts(days: Int = 30, calendar: Calendar = .current) async
    -> [String: UsageCost.Estimate]
  {
    let now = clock.now()
    guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: now) else {
      return [:]
    }
    let first = LocalDay(start, calendar: calendar)
    let list = await prices?.current()
    var tokens: [String: [String: TokenCounts]] = [:]
    for bucket in await loadedSnapshot().buckets where bucket.day >= first {
      tokens[bucket.providerID, default: [:]][bucket.model, default: TokenCounts()] += bucket.tokens
    }
    var costs: [String: UsageCost.Estimate] = [:]
    for (providerID, models) in tokens {
      costs[providerID] = UsageCost.estimate(
        models.sorted { $0.key < $1.key }.map {
          (UsageModelKey(providerID: providerID, model: $0.key), $0.value)
        }, prices: list)
    }
    return costs
  }

  public func tokens() async -> TokenUsageSnapshot {
    await loadedSnapshot()
  }

  /// Every run recorded, the open ones included as they stand now.
  public func runs() async -> [UsageRun] {
    await recorder.prepare()
    let recorded = UsageLedgerFold.runs(from: (try? await ledger.events()) ?? [])
    let open = Dictionary(
      (await recorder.openRuns()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return recorded.map { run in
      guard run.isOpen, var current = open[run.id] else { return run }
      current.suspensions = run.suspensions
      return current
    }
  }

  public func report(
    period: UsagePeriod, grouping: UsageGrouping, calendar: Calendar = .current
  ) async -> UsageReport {
    let now = clock.now()
    let list = await prices?.current()
    return UsageAggregator.report(
      runs: await runs(), tokens: await loadedSnapshot().buckets,
      period: period.interval(now: now, calendar: calendar), grouping: grouping, now: now,
      calendar: calendar, cost: Self.cost(at: list))
  }

  /// Everything a screen shows, from one reading of the journal: the report for the period, the
  /// whole usage of each of `sessions`, and of each family of `families` (#606) — a coordinator
  /// together with every session under it.
  public func overview(
    period: UsagePeriod, grouping: UsageGrouping, sessions: [SessionID],
    families: [SessionID: [SessionID]] = [:], calendar: Calendar = .current
  ) async -> UsageOverview {
    let now = clock.now()
    let runs = await runs()
    let tokens = await loadedSnapshot()
    let buckets = tokens.buckets
    let list = await prices?.current()
    let report = UsageAggregator.report(
      runs: runs, tokens: buckets, period: period.interval(now: now, calendar: calendar),
      grouping: grouping, now: now, calendar: calendar, cost: Self.cost(at: list))
    let wanted = Set(sessions).union(families.keys).union(families.values.joined())
    let runsBySession = Dictionary(grouping: runs.filter { wanted.contains($0.sessionID) }) {
      $0.sessionID
    }
    let bucketsBySession = Dictionary(
      grouping: buckets.filter { wanted.contains($0.sessionID) }
    ) { $0.sessionID }
    func usage(of ids: [SessionID]) -> UsageOverview.Session {
      let runs = ids.flatMap { runsBySession[$0] ?? [] }
      let buckets = ids.flatMap { bucketsBySession[$0] ?? [] }
      let whole = UsageAggregator.report(
        runs: runs, tokens: buckets, period: nil, grouping: .model, now: now, calendar: calendar)
      let models = UsageAggregator.report(
        runs: [], tokens: buckets, period: nil, grouping: .model, now: now, calendar: calendar)
      let cost = UsageCost.estimate(
        models.rows.compactMap { row in
          guard case .model(let providerID, let model) = row.key else { return nil }
          return (UsageModelKey(providerID: providerID, model: model), row.tokens)
        }, prices: list)
      return UsageOverview.Session(
        total: whole.total, models: models.rows,
        hasTranscript: ids.contains { tokens.hasTranscript(for: $0) },
        transcriptMissingSince: ids.compactMap { tokens.missingSince(for: $0) }.max(), cost: cost)
    }
    var perSession: [SessionID: UsageOverview.Session] = [:]
    for id in sessions {
      perSession[id] = usage(of: [id])
    }
    var perFamily: [SessionID: UsageOverview.Session] = [:]
    for (id, members) in families where !members.isEmpty {
      perFamily[id] = usage(of: [id] + members)
    }
    return UsageOverview(
      report: report, sessions: perSession, families: perFamily,
      runsRecordedSince: runs.map(\.startedAt).min(), pricesFetchedAt: list?.fetchedAt)
  }

  /// The cost of a bucket at its model's price, `nil` without one.
  private static func cost(at list: ModelPriceList?) -> (TokenUsageBucket) -> Decimal? {
    { bucket in
      list?.price(for: bucket.model, providerID: bucket.providerID).map {
        UsageCost.cost(of: bucket.tokens, at: $0)
      }
    }
  }

  public func trackingIntervals() async -> [UsageTrackingInterval] {
    await tracking.intervals()
  }

  public func setTracking(_ enabled: Bool) async {
    generation += 1
    changesUnderWay += 1
    defer { changesUnderWay -= 1 }
    contextFiles = [:]
    await recorder.setTracking(enabled)
  }

  /// Deletes what was recorded and read. The agents' transcripts are left alone, and what they
  /// say about the time before this instant is never read again.
  public func clear() async {
    // The data is another copy's: erasing its tokens and not its runs would leave them apart.
    guard await !recorder.isReadOnly() else { return }
    generation += 1
    changesUnderWay += 1
    defer { changesUnderWay -= 1 }
    await recorder.clear()
    try? await tokenStore.clear()
    snapshot = .empty
  }

  private func loadedSnapshot() async -> TokenUsageSnapshot {
    if let snapshot { return snapshot }
    let loaded = await tokenStore.load()
    snapshot = loaded
    return loaded
  }
}

/// What the usage screens show, read at once.
public struct UsageOverview: Sendable {
  public struct Session: Equatable, Sendable {
    public var total: UsageRow
    /// The tokens by model the CLI said answered.
    public var models: [UsageRow]
    public var hasTranscript: Bool
    /// When a transcript of this session stopped being found, the last time it was read.
    public var transcriptMissingSince: Date?
    /// What its tokens would have cost at the public prices (#574).
    public var cost = UsageCost.Estimate()
  }

  public var report: UsageReport
  public var sessions: [SessionID: Session]
  /// A coordinator's usage together with that of every session under it (#606), for the
  /// coordinators that have any.
  public var families: [SessionID: Session] = [:]
  /// When the first run was recorded: running time and runs start there, tokens do not.
  public var runsRecordedSince: Date?
  /// When the prices the costs were computed with were read; `nil` without any.
  public var pricesFetchedAt: Date?
}
