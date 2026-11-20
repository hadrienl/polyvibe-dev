import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

/// A moment's icon answers the pointer over its whole square, not only where its strokes are drawn
/// (#572): the hollow of a question's ring, of a test's circle, the box around a bookmark's tag.
@MainActor
@Suite("The square of a moment's icon", .serialized)
struct MomentHitBoxTests {
  /// Answers, then a question: the ring the tests click into.
  private static func model() -> ConversationModel {
    let model = ConversationModel(sessionID: SessionID())
    model.write = { _ in }
    model.processRunning = { true }
    var entries = (0..<3).map {
      ConversationEntry(id: "a\($0)", content: .agentText("Answer \($0)"))
    }
    entries.append(
      ConversationEntry(
        id: "q",
        content: .tool(
          ToolCall(
            callID: "q", kind: .question, state: .succeeded,
            parameters: [.init(.question, "Which one?")]))))
    entries.append(ConversationEntry(id: "z", content: .agentText("End")))
    model.apply(ConversationSnapshot(entries: entries, availability: .available))
    return model
  }

  private static func window(_ view: some View, width: Double, height: Double) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: -20000, y: 0, width: width, height: height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: view)
    window.orderFrontRegardless()
    return window
  }

  private static func settle(_ window: NSWindow) async throws {
    for _ in 0..<20 {
      window.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private static func scrollView(in view: NSView) -> NSScrollView? {
    view as? NSScrollView ?? view.subviews.lazy.compactMap(scrollView(in:)).first
  }

  /// A click at a point given from the top of the window.
  private static func click(_ window: NSWindow, x: Double, y: Double) async throws {
    let point = NSPoint(x: x, y: window.frame.height - y)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      window.sendEvent(event)
      try await Task.sleep(for: .milliseconds(30))
    }
  }

  @Test("A click in the empty middle of a question's ring, in the overview, brings it up")
  func overviewRing() async throws {
    let model = Self.model()
    let metrics = ConversationOverviewLayout.Metrics(
      columnWidth: 600, textSize: 14.5, lineHeight: 1.4, blockSpacing: 18, paragraphSpacing: 10)
    let height = 600.0
    let window = Self.window(
      ConversationOverview(
        model: model, theme: .systemDark, metrics: metrics, pager: ConversationPager(), room: 400
      ).frame(width: 80, height: height), width: 80, height: height)
    defer { window.close() }
    try await Self.settle(window)
    let layout = ConversationOverviewLayout(
      blocks: model.blocks, measured: [:], metrics: metrics, shapes: ConversationOverviewShapes())
    let cluster = try #require(
      ConversationOverview.clusters(
        of: model.shownMoments, layout: layout, scale: layout.scale(forHeight: height)
      ).first)
    // The ring's middle, where nothing is drawn, then two corners of its square.
    let middle = ConversationOverview.tagMargin / 2
    for (x, dy) in [(middle, 0.0), (2.0, -5.0), (ConversationOverview.tagMargin - 2, 5.0)] {
      model.revealedBlockID = nil
      try await Self.click(window, x: x, y: cluster.y + dy)
      #expect(model.revealedBlockID == "q", "x \(x), \(dy) from the icon's middle")
    }
  }

  @Test("In the messages' margin, the whole square of the icon and of the bookmark answer")
  func margin() async throws {
    let model = Self.model()
    let window = Self.window(
      ConversationView(model: model, theme: .systemDark, appearance: ConversationAppearance()),
      width: 900, height: 700)
    defer { window.close() }
    try await Self.settle(window)
    let row = try #require(model.overview.frames["q"])
    let host = try #require(window.contentView)
    // A tool's first line starts 9 points into its frame; the margin is 48 points wide, the
    // moment's square first, the bookmark's after it.
    let lineHeight =
      ConversationAppearance.TextSize.standard.pointSize
      * ConversationTheme.systemDark.layout.lineHeight
    // From the messages to the window: where the scroll view shows them.
    let scroll = try #require(Self.scrollView(in: host))
    let visible = scroll.documentVisibleRect
    let origin = scroll.convert(NSPoint.zero, to: nil)
    let top = window.frame.height - origin.y - (scroll.isFlipped ? 0 : scroll.frame.height)
    let middleY =
      top + row.minY - visible.minY + 9 + BookmarkGutter.boxHeight(lineHeight: lineHeight) / 2
    let icon = NSPoint(
      x: row.minX - BookmarkGutter.reach - MomentGutterMark.width / 2,
      y: window.frame.height - middleY)
    // The whole margin of the row — the moment's square, the bookmark's box — is the messages',
    // never the pager's probe behind them, which used to take whatever nothing was drawn on.
    for x in stride(from: icon.x - MomentGutterMark.width / 2, to: row.minX, by: 2) {
      for dy in [-6.0, 0.0, 6.0] {
        let point = NSPoint(x: x, y: icon.y + dy)
        let hit = host.hitTest(point).map { String(describing: type(of: $0)) } ?? "nothing"
        #expect(!hit.contains("Probe"), "\(point) is taken by \(hit)")
      }
    }

    // The bookmark's box, left of its tag: empty, and still its button. Set first: unset, it is
    // only drawn while the pointer is on its message, which a click sent here does not say.
    model.loadBookmarks(["q"])
    try await Self.settle(window)
    try await Self.click(window, x: row.minX - BookmarkGutter.reach + 1, y: middleY)
    #expect(!model.isBookmarked(model.blocks[3]))
  }
}
