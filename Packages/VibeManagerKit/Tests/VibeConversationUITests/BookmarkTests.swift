import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

/// Bookmarks in the conversation, and the overview's way about it (#567).
@MainActor
@Suite("Bookmarks in the conversation")
struct BookmarkTests {
  private static func model(_ count: Int = 6) -> ConversationModel {
    let model = ConversationModel(sessionID: SessionID())
    let entries = (0..<count).map { index in
      ConversationEntry(
        id: "m\(index)",
        content: index.isMultiple(of: 2)
          ? .userPrompt("prompt \(index)", attachments: []) : .agentText("answer \(index)"))
    }
    model.apply(ConversationSnapshot(entries: entries, availability: .available))
    return model
  }

  /// Rows built where they would be: 100 points each, 20 apart; the top of what is read at `top`.
  private static func laidOut(_ model: ConversationModel, top: Double) {
    for (index, block) in model.blocks.enumerated() {
      model.overview.rowLaidOut(
        block.id, frame: CGRect(x: 0, y: Double(index) * 120, width: 600, height: 100))
    }
    model.overview.scrolled(readableTop: top, readableHeight: 300)
  }

  @Test("A bookmark set is shown, kept, and taken away by a second click")
  func toggle() {
    let model = Self.model()
    var saved: [Set<String>] = []
    model.saveBookmarks = { saved.append($0) }
    model.toggleBookmark(model.blocks[1])
    #expect(model.isBookmarked(model.blocks[1]))
    #expect(model.bookmarkedIndices == [1])
    #expect(model.bookmarkedBlocks.map(\.id) == ["m1"])
    model.toggleBookmark(model.blocks[1])
    #expect(!model.isBookmarked(model.blocks[1]))
    #expect(saved == [["m1"], []])
  }

  @Test("Bookmarks read from the store join those set before they arrived, saved with them")
  func load() {
    let model = Self.model()
    var saved: [Set<String>] = []
    model.saveBookmarks = { saved.append($0) }
    model.toggleBookmark(model.blocks[0])
    model.loadBookmarks(["m3", "gone"])
    #expect(model.bookmarks == ["m0", "m3", "gone"])
    #expect(model.bookmarkedIndices == [0, 3])
    // Saved again with what was read: the write of the first alone would have lost them.
    #expect(saved == [["m0"], ["m0", "m3", "gone"]])
  }

  @Test("Read with none set before, they are not written back")
  func loadAlone() {
    let model = Self.model()
    var saves = 0
    model.saveBookmarks = { _ in saves += 1 }
    model.loadBookmarks(["m3"])
    #expect(saves == 0)
  }

  @Test("Near the end, where the view cannot bring a bookmark to the top, Next goes on from it")
  func nextNearTheEnd() {
    let model = Self.model()
    model.loadBookmarks(["m4", "m5"])
    // The view at the bottom: m3 at the top, m4 and m5 below it, in what is read.
    Self.laidOut(model, top: 370)
    #expect(model.revealNextBookmark())
    #expect(model.revealedBlockID == "m4")
    // The view could not move: the top is still m3.
    #expect(model.revealNextBookmark())
    #expect(model.revealedBlockID == "m5")
    #expect(!model.revealNextBookmark())
    #expect(model.revealPreviousBookmark())
    #expect(model.revealedBlockID == "m4")
  }

  @Test("Messages arriving later find their bookmarks")
  func arriving() {
    let model = Self.model(2)
    model.loadBookmarks(["m4"])
    #expect(model.bookmarkedIndices.isEmpty)
    let entries = (0..<6).map {
      ConversationEntry(id: "m\($0)", content: .agentText("answer \($0)"))
    }
    model.apply(ConversationSnapshot(entries: entries, availability: .available))
    #expect(model.bookmarkedIndices == [4])
  }

  @Test("The top of what is read is the row it falls in, and how far into it")
  func top() {
    let model = Self.model()
    Self.laidOut(model, top: 250)
    #expect(model.overview.top == .init(blockID: "m2", offset: 10))
    model.overview.scrolled(readableTop: 110, readableHeight: 300)
    // Between two rows: the one above, at its end.
    #expect(model.overview.top == .init(blockID: "m0", offset: 110))
    model.overview.rowGone("m0")
    model.overview.scrolled(readableTop: 0, readableHeight: 300)
    #expect(model.overview.top == .init(blockID: "m1", offset: 0))
  }

  @Test("Next and Previous Bookmark walk from the top of what is read, lighting what they reach")
  func walk() {
    let model = Self.model()
    model.loadBookmarks(["m1", "m4"])
    Self.laidOut(model, top: 0)
    #expect(model.revealNextBookmark())
    #expect(model.revealedBlockID == "m1")
    #expect(model.highlightedBlockID == "m1")
    // The view now at m1's start.
    model.overview.scrolled(readableTop: 120, readableHeight: 300)
    #expect(model.revealNextBookmark())
    #expect(model.revealedBlockID == "m4")
    model.overview.scrolled(readableTop: 480, readableHeight: 300)
    #expect(!model.revealNextBookmark())
    #expect(model.revealPreviousBookmark())
    #expect(model.revealedBlockID == "m1")
    // Inside m4, past its start: Previous goes back to its start first.
    model.overview.scrolled(readableTop: 530, readableHeight: 300)
    #expect(model.revealPreviousBookmark())
    #expect(model.revealedBlockID == "m4")
    #expect(!model.scroll.isFollowing)
  }

