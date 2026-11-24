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
  }

  final class GateView: NSView {
    var isShown = true {
      didSet { if oldValue != isShown { apply() } }
    }
    private weak var field: NSScrollView?

    /// Clicks, scrolling and the pointer stay the field's.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      apply()
    }

    override func layout() {
      super.layout()
      if field == nil { apply() }
    }

    private func apply() {
      guard window != nil, let field = field ?? Self.field(after: self) else { return }
      self.field = field
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

    /// The field this view is laid behind: the first one SwiftUI placed after it, where it is. Not
    /// only the one at the same place — the field of a conversation behind is exactly there too.
    static func field(after gate: NSView) -> NSScrollView? {
      let place = gate.convert(gate.bounds, to: nil)
      guard place.width > 0, place.height > 0 else { return nil }
      var level: NSView = gate
      while let parent = level.superview {
        if let index = parent.subviews.firstIndex(where: { $0 === level }) {
          for sibling in parent.subviews[(index + 1)...] {
            if let field = textField(in: sibling, at: place) { return field }
          }
        }
        level = parent
      }
      return nil
    }

    private static func textField(in view: NSView, at place: NSRect) -> NSScrollView? {
      if let scroll = view as? NSScrollView, scroll.documentView is NSTextView {
        let frame = scroll.convert(scroll.bounds, to: nil)
        return abs(frame.midX - place.midX) < 1 && abs(frame.midY - place.midY) < 1 ? scroll : nil
      }
      return view.subviews.lazy.compactMap { textField(in: $0, at: place) }.first
    }
  }
}
