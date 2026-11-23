import Foundation
import VibeApplication

/// A window of the account's quota, as agy's status line gives it (#599): `quota.<bucket>` with
/// the share left and when it comes back. agy 1.5.14 names two weekly buckets, `gemini-weekly` and
/// `3p-weekly` (its Claude and GPT models).
public struct AntigravityQuotaBucket: Hashable, Sendable {
  public let id: String
  /// From 0, spent, to 1, untouched.
  public let remainingFraction: Double
  public let resetsAt: Date?

  public init(id: String, remainingFraction: Double, resetsAt: Date?) {
    self.id = id
    self.remainingFraction = remainingFraction
    self.resetsAt = resetsAt
  }

  /// Nothing left: agy refuses the models of this bucket until it resets.
  public var isExhausted: Bool { remainingFraction <= 0 }

  /// Spent, and not come back yet: a bucket whose reset has passed is no longer the reason.
  public func isSpent(at now: Date) -> Bool {
    guard isExhausted else { return false }
    guard let resetsAt else { return true }
    return resetsAt > now
  }

  /// What the status command wrote: `bucket=fraction@reset;…`. A bucket without a share is left
  /// out; a reset that does not read as a date is unknown.
  static func parse(_ text: String) -> [AntigravityQuotaBucket] {
    text.split(separator: ";").prefix(8).compactMap { part in
      guard let equal = part.firstIndex(of: "=") else { return nil }
      let id = String(part[..<equal])
      let value = part[part.index(after: equal)...]
      let fraction: Substring
      let reset: Substring?
      if let at = value.firstIndex(of: "@") {
        fraction = value[..<at]
        reset = value[value.index(after: at)...]
      } else {
        fraction = value
        reset = nil
      }
      guard !id.isEmpty, let share = Double(fraction), share.isFinite else { return nil }
      return AntigravityQuotaBucket(
        id: id, remainingFraction: min(max(share, 0), 1),
        resetsAt: reset.flatMap { TranscriptDates.parse(String($0)) })
    }
  }

  /// The bucket as the user knows it: agy's two buckets by the models they hold, any other by its
  /// identifier.
  var displayName: String {
    switch id {
    case "gemini-weekly":
      return String(
        localized: "Gemini models, weekly", bundle: .module,
        comment: "An Antigravity quota: the weekly limit of its Gemini models.")
    case "3p-weekly":
      return String(
        localized: "Claude and GPT models, weekly", bundle: .module,
        comment: "An Antigravity quota: the weekly limit of its Claude and GPT models.")
    default:
      return id
    }
  }

  /// What is known when agy fails with a bucket spent: “Antigravity stopped on an error. Quota
  /// reached: Gemini models, weekly — resets Fri 28 Nov, 13:39.” agy does not say which bucket
  /// the turn needed, so the sentence states both facts without tying them.
  static func failure(_ buckets: [AntigravityQuotaBucket], now: Date = Date()) -> String? {
    let spent = buckets.filter { $0.isSpent(at: now) }
    guard !spent.isEmpty else { return nil }
    let names = spent.map(\.displayName).joined(separator: ", ")
    let resets = spent.compactMap(\.resetsAt).filter { $0 > now }.min()
    guard let resets else {
      return String(
        localized: "Antigravity stopped on an error. Quota reached: \(names).", bundle: .module,
        comment:
          "An Antigravity turn failed while a quota was spent. The argument names the quotas.")
    }
    let date = resets.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute())
    return String(
      localized: "Antigravity stopped on an error. Quota reached: \(names) — resets \(date).",
      bundle: .module,
      comment:
        "An Antigravity turn failed while a quota was spent. The first argument names the quotas, the second is a date and time, such as “Fri 28 Nov, 13:39”."
    )
  }
}