  @Test("Toggle Bookmark marks the selection's message, else the one at the top")
  func toggleInView() {
    let model = Self.model()
    Self.laidOut(model, top: 370)
    #expect(model.toggleBookmarkInView())
    #expect(model.bookmarks == ["m3"])
    model.selectedBlockID = { "m5" }
    #expect(model.toggleBookmarkInView())
    #expect(model.bookmarks == ["m3", "m5"])
  }

  @Test("Nothing built, there is nothing to mark nor walk from")
  func nothingLaidOut() {
    let model = Self.model()
    #expect(!model.toggleBookmarkInView())
    #expect(!model.revealPreviousBookmark())
  }

  @Test("A click in the overview asks for a place, again when it is the same")
  func overviewScroll() {
    let model = Self.model()
    model.scrollOverview(to: "m2", offset: 12)
    let first = model.overviewScroll
    model.scrollOverview(to: "m2", offset: 12)
    #expect(model.overviewScroll?.blockID == "m2")
    #expect(model.overviewScroll?.offset == 12)
    #expect(model.overviewScroll != first)
  }

  @Test("A bookmark's label is the start of its message on one line")
  func label() {
    let long = String(repeating: "word ", count: 40)
    let block = ConversationBlock.entry(
      ConversationEntry(id: "a", content: .agentText("First line\nsecond \(long)")))
    let label = ConversationModel.bookmarkLabel(of: block)
    #expect(label.hasPrefix("First line second word"))
    #expect(label.count == 120)
    #expect(label.hasSuffix("…"))
  }

  private static func prompt(_ text: String) -> ConversationBlock {
    .entry(ConversationEntry(id: "p", content: .userPrompt(text, attachments: [])))
  }

  @Test("Vibe Manager's news is named by who sent it and the sessions it is about, not their identifiers")
  func applicationNews() {
    let block = Self.prompt(
      """
      [Vibe Manager] 2 events:
      - “Revue générale” (B72A6790-1C2D-4E5F-8A9B-0C1D2E3F4A5B) finished its turn.
      - “#12 export” (0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D) stopped: its agent is no longer running.
      """)
    #expect(ConversationModel.bookmarkExcerpt(of: block) == "Revue générale, #12 export")
    #expect(ConversationModel.bookmarkLabel(of: block) == "Vibe Manager · Revue générale, #12 export")
  }

  @Test("A coordinator's message is named by its coordinator, then its words without their marks")
  func coordinatorMessage() {
    let block = Self.prompt("[Coordinator “Release”] Fix the **tooltip**, then open a PR.")
    #expect(ConversationModel.bookmarkExcerpt(of: block) == "Fix the tooltip, then open a PR.")
    let label = ConversationModel.bookmarkLabel(of: block)
    #expect(label.hasSuffix(" · Fix the tooltip, then open a PR."))
    #expect(label.contains("Release"))
    #expect(!label.contains("[Coordinator"))
  }

  @Test("A reply's bookmark is named by the user's words, not the passage it quotes")
  func replyLabel() {
    // From the review session's patch, kept as it was written.
    let quote = ReplyQuote(excerpt: "the passage", author: .agent, date: nil)
    let reply = Self.prompt(ReplyQuote.compose(quote, message: "Fix it"))
    #expect(ConversationModel.bookmarkLabel(of: reply) == "Fix it")
    #expect(ConversationModel.bookmarkExcerpt(of: reply) == "Fix it")
  }

  @Test("Several messages of one coordinator are told apart by their words")
  func coordinatorMessagesApart() {
    func label(_ text: String) -> String {
      ConversationModel.bookmarkLabel(
        of: Self.prompt(CoordinationPolicy.fromCoordinator(text, coordinatorName: "V2")))
    }
    #expect(label("Rebase on main.").contains("V2"))
    #expect(label("Rebase on main.").hasSuffix(" · Rebase on main."))
    #expect(label("Rebase on main.") != label("Open the PR."))
  }

  @Test("A message sent as coordination is turned on is named by the user's words, not the note")
  func prefacedLabel() {
    let block = Self.prompt(CoordinatorInstructions.turnedOn + "\n\nShip it")
    #expect(ConversationModel.bookmarkLabel(of: block) == "Ship it")
    #expect(ConversationModel.bookmarkExcerpt(of: block) == "Ship it")
  }

  @Test("Vibe Manager's news that names no session is named by its words")
  func applicationNewsWithoutSessions() {
    let block = Self.prompt(CoordinationInbox.message(for: [.wake("is #12 merged?", at: .now)]))
    let excerpt = ConversationModel.bookmarkExcerpt(of: block)
    #expect(excerpt.contains("is #12 merged?"))
    #expect(!excerpt.contains("\\"))
    #expect(ConversationModel.bookmarkLabel(of: block) == "Vibe Manager · " + excerpt)
  }

