import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

/// The conversations kept behind the one on screen are at zero opacity, still in the window for
/// AppKit: their text put its I-beam over the buttons and the links of the one shown.
@MainActor
@Suite("The pointer over a conversation, and the ones kept behind it")
struct HiddenConversationPointerTests {
  private func window(_ content: NSView) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    return window
  }

  private static func segment(in view: NSView?) -> SegmentTextView? {
    guard let view else { return nil }
    return view as? SegmentTextView ?? view.subviews.lazy.compactMap(segment(in:)).first
  }

  private func moved(to point: NSPoint, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(
      with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
      pressure: 0)!
  }

  @Test("A message's text knows whether its conversation is the one on screen")
  func followsTheConversation() throws {
    let hosting = NSHostingView(rootView: AnyView(segment(live: false)))
    let window = window(hosting)
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded()
    let view = try #require(Self.segment(in: hosting))
    #expect(!view.isLive)
    hosting.rootView = AnyView(segment(live: true))
    hosting.layoutSubtreeIfNeeded()
    #expect(view.isLive)
  }

  private func segment(live: Bool) -> some View {
    SegmentView(content: .code("let answer = 42", language: "swift"))
      .environment(\.conversationTheme, .systemDark)
      .environment(\.conversationAppearance, ConversationAppearance())
      .environment(\.conversationIsLive, live)
  }

  private struct Stack: View {
    let models: [ConversationModel]
    let shown: Int

    var body: some View {
      ZStack {
        ForEach(models.indices, id: \.self) { index in
          PromptComposer(model: models[index], isActive: index == shown)
            .opacity(index == shown ? 1 : 0)
            .allowsHitTesting(index == shown)
            .disabled(index != shown)
        }
      }
      .environment(\.conversationTheme, .systemDark)
      .environment(\.conversationAppearance, ConversationAppearance())
      .frame(width: 400, height: 160)
    }
  }

  private static func fields(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).flatMap { $0.documentView is NSTextView ? [$0] : nil }
      ?? view.subviews.flatMap(fields(in:))
  }

  @Test("The field of a conversation kept behind is hidden, the shown one's never")
  func hiddenComposer() throws {
    let models = (0..<3).map { _ in
      let model = ConversationModel(sessionID: SessionID())
      model.apply(ConversationSnapshot(availability: .available))
      return model
    }
    let hosting = NSHostingView(rootView: Stack(models: models, shown: 1))
    let window = window(hosting)
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded()
    // A disabled field at zero opacity is still one AppKit edits, and shows its I-beam over.
    let fields = Self.fields(in: hosting)
    try #require(fields.count == 3)
    #expect(fields.map(\.isHidden) == [true, false, true])
    for shown in [0, 2, 1] {
      hosting.rootView = Stack(models: models, shown: shown)
      hosting.layoutSubtreeIfNeeded()
      #expect(Self.fields(in: hosting).map { !$0.isHidden } == (0..<3).map { $0 == shown })
    }
  }

  @Test("A field placed after its gate is hidden as soon as it is there, not at the next switch")
  func fieldPlacedLater() async throws {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let window = window(container)
    defer { window.close() }
    let place = NSRect(x: 20, y: 20, width: 300, height: 40)
    let gate = HiddenFieldGate.GateView(frame: place)
    container.addSubview(gate)
    // Launched behind the conversation shown: SwiftUI lays the gate out before the field.
    gate.isShown = false
    gate.layoutSubtreeIfNeeded()
    let field = field(at: place)
    container.addSubview(field)
    for _ in 0..<20 where !field.isHidden {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(field.isHidden)
    gate.isShown = true
    #expect(!field.isHidden)
  }

  private func field(at place: NSRect) -> NSScrollView {
    let field = NSScrollView(frame: place)
    field.documentView = NSTextView(frame: NSRect(origin: .zero, size: place.size))
    return field
  }

  @Test("A gate whose field is not there yet never takes the next conversation's, right there")
  func neverAnotherConversationsField() async throws {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let window = window(container)
    defer { window.close() }
    let place = NSRect(x: 20, y: 20, width: 300, height: 40)
    // The conversation kept behind, its field not placed yet, then the one shown.
    let hidden = HiddenFieldGate.GateView(frame: place)
    let shown = HiddenFieldGate.GateView(frame: place)
    let shownField = field(at: place)
    for view in [hidden, shown, shownField] { container.addSubview(view) }
    hidden.isShown = false
    shown.isShown = true
    try await Task.sleep(for: .milliseconds(100))
    #expect(!shownField.isHidden)

    let hiddenField = field(at: place)
    container.addSubview(hiddenField, positioned: .above, relativeTo: hidden)
    for _ in 0..<20 where !hiddenField.isHidden {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(hiddenField.isHidden)
    #expect(!shownField.isHidden)
  }

  @Test("« Reply to Selection » comes back with its conversation, as the selection does")
  func selectionReplyComesBack() throws {
    let view = SegmentTextView()
    view.show(
      NSAttributedString(
        string: "A passage to quote.", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
    view.frame = CGRect(x: 0, y: 0, width: 400, height: view.height(forWidth: 400))
    view.offerSelectionReply(endingAt: 9, passage: "A passage", reply: { _ in })
    let button = try #require(view.replyButton)
    #expect(!button.isHidden)
    view.isLive = false
    #expect(button.isHidden)
    view.isLive = true
    #expect(!button.isHidden)
  }

  @Test("Hidden, its text follows no pointer: no « Reply » under it, and none left shown")
  func hiddenFollowsNoPointer() throws {
    let view = SegmentTextView()
    view.show(
      NSAttributedString(
        string: "A paragraph to reply to.", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
    view.frame = CGRect(x: 0, y: 0, width: 400, height: view.height(forWidth: 400))
    view.offersParagraphReply = true
    view.replyAction = { _ in }
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    container.addSubview(view)
    let window = window(container)
    defer { window.close() }
    view.updateTrackingAreas()
    let overText = view.convert(NSPoint(x: 20, y: 5), to: nil)

    view.mouseMoved(with: moved(to: overText, in: window))
    let shown = try #require(view.replyButton)
    #expect(!shown.isHidden)
    #expect(view.replyTrackingArea != nil)

    view.isLive = false
    #expect(shown.isHidden)
    #expect(view.replyTrackingArea == nil)
    view.mouseMoved(with: moved(to: overText, in: window))
    #expect(shown.isHidden)

    view.isLive = true
    #expect(view.replyTrackingArea != nil)
    view.mouseMoved(with: moved(to: overText, in: window))
    #expect(!shown.isHidden)
  }
}
