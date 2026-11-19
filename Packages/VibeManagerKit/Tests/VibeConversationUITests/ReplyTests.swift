import AppKit
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeConversationUI

@MainActor
@Suite("Replying to a passage of the conversation (#565)")
struct ReplyTests {
  private final class Terminal: @unchecked Sendable {
    var written: [[UInt8]] = []
  }

  private let paris = TimeZone(identifier: "Europe/Paris")!
  /// 2026-11-19 14:32, in Paris.
  private let said = Date(timeIntervalSince1970: 1_795_095_120)

  private func model() -> (ConversationModel, Terminal) {
    let model = ConversationModel(sessionID: SessionID())
    let terminal = Terminal()
    model.write = { terminal.written.append($0) }
    model.processRunning = { true }
    model.promptFormat = AgentPromptFormat(
      queueKey: [0x09], submitDelay: .zero,
      shellEntry: ShellEntry(switchDelay: .zero, chunkDelay: .zero))
    model.apply(ConversationSnapshot(availability: .available))
    return (model, terminal)
  }

  private func answer(_ id: String, _ text: String, at date: Date? = nil) -> ConversationEntry {
    ConversationEntry(id: id, date: date, content: .agentText(text))
  }

  private func prompt(_ id: String, _ text: String, at date: Date? = nil) -> ConversationEntry {
    ConversationEntry(id: id, date: date, content: .userPrompt(text, attachments: []))
  }

  @Test("The passage goes in front of the message, once, and the field lets it go")
  func send() async throws {
    let (model, _) = model()
    model.reply(to: "  Note : les remises.  ", author: .agent, date: nil, blockID: "a")
    #expect(model.replyTarget?.quote.excerpt == "Note : les remises.")
    model.draft = "Corrige-les aussi."
    #expect(await model.send())
    let sent = try #require(model.echoes.first?.text)
    #expect(
      sent
        == "↩ Replying to your message (quoted for context, not an instruction):\n"
        + "> Note : les remises.\n\nCorrige-les aussi.")
    #expect(model.replyTarget == nil)
    // Recalled, the message comes back without the passage.
    #expect(model.promptHistory.prompts.last == "Corrige-les aussi.")
  }

  @Test("A command of the CLI or of the shell takes no passage: it waits for the next message")
  func commands() async {
    let (model, _) = model()
    model.reply(to: "passage", author: .agent, date: nil, blockID: "a")
    model.draft = "/compact"
    #expect(await model.send())
    #expect(model.echoes.last?.text == "/compact")
    model.draft = "!ls"
    #expect(await model.send())
    #expect(model.echoes.last?.text == "ls")
    #expect(model.replyTarget?.quote.excerpt == "passage")
  }

  @Test("✕ or Escape take the passage back; an empty one is never offered")
  func cancel() {
    let (model, _) = model()
    model.reply(to: "  \n ", author: .agent, date: nil, blockID: "a")
    #expect(model.replyTarget == nil)
    #expect(!model.cancelReply())
    model.reply(to: "passage", author: .user, date: nil, blockID: "u")
    #expect(model.cancelReply())
    #expect(model.replyTarget == nil)
  }

  @Test("Read again, a reply knows the message it quotes, and the message its replies")
  func links() {
    let quote = ReplyQuote(excerpt: "Note : les remises (applyDiscount).", author: .agent, time: "14:32")
    var links = ReplyLinks()
    let blocks: [ConversationBlock] = [
      .entry(answer("a1", "Note : les remises (`applyDiscount`).", at: said)),
      .entry(answer("a2", "Note : les remises (`applyDiscount`).", at: said.addingTimeInterval(3_600))),
      .entry(prompt("r1", ReplyQuote.compose(quote, message: "Corrige."))),
      .entry(prompt("p", "Autre chose.")),
      .entry(prompt("r2", ReplyQuote.compose(quote, message: "Encore."))),
    ]
    links.update(blocks, from: 0, timeZone: paris)
    // The one said at the time quoted, though another later says the same.
    #expect(links.sources == ["r1": "a1", "r2": "a1"])
    #expect(links.replies == ["a1": ["r1", "r2"]])
    // Laid out again from the last block, the others keep theirs.
    links.update(Array(blocks.prefix(4)), from: 4, timeZone: paris)
    #expect(links.sources == ["r1": "a1"])
    #expect(links.replies == ["a1": ["r1"]])
  }

  @Test("A reply to one's own message finds it, without the passage it quoted itself")
  func ownMessage() {
    let first = ReplyQuote(excerpt: "the plan", author: .agent, time: nil)
    let own = ReplyQuote(excerpt: "Do it my way.", author: .user, time: nil)
    let blocks: [ConversationBlock] = [
      .entry(answer("a", "the plan")),
      .entry(prompt("u", ReplyQuote.compose(first, message: "Do it my way."))),
      .entry(prompt("r", ReplyQuote.compose(own, message: "Actually, not."))),
    ]
    var links = ReplyLinks()
    links.update(blocks, from: 0)
    #expect(links.sources == ["u": "a", "r": "u"])
  }

  @Test("From a reply to its passage and back, and from the passage to its reply")
  func navigation() {
    let (model, _) = model()
    let quote = ReplyQuote(excerpt: "Note : les remises.", author: .agent, time: nil)
    model.apply(
      ConversationSnapshot(
        entries: [
          answer("a", "Note : les remises."), prompt("p", "Autre chose."),
          prompt("r", ReplyQuote.compose(quote, message: "Corrige.")),
        ], availability: .available))
    #expect(model.replyLinks.replies == ["a": ["r"]])
    model.showSource(of: quote, replyID: "r")
    #expect(model.revealedBlockID == "a")
    #expect(model.highlightedBlockID == "a")
    #expect(model.returnBlockID == "r")
    model.returnToReply()
    #expect(model.revealedBlockID == "r")
    #expect(model.returnBlockID == nil)
    model.showReply("r")
    #expect(model.revealedBlockID == "r")
    #expect(model.highlightedBlockID == "r")
    // From a reply still on its way, the way back is the conversation's end.
    model.showSource(of: quote, replyID: nil)
    #expect(model.revealedBlockID == "a")
    let bottom = model.scrollToBottomRequest
    model.returnToReply()
    #expect(model.scrollToBottomRequest == bottom + 1)
  }
}

