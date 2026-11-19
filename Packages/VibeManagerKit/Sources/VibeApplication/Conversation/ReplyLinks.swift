import Foundation

/// Which message each reply of the conversation quotes, and the replies each message has (#565).
///
/// Read from the transcript alone: a reply's prompt says the passage and when it was said, and the
/// message it came from is the latest before it that was said then and holds it.
public struct ReplyLinks: Hashable, Sendable {
  /// The block a reply quotes, by the reply's block.
  public private(set) var sources: [String: String] = [:]
  /// The replies to a block, in the conversation's order.
  public private(set) var replies: [String: [String]] = [:]
  /// Where each reply is among the blocks: those before the blocks laid out again keep theirs.
  private var places: [String: Int] = [:]

  public init() {}

  /// Brought up to date for the blocks from `restart` on, those before it unchanged. Laid out at
  /// every word the agent writes: only the blocks laid out again are read.
  public mutating func update(
    _ blocks: [ConversationBlock], from restart: Int, timeZone: TimeZone = .current
  ) {
    var places = self.places.filter { $0.value < restart }
    var sources = self.sources.filter { places[$0.key] != nil }
    for index in blocks.indices.dropFirst(restart) {
      guard case .entry(let entry) = blocks[index], case .userPrompt(let text, _) = entry.content,
        let (quote, _) = ReplyQuote.split(text),
        let source = Self.source(of: quote, in: blocks[..<index], timeZone: timeZone)
      else { continue }
      sources[entry.id] = source
      places[entry.id] = index
    }
    guard sources != self.sources else {
      self.places = places
      return
    }
    var replies: [String: [String]] = [:]
    for (reply, source) in sources.sorted(by: { places[$0.key, default: 0] < places[$1.key, default: 0] }) {
      replies[source, default: []].append(reply)
    }
    self.sources = sources
    self.replies = replies
    self.places = places
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
      case (.userPrompt(let said, _), .user): text = ReplyQuote.message(of: said)
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
