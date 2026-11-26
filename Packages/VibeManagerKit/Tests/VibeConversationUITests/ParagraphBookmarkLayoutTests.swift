import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

@MainActor
@Suite("Paragraph bookmark geometry (#594)", .serialized, .timeLimit(.minutes(1)))
struct ParagraphBookmarkLayoutTests {
  private let markdown = """
    # A decision worth keeping

    A long paragraph whose words wrap at different widths. The bookmark stays on this paragraph when the conversation becomes narrower, while the following list moves down.

    - Keep the paragraph identity.
    - Keep text selection continuous.

    ```swift
    let anchor = BookmarkAnchor(entryID: id, unit: 3)
    save(anchor.stored)
    ```

    | Scope | Bookmark |
    | --- | --- |
    | Table | Whole table |
    """

  private func settle(_ window: NSWindow, until condition: () -> Bool) async throws {
    while !Task.isCancelled {
      window.layoutIfNeeded()
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CancellationError()
  }

  @Test func followsParagraphAcrossWidths() async throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let layout = ParagraphBookmarkLayout()
    let selection = ConversationSelection()
    window.contentView = NSHostingView(
      rootView:
        MarkdownView(text: markdown)
        .environment(\.paragraphBookmarkLayout, layout)
        .environment(\.conversationSelection, selection)
        .environment(\.selectionBlock, "answer")
        .background { BookmarkRowOrigin(layout: layout) }
        .frame(maxHeight: .infinity, alignment: .top))
    try await settle(window) { layout.positions.count == 7 }
    let before = layout.positions
    #expect(layout.unit(at: before[2].top + 1) == 2)
    let model = ConversationModel(sessionID: SessionID())
    model.apply(
      ConversationSnapshot(
        entries: [ConversationEntry(id: "answer", content: .agentText(markdown))],
        availability: .available))
    model.toggleBookmark(model.blocks[0], unit: layout.unit(at: before[2].top + 1))
    #expect(model.bookmarks == ["answer#u2"])
    window.setContentSize(NSSize(width: 300, height: 900))
    try await settle(window) {
      layout.positions.count == 7 && layout.positions[2].top > before[2].top
    }
    #expect(layout.unit(at: layout.positions[2].top + 1) == 2)
    #expect(model.bookmarkUnits(in: model.blocks[0]) == [2])
    // An exact range is used even when the quote does not occur in the message.
    let view = try #require(selection.shown.first?.view)
    let range = try #require(model.units(in: model.blocks[0]).first { $0.index == 2 }?.range)
    let light = LitPassage(
      blockID: "answer", quote: ReplyQuote(excerpt: "ignored", author: .agent, date: nil),
      request: 1, segment: 0, range: range)
    #expect(view.applyLight(light) == true)
    #expect(view.litRange == range)
  }

  @Test func ordinaryRowsDoNotMeasureUnits() async throws {
    let model = ConversationModel(sessionID: SessionID())
    model.apply(
      ConversationSnapshot(
        entries: (0..<20).map {
          ConversationEntry(
            id: "a\($0)", content: .agentText("First paragraph.\n\nSecond paragraph."))
        }, availability: .available))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 1600),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = NSHostingView(
      rootView:
        VStack {
          ForEach(model.blocks) { BlockRow(block: $0, model: model, spacing: 8) }
        })
    func origins(_ view: NSView?) -> Int {
      guard let view else { return 0 }
      return (view is BookmarkRowOrigin.Origin ? 1 : 0)
        + view.subviews.reduce(0) { $0 + origins($1) }
    }
    window.layoutIfNeeded()
    #expect(origins(window.contentView) == 0)
    model.toggleBookmark(model.blocks[10], unit: 1)
    try await settle(window) { origins(window.contentView) == 1 }
    #expect(origins(window.contentView) == 1)
  }

  @Test func foldedReasoningUsesItsHeaderThenRestoresParagraphPositions() async throws {
    let model = ConversationModel(sessionID: SessionID())
    let text = String(repeating: "A long first paragraph. ", count: 60) + "\n\nLast paragraph."
    model.apply(
      ConversationSnapshot(
        entries: [
          ConversationEntry(id: "r", content: .reasoning(text)),
          ConversationEntry(id: "next", content: .agentText("Following message")),
        ], availability: .available))
    model.setExpanded(true, for: "r")
    model.loadBookmarks(["r#u1"])
    let block = try #require(model.blocks.first)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 900),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: BlockRow(block: block, model: model, spacing: 8)
        .frame(width: 500, height: 900, alignment: .topLeading)
        .coordinateSpace(name: ConversationView.contentSpace))
    defer { window.close() }
    try await settle(window) { (model.shownMoments.first?.unitOffset ?? 0) > 100 }
    let expandedOffset = try #require(model.shownMoments.first?.unitOffset)
    model.setExpanded(false, for: "r")
    try await settle(window) { (model.overview.measured["r"] ?? .infinity) < 100 }
    // A measurement already queued by the old text view must not put the trait back below
    // its now-folded row. New bookmarks placed while folded use the same header fallback.
    model.recordBookmarkPositions([.init(unit: 1, top: expandedOffset, height: 18)], for: "r")
    model.toggleBookmark(block, unit: 0)
    let foldedHeight = try #require(model.overview.measured["r"])
    #expect(model.shownMoments.allSatisfy { $0.unitOffset >= 0 && $0.unitOffset <= foldedHeight })
    #expect(model.shownMoments.allSatisfy { $0.unitFraction == 0 })
    let headerOffset = try #require(model.shownMoments.first?.unitOffset)
    model.overview.scrolled(
      readableTop: (model.overview.top(of: "r") ?? 0) + headerOffset, readableHeight: 900)
    #expect(model.revealNextMoment())
    #expect(model.isExpanded(id: "r", default: false))
    #expect(model.litPassage?.range == model.units(in: block).last?.range)
    try await settle(window) {
      model.shownMoments.first { $0.moment.unit == 1 }?.unitOffset == expandedOffset
    }
  }

  @Test func screenshots() async throws {
    guard let destination = ProcessInfo.processInfo.environment["BOOKMARK_SNAPSHOT_DIR"] else {
      return
    }
    try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
    for (name, theme) in [("light", ConversationTheme.systemLight), ("dark", .systemDark)] {
      let model = ConversationModel(sessionID: SessionID())
      model.apply(
        ConversationSnapshot(
          entries: [ConversationEntry(id: "answer", content: .agentText(markdown))],
          availability: .available))
      model.loadBookmarks(["answer#u1", "answer#u3", "answer#u5"])
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 660), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.contentView = NSHostingView(
        rootView:
          ConversationView(model: model, theme: theme, appearance: ConversationAppearance())
          .environment(\.colorScheme, name == "light" ? .light : .dark))
      try await settle(window) {
        model.shownMoments.count == 3 && model.shownMoments[2].unitOffset > 0
      }
      let content = try #require(window.contentView)
      let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(
        to: URL(fileURLWithPath: destination).appendingPathComponent("bookmarks-\(name).png"))
    }
  }
}