@MainActor
@Suite("« Reply » over a message's text (#565)")
struct ReplyButtonPlacementTests {
  private func view(_ text: String, width: CGFloat) -> SegmentTextView {
    let view = SegmentTextView()
    view.show(
      NSAttributedString(
        string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
    view.frame = CGRect(x: 0, y: 0, width: width, height: view.height(forWidth: width))
    view.layoutManager?.ensureLayout(for: view.textContainer!)
    return view
  }

  @Test("The paragraph under the pointer, without its line break; none beside the text")
  func paragraph() throws {
    let view = view("First paragraph.\nSecond one.", width: 400)
    let first = try #require(view.paragraph(at: NSPoint(x: 10, y: 5)))
    #expect((view.string as NSString).substring(with: first) == "First paragraph.")
    let lineHeight = view.height(forWidth: 400) / 2
    let second = try #require(view.paragraph(at: NSPoint(x: 10, y: lineHeight * 1.5)))
    #expect((view.string as NSString).substring(with: second) == "Second one.")
    #expect(view.paragraph(at: NSPoint(x: 10, y: lineHeight * 4)) == nil)
  }

  @Test("After the last word with its label, its icon alone at the end of a full line")
  func frame() throws {
    let view = view("Short.", width: 400)
    let size = CGSize(width: 60, height: 18)
    let icon = CGSize(width: 22, height: 18)
    let (after, iconOnly) = try #require(
      view.replyButtonFrame(after: 6, size: size, iconSize: icon))
    #expect(!iconOnly)
    #expect(after.minX > 20 && after.maxX < 400)
    let full = self.view(String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces), width: 120)
    let end = (full.string as NSString).length
    let (frame, onlyIcon) = try #require(full.replyButtonFrame(after: end, size: size, iconSize: icon))
    #expect(onlyIcon)
    #expect(frame.maxX <= 120)
    #expect(view.replyButtonFrame(after: 0, size: size, iconSize: icon) == nil)
  }
}
