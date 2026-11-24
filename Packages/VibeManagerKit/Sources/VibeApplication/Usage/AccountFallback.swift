import Foundation

/// An account at its limit (#600): a window of its quota spent, that will not come back soon.
public struct AccountLimit: Hashable, Sendable {
  /// When every spent window is back; `nil` when the CLI did not say for one of them.
  public let resetsAt: Date?
  /// When the CLI said so.
  public let measuredAt: Date

  /// A limit whose end is unknown is believed this long: the next reading tells.
  public static let unknownResetTrust: TimeInterval = 10 * 60

  public init(resetsAt: Date?, measuredAt: Date) {
    self.resetsAt = resetsAt
    self.measuredAt = measuredAt
  }

  /// Whether the account is still at its limit at `now`.
  public func holds(at now: Date) -> Bool {
    guard let resetsAt else { return now < measuredAt.addingTimeInterval(Self.unknownResetTrust) }
    return now < resetsAt
  }
}

/// When a session goes on with the next account of the backup chain, and with which (#600).
///
/// Only the account's limit moves a session: a spent quota, or a rate limit that lifts in a while.
/// A passing error — a 503, a 429 that resets in 0 s — is the agent's to retry, and changes
/// nothing.
public enum AccountFallbackRules {
  /// A limit that lifts sooner than this is waited for, not fled.
  public static let minimumWait: TimeInterval = 15 * 60

  /// The limit the account is at, by what its CLI said of its quota at `now`: a window spent that
  /// does not come back within `minimumWait`. A spent window of one model is not the account's —
  /// the session may well run another —, nor one group of Antigravity's among others: only every
  /// one of them spent is.
  public static func limit(of quota: AccountQuota?, at now: Date) -> AccountLimit? {
    guard let quota else { return nil }
    func isSpent(_ window: QuotaWindow) -> Bool {
      window.isExhausted && !window.hasReset(at: now)
    }
    var blocking: [QuotaWindow] = quota.windows.filter { window in
      switch window.kind {
      case .session, .minutes, .weekly: isSpent(window)
      case .weeklyModel, .group: false
      }
    }
    let groups = quota.windows.filter {
      if case .group = $0.kind { return true }
      return false
    }
    if !groups.isEmpty, groups.allSatisfy(isSpent) { blocking += groups }
    guard !blocking.isEmpty else { return nil }
    let dates = blocking.map(\.resetsAt)
    let resetsAt = dates.contains(nil) ? nil : dates.compactMap { $0 }.max()
    if let resetsAt, resetsAt.timeIntervalSince(now) < minimumWait { return nil }
    return AccountLimit(resetsAt: resetsAt, measuredAt: quota.measuredAt)
  }

  /// The words a CLI's refusal at the account's limit holds, one at least — Claude Code's “You've
  /// hit your limit”, Codex's “usage limit”, Antigravity's `RESOURCE_EXHAUSTED (code 429)`. A
  /// prompt too long or an overloaded server says none of them: the quota may read 100 % at the
  /// same time, extra usage going on, and the turn is still not the account's to hand over.
  static let limitWords = ["limit", "quota", "exhausted", "429"]

  /// Whether the conversation ends on the provider's refusal at a limit: the error notice of #599
  /// is the last thing written, whatever the agent did of the turn before it.
  public static func endsOnLimitError(_ entries: [ConversationEntry]) -> Bool {
    for entry in entries.reversed() {
      switch entry.content {
      case .notice(.error(let text)):
        let lowered = text.lowercased()
        return limitWords.contains { lowered.contains($0) }
      // Written by the CLI beside the conversation: what the error was said after.
      case .notice(.information): continue
      default: return false
      }
    }
    return false
  }

  /// The accounts to go on with, in the order to try them: those after the session's in the
  /// chain, then those before it. None for an account the chain leaves out.
  public static func candidates(after providerID: String, in chain: [String]) -> [String] {
    guard let index = chain.firstIndex(of: providerID) else { return [] }
    return Array(chain[(index + 1)...] + chain[..<index])
  }
}
