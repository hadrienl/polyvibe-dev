import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

@MainActor
@Suite("Bookmarks remain reachable beside non-text rows (#594)", .serialized)
struct NonTextBookmarkGutterTests {
  /// A native button stands in for each tag so its lifetime and action can be inspected in an
  /// offscreen host, without relying on SwiftUI's accessibility tree for invisible windows.
  private struct Tag: NSViewRepresentable {
    let toggle: () -> Void
    final class Coordinator: NSObject {
      var toggle: () -> Void = {}
      @objc func press() { toggle() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
      NSButton(title: "Bookmark", target: context.coordinator, action: #selector(Coordinator.press))
    }
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.toggle = toggle }
  }

  private func buttons(in view: NSView) -> [NSButton] {
    if let button = view as? NSButton { return [button] }
    return view.subviews.flatMap(buttons(in:))
  }

  @Test(arguments: [false, true])
  func crossingIntoTheMarginKeepsTheSameWholeBlockTag(reasoning: Bool) throws {
    let model = ConversationModel(sessionID: SessionID())
    let entries: [ConversationEntry] =
      reasoning
      ? [ConversationEntry(id: "reasoning", content: .reasoning(nil))]
      : ["call", "other"].map {
        ConversationEntry(
          id: $0, content: .tool(ToolCall(callID: $0, kind: .shell, state: .succeeded)))
      }
    model.apply(ConversationSnapshot(entries: entries, availability: .available))
    let block = try #require(model.blocks.first)
    #expect(block.bookmarkMarkdown == nil)
    func gutter(bodyHovered: Bool) -> some View {
      ZStack {
        BookmarkGutterUnits(
          marked: [], hoveredUnit: 0, showsHoveredUnit: bodyHovered,
          keepsWholeBlockTag: block.bookmarkMarkdown == nil
        ) { unit in
          Tag { model.toggleBookmark(block, unit: unit) }
        }
      }.frame(width: 100, height: 60)
    }
    let hosting = NSHostingView(rootView: gutter(bodyHovered: true))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded()
    let original = try #require(buttons(in: hosting).first)
    // The pointer left the body, but has not entered the tag yet: all transient hover state is
    // false and there is no paragraph tracker. The existing clickable tag must remain mounted.
    hosting.rootView = gutter(bodyHovered: false)
    hosting.layoutSubtreeIfNeeded()
    let reachable = try #require(buttons(in: hosting).first)
    #expect(buttons(in: hosting).count == 1)
    #expect(reachable === original)
    reachable.performClick(nil)
    #expect(model.bookmarks == [reasoning ? "reasoning" : "call"])
    reachable.performClick(nil)
    #expect(model.bookmarks.isEmpty)
  }

  @Test func textRowsKeepOnlyMarkedTagsOutsideHover() {
    func gutter(hovered: Bool) -> some View {
      ZStack {
        BookmarkGutterUnits(
          marked: [1, 2], hoveredUnit: 3, showsHoveredUnit: hovered,
          keepsWholeBlockTag: false
        ) { _ in Tag {} }
      }.frame(width: 100, height: 60)
    }
    let hosting = NSHostingView(rootView: gutter(hovered: true))
    hosting.layoutSubtreeIfNeeded()
    #expect(buttons(in: hosting).count == 3)
    hosting.rootView = gutter(hovered: false)
    hosting.layoutSubtreeIfNeeded()
    #expect(buttons(in: hosting).count == 2)
  }
}
