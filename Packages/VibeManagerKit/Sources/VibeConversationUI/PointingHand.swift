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
      content.modifier(PushedPointingHand(isOn: isOn))
    }
  }
}

/// Before macOS 15: the hand pushed while the pointer is over, popped as it leaves — the pointer
/// under it comes back, an I-beam over text included — or as the action turns off.
private struct PushedPointingHand: ViewModifier {
  let isOn: Bool
  @State private var isPushed = false

  func body(content: Content) -> some View {
    content
      .onContinuousHover { phase in
        switch phase {
        case .active: if isOn { push() }
        case .ended: pop()
        }
      }
      .onChange(of: isOn) { _, isOn in if !isOn { pop() } }
      .onDisappear { pop() }
  }

  private func push() {
    guard !isPushed else { return }
    NSCursor.pointingHand.push()
    isPushed = true
  }

  private func pop() {
    guard isPushed else { return }
    NSCursor.pop()
    isPushed = false
  }
}
