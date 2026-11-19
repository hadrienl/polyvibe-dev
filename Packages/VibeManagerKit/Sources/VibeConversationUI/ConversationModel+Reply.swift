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

  /// The passage the next message replies to, while the field shows it: an answer to the agent's
  /// question takes none, and it waits for the next message.
  public var shownReplyTarget: ReplyTarget? {
    [.ready, .chattingAboutQuestion].contains(composerState) ? replyTarget : nil
  }

  /// Whether `draft` is a command of the CLI — `/compact`, `/review 12` —, not a message that
  /// starts with a path, as `/Users/me/Foo.swift still crashes`.
  static func isCLICommand(_ draft: String) -> Bool {
    guard draft.hasPrefix("/") else { return false }
    let name = draft.dropFirst().prefix { !$0.isWhitespace }
    return !name.isEmpty
      && name.allSatisfy { $0.isLetter || $0.isNumber || ":_-.".contains($0) }
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
    reveal(source, passage: quote)
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

  /// Brings `blockID` into view, lit: only `passage` of it when one of its texts shows it — the
  /// paragraph, the selection replied to —, else all of it.
  func reveal(_ blockID: String, passage: ReplyQuote? = nil) {
    scroll.jumpedAway()
    revealedBlockID = blockID
    revealRequest += 1
    litPassageShown = false
    let request = revealRequest
    litPassage = passage.map { LitPassage(blockID: blockID, quote: $0, request: request) }
    highlightedBlockID = passage == nil ? blockID : nil
    highlightTask?.cancel()
    highlightTask = Task { [weak self] in
      if passage != nil {
        // Its message laid out, and its texts told: one of them shows it, or none does.
        try? await Task.sleep(for: Self.passageSearchDuration)
        guard !Task.isCancelled, let self else { return }
        if !self.litPassageShown { self.highlightedBlockID = blockID }
      }
      try? await Task.sleep(for: Self.highlightDuration)
      guard !Task.isCancelled, let self else { return }
      if self.highlightedBlockID == blockID { self.highlightedBlockID = nil }
      if self.litPassage?.request == request { self.litPassage = nil }
    }
  }

  /// How long its message's texts have to find the passage, before the whole message is lit.
  static let passageSearchDuration = Duration.milliseconds(500)

  /// A text of its message shows the passage lit.
  func passageShown(_ passage: LitPassage) {
    if litPassage == passage { litPassageShown = true }
  }
}

/// The passage a reply quotes, lit in the message it comes from (#565).
public struct LitPassage: Hashable, Sendable {
  public var blockID: String
  public var quote: ReplyQuote
  /// The request that brought it into view: shown again, it is lit and scrolled to again.
  public var request: Int
}
