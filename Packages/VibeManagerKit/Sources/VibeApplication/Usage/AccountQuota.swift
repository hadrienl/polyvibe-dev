import Foundation

/// A window of an account's quota, as its CLI says it (#599): Codex's five hours and week,
/// Claude Code's session, week and week of one model, Antigravity's weekly groups.
public struct QuotaWindow: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    /// Claude Code's current session, five hours.
    case session
    /// A window of so many minutes: Codex's 300 and 10 080.
    case minutes(Int)
    /// Every model, over a week.
    case weekly
    /// One model, over a week: Claude Code's `weekly_scoped`.
    case weeklyModel(String)
    /// A group of models with a limit of its own, by the name its CLI gives it: Antigravity's.
    case group(String)
  }

  public let id: String
  public let kind: Kind
  /// From 0, untouched, to 1, spent.
  public let usedFraction: Double
  public let resetsAt: Date?

  public init(id: String, kind: Kind, usedFraction: Double, resetsAt: Date?) {
    self.id = id
    self.kind = kind
    self.usedFraction = usedFraction.isFinite ? min(max(usedFraction, 0), 1) : 0
    self.resetsAt = resetsAt
  }

  public var isExhausted: Bool { usedFraction >= 1 }

  /// Whether the window came back since it was read: its share no longer says anything.
  public func hasReset(at now: Date) -> Bool {
    resetsAt.map { $0 <= now } ?? false
  }
}

/// What an account's CLI said of its quota, at one moment. Never written to disk.
public struct AccountQuota: Hashable, Sendable {
  public let windows: [QuotaWindow]
  /// The plan, as the CLI names it: “plus”, “pro”.
  public let plan: String?
  public let measuredAt: Date

  public init(windows: [QuotaWindow], plan: String? = nil, measuredAt: Date) {
    self.windows = windows
    self.plan = plan
    self.measuredAt = measuredAt
  }

  /// The window nearest its limit, among those that have not reset since.
  public func mostUsed(at now: Date) -> QuotaWindow? {
    windows.filter { !$0.hasReset(at: now) }.max { $0.usedFraction < $1.usedFraction }
  }
}

/// Why an account shows no quota.
public enum QuotaUnavailability: Hashable, Sendable {
  /// The agent has no way to tell its quota.
  case notReportedByAgent
  /// Its CLI is not installed, or cannot run.
  case notInstalled
  /// Its CLI answered that it is signed out.
  case signedOut
  /// Its CLI answered something this version does not read.
  case unrecognized
  /// Its CLI failed, or took too long.
  case failed
  /// Usage tracking is off: nothing is asked.
  case trackingOff
}

public enum AccountQuotaReading: Hashable, Sendable {
  case measured(AccountQuota)
  case unavailable(QuotaUnavailability)

  public var quota: AccountQuota? {
    if case .measured(let quota) = self { return quota }
    return nil
  }
}

/// An agent that can ask its CLI for its account's quota, with the account's own sign-in: no
/// token or keychain item is read by the application, and no turn is spent.
public protocol AgentQuotaReporting: Sendable {
  func readQuota() async -> AccountQuotaReading
  /// The provider's own page of the account's usage, opened from the Quotas popover.
  var quotaPageURL: URL? { get }
}

/// The last quota of each account, asked at most once in `minimumInterval`; requests for the same
/// account while one is under way share it.
public actor AccountQuotaService {
  public struct Entry: Hashable, Sendable {
    public let reading: AccountQuotaReading
    public let readAt: Date
  }

  private let minimumInterval: TimeInterval
  private let now: @Sendable () -> Date
  private var entries: [String: Entry] = [:]
  private var asked: [String: Date] = [:]
  private var pending: [String: Task<Entry, Never>] = [:]
  /// Moved on by `clear`: a reading asked before is not kept.
  private var generation = 0

  public init(
    minimumInterval: TimeInterval = 30, now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.minimumInterval = minimumInterval
    self.now = now
  }

  public func entry(for providerID: String) -> Entry? { entries[providerID] }

  public var all: [String: Entry] { entries }

  /// The account's quota, asked again unless it was in the last `minimumInterval`.
  @discardableResult
  public func refresh(_ providerID: String, with reporter: any AgentQuotaReporting) async -> Entry {
    if let pending = pending[providerID] { return await pending.value }
    if let entry = entries[providerID], let asked = asked[providerID],
      now().timeIntervalSince(asked) < minimumInterval
    {
      return entry
    }
    asked[providerID] = now()
    let clock = now
    let generation = generation
    let task = Task { Entry(reading: await reporter.readQuota(), readAt: clock()) }
    pending[providerID] = task
    let entry = await task.value
    // Cleared meanwhile, as when tracking is turned off: the answer is not kept.
    guard generation == self.generation else { return entry }
    pending[providerID] = nil
    // A failure does not hide what was measured before: the last figures stay, with their age.
    if case .unavailable(let reason) = entry.reading, reason == .failed,
      let previous = entries[providerID], previous.reading.quota != nil
    {
      return previous
    }
    entries[providerID] = entry
    return entry
  }

  public func clear() {
    generation += 1
    entries = [:]
    asked = [:]
    pending = [:]
  }
}
