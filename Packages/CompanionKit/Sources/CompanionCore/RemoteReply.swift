import Foundation

/// A quotation prepared by the Mac using its own ReplyQuote rules (#633).
public struct RemoteReply: Codable, Hashable, Sendable {
  public enum Author: String, Codable, Hashable, Sendable { case user, agent }
  public var excerpt: String
  public var author: Author
  public var date: Date?
  public var time: String?
  public var sourceID: String?

  public init(excerpt: String, author: Author, date: Date?, sourceID: String?, time: String? = nil)
  {
    self.excerpt = excerpt
    self.author = author
    self.date = date
    self.time = time
    self.sourceID = sourceID
  }
}

/// An unsent phone draft belongs to its conversation, including across a reconnection.
public struct RemoteConversationDraft: Equatable, Sendable {
  public var text: String
  public var files: [RemoteFile]
  public var reply: RemoteReply?

  public init(text: String = "", files: [RemoteFile] = [], reply: RemoteReply? = nil) {
    self.text = text
    self.files = files
    self.reply = reply
  }

  public var isEmpty: Bool { text.isEmpty && files.isEmpty && reply == nil }
}
