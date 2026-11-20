import Foundation
import VibeConversationUI

extension AppModel {
  // MARK: Bookmarks (#567)

  /// The conversation on screen, for the bookmark commands: none while a session is shown as its
  /// terminal.
  var conversationOnScreen: ConversationModel? {
    guard isSessionOnScreen, let id = selectedSessionID,
      let shown = sessions.first(where: { $0.id == id }),
      presentation(of: shown) == .conversation
    else { return nil }
    return conversations.existingModel(for: id)
  }

  /// Whether the bookmark commands apply: a conversation with messages is on screen.
  public var canUseBookmarks: Bool {
    conversationOnScreen.map { !$0.blocks.isEmpty } ?? false
  }

  /// Toggle Bookmark, ⌘B: on the message the selection is in, the one at the top otherwise.
  public func toggleBookmark() {
    guard conversationOnScreen?.toggleBookmarkInView() == true else { return beep() }
  }

  /// Next Moment, ⌥⌘J: the next moment shown, whatever its kind (#572). A beep past the last one.
  public func revealNextMoment() {
    guard conversationOnScreen?.revealNextMoment() == true else { return beep() }
  }

  /// Previous Moment, ⌥⌘K. A beep before the first one.
  public func revealPreviousMoment() {
    guard conversationOnScreen?.revealPreviousMoment() == true else { return beep() }
  }
}
