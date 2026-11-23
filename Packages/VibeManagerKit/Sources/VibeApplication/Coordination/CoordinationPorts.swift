import Foundation
import VibeDomain

/// The user's settings for coordination (#352).
@MainActor
public protocol CoordinationPreferences: AnyObject {
  /// How many children of one coordinator may run at once.
  var maximumRunningChildren: Int { get set }
}

public enum CoordinationLimits {
  public static let defaultRunningChildren = 3
  public static let runningChildren = 1...10
}

/// A wake-up a coordinator asked for (#352).
public struct CoordinationWake: Hashable, Codable, Sendable {
  public let date: Date
  public let reason: String

  public init(date: Date, reason: String) {
    self.date = date
    self.reason = reason
  }
}

/// Where the wake-ups are kept, beside the store (#352).
public protocol CoordinationStore: Sendable {
  func wakes() async -> [SessionID: CoordinationWake]
  func setWake(_ wake: CoordinationWake?, for coordinator: SessionID) async
}
