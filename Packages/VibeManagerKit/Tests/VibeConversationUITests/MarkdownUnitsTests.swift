import AppKit
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

@MainActor
@Suite("Semantic bookmark units (#594)")
struct MarkdownUnitsTests {
  @Test func semanticUnits() {
    let markdown = """
      # Heading

      A paragraph with a hard  
      break and 😀.

      - First
        - Nested
      - Last

      > Quoted

      ```swift
      first()

      last()
      ```

      | A | B |
      | - | - |
      | x | y |

      ---
      """
    let units = MarkdownUnits.units(of: MarkdownDocument.blocks(from: markdown))
    #expect(units.count == 10)
    #expect(units.map(\.index) == Array(0..<10))
    #expect(units[1].text.contains("break and 😀."))
    #expect(units[3].text.contains("Nested"))
    #expect(units[6].text == "first()")
    #expect(units[7].text == "")
    #expect(units[8].text == "last()")
    #expect(units[9].text.contains("x"))
    let grown = MarkdownUnits.units(of: MarkdownDocument.blocks(from: markdown + "\nMore."))
    #expect(Array(grown.prefix(units.count)) == units)
  }

  private func model() -> ConversationModel {
    let model = ConversationModel(sessionID: SessionID())
    model.apply(
      ConversationSnapshot(
        entries: [
          ConversationEntry(id: "a", content: .agentText("One\n\nTwo\n\nThree")),
          ConversationEntry(id: "b", content: .agentText("Next")),
        ], availability: .available))
    model.overview.rowLaidOut("a", frame: CGRect(x: 0, y: 0, width: 500, height: 300))
    model.overview.rowLaidOut("b", frame: CGRect(x: 0, y: 320, width: 500, height: 100))
    model.recordBookmarkPositions(
      [
        .init(unit: 0, top: 0, height: 20), .init(unit: 1, top: 100, height: 20),
        .init(unit: 2, top: 200, height: 20),
      ], for: "a")
    model.overview.scrolled(readableTop: 10, readableHeight: 400)
    return model
  }

  @Test func keyboardAndNavigation() {
    let model = model()
    #expect(model.toggleBookmarkInView())
    #expect(model.bookmarks == ["a#u1"])
    model.selectedBookmarkPlace = { SelectionPlace(block: "a", segment: 0, offset: 10) }
    #expect(model.toggleBookmarkInView())
    #expect(model.bookmarks == ["a#u1", "a#u2"])
    model.toggleBookmark(model.blocks[1])
    #expect(model.revealNextMoment())
    #expect(model.litPassage?.range == NSRange(location: 4, length: 3))
    #expect(model.revealNextMoment())
    #expect(model.litPassage?.range == NSRange(location: 8, length: 5))
    #expect(model.revealNextMoment())
    #expect(model.revealedBlockID == "b")
    #expect(model.revealPreviousMoment())
    #expect(model.revealedBlockID == "a")
    #expect(model.litPassage?.range == NSRange(location: 8, length: 5))
    #expect(model.revealPreviousMoment())
    #expect(model.litPassage?.range == NSRange(location: 4, length: 3))
  }

  @Test func measuredPositionsReplaceEstimates() {
    let model = model()
    model.loadBookmarks(["a#u1", "a#u2"])
    #expect(model.shownMoments.map(\.unitOffset) == [100, 200])
    model.recordBookmarkPositions(
      [
        .init(unit: 1, top: 130, height: 20),
        .init(unit: 2, top: 260, height: 20),
      ], for: "a")
    #expect(model.shownMoments.map(\.unitOffset) == [130, 260])
  }
  @Test func overviewLinesNameTheirUnit() throws {
    let model = ConversationModel(sessionID: SessionID())
    model.apply(
      ConversationSnapshot(
        entries: [
          ConversationEntry(id: "a", content: .agentText("First\n\nSecond\n\nThird"))
        ], availability: .available))
    model.loadBookmarks(["a#u1", "a#u2"])
    #expect(model.shownMoments[0].unitFraction > 0)
    let metrics = ConversationOverviewLayout.Metrics(
      columnWidth: 600, textSize: 14,
      lineHeight: 1.25, blockSpacing: 18, paragraphSpacing: 10)
    let layout = ConversationOverviewLayout(
      blocks: model.blocks, measured: ["a": 400], metrics: metrics,
      shapes: ConversationOverviewShapes())
    let estimated = ConversationOverview.momentTop(model.shownMoments[0], layout: layout)
    model.recordBookmarkPositions(
      [
        .init(unit: 1, top: 100, height: 20),
        .init(unit: 2, top: 200, height: 20),
      ], for: "a")
    #expect(ConversationOverview.momentTop(model.shownMoments[0], layout: layout) == 100)
    #expect(estimated != 100)
    // Same cluster, separate lines: clicking the lower line finds the second anchor.
    let scale = 0.1
    let y = ConversationOverview.iconY(top: 200, scale: scale)
    let found = try #require(
      ConversationOverview.cluster(
        near: CGPoint(x: 40, y: y),
        moments: model.shownMoments, layout: layout, scale: scale))
    #expect(found.moments == 0..<2)
    #expect(model.shownMoments[found.touched].moment.unit == 2)
    model.revealMoment("a", unit: model.shownMoments[found.touched].moment.unit, bookmark: true)
    #expect(model.litPassage?.range == NSRange(location: 13, length: 5))
  }

  @Test func plainPromptsAndPlans() {
    let prompt = ConversationBlock.entry(
      ConversationEntry(
        id: "p",
        content: .userPrompt("First line\nstill first\n\nSecond paragraph", attachments: [])))
    let units = MarkdownUnits.units(in: prompt.bookmarkContents)
    #expect(units.count == 2)
    #expect(units[0].text == "First line\nstill first")
    #expect(units[1].text == "Second paragraph")
    let plan = ConversationBlock.entry(
      ConversationEntry(
        id: "plan",
        content: .tool(
          ToolCall(
            callID: "plan", kind: .plan, state: .succeeded,
            parameters: [.init(.plan, "# Plan\n\n- One\n- Two")]))))
    #expect(MarkdownUnits.units(in: plan.bookmarkContents).count == 3)
  }

  @Test func manualScrollForgetsAUnitThatLeftTheViewport() {
    let model = model()
    model.loadBookmarks(["a", "a#u1", "a#u2"])
    #expect(model.revealNextMoment())
    #expect(model.litPassage?.range == NSRange(location: 4, length: 3))
    // The message remains visible, but the last revealed paragraph is now above the viewport.
    model.overview.scrolled(readableTop: 220, readableHeight: 200)
    #expect(model.revealPreviousMoment())
    #expect(model.litPassage?.range == NSRange(location: 8, length: 5))
  }

}
