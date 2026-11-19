import Foundation

/// Which message each reply of the conversation quotes, and the replies each message has (#565).
///
/// Read from the transcript alone: a reply's prompt says the passage and when it was said, and the
/// message it came from is the latest before it that was said then and holds it.
public struct ReplyLinks: Equatable, Sendable {
  /// The block a reply quotes, by the reply's block.
  public private(set) var sources: [String: String] = [:]
  /// The replies to a block, in the conversation's order.
  public private(set) var replies: [String: [String]] = [:]
  public init() {}

  /// Brought up to date for the blocks from `restart` on, those before it unchanged. Laid out at
  /// every word the agent writes: only the blocks laid out again are read.
  ///
  /// `places` says where each reply is among the blocks — those before the blocks laid out again
  /// keep theirs —, kept by the caller apart from the links: a reply moved among the blocks
  /// changes no link, and redraws nothing.
  public mutating func update(
    _ blocks: [ConversationBlock], from restart: Int, places: inout [String: Int],
    timeZone: TimeZone = .current
  ) {
    places = places.filter { $0.value < restart }
    var sources = self.sources.filter { places[$0.key] != nil }
    for index in blocks.indices.dropFirst(restart) {
      guard case .entry(let entry) = blocks[index],
        case .userPrompt(let text, let attachments) = entry.content,
        let quote = Self.shown(text, attachments: attachments).quote,
        let source = Self.source(of: quote, in: blocks[..<index], timeZone: timeZone)
      else { continue }
      sources[entry.id] = source
      places[entry.id] = index
    }
    guard sources != self.sources else { return }
    var replies: [String: [String]] = [:]
    for (reply, source) in sources.sorted(by: {
      places[$0.key, default: 0] < places[$1.key, default: 0]
    }) {
      replies[source, default: []].append(reply)
    }
    self.sources = sources
    self.replies = replies
  }

  /// A prompt as the conversation shows it: without the paths that became attachments — an
  /// echo's text never holds them —, and, for a reply, the passage it quotes apart from the user's
  /// words, what the application put in front of it (#352) gone.
  public static func shown(_ text: String, attachments: [MessageAttachment])
    -> (quote: ReplyQuote?, message: String)
  {
    let attached = AttachedPaths.displayText(
      text, joinedCount: attachments.filter(\.isWrittenInText).count)
    guard let reply = ReplyQuote.split(CoordinatorInstructions.userText(of: attached) ?? attached)
    else { return (nil, attached) }
    return (reply.quote, reply.message)
  }

  /// The block among `blocks` the passage comes from: the latest said by its author, at its time,
  /// that holds it.
  public static func source(
    of quote: ReplyQuote, in blocks: ArraySlice<ConversationBlock>, timeZone: TimeZone = .current
  ) -> String? {
    for block in blocks.reversed() {
      guard case .entry(let entry) = block else { continue }
      let text: String
      switch (entry.content, quote.author) {
      case (.agentText(let said), .agent): text = said
      // Vibe Manager's and a coordinator's messages are not the user's, nor replied to.
      case (.userPrompt(let said, let attachments), .user)
      where RelayedMessage(said, attachments: attachments) == nil:
        text = shown(said, attachments: attachments).message
      default: continue
      }
      if let time = quote.time {
        guard let date = entry.date, ReplyQuote.time(of: date, in: timeZone) == time else {
          continue
        }
      }
      if quote.isQuoted(in: text) { return entry.id }
    }
    return nil
  }
}
