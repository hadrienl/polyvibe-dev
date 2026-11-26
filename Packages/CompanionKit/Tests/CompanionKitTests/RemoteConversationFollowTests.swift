import CompanionCore
import Testing

@Suite("The conversation the phone follows (#631)")
struct RemoteConversationFollowTests {
  @Test(
    "Returning before the first Mac reply still sends the stop and cannot resubscribe on reconnect")
  func leaveBeforeReply() {
    var follow = RemoteConversationFollow()
    let start = follow.show("session")
    // No conversation has arrived: the requested selection is enough to stop its Mac watch.
    let stop = follow.hide("session")
    #expect(
      [start, stop].compactMap { $0 } == [.show(sessionID: "session"), .show(sessionID: nil)])
    #expect(follow.sessionID == nil)
    #expect(follow.hide("session") == nil)
  }

  @Test("The old view disappearing after another session opens cannot stop the new watch")
  func previousView() {
    var follow = RemoteConversationFollow()
    _ = follow.show("old")
    _ = follow.show("new")
    #expect(follow.hide("old") == nil)
    #expect(follow.sessionID == "new")
    #expect(follow.hide("new") == .show(sessionID: nil))
  }
}
