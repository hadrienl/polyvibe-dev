import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

/// The overview's preview, on the icons of the margin too (#608): the same words for a moment,
/// for several, for a bookmark, shown while the pointer is on the icon and never while the
/// messages scroll.
@MainActor
@Suite("The margin's preview")
struct MarginPreviewTests {
  private static let day = Date(timeIntervalSince1970: 1_790_000_000)

  private static func shell(_ id: String, _ command: String, output: String) -> ConversationEntry {
    ConversationEntry(
      id: id, date: day,
      content: .tool(
        ToolCall(
          callID: id, kind: .shell, state: .succeeded, parameters: [.init(.command, command)],
          output: ToolOutput(text: output))))
  }

  /// A prompt, a commit alone, an answer, then a commit and a push in one command, and a last
  /// answer.
  private static func model() -> ConversationModel {
    let model = ConversationModel(sessionID: SessionID())
    model.write = { _ in }
    model.processRunning = { true }
    model.agentName = "Claude"
    let entries = [
      ConversationEntry(
        id: "p0", date: day, content: .userPrompt("Round the VAT per line", attachments: [])),
      shell(
        "t1", "git commit -m 'fix(cart): round VAT per line'",
        output: "[main 1a2b3c4] fix(cart): round VAT per line\n 1 file changed\n"),
      ConversationEntry(id: "a2", date: day, content: .agentText("Committed. Pushing now.")),
      shell(
        "t3", "git commit -m 'test(cart): rounding' && git push origin main",
        output: "[main 5d6e7f8] test(cart): rounding\n 1 file changed\nTo github.com:o/r.git\n"
          + "   1a2b3c4..5d6e7f8  main -> main\n"),
      ConversationEntry(id: "a5", date: day, content: .agentText("Done, all pushed.")),
    ]
    model.apply(ConversationSnapshot(entries: entries, availability: .available))
    return model
  }

  /// The preview the overview shows for the moments of one block, bookmarks aside or not.
  private static func overviewContent(
    of block: ConversationBlock, in model: ConversationModel, bookmark: Bool
  ) -> MomentPreviewContent {
    let index = model.blocks.firstIndex { $0.id == block.id }!
    let placed = model.shownMoments.filter {
      $0.blockIndex == index && ($0.moment.kind == .bookmark) == bookmark
    }
    return MomentPreviewContent(placed: placed, model: model)
  }

  private static func blocks(
    withMoments count: Int, in model: ConversationModel
  ) -> [ConversationBlock] {
    model.blocks.filter { model.moments(of: $0).count == count }
  }

  @Test("One moment: what happened and when, as the overview shows it")
  func oneMoment() throws {
    let model = Self.model()
    let block = try #require(Self.blocks(withMoments: 1, in: model).first)
    let content = try #require(
      MomentPreviewContent(
        margin: .moments, of: block, model: model, appearance: ConversationAppearance()))
    #expect(content.items.count == 1)
    let item = try #require(content.items.first)
    #expect(item.label == "Commit “fix(cart): round VAT per line”")
    #expect(item.heading == "Git · \(MomentPresentation.time(of: Self.day)!)")
    #expect(!item.isExcerpt)
    #expect(content == Self.overviewContent(of: block, in: model, bookmark: false))
  }

  @Test("Several moments sharing the icon: each one, in order, as the overview lists them")
  func severalMoments() throws {
    let model = Self.model()
    let block = try #require(Self.blocks(withMoments: 2, in: model).first)
    let content = try #require(
      MomentPreviewContent(
        margin: .moments, of: block, model: model, appearance: ConversationAppearance()))
    #expect(content.items.map(\.label) == ["Commit “test(cart): rounding”", "Pushed to main"])
    #expect(content == Self.overviewContent(of: block, in: model, bookmark: false))
  }

  @Test("Moments of a hidden kind are not in the preview, as they are not on the icon")
  func hiddenKind() throws {
    let model = Self.model()
    let block = try #require(Self.blocks(withMoments: 2, in: model).first)
    var appearance = ConversationAppearance()
    appearance.hiddenMomentKinds = [ConversationMomentKind.git.rawValue]
    #expect(
      MomentPreviewContent(margin: .moments, of: block, model: model, appearance: appearance)
        == nil)
  }

  @Test("A bookmark: who wrote the message, when, and its start, in the messages' type")
  func bookmark() throws {
    let model = Self.model()
    let block = model.blocks[0]
    #expect(
      MomentPreviewContent(
        margin: .bookmark, of: block, model: model, appearance: ConversationAppearance()) == nil)
    model.toggleBookmark(block)
    let content = try #require(
      MomentPreviewContent(
        margin: .bookmark, of: block, model: model, appearance: ConversationAppearance()))
    let item = try #require(content.items.first)
    #expect(content.items.count == 1)
    #expect(item.heading == "You · \(MomentPresentation.time(of: Self.day)!)")
    #expect(item.label == "Round the VAT per line")
    #expect(item.isExcerpt)
    #expect(content == Self.overviewContent(of: block, in: model, bookmark: true))
  }

  @Test("An answer bookmarked is the agent's")
  func agentBookmark() throws {
    let model = Self.model()
    let block = try #require(model.blocks.first { $0.id == "a5" })
    model.toggleBookmark(block)
    let content = try #require(
      MomentPreviewContent(
        margin: .bookmark, of: block, model: model, appearance: ConversationAppearance()))
    #expect(content.items.first?.heading?.hasPrefix("Claude · ") == true)
    #expect(content == Self.overviewContent(of: block, in: model, bookmark: true))
  }

  // MARK: - Pointer

  @Test("Shown while the pointer is on an icon; hidden when it leaves it, not another")
  func pointer() {
    let preview = ConversationMarginPreview()
    let anchor = CGRect(x: 10, y: 200, width: 18, height: 20)
    preview.pointerOn(blockID: "b1", target: .moments, anchor: anchor)
    #expect(preview.hover == .init(blockID: "b1", target: .moments, anchor: anchor))
    preview.pointerLeft(blockID: "b1", target: .bookmark)
    preview.pointerLeft(blockID: "b2", target: .moments)
    #expect(preview.hover != nil)
    preview.pointerOn(blockID: "b1", target: .bookmark, anchor: anchor.offsetBy(dx: 18, dy: 0))
    #expect(preview.hover?.target == .bookmark)
    preview.pointerLeft(blockID: "b1", target: .moments)
    #expect(preview.hover?.target == .bookmark)
    preview.pointerLeft(blockID: "b1", target: .bookmark)
    #expect(preview.hover == nil)
  }

  @Test("A scroll hides it, and the rows passing under the pointer do not show it again")
  func scroll() {
    var now = ContinuousClock.now
    let preview = ConversationMarginPreview()
    preview.now = { now }
    let anchor = CGRect(x: 10, y: 200, width: 18, height: 20)
    preview.pointerOn(blockID: "b1", target: .moments, anchor: anchor)
    preview.scrolled()
    #expect(preview.hover == nil)
    // A row brought under the still pointer by the scroll.
    now += .milliseconds(100)
    preview.pointerOn(blockID: "b2", target: .moments, anchor: anchor)
    #expect(preview.hover == nil)
    // The scroll over, the pointer moves on an icon.
    now += ConversationMarginPreview.quietAfterScroll
    preview.pointerOn(blockID: "b2", target: .moments, anchor: anchor)
    #expect(preview.hover?.blockID == "b2")
  }
}
