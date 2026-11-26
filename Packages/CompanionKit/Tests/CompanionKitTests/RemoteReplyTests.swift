import CompanionCore
import Foundation
import Testing

@Suite("Remote quotation transport (#633)")
struct RemoteReplyTests {
  @Test("All reply messages survive framing, including missing dates and files")
  func messages() throws {
    let reply = RemoteReply(excerpt: "First\n> nested\n🐘", author: .agent, date: nil, sourceID: "a")
    let messages: [RemoteMessage] = [
      .prepareReply(sessionID: "s", requestID: "p", sourceID: "a", excerpt: reply.excerpt),
      .replyPrepared(sessionID: "s", requestID: "p", reply: reply),
      .replyPrepared(sessionID: "s", requestID: "p", reply: nil),
      .sendReply(sessionID: "s", requestID: "r", text: "Continue", files: [], reply: reply),
      .replySent(sessionID: "s", requestID: "r", sent: true, quoted: true),
      .replySent(sessionID: "s", requestID: "r", sent: false, quoted: false),
    ]
    for message in messages {
      let data = try JSONEncoder().encode(message)
      #expect(try JSONDecoder().decode(RemoteMessage.self, from: data) == message)
    }
  }

  @Test("Old entries have no quotation and only version six offers replies")
  func compatibility() throws {
    let old = Data(#"{"id":"a","kind":{"agent":{"_0":"Hello"}}}"#.utf8)
    #expect(try JSONDecoder().decode(RemoteEntry.self, from: old).reply == nil)
    #expect(!CompanionRemote.takesReplies(nil))
    #expect(!CompanionRemote.takesReplies(5))
    #expect(CompanionRemote.takesReplies(6))
  }
}
