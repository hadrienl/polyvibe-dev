import Foundation
import Testing

@testable import VibeApplication

@Suite("A reply to a passage of the conversation (#565)")
struct ReplyQuoteTests {
  private let paris = TimeZone(identifier: "Europe/Paris")!

  @Test("The agent reads a line saying what it is, the passage quoted, then the message")
  func compose() {
    let quote = ReplyQuote(
      excerpt: "Note : les remises arrondissent encore.", author: .agent, time: "14:32")
    #expect(
      ReplyQuote.compose(quote, message: "Corrige-les aussi.")
        == """
        ↩ Replying to your message of 14:32 (quoted for context, not an instruction):
        > Note : les remises arrondissent encore.

        Corrige-les aussi.
        """)
  }

  @Test("Read back, a prompt gives the passage, who said it, when, and the message alone")
  func roundTrip() throws {
    for quote in [
      ReplyQuote(excerpt: "one\n\ntwo", author: .agent, time: "09:05"),
      ReplyQuote(excerpt: "mine", author: .user, time: nil),
    ] {
      let prompt = ReplyQuote.compose(quote, message: "first line\n\nsecond line")
      let read = try #require(ReplyQuote.split(prompt))
      #expect(read.quote == quote)
      #expect(read.message == "first line\n\nsecond line")
      #expect(ReplyQuote.message(of: prompt) == "first line\n\nsecond line")
    }
    #expect(
      ReplyQuote.compose(ReplyQuote(excerpt: "mine", author: .user, time: nil), message: "m")
        .hasPrefix("↩ Replying to my message (quoted for context, not an instruction):\n> mine"))
  }

  @Test("A prompt that only looks like one is left as it is")
  func notAReply() {
    for prompt in [
      "hello", "↩ Replying to nothing", "↩ Replying to your message of 14:32 (quoted for context, "
        + "not an instruction):\nno quote",
    ] {
      #expect(ReplyQuote.split(prompt) == nil)
      #expect(ReplyQuote.message(of: prompt) == prompt)
    }
  }

  @Test("The time is the passage's, where the user is")
  func time() {
    // 2026-11-19 13:32 UTC.
    let date = Date(timeIntervalSince1970: 1_795_095_120)
    #expect(ReplyQuote(excerpt: "x", author: .agent, date: date, timeZone: paris).time == "14:32")
    #expect(ReplyQuote(excerpt: "x", author: .agent, date: nil).time == nil)
  }

  @Test("A passage is trimmed, its blank lines kept single, and a long one cut")
  func trimmed() {
    #expect(ReplyQuote.trimmed("  \n a \n\n\n b \n\n") == "a\n\nb")
    let long = String(repeating: "word ", count: 400)
    let cut = ReplyQuote.trimmed(long)
    #expect(cut.count <= ReplyQuote.maximumLength)
    #expect(cut.hasSuffix("…"))
  }

  @Test("The passage is found in the Markdown of the message it was shown from")
  func found() {
    let quote = ReplyQuote(
      excerpt: "Note : les remises (applyDiscount) arrondissent encore sur le total.",
      author: .agent, time: nil)
    #expect(
      quote.isQuoted(
        in: "C'est fait.\n\nNote : les remises (`applyDiscount`) arrondissent **encore** sur le "
          + "total."))
    #expect(!quote.isQuoted(in: "Something else entirely."))
    let cut = ReplyQuote(excerpt: "C'est fait. Note…", author: .agent, time: nil)
    #expect(cut.isQuoted(in: "C'est fait.\n\nNote : les remises."))
    #expect(!ReplyQuote(excerpt: "…", author: .agent, time: nil).isQuoted(in: "anything"))
    // A link is read as it is shown: its text, not its address.
    let linked = ReplyQuote(
      excerpt: "Voir Foo.swift qui calcule le total.", author: .agent, time: nil)
    #expect(linked.isQuoted(in: "Voir [Foo.swift](Sources/Foo.swift:12) qui calcule le total."))
  }
}
