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
}
