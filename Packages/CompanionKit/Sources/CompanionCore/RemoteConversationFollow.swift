/// The conversation the phone asked to follow, independently of whether the Mac has answered.
/// A disappearing view may release its own selection, never the next view's (#631).
public struct RemoteConversationFollow: Sendable {
  public private(set) var sessionID: String?

  public init() {}

  public mutating func show(_ sessionID: String?) -> RemoteMessage {
    self.sessionID = sessionID
    return .show(sessionID: sessionID)
  }

  /// Also sends the stop before the first conversation frame, or while disconnected.
  public mutating func hide(_ sessionID: String) -> RemoteMessage? {
    guard self.sessionID == sessionID else { return nil }
    return show(nil)
  }
}