  @Test("A coordinator's lists, headings and quotes lose their marks")
  func coordinatorBlocks() {
    let block = Self.prompt(
      "[Coordinator “Release”] ## Plan\n\n- Rebase on main\n- Open the PR\n\n> Not before CI.")
    #expect(
      ConversationModel.bookmarkExcerpt(of: block)
        == "Plan Rebase on main Open the PR Not before CI.")
  }

  @Test("Near a bookmark's line, the preview stands at the line, wherever the pointer is")
  func previewKeepsToTheLine() {
    let model = Self.model()
    let shapes = ConversationOverviewShapes()
    let layout = ConversationOverviewLayout(
      blocks: model.blocks, measured: Dictionary(uniqueKeysWithValues: model.blocks.map { ($0.id, 100.0) }),
      metrics: .init(
        columnWidth: 600, textSize: 14, lineHeight: 1.2, blockSpacing: 20, paragraphSpacing: 8),
      shapes: shapes)
    // Block 2 starts at 240 points: its line at 240 × 0.1 + 1.5.
    let line = ConversationOverview.bookmarkY(top: 240, scale: 0.1)
    for pointer in [line - 4, line, line + 4] {
      let found = ConversationOverview.bookmarkLine(
        nearY: pointer, marked: [2], layout: layout, scale: 0.1)
      #expect(found?.id == "m2")
      #expect(found?.y == line)
    }
    #expect(
      ConversationOverview.bookmarkLine(nearY: line + 6, marked: [2], layout: layout, scale: 0.1)
        == nil)
  }

  @Test("A bookmark's preview reads in the messages' own font and size, a serif theme's included")
  func previewType() {
    var theme = ConversationTheme.systemDark
    theme.fontStyle = .serif
    var appearance = ConversationAppearance()
    appearance.textSize = .extraLarge
    let style = BookmarkPreviewStyle(theme: theme, appearance: appearance)
    #expect(style.textSize == 18)
    #expect(style.excerptFont == theme.messageFont(size: 18))
    #expect(style.headingFont == theme.interfaceFont(size: 18 * 0.86, weight: .semibold))
  }

  @Test("An answer's bookmark reads as the answer does, without its Markdown")
  func answerWithoutMarkdown() {
    let answer = ConversationBlock.entry(
      ConversationEntry(
        id: "a", content: .agentText("## Plan\n\n- **Rebase** on `main`\n\nThen ship.")))
    #expect(ConversationModel.bookmarkLabel(of: answer) == "Plan Rebase on main Then ship.")
    let reasoning = ConversationBlock.entry(
      ConversationEntry(id: "r", content: .reasoning("*Check* the tests.")))
    #expect(ConversationModel.bookmarkExcerpt(of: reasoning) == "Check the tests.")
  }

  @Test("A rule says nothing, and a block of code leaves one space before what follows")
  func plainTextBetweenBlocks() {
    #expect(ConversationModel.plainText(ofMarkdown: "Before\n\n---\n\nAfter") == "Before After")
    #expect(
      ConversationModel.plainText(ofMarkdown: "```swift\nlet x = 1\n```\n\nThen ship.")
        == "let x = 1 Then ship.")
  }

  @Test("Lines moved by a new layout or scale take the preview with them; one unmarked has none")
  func previewFollowsTheLayout() {
    let model = Self.model()
    let metrics = ConversationOverviewLayout.Metrics(
      columnWidth: 600, textSize: 14, lineHeight: 1.2, blockSpacing: 20, paragraphSpacing: 8)
    let before = ConversationOverviewLayout(
      blocks: model.blocks,
      measured: Dictionary(uniqueKeysWithValues: model.blocks.map { ($0.id, 100.0) }),
      metrics: metrics, shapes: ConversationOverviewShapes())
    let line = ConversationOverview.lineY(of: "m2", marked: [2], layout: before, scale: 0.1)
    #expect(line == ConversationOverview.bookmarkY(top: 240, scale: 0.1))
    // The first row measured 200 points taller: the line moves down 20 points.
    let after = before.remeasured(
      Dictionary(uniqueKeysWithValues: model.blocks.map { ($0.id, $0.id == "m0" ? 300.0 : 100.0) }))
    #expect(
      ConversationOverview.lineY(of: "m2", marked: [2], layout: after, scale: 0.1)
        == ConversationOverview.bookmarkY(top: 440, scale: 0.1))
    // A longer conversation drawn smaller.
    #expect(
      ConversationOverview.lineY(of: "m2", marked: [2], layout: after, scale: 0.05)
        == ConversationOverview.bookmarkY(top: 440, scale: 0.05))
    #expect(ConversationOverview.lineY(of: "m2", marked: [], layout: after, scale: 0.1) == nil)
    #expect(ConversationOverview.lineY(of: "gone", marked: [2], layout: after, scale: 0.1) == nil)
  }
}
