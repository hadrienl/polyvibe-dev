import Foundation
import Testing

@testable import VibeApplication

@Suite("Bookmarks in a conversation (#567)")
struct ConversationBookmarksTests {
  private static func prompt(_ id: String) -> ConversationEntry {
    ConversationEntry(id: id, content: .userPrompt("prompt \(id)", attachments: []))
  }

  private static func read(_ id: String) -> ConversationEntry {
    ConversationEntry(
      id: id, content: .tool(ToolCall(callID: id, kind: .read, state: .succeeded)))
  }

  private static let entries = [prompt("p1"), read("r1"), read("r2"), prompt("p2")]

  @Test("A bookmark on a group of tools names its first call, and finds it ungrouped too")
  func groups() throws {
    let grouped = ConversationGrouping.blocks(Self.entries, grouping: true)
    let group = try #require(grouped.first { $0.id == "group:r1" })
    let bookmarks = ConversationBookmarks.toggled([], on: group)
    #expect(bookmarks == ["r1"])
    #expect(ConversationBookmarks.markedIndices(in: grouped, bookmarks: bookmarks) == [1])

    let ungrouped = ConversationGrouping.blocks(Self.entries, grouping: false)
    #expect(ConversationBookmarks.markedIndices(in: ungrouped, bookmarks: bookmarks) == [1])
  }

  @Test("A group holding any bookmarked call is marked, and toggled it loses them all")
  func groupUnmarked() throws {
    let grouped = ConversationGrouping.blocks(Self.entries, grouping: true)
    let group = try #require(grouped.first { $0.id == "group:r1" })
    // Set on the second call while the tools were shown one by one.
    #expect(ConversationBookmarks.isMarked(group, in: ["r2"]))
    #expect(ConversationBookmarks.toggled(["r2", "p1"], on: group) == ["p1"])
  }

  @Test("An entry no longer shown marks nothing, and is kept")
  func gone() {
    let blocks = ConversationGrouping.blocks(Self.entries)
    let bookmarks: Set<String> = ["gone", "p2"]
    #expect(ConversationBookmarks.markedIndices(in: blocks, bookmarks: bookmarks) == [2])
    let toggled = ConversationBookmarks.toggled(bookmarks, on: blocks[0])
    #expect(toggled == ["gone", "p2", "p1"])
  }

  @Test("The next bookmark is below the block at the top of the view, none past the last")
  func next() {
    let marked = [2, 5, 9]
    #expect(ConversationBookmarks.next(after: 0, in: marked) == 2)
    #expect(ConversationBookmarks.next(after: 2, in: marked) == 5)
    #expect(ConversationBookmarks.next(after: 6, in: marked) == 9)
    #expect(ConversationBookmarks.next(after: 9, in: marked) == nil)
  }

  @Test("The previous one is the block at the top once the view is past its start")
  func previous() {
    let marked = [2, 5, 9]
    #expect(ConversationBookmarks.previous(before: 5, offset: 0, in: marked) == 2)
    #expect(ConversationBookmarks.previous(before: 5, offset: 3, in: marked) == 2)
    #expect(ConversationBookmarks.previous(before: 5, offset: 40, in: marked) == 5)
    #expect(ConversationBookmarks.previous(before: 7, offset: 40, in: marked) == 5)
    #expect(ConversationBookmarks.previous(before: 2, offset: 0, in: marked) == nil)
  }
}

@Suite("The overview of a conversation (#567)")
struct ConversationOverviewLayoutTests {
  private static let metrics = ConversationOverviewLayout.Metrics(
    columnWidth: 700, textSize: 14, lineHeight: 1.25, blockSpacing: 18, paragraphSpacing: 10)

  private static func text(_ id: String, _ text: String) -> ConversationBlock {
    .entry(ConversationEntry(id: id, content: .agentText(text)))
  }

  private static func tool(_ id: String, failed: Bool = false) -> ConversationBlock {
    .entry(
      ConversationEntry(
        id: id,
        content: .tool(
          ToolCall(callID: id, kind: .shell, state: failed ? .failed(exitCode: 1) : .succeeded))))
  }

