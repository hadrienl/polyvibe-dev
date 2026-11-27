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

  /// A reply as the phone shows it: the user's words apart, the passage, and the entry it
  /// quotes, `sourceID`, found by the Mac's own links.
  static func shown(
    _ entry: ConversationEntry, quoting sourceID: String?,
    before entries: ArraySlice<ConversationEntry>
  ) -> (message: String, reply: RemoteReply)? {
    guard case .userPrompt(let text, let attachments) = entry.content,
      RelayedMessage(text, attachments: attachments) == nil
    else { return nil }
    let shown = ReplyLinks.shown(text, attachments: attachments)
    guard let quote = shown.quote else { return nil }
    let source = sourceID.flatMap { id in entries.last { $0.id == id } }
    return (
      shown.message,
      RemoteReply(
        excerpt: quote.excerpt, author: quote.author == .agent ? .agent : .user,
        date: source?.date, sourceID: source?.id, time: quote.time)
    )
  }

  /// The entry each reply quotes, read from the entries alone, as the model reads its blocks.
  static func sources(of entries: [ConversationEntry]) -> [String: String] {
    var links = ReplyLinks()
    var places: [String: Int] = [:]
    links.update(entries.map(ConversationBlock.entry), from: 0, places: &places)
    return links.sources
  }
}
