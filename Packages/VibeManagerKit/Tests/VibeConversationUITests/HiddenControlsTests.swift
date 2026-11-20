import AppKit
import SwiftUI
import Testing
import VibeApplication

@testable import VibeConversationUI

/// The controls every message has, hidden until the pointer comes: not built as buttons until
/// then, which a drag in the overview of a long conversation paid for at every frame (#567).
@MainActor
@Suite("Controls hidden on every message")
struct HiddenControlsTests {
  private func fittingSize(_ view: some View) -> CGSize {
    let hosting = NSHostingView(
      rootView:
        view
        .environment(\.conversationTheme, .systemDark)
        .environment(\.conversationAppearance, ConversationAppearance()))
    hosting.layoutSubtreeIfNeeded()
    return hosting.fittingSize
  }

  @Test("The room kept for « Reply » is the button's own: nothing moves when the pointer comes")
  func replyRoom() {
    let button = fittingSize(ReplyButton {})
    #expect(button.width > 0 && button.height > 0)
    #expect(fittingSize(ReplyLabel().hidden()) == button)
  }
}