  @Test("Text is wrapped at the column's width, paragraph by paragraph")
  func wrap() {
    // 100 characters a line at 700 points of 14-point text.
    let long = String(repeating: "a", count: 250)
    let wrapped = ConversationOverviewLayout.wrap("\(long)\n\nshort\n\n", width: 100)
    #expect(wrapped.count == 4)
    #expect(wrapped.paragraphs == 2)
    #expect(wrapped.lines == [1, 1, 0.5, 0.05])
  }

  @Test("Blocks never built are estimated, and the height measured replaces the estimate")
  func estimates() throws {
    let blocks = [Self.text("a", "one line"), Self.tool("t"), Self.text("b", "x")]
    let estimated = ConversationOverviewLayout(blocks: blocks, measured: [:], metrics: Self.metrics)
    let pitch = 14 * 1.25
    #expect(estimated.items.map(\.height) == [pitch, pitch + 20, pitch])
    #expect(estimated.items.map(\.top) == [0, pitch + 18, 2 * pitch + 20 + 36])
    #expect(estimated.height == 3 * pitch + 20 + 36)

    let measured = ConversationOverviewLayout(
      blocks: blocks, measured: ["t": 100], metrics: Self.metrics, reusing: estimated)
    #expect(measured.items[1].height == 100)
    #expect(measured.items[2].top == pitch + 18 + 100 + 18)
    #expect(measured.items[1].shape == estimated.items[1].shape)
  }

  @Test("A failed tool is drawn as a failure")
  func failure() {
    let layout = ConversationOverviewLayout(
      blocks: [Self.tool("ok"), Self.tool("ko", failed: true)], measured: [:],
      metrics: Self.metrics)
    #expect(layout.items.map(\.shape.mark) == [.tool, .failure])
  }

  @Test("A height in the conversation is a block and how far into it, and back")
  func positions() throws {
    let blocks = [Self.text("a", "x"), Self.text("b", "x"), Self.text("c", "x")]
    let layout = ConversationOverviewLayout(
      blocks: blocks, measured: ["a": 100, "b": 50, "c": 80], metrics: Self.metrics)
    // a: 0–100, b: 118–168, c: 186–266.
    #expect(layout.position(atY: -5) == .init(index: 0, offset: 0))
    #expect(layout.position(atY: 40) == .init(index: 0, offset: 40))
    #expect(layout.position(atY: 110) == .init(index: 0, offset: 100))
    #expect(layout.position(atY: 130) == .init(index: 1, offset: 12))
    #expect(layout.position(atY: 1000) == .init(index: 2, offset: 80))
    #expect(layout.y(of: .init(index: 1, offset: 12)) == 130)
    #expect(layout.index(of: "c") == 2)
    #expect(ConversationOverviewLayout().position(atY: 0) == nil)
  }

  @Test("The whole conversation fits the overview, never drawn larger than a fifth")
  func scale() {
    let blocks = [Self.text("a", "x")]
    let layout = ConversationOverviewLayout(
      blocks: blocks, measured: ["a": 10_000], metrics: Self.metrics)
    #expect(layout.scale(forHeight: 500) == 0.05)
    let short = ConversationOverviewLayout(blocks: blocks, measured: ["a": 100], metrics: Self.metrics)
    #expect(short.scale(forHeight: 500) == ConversationOverviewLayout.maximumScale)
  }

  @Test("The overview takes the margin right of the text, which does not move")
  func wideMargin() {
    // A 1400-point pane, an 820-point column between 32-point margins: 258 points on each side
    // of them, then the right margin, less the gap.
    let placement = ConversationOverviewLayout.placement(
      paneWidth: 1400, contentWidth: 820, leadingMargin: 32, trailingMargin: 32)
    #expect(placement == .init(width: 278, reserved: 0))
  }

  @Test("Narrower than the minimum, it keeps the minimum and the text makes room")
  func narrowMargin() {
    let placement = ConversationOverviewLayout.placement(
      paneWidth: 900, contentWidth: 820, leadingMargin: 32, trailingMargin: 32)
    #expect(placement.width == ConversationOverviewLayout.minimumWidth)
    #expect(placement.reserved == ConversationOverviewLayout.minimumWidth)
  }
}
