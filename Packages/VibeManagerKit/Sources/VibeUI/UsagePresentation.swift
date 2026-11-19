import Foundation
import VibeApplication
import VibeDomain

/// How usage figures read. Pure, so the wording can be held to in tests.
enum UsagePresentation {
  static var tokensExplanation: String {
    String(
      localized: """
        Tokens are read from the transcripts Claude Code and Codex write on this Mac. They are \
        approximate: a transcript the CLI deletes can no longer be read, an interrupted answer may \
        be written without its usage, calls the CLI makes outside its transcript are not seen, and \
        sessions started outside Polyvibe are never counted.
        """,
      bundle: .module)
  }
  static var costExplanation: String {
    String(
      localized: """
        The cost is an API equivalent: the tokens each model reported, at its public price per \
        token for input, cache reads, cache writes and output. On a subscription, it is what the \
        work would have cost paid by the token, not what was paid. The prices come from \
        LiteLLM's public list, read again once a day; nothing about you is sent. Cache writes are \
        counted at the five-minute price and long-context prices are left aside, hence the ≈. A \
        model without a known price is left out of the total, never counted as free.
        """,
      bundle: .module)
  }
  static var runningTimeExplanation: String {
    String(
      localized: """
        The time the agent's process was running in Polyvibe, whether it was working or \
        waiting for you. Time the Mac spent asleep is not counted.
        """,
      bundle: .module)
  }
  static var privacyNote: String {
    String(
      localized:
        "Usage is recorded on this Mac only. Only the public lists of prices and exchange rates are downloaded.",
      bundle: .module,
      comment:
        "What stays on the Mac, under the usage figures: only the public lists of model prices (#574) and of the European Central Bank's exchange rates (#599) are fetched."
    )
  }

  /// “≈ 4,82 $”: the cost in the currency chosen (#599), converted from the dollars the prices
  /// are in at the bank's rate — in dollars while no rate is known. A cost that rounds to nothing
  /// without being nothing is “< 0,01 $”, never a zero.
  static func cost(
    _ amount: Decimal, approximate: Bool = true, locale: Locale = .current,
    conversion: CostConversion = CostConversion.current
  ) -> String {
    let style = Decimal.FormatStyle.Currency(code: conversion.code, locale: locale)
      .presentation(.narrow)
    let converted = amount * conversion.perDollar
    // Below a cent, never a rounding: half a cent rounds to the even “0,00 $”.
    if converted > 0, converted < Decimal(1) / 100 {
      return "< " + (Decimal(1) / 100).formatted(style)
    }
    return (approximate ? "≈ " : "") + converted.formatted(style)
  }

  /// Said of a model without a known price, whose tokens are left out of a cost.
  static func unknownPrice(locale: Locale = .current) -> String {
    String(
      localized: LocalizedStringResource(
        "Unknown price", locale: locale, bundle: .module,
        comment: "A model whose public price per token is not known: its cost is not counted."))
  }

  /// Under a cost some of whose models have no price.
  static func unpricedModelsLeftOut(locale: Locale = .current) -> String {
    String(
      localized: LocalizedStringResource(
        "Models without a known price are left out of the total.", locale: locale,
        bundle: .module, comment: "Under a cost, when a model has no known price."))
  }

  /// “4.82 US dollars”: the cost as VoiceOver reads it.
  static func spokenCost(
    _ amount: Decimal, locale: Locale = .current,
    conversion: CostConversion = CostConversion.current
  ) -> String {
    (amount * conversion.perDollar).formatted(
      Decimal.FormatStyle.Currency(code: conversion.code, locale: locale).presentation(.fullName))
  }

