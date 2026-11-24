import AppKit
import SwiftUI

extension View {
  /// The pointing hand over one of a message's actions — « Reply », its bookmark —, as over a
  /// link: what a click there does is act on the message.
  func pointingHand() -> some View {
    modifier(PointingHand())
  }
}

private struct PointingHand: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.pointerStyle(.link)
    } else {
      content.onContinuousHover { phase in
        switch phase {
        case .active: NSCursor.pointingHand.set()
        case .ended: NSCursor.arrow.set()
        }
      }
    }
  }
}
