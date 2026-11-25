import Foundation

/// The usage of the conversation shown on a phone (#631). Amounts are converted by the Mac;
/// the phone only formats them. A tracking-off message replaces any previous figures.
public struct RemoteSessionUsage: Codable, Hashable, Sendable {
  public var sessionID: String
  public var isTrackingOn: Bool
  public var currency: String
  public var context: RemoteUsageContext?
  public var contextUnavailable: String?
  public var runningTime: TimeInterval?
  public var tokens: Int?
  public var tokensUnavailable: String?
  public var cost: RemoteQuotaCost?
  public var models: [RemoteModelCost]
  public var family: RemoteFamilyUsage?

  public init(
    sessionID: String, isTrackingOn: Bool = true, currency: String,
    context: RemoteUsageContext? = nil, contextUnavailable: String? = nil,
    runningTime: TimeInterval? = nil, tokens: Int? = nil, tokensUnavailable: String? = nil,
    cost: RemoteQuotaCost? = nil, models: [RemoteModelCost] = [], family: RemoteFamilyUsage? = nil
  ) {
    self.sessionID = sessionID
    self.isTrackingOn = isTrackingOn
    self.currency = currency
    self.context = context
    self.contextUnavailable = contextUnavailable
    self.runningTime = runningTime
    self.tokens = tokens
    self.tokensUnavailable = tokensUnavailable
    self.cost = cost
    self.models = models
    self.family = family
  }

  public var hasFigures: Bool {
    isTrackingOn && (context != nil || runningTime != nil || cost != nil || family != nil)
  }
}

public struct RemoteUsageContext: Codable, Hashable, Sendable {
  public var usedTokens: Int
  public var windowSize: Int?
  public var compactionThreshold: Int?
  /// The share sent by the Mac follows the CLI's compaction threshold, as on its status bar.
  public var percentUsed: Int?
  public var isEstimate: Bool

  public init(
    usedTokens: Int, windowSize: Int?, percentUsed: Int?, isEstimate: Bool = false,
    compactionThreshold: Int? = nil
  ) {
    self.usedTokens = usedTokens
    self.windowSize = windowSize
    self.compactionThreshold = compactionThreshold
    self.percentUsed = percentUsed
    self.isEstimate = isEstimate
  }
}

public struct RemoteModelCost: Codable, Hashable, Sendable {
  public var providerName: String
  public var model: String?
  /// `nil` means an unknown price, never a free model.
  public var amount: Decimal?

  public init(providerName: String, model: String?, amount: Decimal?) {
    self.providerName = providerName
    self.model = model
    self.amount = amount
  }
}

public struct RemoteFamilyUsage: Codable, Hashable, Sendable {
  public struct Child: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var depth: Int
    public var cost: RemoteQuotaCost?

    public init(id: String, name: String, depth: Int, cost: RemoteQuotaCost?) {
      self.id = id
      self.name = name
      self.depth = depth
      self.cost = cost
    }
  }

  public var cost: RemoteQuotaCost?
  public var children: [Child]

  public init(cost: RemoteQuotaCost?, children: [Child]) {
    self.cost = cost
    self.children = children
  }
}

/// Locale-dependent numbers only: sentences belong to the phone's string catalog.
public enum RemoteUsageFormat {
  public static func duration(_ seconds: TimeInterval) -> String {
    Duration.seconds(max(0, seconds)).formatted(.time(pattern: .hourMinuteSecond))
  }

  public static func tokens(_ count: Int, locale: Locale) -> String {
    count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
  }

  /// Without a known context window, the running time takes the share's place.
  public static func contextOrTime(_ usage: RemoteSessionUsage, locale: Locale) -> String {
    if let percent = usage.context?.percentUsed {
      return (Double(percent) / 100).formatted(
        .percent.precision(.fractionLength(0)).locale(locale))
    }
    return usage.runningTime.map(duration) ?? "—"
  }
}