  /// “1 $ = 0,86 € · ECB, 21/11”: the rate a cost was converted at, under it.
  static func conversionNote(_ conversion: CostConversion, locale: Locale = .current) -> String? {
    guard conversion.code != "USD", let day = conversion.day else { return nil }
    let one = Decimal(1).formatted(
      Decimal.FormatStyle.Currency(code: "USD", locale: locale).presentation(.narrow)
        .precision(.fractionLength(0)))
    let rate = conversion.perDollar.formatted(
      Decimal.FormatStyle.Currency(code: conversion.code, locale: locale).presentation(.narrow)
        .precision(.fractionLength(2...4)))
    return String(
      localized: LocalizedStringResource(
        "\(one) = \(rate) · European Central Bank, \(day)", locale: locale, bundle: .module,
        comment:
          "The rate costs are converted at, such as “1 $ = 0,86 € · European Central Bank, 2026-11-21”."
      ))
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded(.down))
    if minutes < 1 { return seconds > 0 ? "< 1 min" : "0 min" }
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest) min" }
    return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
  }

  static func tokens(_ value: Int) -> String {
    switch value {
    case ..<1_000: return "\(value)"
    case ..<1_000_000: return trimmed(Double(value) / 1_000) + " k"
    default: return trimmed(Double(value) / 1_000_000) + " M"
    }
  }

  private static func trimmed(_ value: Double) -> String {
    value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
  }

  /// "2 starts · 5 resumes (2 after relaunch) · 1 new process · 1 switch".
  static func runs(_ counts: UsageRunCounts, locale: Locale = .current) -> String {
    runParts(counts, locale: locale).joined(separator: " · ")
  }

  /// The runs said in parts, each short enough for a line of its own in a narrow column.
  static func runParts(_ counts: UsageRunCounts, locale: Locale = .current) -> [String] {
    guard counts.total > 0 else {
      return [
        String(
          localized: LocalizedStringResource(
            "None recorded", locale: locale, bundle: .module,
            comment: "No run of an agent was recorded."))
      ]
    }
    var parts: [String] = []
    if counts.starts > 0 {
      parts.append(
        String(
          localized: LocalizedStringResource(
            "\(counts.starts) starts", locale: locale, bundle: .module,
            comment: "How many times an agent was started for the first time.")))
    }
    if counts.resumes > 0 {
      parts.append(
        String(
          localized: LocalizedStringResource(
            "\(counts.resumes) resumes", locale: locale, bundle: .module,
            comment: "How many times an agent resumed its conversation.")))
    }
    if counts.restarts > 0 {
      parts.append(
        String(
          localized: LocalizedStringResource(
            "\(counts.restarts) new processes", locale: locale, bundle: .module,
            comment: "How many times an agent was restarted without resuming its conversation.")))
    }
    if counts.afterRelaunch > 0, let last = parts.indices.last {
      parts[last] += String(
        localized: LocalizedStringResource(
          " (\(counts.afterRelaunch) after relaunch)", locale: locale, bundle: .module,
          comment:
            "How many of the resumes followed a relaunch of Polyvibe. Keep the leading space."))
    }
    if counts.afterSwitch > 0 {
      parts.append(
        String(
          localized: LocalizedStringResource(
            "\(counts.afterSwitch) switches", locale: locale, bundle: .module,
            comment: "How many times the session's agent was switched.")))
    }
    return parts
  }

  static func tokenSummary(_ tokens: TokenCounts, locale: Locale = .current) -> String {
    tokenParts(tokens, locale: locale).joined(separator: " · ")
  }

  /// The tokens said in parts, each short enough for a line of its own in a narrow column.
  static func tokenParts(_ tokens: TokenCounts, locale: Locale = .current) -> [String] {
    var parts = [
      String(
        localized: LocalizedStringResource(
          "\(Self.tokens(tokens.input)) in", locale: locale, bundle: .module,
          comment: "Input tokens, abbreviated: “12.3 k in”.")),
      String(
        localized: LocalizedStringResource(
          "\(Self.tokens(tokens.output)) out", locale: locale, bundle: .module,
          comment: "Output tokens, abbreviated: “4.5 k out”.")),
    ]
    if tokens.cacheRead > 0 {
      parts.append(
        String(
          localized: LocalizedStringResource(
            "\(Self.tokens(tokens.cacheRead)) cache read", locale: locale, bundle: .module,
            comment: "Tokens read from the cache, abbreviated: “1.2 M cache read”.")))
    }
    if tokens.cacheWrite > 0 {
      parts.append(
        String(
          localized: LocalizedStringResource(
            "\(Self.tokens(tokens.cacheWrite)) cache write", locale: locale, bundle: .module,
            comment: "Tokens written to the cache, abbreviated: “80.0 k cache write”.")))
    }
    return parts
  }

  /// “≈ 92 k / 167 k · 55 %” — of the way to the automatic compaction, or to the end of the
  /// window when it is not known — or “≈ 92 k tokens” without either.
  static func context(_ usage: ContextWindowUsage) -> String {
    guard let window = usage.compactionThreshold ?? usage.windowSize,
      let percent = usage.percentUsed
    else {
      return "≈ "
        + String(
          localized: "\(tokens(usage.usedTokens)) tokens", bundle: .module,
          comment: "The context, read by VoiceOver: a number of tokens.")
    }
    return "≈ \(tokens(usage.usedTokens)) / \(tokens(window)) · \(percent)\u{00A0}%"
  }

  static func unavailable(_ reason: UsageUnavailability, locale: Locale = .current) -> String {
    switch reason {
    case .notReportedByAgent:
      return String(
        localized: LocalizedStringResource(
          "Not reported by this agent", locale: locale, bundle: .module,
          comment: "Why a usage figure is missing."))
    case .noTranscript:
      return String(
        localized: LocalizedStringResource(
          "No transcript found", locale: locale, bundle: .module,
          comment: "Why a usage figure is missing."))
    case .trackingOff:
      return String(
        localized: LocalizedStringResource(
          "Usage tracking is off", locale: locale, bundle: .module,
          comment: "Why a usage figure is missing."))
    }
  }

  static func periodName(_ period: UsagePeriod) -> LocalizedStringResource {
    switch period {
    case .today:
      return LocalizedStringResource(
        "Today", bundle: .module, comment: "A period of the Usage window.")
    case .last7Days:
      return LocalizedStringResource(
        "Last 7 days", bundle: .module, comment: "A period of the Usage window.")
    case .last30Days:
      return LocalizedStringResource(
        "Last 30 days", bundle: .module, comment: "A period of the Usage window.")
    case .thisMonth:
      return LocalizedStringResource(
        "This month", bundle: .module, comment: "A period of the Usage window.")
    case .previousMonth:
      return LocalizedStringResource(
        "Previous month", bundle: .module, comment: "A period of the Usage window.")
    case .allTime:
      return LocalizedStringResource(
        "All time", bundle: .module, comment: "A period of the Usage window.")
    }
  }

  static func groupingName(_ grouping: UsageGrouping) -> LocalizedStringResource {
    switch grouping {
    case .session:
      return LocalizedStringResource(
        "Session", bundle: .module, comment: "What the Usage window groups its figures by.")
    case .provider:
      return LocalizedStringResource(
        "Agent", bundle: .module, comment: "What the Usage window groups its figures by.")
    case .model:
      return LocalizedStringResource(
        "Model", bundle: .module,
        comment: "What the Usage window groups its figures by: an agent's model.")
    }
  }
}

/// The currency costs are drawn in, and its rate to the dollar (#599).
public struct CostConversion: Hashable, Sendable {
  public let code: String
  public let perDollar: Decimal
  /// The day of the bank's rate; `nil` for the dollar.
  public let day: String?

  public static let dollar = CostConversion(code: "USD", perDollar: 1, day: nil)

  /// What every cost is drawn with: set by the usage model when the currency or its rate changes.
  nonisolated(unsafe) public static var current = CostConversion.dollar

  /// The currency chosen at the rate known; the dollar when it has none.
  public static func make(code: String, rates: ExchangeRates?) -> CostConversion {
    guard code != "USD", let rates, let rate = rates.perDollar(code) else { return .dollar }
    return CostConversion(code: code, perDollar: rate, day: rates.day)
  }
}
