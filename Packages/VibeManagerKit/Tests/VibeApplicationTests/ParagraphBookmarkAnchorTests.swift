import Testing

@testable import VibeApplication

@Suite("Paragraph bookmark anchors (#594)")
struct ParagraphBookmarkAnchorTests {
  @Test func storage() {
    for id in ["entry", "entry#part", "uuid#with#hashes"] {
      for unit in [0, 1, 42] {
        let anchor = BookmarkAnchor(entryID: id, unit: unit)
        #expect(BookmarkAnchor(anchor.stored) == anchor)
      }
    }
    #expect(BookmarkAnchor("old").unit == 0)
    #expect(BookmarkAnchor("entry#uinvalid").entryID == "entry#uinvalid")
  }

  @Test func independentParagraphs() {
    let blocks = [
      ConversationBlock.entry(ConversationEntry(id: "a", content: .agentText("A"))),
      .entry(ConversationEntry(id: "b", content: .agentText("B"))),
    ]
    var bookmarks = ConversationBookmarks.toggled([], on: blocks[0], unit: 0)
    bookmarks = ConversationBookmarks.toggled(bookmarks, on: blocks[0], unit: 3)
    bookmarks = ConversationBookmarks.toggled(bookmarks, on: blocks[1], unit: 1)
    #expect(bookmarks == ["a", "a#u3", "b#u1"])
    #expect(
      ConversationBookmarks.marked(in: blocks, bookmarks: bookmarks).map(\.unit) == [0, 3, 1])
    let placed = ConversationMoments.placed(in: blocks, bookmarks: bookmarks)
    #expect(placed.map(\.moment.unit) == [0, 3, 1])
    #expect(placed.map(\.blockIndex) == [0, 0, 1])
    bookmarks = ConversationBookmarks.toggled(bookmarks, on: blocks[0], unit: 3)
    #expect(bookmarks == ["a", "b#u1"])
  }
}
