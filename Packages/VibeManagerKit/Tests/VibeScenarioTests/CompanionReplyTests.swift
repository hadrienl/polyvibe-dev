import CompanionCore
import Foundation
import Testing
import VibeApplication

@testable import VibeComposition

@Suite("The phone replies to a passage using the Mac's quotation (#633)")
@MainActor
struct CompanionReplyTests {
  let date = Date(timeIntervalSince1970: 1_795_360_000)

  @Test("The Mac prepares exactly its own normalized, bounded quote, without inventing a date")
  func prepare() throws {
    let text = String(repeating: "Éléphant 🐘 and **Markdown**.\n", count: 100)
    let entries = [ConversationEntry(id: "a", content: .agentText(text))]
    let reply = try #require(
      CompanionRemoteReply.prepare(sourceID: "a", excerpt: text, entries: entries))
    let quote = ReplyQuote(excerpt: text, author: .agent, date: nil)
    #expect(reply.excerpt == quote.excerpt)
    #expect(reply.excerpt.count <= ReplyQuote.maximumLength)
    #expect(reply.author == .agent)
    #expect(reply.date == nil)
    #expect(reply.time == nil)
    #expect(reply.sourceID == "a")
    #expect(CompanionRemoteReply.prepare(sourceID: "gone", excerpt: text, entries: entries) == nil)
    #expect(
      CompanionRemoteReply.prepare(sourceID: "a", excerpt: "another passage", entries: entries)
        == nil)
    #expect(CompanionRemoteReply.prepare(sourceID: "a", excerpt: "  ", entries: entries) == nil)
  }

  @Test("A Mac reply stays plain text on v5 and separates on v6, with an origin outside the slice")
  func received() throws {
    let source = ConversationEntry(
      id: "a", date: date, content: .agentText("Keep **unknown prices** out."))
    let quote = ReplyQuote(excerpt: "Keep unknown prices out.", author: .agent, date: date)
    let prompt = ReplyQuote.compose(quote, message: "Say that in the UI.")
    let reply = ConversationEntry(
      id: "u", date: date.addingTimeInterval(10), content: .userPrompt(prompt, attachments: []))
    let entries = [source, reply]
    let old = CompanionRemoteServer.entries(entries, replies: false, limit: 1)
    #expect(old[0].kind == .user(prompt, attachments: []))
    #expect(old[0].reply == nil)
    let new = CompanionRemoteServer.entries(entries, replies: true, limit: 1)
    #expect(new.count == 1)
    #expect(new[0].kind == .user("Say that in the UI.", attachments: []))
    #expect(new[0].reply?.sourceID == "a")
    #expect(new[0].reply?.excerpt == quote.excerpt)
    #expect(new[0].reply?.date == date)
    #expect(new[0].reply?.time == quote.time)
  }

  @Test("An origin absent from the history leaves the quotation readable, without a false link")
  func missing() {
    let quote = ReplyQuote(excerpt: "Old passage", author: .agent, time: "14:32")
    let entry = ConversationEntry(
      id: "u", content: .userPrompt(ReplyQuote.compose(quote, message: "Continue"), attachments: [])
    )
    let remote = CompanionRemoteServer.entries([entry], replies: true)[0]
    #expect(remote.reply?.excerpt == "Old passage")
    #expect(remote.reply?.sourceID == nil)
    #expect(remote.reply?.date == nil)
    #expect(remote.reply?.time == "14:32")
  }

  @Test("Repeated passages choose the same latest preceding origin as the Mac")
  func repeated() {
    let quote = ReplyQuote(excerpt: "Same words", author: .agent, date: date)
    let entries = [
      ConversationEntry(id: "a", date: date, content: .agentText("Same words")),
      ConversationEntry(id: "b", date: date, content: .agentText("Same words")),
      ConversationEntry(
        id: "u", content: .userPrompt(ReplyQuote.compose(quote, message: "Yes"), attachments: [])),
      ConversationEntry(id: "later", date: date, content: .agentText("Same words")),
    ]
    #expect(CompanionRemoteServer.entries(entries, replies: true)[2].reply?.sourceID == "b")
  }

  @Test("Each push takes the model's links as they are, without searching the history again")
  func modelLinks() {
    let quote = ReplyQuote(excerpt: "Same words", author: .agent, date: date)
    let entries = [
      ConversationEntry(id: "a", date: date, content: .agentText("Same words")),
      ConversationEntry(
        id: "u", content: .userPrompt(ReplyQuote.compose(quote, message: "Yes"), attachments: [])),
    ]
    let linked = CompanionRemoteServer.entries(entries, replies: true, sources: ["u": "a"])
    #expect(linked[1].reply?.sourceID == "a")
    #expect(linked[1].reply?.date == date)
    let unlinked = CompanionRemoteServer.entries(entries, replies: true, sources: [:])
    #expect(unlinked[1].reply?.sourceID == nil)
    #expect(unlinked[1].reply?.excerpt == "Same words")
  }
}
