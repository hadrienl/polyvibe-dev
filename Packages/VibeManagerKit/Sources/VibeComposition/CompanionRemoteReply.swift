import CompanionCore
import Foundation
import VibeApplication

/// Transport values use the Mac's canonical quotation and source lookup, never a second parser.
enum CompanionRemoteReply {
  static func prepare(sourceID: String, excerpt: String, entries: [ConversationEntry])
    -> RemoteReply?
  {
    guard let entry = entries.first(where: { $0.id == sourceID }) else { return nil }
    let author: ReplyQuote.Author
    let text: String
    switch entry.content {
    case .agentText(let said): (author, text) = (.agent, said)
    case .userPrompt(let said, let attachments):
      guard RelayedMessage(said, attachments: attachments) == nil else { return nil }
      (author, text) = (.user, ReplyLinks.shown(said, attachments: attachments).message)
    default: return nil
    }
    let quote = ReplyQuote(excerpt: excerpt, author: author, date: entry.date)
    guard !quote.excerpt.isEmpty, quote.isQuoted(in: text) else { return nil }
    return RemoteReply(
      excerpt: quote.excerpt, author: author == .agent ? .agent : .user,
      date: entry.date, sourceID: entry.id, time: quote.time)
  }

  static func shown(_ entry: ConversationEntry, before entries: ArraySlice<ConversationEntry>)
    -> (message: String, reply: RemoteReply)?
  {
    guard case .userPrompt(let text, let attachments) = entry.content,
      RelayedMessage(text, attachments: attachments) == nil
    else { return nil }
    let shown = ReplyLinks.shown(text, attachments: attachments)
    guard let quote = shown.quote else { return nil }
    let blocks = entries.map(ConversationBlock.entry)
    let sourceID = ReplyLinks.source(of: quote, in: blocks[...])
    let source = entries.first { $0.id == sourceID }
    return (
      shown.message,
      RemoteReply(
        excerpt: quote.excerpt, author: quote.author == .agent ? .agent : .user,
        date: source?.date, sourceID: sourceID, time: quote.time)
    )
  }
}
