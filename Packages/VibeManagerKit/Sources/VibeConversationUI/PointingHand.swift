import AppKit
import SwiftUI

extension View {
  /// The pointing hand over one of the conversation's actions — « Reply », a bookmark, a code
  /// block's Copy and Run —, as over a link. `false` leaves the pointer as it is: a disabled
  /// action shows no hand.
  func pointingHand(_ isOn: Bool = true) -> some View {
    modifier(PointingHand(isOn: isOn))
  }
}

private struct PointingHand: ViewModifier {
  let isOn: Bool

  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.pointerStyle(isOn ? .link : nil)
    } else {
      content.onContinuousHover { phase in
        guard isOn else { return }
        switch phase {
        case .active: NSCursor.pointingHand.set()
        case .ended: NSCursor.arrow.set()
        }
      }
    }
  }
}
