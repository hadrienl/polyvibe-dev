import Foundation

/// What the phone shows of the Mac's quotas (#630), and so what the Mac reads for it.
public enum RemoteQuotaWatch: String, Codable, Hashable, Sendable {
  /// The list of sessions is on screen, with its dial: the Mac sends what it knows, and asks the
  /// accounts used in the last day again every ten minutes.
  case gauge
  /// The Quotas sheet is open: every account asked now, then every minute, and the costs of the
  /// last thirty days, as the Mac's Quotas popover does.
  case sheet
}

/// Why an account shows no quota, as the Mac says it.
public enum RemoteQuotaUnavailability: String, Codable, Hashable, Sendable {
  case notReportedByAgent, notInstalled, signedOut, unrecognized, failed, trackingOff
}

/// A window of an account's quota: Codex's five hours, Claude Code's session or week.
public struct RemoteQuotaWindow: Codable, Hashable, Sendable, Identifiable {
  public enum Kind: Codable, Hashable, Sendable {
    /// Claude Code's current session, five hours.
    case session
    /// A window of so many minutes; 0 for one whose CLI did not give its length.
    case minutes(Int)
    /// Every model, over a week.
    case weekly
    /// One model, over a week.
    case weeklyModel(String)
    /// A group of models with a limit of its own, by the name its CLI gives it.
    case group(String)
  }

  public var id: String
  public var kind: Kind
  /// From 0, untouched, to 1, spent.
  public var usedFraction: Double
  public var resetsAt: Date?

  public init(id: String, kind: Kind, usedFraction: Double, resetsAt: Date?) {
    self.id = id
    self.kind = kind
    self.usedFraction = usedFraction
    self.resetsAt = resetsAt
  }

  public var isExhausted: Bool { usedFraction >= 1 }

  /// Whether the window came back since it was read: its share no longer says anything.
  public func hasReset(at now: Date) -> Bool {
    resetsAt.map { $0 <= now } ?? false
  }
}

/// What an account's last thirty days would have cost at public API prices.
public struct RemoteQuotaCost: Codable, Hashable, Sendable {
  /// In the currency of `RemoteQuotas`, converted already.
  public var amount: Decimal
  /// Whether one of its models at least has a known price: without, there is no amount to say.
  public var hasPrice: Bool
  /// Whether models without a known price were left out of the amount.
  public var leavesOutUnpriced: Bool

  public init(amount: Decimal, hasPrice: Bool, leavesOutUnpriced: Bool) {
    self.amount = amount
    self.hasPrice = hasPrice
    self.leavesOutUnpriced = leavesOutUnpriced
  }
}

/// An account of the Mac and its quota, as its Quotas popover shows it.
public struct RemoteQuotaAccount: Codable, Hashable, Sendable, Identifiable {
  /// The provider's identifier: `claude-code`, `codex`, `antigravity`, `account.<uuid>`.
  public var id: String
  public var name: String
  /// The plan, as the CLI names it: “plus”, “pro”.
  public var plan: String?
  /// The provider's own page of the account's usage.
  public var usageURL: URL?
  /// When the figures were read; `nil` while none were.
  public var measuredAt: Date?
  /// Whether the Mac is asking the account's CLI now.
  public var isAsking: Bool
  /// Why there is no figure, when the CLI said.
  public var unavailable: RemoteQuotaUnavailability?
  public var windows: [RemoteQuotaWindow]
  /// `nil` for an account without any session over the last thirty days.
  public var cost: RemoteQuotaCost?

  public init(
    id: String, name: String, plan: String? = nil, usageURL: URL? = nil, measuredAt: Date? = nil,
    isAsking: Bool = false, unavailable: RemoteQuotaUnavailability? = nil,
    windows: [RemoteQuotaWindow] = [], cost: RemoteQuotaCost? = nil
  ) {
    self.id = id
    self.name = name
    self.plan = plan
    self.usageURL = usageURL
    self.measuredAt = measuredAt
    self.isAsking = isAsking
    self.unavailable = unavailable
    self.windows = windows
    self.cost = cost
  }

  /// The window nearest its limit, among those that have not reset since.
  public func mostUsed(at now: Date) -> RemoteQuotaWindow? {
    windows.filter { !$0.hasReset(at: now) }.max { $0.usedFraction < $1.usedFraction }
  }
}

/// Every account of the Mac and its quota (#630), sent while the phone watches them.
public struct RemoteQuotas: Codable, Hashable, Sendable {
  /// Usage tracking is on, on the Mac: off, nothing is read, and `accounts` is empty.
  public var isTrackingOn: Bool
  /// Whether shares are shown as what is left rather than what was used: the Mac's setting.
  public var showsRemaining: Bool
  /// The currency of the costs, ISO 4217.
  public var currency: String
  public var accounts: [RemoteQuotaAccount]

  public init(
    isTrackingOn: Bool, showsRemaining: Bool, currency: String, accounts: [RemoteQuotaAccount]
  ) {
    self.isTrackingOn = isTrackingOn
    self.showsRemaining = showsRemaining
    self.currency = currency
    self.accounts = accounts
  }

  /// The window nearest its limit among every account's, and how near.
  public func gauge(at now: Date) -> RemoteQuotaGauge {
    guard isTrackingOn, let most = accounts.compactMap({ $0.mostUsed(at: now)?.usedFraction }).max()
    else { return .unknown }
    return RemoteQuotaGauge(level: RemoteQuotaGauge.level(for: most), usedFraction: most)
  }

  /// The accounts with a window spent, with those windows.
  public func blocked(at now: Date) -> [(account: RemoteQuotaAccount, windows: [RemoteQuotaWindow])]
  {
    accounts.compactMap { account in
      let spent = account.windows.filter { $0.isExhausted && !$0.hasReset(at: now) }
      return spent.isEmpty ? nil : (account, spent)
    }
  }

  /// The thirty days of every account that has a price; `nil` when none has.
  public var totalCost: Decimal? {
    let priced = accounts.compactMap(\.cost).filter(\.hasPrice)
    return priced.isEmpty ? nil : priced.reduce(Decimal(0)) { $0 + $1.amount }
  }

  /// Whether a model without a known price was left out of some account's cost.
  public var leavesOutUnpriced: Bool {
    accounts.contains { $0.cost?.leavesOutUnpriced == true }
  }
}

/// The needle and colour of the dial: green under four fifths used, orange up to the limit, red
/// at it, grey without any figure — the Mac's `QuotaGauge`, whose thresholds a test keeps equal.
public struct RemoteQuotaGauge: Hashable, Sendable {
  public enum Level: Hashable, Sendable {
    case normal, near, reached, unknown
  }

  public static let nearThreshold = 0.8
  public static let unknown = RemoteQuotaGauge(level: .unknown, usedFraction: nil)

  public let level: Level
  /// The share used of the window nearest its limit.
  public let usedFraction: Double?

  public init(level: Level, usedFraction: Double?) {
    self.level = level
    self.usedFraction = usedFraction
  }

  public static func level(for usedFraction: Double) -> Level {
    if usedFraction >= 1 { return .reached }
    if usedFraction >= nearThreshold { return .near }
    return .normal
  }

  /// Where the needle points, from 0 on the left to 1 on the right.
  public func needle(showsRemaining: Bool) -> Double {
    guard let usedFraction else { return 0 }
    return showsRemaining ? 1 - usedFraction : usedFraction
  }
}
