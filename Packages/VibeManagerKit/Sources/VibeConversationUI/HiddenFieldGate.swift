import AppKit
import SwiftUI

/// Laid behind a conversation's field: hides the field's own view while the conversation is not
/// the one on screen.
///
/// The conversations kept behind the one shown are only at zero opacity, and a disabled
/// `TextEditor` is still editable for AppKit: their fields, right where the shown one's is, put
/// their I-beam over its buttons. Hidden, a field shows no pointer, follows none, and is not
/// drawn; what it holds, its caret and its undo stay.
struct HiddenFieldGate: NSViewRepresentable {
  let isShown: Bool

  func makeNSView(context: Context) -> GateView { GateView() }

  func updateNSView(_ view: GateView, context: Context) {
    view.isShown = isShown
    // Each update is another chance to find a field not placed yet.
    view.findFieldIfNeeded()
  }

  final class GateView: NSView {
    var isShown = true {
      didSet { if oldValue != isShown { apply() } }
    }
    private weak var field: NSScrollView?
    /// The field each gate took, so that no other gate takes it too.
    @MainActor private static let claimed = NSMapTable<NSScrollView, GateView>.weakToWeakObjects()
    /// The turns of the run loop it still looks again on, while its field is not there.
    private var retries = 0
    private var retryScheduled = false

    /// Clicks, scrolling and the pointer stay the field's.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      retries = 20
      apply()
    }

    override func layout() {
      super.layout()
      findFieldIfNeeded()
    }

    func findFieldIfNeeded() {
      if field == nil { apply() }
    }

    private func apply() {
      guard window != nil else { return }
      guard let field = field ?? claimField() else { return scheduleRetry() }
      guard field.isHidden == isShown else { return }
      // Hiding the view with the keyboard would hand it to the next key view, a button that would
      // then receive what was typed.
      if !isShown, let window, let responder = window.firstResponder as? NSView,
        responder.isDescendant(of: field)
      {
        window.makeFirstResponder(nil)
      }
      field.isHidden = !isShown
    }

    private func claimField() -> NSScrollView? {
      guard let found = Self.field(after: self) else { return nil }
      if let owner = Self.claimed.object(forKey: found), owner !== self { return nil }
      Self.claimed.setObject(self, forKey: found)
      field = found
      return found
    }

    /// SwiftUI may lay the gate out before the field: looked for again on the next turns, as
    /// nothing else is sure to come.
    private func scheduleRetry() {
      guard retries > 0, !retryScheduled else { return }
      retries -= 1
      retryScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        retryScheduled = false
        findFieldIfNeeded()
      }
    }

    /// What a walk after the gate met first.
    private enum Found {
      case field(NSScrollView)
      /// Another conversation's gate: what follows is its field, never this one's.
      case otherGate
    }

    /// The field this view is laid behind: the first one SwiftUI placed after it, where it is, and
    /// none past another gate. Not only the one at the same place — the field of a conversation
    /// behind is exactly there too, and comes after that conversation's own gate.
    static func field(after gate: GateView) -> NSScrollView? {
      let place = gate.convert(gate.bounds, to: nil)
      guard place.width > 0, place.height > 0 else { return nil }
      var level: NSView = gate
      while let parent = level.superview {
        if let index = parent.subviews.firstIndex(where: { $0 === level }) {
          for sibling in parent.subviews[(index + 1)...] {
            switch first(in: sibling, at: place) {
            case .field(let field): return field
            case .otherGate: return nil
            case nil: continue
            }
          }
        }
        level = parent
      }
      return nil
    }

    private static func first(in view: NSView, at place: NSRect) -> Found? {
      if view is GateView { return .otherGate }
      if let scroll = view as? NSScrollView, scroll.documentView is NSTextView {
        let frame = scroll.convert(scroll.bounds, to: nil)
        let there = abs(frame.midX - place.midX) < 1 && abs(frame.midY - place.midY) < 1
        return there ? .field(scroll) : nil
      }
      for subview in view.subviews {
        if let found = first(in: subview, at: place) { return found }
      }
      return nil
    }
  }
}
