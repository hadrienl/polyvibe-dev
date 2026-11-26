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
    let unit: Int
    let toggle: () -> Void
    init(unit: Int = 0, toggle: @escaping () -> Void) {
      self.unit = unit
      self.toggle = toggle
    }
    final class Coordinator: NSObject {
      var toggle: () -> Void = {}
      @objc func press() { toggle() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
      NSButton(title: "Bookmark", target: context.coordinator, action: #selector(Coordinator.press))
    }
    func updateNSView(_ view: NSButton, context: Context) {
      context.coordinator.toggle = toggle
      view.identifier = NSUserInterfaceItemIdentifier("unit-\(unit)")
    }
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
  @Test func unsharedReasoningBookmarkDescribesTheReasoning() throws {
    let model = ConversationModel(sessionID: SessionID())
    model.apply(
      ConversationSnapshot(
        entries: [
          ConversationEntry(id: "reasoning", content: .reasoning(nil))
        ], availability: .available))
    model.loadBookmarks(["reasoning"])
    let block = try #require(model.blocks.first)
    let expected = String(localized: "Reasoning not shared by the agent", bundle: .module)
    #expect(ConversationModel.bookmarkExcerpt(of: block) == expected)
    #expect(ConversationModel.bookmarkLabel(of: block) == expected)
    let margin = try #require(
      MomentPreviewContent(
        margin: .bookmark, of: block, model: model,
        appearance: model.appearance))
    #expect(margin.items.first?.label == expected)
    let overview = MomentPreviewContent(placed: model.shownMoments, model: model)
    #expect(overview.items.first?.label == expected)
  }

  @Test func removingTheLastParagraphBookmarkKeepsTheHoveredTagAndGeometry() throws {
    let model = ConversationModel(sessionID: SessionID())
    model.apply(
      ConversationSnapshot(
        entries: [
          ConversationEntry(id: "a", content: .agentText("First\n\nSecond\n\nThird"))
        ], availability: .available))
    let block = try #require(model.blocks.first)
    model.toggleBookmark(block, unit: 2)
    var hover = BookmarkGutterHover()
    let layout = ParagraphBookmarkLayout()
    layout.positions = [.init(unit: 0, top: 0, height: 18), .init(unit: 2, top: 140, height: 18)]
    var keptLayout: ParagraphBookmarkLayout? = layout
    func gutter() -> some View {
      ZStack(alignment: .topLeading) {
        BookmarkGutterUnits(
          marked: model.bookmarkUnits(in: block), hoveredUnit: hover.unit,
          showsHoveredUnit: keptLayout != nil || hover.isHovered, keepsWholeBlockTag: false
        ) { unit in
          Tag(unit: unit) {
            model.toggleBookmark(block, unit: unit)
            if hover.canReleaseLayout(bodyHovered: false, isMarked: model.isBookmarked(block)) {
              keptLayout = nil
            }
          }.offset(y: keptLayout?.positions.first { $0.unit == unit }?.top ?? 0)
        }
      }.frame(width: 100, height: 220, alignment: .topLeading)
    }
    let hosting = NSHostingView(rootView: gutter())
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 220),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded()
    let original = try #require(buttons(in: hosting).first { $0.identifier?.rawValue == "unit-2" })
    let originalFrame = original.convert(original.bounds, to: hosting)
    // Enter directly from the margin, without the body ever selecting unit 2.
    hover.moved(true, on: 2)
    hosting.rootView = gutter()
    hosting.layoutSubtreeIfNeeded()
    original.performClick(nil)
    hosting.rootView = gutter()
    hosting.layoutSubtreeIfNeeded()
    let remaining = try #require(buttons(in: hosting).first { $0.identifier?.rawValue == "unit-2" })
    #expect(model.bookmarks.isEmpty)
    #expect(remaining === original)
    #expect(remaining.convert(remaining.bounds, to: hosting) == originalFrame)
    #expect(keptLayout === layout)
    remaining.performClick(nil)
    #expect(model.bookmarks == ["a#u2"])
    remaining.performClick(nil)
    hover.moved(false, on: 2)
    if hover.canReleaseLayout(bodyHovered: false, isMarked: model.isBookmarked(block)) {
      keptLayout = nil
    }
    hosting.rootView = gutter()
    hosting.layoutSubtreeIfNeeded()
    #expect(keptLayout == nil)
    #expect(buttons(in: hosting).isEmpty)
  }

  @Test func aLateExitFromThePreviousTagDoesNotClearTheCurrentHover() {
    var hover = BookmarkGutterHover()
    hover.moved(true, on: 1)
    hover.moved(true, on: 2)
    hover.moved(false, on: 1)
    #expect(hover.unit == 2)
    #expect(!hover.canReleaseLayout(bodyHovered: false, isMarked: false))
    hover.moved(false, on: 2)
    #expect(hover.canReleaseLayout(bodyHovered: false, isMarked: false))
    #expect(!hover.canReleaseLayout(bodyHovered: true, isMarked: false))
    #expect(!hover.canReleaseLayout(bodyHovered: false, isMarked: true))
  }

}
