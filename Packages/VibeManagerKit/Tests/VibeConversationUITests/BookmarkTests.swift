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
    #expect(model.revealNextMoment())
    #expect(model.revealedBlockID == "m4")
    // The view could not move: the top is still m3.
    #expect(model.revealNextMoment())
    #expect(model.revealedBlockID == "m5")
    #expect(!model.revealNextMoment())
    #expect(model.revealPreviousMoment())
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
    #expect(model.revealNextMoment())
    #expect(model.revealedBlockID == "m1")
    #expect(model.highlightedBlockID == "m1")
    // The view now at m1's start.
    model.overview.scrolled(readableTop: 120, readableHeight: 300)
    #expect(model.revealNextMoment())
    #expect(model.revealedBlockID == "m4")
    model.overview.scrolled(readableTop: 480, readableHeight: 300)
    #expect(!model.revealNextMoment())
    #expect(model.revealPreviousMoment())
    #expect(model.revealedBlockID == "m1")
    // Inside m4, past its start: Previous goes back to its start first.
    model.overview.scrolled(readableTop: 530, readableHeight: 300)
    #expect(model.revealPreviousMoment())
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
    #expect(!model.revealPreviousMoment())
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
    // Where the overview placed the block, in the messages, goes with it.
    model.scrollOverview(to: "m3", offset: 12, top: 340)
    #expect(model.overviewScroll?.top == 340)
  }

  @Test("A drag in the overview leaves the end once: its next steps tell nothing more of it")
  func dragLeavesTheEndOnce() {
    let model = Self.model()
    model.scrollOverview(to: "m2", offset: 0)
    #expect(!model.scroll.isFollowing)
    final class Flag: @unchecked Sendable { var told = false }
    let flag = Flag()
    withObservationTracking {
      _ = model.scroll
    } onChange: {
      flag.told = true
    }
    // Before, each step had the whole list, which shows how many messages arrived, made again.
    model.scrollOverview(to: "m3", offset: 0)
    #expect(!flag.told)
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

  @Test(
    "Vibe Manager's news is named by who sent it and the sessions it is about, not their identifiers"
  )
  func applicationNews() {
    let block = Self.prompt(
      """
      [Vibe Manager] 2 events:
      - “Revue générale” (B72A6790-1C2D-4E5F-8A9B-0C1D2E3F4A5B) finished its turn.
      - “#12 export” (0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D) stopped: its agent is no longer running.
      """)
    #expect(ConversationModel.bookmarkExcerpt(of: block) == "Revue générale, #12 export")
    #expect(
      ConversationModel.bookmarkLabel(of: block) == "Vibe Manager · Revue générale, #12 export")
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

  /// The blocks laid out 100 points tall, 20 apart: block `i` starts at `i × 120`.
  private static func evenLayout(_ model: ConversationModel) -> ConversationOverviewLayout {
    ConversationOverviewLayout(
      blocks: model.blocks,
      measured: Dictionary(uniqueKeysWithValues: model.blocks.map { ($0.id, 100.0) }),
      metrics: .init(
        columnWidth: 600, textSize: 14, lineHeight: 1.2, blockSpacing: 20, paragraphSpacing: 8),
      shapes: ConversationOverviewShapes())
  }

  @Test("A block not built is placed from the row built nearest it, as the overview lays them")
  func blockNotBuiltPlacedFromItsNeighbour() {
    let model = Self.model()
    let layout = Self.evenLayout(model)
    // Only blocks 2 and 3 are built, lower in the messages than the overview lays them.
    model.overview.rowLaidOut("m2", frame: CGRect(x: 0, y: 1000, width: 600, height: 100))
    model.overview.rowLaidOut("m3", frame: CGRect(x: 0, y: 1120, width: 600, height: 100))
    let tracker = model.overview
    // Built: where its row is.
    #expect(tracker.documentTop(of: 3, in: layout, reach: 300) == 1120)
    // Just above what is built, where a drag upwards goes: one block above block 2.
    #expect(tracker.documentTop(of: 1, in: layout, reach: 300) == 880)
    // Below: from block 3, the nearest.
    #expect(tracker.documentTop(of: 5, in: layout, reach: 300) == 1360)
    // Further than the reach: left to the list, which finds the block itself.
    #expect(tracker.documentTop(of: 5, in: layout, reach: 200) == nil)
    #expect(tracker.documentTop(of: 9, in: layout, reach: 300) == nil)
  }

  @Test("Near a bookmark's line, the preview stands at the line, wherever the pointer is")
  func previewKeepsToTheLine() {
    let model = Self.model()
    model.loadBookmarks(["m2"])
    let layout = Self.evenLayout(model)
    // Block 2 starts at 240 points: its line at 240 × 0.1 + 1.5.
    let line = ConversationOverview.iconY(top: 240, scale: 0.1)
    for pointer in [line - 4, line, line + 4] {
      let found = ConversationOverview.cluster(
        near: CGPoint(x: 40, y: pointer), moments: model.shownMoments, layout: layout, scale: 0.1)
      #expect(found?.moments == 0..<1)
      #expect(found?.y == line)
    }
    #expect(
      ConversationOverview.cluster(
        near: CGPoint(x: 40, y: line + 6), moments: model.shownMoments, layout: layout,
        scale: 0.1) == nil)
  }

  // MARK: - Moments (#572)

  private static func shell(_ id: String, _ command: String) -> ConversationEntry {
    ConversationEntry(
      id: id,
      content: .tool(
        ToolCall(
          callID: id, kind: .shell, state: .succeeded, parameters: [.init(.command, command)])))
  }

  /// A prompt, a commit, an answer, an error, a push.
  private static func momentsModel() -> ConversationModel {
    let model = ConversationModel(sessionID: SessionID())
    let entries = [
      ConversationEntry(id: "m0", content: .userPrompt("Commit", attachments: [])),
      shell("m1", "git commit -m one"),
      ConversationEntry(id: "m2", content: .agentText("Done")),
      ConversationEntry(id: "m3", content: .notice(.error("Overloaded"))),
      shell("m4", "git push origin main"),
    ]
    model.apply(ConversationSnapshot(entries: entries, availability: .available))
    return model
  }

  @Test("The moments are read from the blocks, bookmarks among them, in order")
  func moments() {
    let model = Self.momentsModel()
    #expect(model.moments.map(\.moment.kind) == [.git, .incident, .git])
    model.toggleBookmark(model.blocks[2])
    #expect(model.moments.map(\.moment.kind) == [.git, .bookmark, .incident, .git])
    #expect(model.momentIndices == [1, 2, 3, 4])
    #expect(model.momentBlocks.map(\.block.id) == ["m1", "m2", "m3", "m4"])
  }

  @Test("A kind hidden leaves the overview and the way from one moment to the next")
  func hiddenKinds() {
    let model = Self.momentsModel()
    let revision = model.momentsRevision
    model.appearance.hiddenMomentKinds = ["git"]
    #expect(model.shownMoments.map(\.moment.kind) == [.incident])
    #expect(model.momentIndices == [3])
    #expect(model.momentsRevision > revision)
    // Kept, though hidden: the filter says how many there are.
    #expect(model.moments.count == 3)

    Self.laidOut(model, top: 0)
    #expect(model.revealNextMoment())
    #expect(model.revealedBlockID == "m3")
    model.overview.scrolled(readableTop: 360, readableHeight: 300)
    #expect(!model.revealNextMoment())
    model.appearance.hiddenMomentKinds = []
    #expect(model.revealNextMoment())
    #expect(model.revealedBlockID == "m4")
  }

  @Test("The filters ask the workspace, which hands every session the settings back")
  func filterAsksTheWorkspace() {
    let model = Self.momentsModel()
    var asked: [(ConversationMomentKind, Bool)] = []
    model.setMomentKindShown = { asked.append(($0, $1)) }
    model.setMomentKindShown?(.git, false)
    #expect(asked.count == 1)
    #expect(asked.first?.0 == .git)
    #expect(asked.first?.1 == false)
  }

  @Test("Moments drawn close share an icon; the pointer on it finds them all")
  func clusterUnderThePointer() {
    let model = Self.momentsModel()
    let layout = Self.evenLayout(model)
    // At a twentieth, blocks are 6 points apart: m3 within 13 points of m1, m4 not.
    let clusters = ConversationOverview.clusters(
      of: model.shownMoments, layout: layout, scale: 0.05)
    #expect(clusters.map(\.moments) == [0..<2, 2..<3])
    let icon = ConversationOverview.iconY(top: 120, scale: 0.05)
    let found = ConversationOverview.cluster(
      near: CGPoint(x: 8, y: icon + 2), moments: model.shownMoments, layout: layout, scale: 0.05)
    #expect(found?.moments == 0..<2)
    // Off the margin, an icon is not under the pointer: only a bookmark's line is.
    #expect(
      ConversationOverview.cluster(
        near: CGPoint(x: 40, y: icon), moments: model.shownMoments, layout: layout,
        scale: 0.05) == nil)
  }
}
