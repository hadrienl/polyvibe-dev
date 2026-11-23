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

@MainActor
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

  private static func layout(
    _ blocks: [ConversationBlock], measured: [String: Double] = [:],
    shapes: ConversationOverviewShapes = ConversationOverviewShapes()
  ) -> ConversationOverviewLayout {
    ConversationOverviewLayout(blocks: blocks, measured: measured, metrics: metrics, shapes: shapes)
  }

  @Test("A text's lines and paragraphs are counted in characters, blank lines left out")
  func lines() {
    let long = String(repeating: "é", count: 250)
    let shape = ConversationOverviewLayout.lines(of: "\(long)\n\n  \nshort\n\n", mark: .text)
    #expect(shape.lineLengths == [250, 5])
    #expect(shape.paragraphs == 2)
    // 100 characters a line: 3 lines, then 1.
    #expect(shape.lineCount(width: 100) == 4)
  }

  @Test("Blocks never built are estimated, and the height measured replaces the estimate")
  func estimates() {
    let blocks = [Self.text("a", "one line"), Self.tool("t"), Self.text("b", "x")]
    let estimated = Self.layout(blocks)
    let pitch = 14 * 1.25
    #expect(estimated.items.map(\.height) == [pitch, pitch + 20, pitch])
    #expect(estimated.items.map(\.top) == [0, pitch + 18, 2 * pitch + 20 + 36])
    #expect(estimated.height == 3 * pitch + 20 + 36)

    let measured = Self.layout(blocks, measured: ["t": 100])
    #expect(measured.items[1].height == 100)
    #expect(measured.items[2].top == pitch + 18 + 100 + 18)
  }

  @Test("A text is read once, until it changes: not for each layout, nor each width")
  func readOnce() {
    let shapes = ConversationOverviewShapes()
    var blocks = [Self.text("a", "first"), Self.text("b", "second")]
    _ = Self.layout(blocks, shapes: shapes)
    _ = Self.layout(blocks, measured: ["a": 40], shapes: shapes)
    _ = ConversationOverviewLayout(
      blocks: blocks, measured: [:],
      metrics: .init(
        columnWidth: 300, textSize: 14, lineHeight: 1.25, blockSpacing: 18, paragraphSpacing: 10),
      shapes: shapes)
    #expect(shapes.readCount == 2)
    blocks[1] = Self.text("b", "second, and more")
    _ = Self.layout(blocks, shapes: shapes)
    #expect(shapes.readCount == 3)
  }

  @Test("Blocks changed at the end are laid out again from there, the others kept")
  func replacing() {
    let shapes = ConversationOverviewShapes()
    let blocks = [Self.text("a", "one"), Self.text("b", "two"), Self.text("c", "three")]
    let first = Self.layout(blocks, shapes: shapes)
    let grown = [Self.text("a", "one"), Self.text("b", "two, longer")] + [Self.text("d", "four")]
    let replaced = first.replacing(from: 1, blocks: grown, measured: [:], shapes: shapes)
    #expect(replaced == Self.layout(grown))
    #expect(replaced.index(of: "c") == nil)
    #expect(replaced.index(of: "d") == 2)
    // "a" was not read again.
    #expect(shapes.readCount == 5)
  }

  @Test("A failed tool is drawn as a failure")
  func failure() {
    let layout = Self.layout([Self.tool("ok"), Self.tool("ko", failed: true)])
    #expect(layout.items.map(\.shape.mark) == [.tool, .failure])
  }

  @Test("A height in the conversation is a block and how far into it, and back")
  func positions() {
    let blocks = [Self.text("a", "x"), Self.text("b", "x"), Self.text("c", "x")]
    let layout = Self.layout(blocks, measured: ["a": 100, "b": 50, "c": 80])
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
    #expect(Self.layout(blocks, measured: ["a": 10_000]).scale(forHeight: 500) == 0.05)
    #expect(
      Self.layout(blocks, measured: ["a": 100]).scale(forHeight: 500)
        == ConversationOverviewLayout.maximumScale)
  }

  @Test("Wide, the overview is no wider than its maximum, and the text does not move (#596)")
  func wideMargin() {
    // A 1400-point pane, an 820-point column between 32-point margins: 258 points on each side
    // of them, then the right margin, less the gap — 278 points, more than the maximum.
    let placement = ConversationOverviewLayout.placement(
      paneWidth: 1400, contentWidth: 820, leadingMargin: 32, trailingMargin: 32)
    #expect(placement == .init(width: ConversationOverviewLayout.maximumWidth, reserved: 0))
    #expect(ConversationOverviewLayout.maximumWidth == 160)
    // Wider still, it stays at the maximum.
    let wider = ConversationOverviewLayout.placement(
      paneWidth: 2560, contentWidth: 820, leadingMargin: 32, trailingMargin: 32)
    #expect(wider == .init(width: 160, reserved: 0))
  }

  @Test("Between the minimum and the maximum, the overview takes the whole margin")
  func mediumMargin() {
    func placement(_ pane: Double) -> ConversationOverviewLayout.Placement {
      ConversationOverviewLayout.placement(
        paneWidth: pane, contentWidth: 820, leadingMargin: 32, trailingMargin: 32)
    }
    // 1100 points: 108 on each side of the column, the right margin, less the gap.
    #expect(placement(1100) == .init(width: 128, reserved: 0))
    // 1164 points: just the maximum; two points more do not widen it.
    #expect(placement(1164) == .init(width: 160, reserved: 0))
    #expect(placement(1166) == .init(width: 160, reserved: 0))
    // Half a point of margin is not drawn.
    #expect(placement(1101) == .init(width: 128, reserved: 0))
  }

  @Test("Narrower than the minimum, it keeps the minimum and the text makes room, little by little")
  func narrowMargin() {
    func placement(_ pane: Double) -> ConversationOverviewLayout.Placement {
      ConversationOverviewLayout.placement(
        paneWidth: pane, contentWidth: 820, leadingMargin: 32, trailingMargin: 32)
    }
    // 956 points: just enough margin, nothing given up.
    #expect(placement(956) == .init(width: 56, reserved: 0))
    // Two points less: two points given up, not the whole width.
    #expect(placement(954) == .init(width: 56, reserved: 2))
    #expect(placement(940) == .init(width: 56, reserved: 16))
    // Once the column fills the pane, its right margin and the gap make up the rest.
    #expect(placement(920) == .init(width: 56, reserved: 36))
    #expect(placement(700) == .init(width: 56, reserved: 36))
  }

  @Test("A bookmark's preview stands left of the overview, centred on the line it is shown for")
  func previewBesideTheLine() {
    let origin = ConversationOverviewLayout.previewOrigin(
      lineY: 300, previewWidth: 280, previewHeight: 60, overviewHeight: 700)
    // The gap between the preview and the overview, left of it; half its height above the line.
    #expect(origin.x == -288)
    #expect(origin.y == 270)
  }

  @Test("Near the top of the overview, the preview moves down to stay within it")
  func previewAtTheTop() {
    let origin = ConversationOverviewLayout.previewOrigin(
      lineY: 2, previewWidth: 280, previewHeight: 60, overviewHeight: 700)
    #expect(origin.y == ConversationOverviewLayout.previewMargin)
    #expect(origin.x == -288)
  }

  @Test("Near the bottom of the overview, the preview moves up to stay within it")
  func previewAtTheBottom() {
    let origin = ConversationOverviewLayout.previewOrigin(
      lineY: 698, previewWidth: 280, previewHeight: 60, overviewHeight: 700)
    #expect(origin.y + 60 == 700 - ConversationOverviewLayout.previewMargin)
  }

  @Test("Taller than the overview, the preview starts at its top")
  func previewTallerThanTheOverview() {
    let origin = ConversationOverviewLayout.previewOrigin(
      lineY: 40, previewWidth: 280, previewHeight: 120, overviewHeight: 100)
    #expect(origin.y == ConversationOverviewLayout.previewMargin)
  }

  // MARK: The margin's preview (#608)

  private func marginOrigin(
    iconX: Double = 40, iconY: Double, width: Double = 280, height: Double = 60,
    paneWidth: Double = 900, paneTop: Double = 0, paneHeight: Double = 700
  ) -> (x: Double, y: Double) {
    ConversationOverviewLayout.marginPreviewOrigin(
      iconMinX: iconX, iconMinY: iconY, iconMaxY: iconY + 20, previewWidth: width,
      previewHeight: height, paneWidth: paneWidth, paneTop: paneTop, paneBottom: paneHeight)
  }

  @Test("In the margin, the preview stands below the icon, from its left: the line stays read")
  func marginPreviewBelow() {
    let origin = marginOrigin(iconY: 300)
    #expect(origin.x == 40)
    #expect(origin.y == 320 + ConversationOverviewLayout.previewMargin)
  }

  @Test("Near the bottom of the pane, it stands above the icon")
  func marginPreviewAbove() {
    let origin = marginOrigin(iconY: 640)
    #expect(origin.y + 60 == 640 - ConversationOverviewLayout.previewMargin)
  }

  @Test("Never under the toolbar: above the icon only below it, else as high as it may go")
  func marginPreviewBelowTheToolbar() {
    // Room above the icon, but under the toolbar: below the icon, as low as the pane allows.
    let origin = marginOrigin(iconY: 100, height: 90, paneTop: 52, paneHeight: 200)
    #expect(origin.y == 200 - 4 - 90)
    let tall = marginOrigin(iconY: 100, height: 300, paneTop: 52, paneHeight: 200)
    #expect(tall.y == 52 + ConversationOverviewLayout.previewMargin)
  }

  @Test("At the pane's right edge it moves left, and never past its left edge")
  func marginPreviewWithinThePane() {
    #expect(marginOrigin(iconX: 700, iconY: 300).x == 900 - 280 - 4)
    #expect(marginOrigin(iconX: 40, iconY: 300, width: 400, paneWidth: 300).x == 4)
  }

  @Test("Taller than the room on either side, it stays in the pane")
  func marginPreviewTall() {
    let origin = marginOrigin(iconY: 40, height: 90, paneHeight: 120)
    #expect(origin.y == 120 - 4 - 90)
    let taller = marginOrigin(iconY: 40, height: 200, paneHeight: 120)
    #expect(taller.y == ConversationOverviewLayout.previewMargin)
  }

  @Test("With room on neither side, it takes the side with more, covering as little of the icon")
  func marginPreviewMoreRoomAbove() {
    // Icon at 150–170 in a pane 200 high: 22 points below, 142 above.
    let origin = marginOrigin(iconY: 150, height: 160, paneHeight: 200)
    #expect(origin.y == ConversationOverviewLayout.previewMargin)
  }

  @Test("The preview grows with the text, and never wider than the messages left of the overview")
  func previewWidth() {
    #expect(ConversationOverviewLayout.previewWidth(textSize: 13, room: 1000) == 260)
    #expect(ConversationOverviewLayout.previewWidth(textSize: 16, room: 1000) == 320)
    #expect(ConversationOverviewLayout.previewWidth(textSize: 16, room: 200) == 188)
  }

  @Test("In a narrow pane, the preview narrows rather than reach past the pane's left edge")
  func previewInANarrowPane() {
    let room = 100.0
    let width = ConversationOverviewLayout.previewWidth(textSize: 13, room: room)
    #expect(width == 88)
    let origin = ConversationOverviewLayout.previewOrigin(
      lineY: 300, previewWidth: width, previewHeight: 60, overviewHeight: 700)
    #expect(origin.x == -room + ConversationOverviewLayout.previewMargin)
  }

  @Test("Moments drawn close share the first one's icon; the next group starts past the gap (#572)")
  func clusters() {
    // At a tenth: 0, 5, 12.9 and 13 points down, then 40 and 41.
    let tops = [0.0, 50, 129, 130, 400, 410]
    #expect(
      ConversationOverviewLayout.clusters(tops, scale: 0.1) == [0..<3, 3..<4, 4..<6])
    #expect(ConversationOverviewLayout.clusters(tops, scale: 1) == [0..<1, 1..<2, 2..<4, 4..<6])
    #expect(ConversationOverviewLayout.clusters([], scale: 0.1).isEmpty)
    #expect(ConversationOverviewLayout.clusters([7], scale: 0.1) == [0..<1])
  }
}
