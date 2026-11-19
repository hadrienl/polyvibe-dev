import Foundation
import VibeApplication

/// The passage the next message replies to (#565), and the block it was taken from.
public struct ReplyTarget: Hashable, Sendable {
  public var quote: ReplyQuote
  public var blockID: String

  public init(quote: ReplyQuote, blockID: String) {
    self.quote = quote
    self.blockID = blockID
  }
}

extension ConversationModel {
  /// How long a block brought into view stays lit.
  static let highlightDuration = Duration.milliseconds(1_600)

  /// Replies to a passage of the block `blockID`: it shows above the field, which takes the
  /// keyboard.
  public func reply(to excerpt: String, author: ReplyQuote.Author, date: Date?, blockID: String) {
    let quote = ReplyQuote(excerpt: excerpt, author: author, date: date)
    guard !quote.excerpt.isEmpty else { return }
    replyTarget = ReplyTarget(quote: quote, blockID: blockID)
    requestComposerFocus()
  }

  /// The passage taken back, by ✕ or Escape. Returns whether there was one.
  @discardableResult
  public func cancelReply() -> Bool {
    guard replyTarget != nil else { return false }
    replyTarget = nil
    return true
  }

  /// The passage put aside while a message that is not the composer's is sent — the phone's — and
  /// given back after.
  public func setReplyAside() -> ReplyTarget? {
    defer { replyTarget = nil }
    return replyTarget
  }

  public func restoreReply(_ target: ReplyTarget?) {
    if let target, replyTarget == nil { replyTarget = target }
  }

  /// Brings the passage a reply quotes into view, lit, and offers the way back to the reply.
  /// `replyID` is `nil` for a reply still on its way: the way back is then the conversation's end.
  public func showSource(of quote: ReplyQuote, replyID: String?) {
    // Only among the messages before the reply: a later one may say the same.
    let end = replyID.flatMap { id in blocks.firstIndex { $0.id == id } } ?? blocks.endIndex
    let source =
      replyID.flatMap { replyLinks.sources[$0] }
      ?? ReplyLinks.source(of: quote, in: blocks[..<end])
    guard let source else { return }
    returnBlockID = replyID ?? Self.conversationEndID
    reveal(source)
  }

  /// Brings a reply into view, lit, from the passage it quotes.
  public func showReply(_ replyID: String) {
    returnBlockID = nil
    reveal(replyID)
  }

  /// Back to the reply the user left: « Back to your reply ».
  public func returnToReply() {
    guard let id = returnBlockID else { return }
    returnBlockID = nil
    if id == Self.conversationEndID {
      jumpToBottom()
    } else {
      reveal(id)
    }
  }

  /// Where « Back to your reply » goes for a reply still on its way.
  static let conversationEndID = "reply:end"

  private func reveal(_ blockID: String) {
    scroll.jumpedAway()
    revealedBlockID = blockID
    revealRequest += 1
    highlightedBlockID = blockID
    highlightTask?.cancel()
    highlightTask = Task { [weak self] in
      try? await Task.sleep(for: Self.highlightDuration)
      guard !Task.isCancelled, let self, self.highlightedBlockID == blockID else { return }
      self.highlightedBlockID = nil
    }
  }
}
