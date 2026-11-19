import CompanionCore
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeComposition

/// What the phone is shown of the messages sessions send each other: folded under their author, as
/// on the Mac, while a phone that does not know them still shows the text.
@Suite("The phone's relayed messages")
@MainActor
struct CompanionRelayedMessageTests {
  @Test("Vibe Manager's news and a coordinator's message carry who wrote them")
  func relayed() throws {
    let child = SessionID()
    let news = CoordinationInbox.message(for: [
      CoordinationEvent(childID: child, childName: "V2", kind: .turnEnded, date: .now)
    ])
    let order = CoordinationPolicy.fromCoordinator("Rebase.", coordinatorName: "Plan")
    let entries = CompanionRemoteServer.entries([
      ConversationEntry(id: "n", content: .userPrompt(news, attachments: [])),
      ConversationEntry(id: "c", content: .userPrompt(order, attachments: [])),
      ConversationEntry(id: "u", content: .userPrompt("Fix it", attachments: [])),
    ])
    #expect(
      entries[0].relayed
        == RemoteRelayed(coordinator: nil, children: ["V2"], body: "- **V2** finished its turn\\."))
    #expect(entries[1].relayed == RemoteRelayed(coordinator: "Plan", children: [], body: "Rebase."))
    #expect(entries[2].relayed == nil)
    // The text as before, for a phone that does not read `relayed`.
    #expect(entries[0].kind == .user(news, attachments: []))
  }

  @Test("An entry from a Mac that sends no author reads as before")
  func olderMac() throws {
    let entry = RemoteEntry(id: "u", kind: .user("Hi", attachments: []))
    let data = try JSONEncoder().encode(entry)
    #expect(!String(decoding: data, as: UTF8.self).contains("relayed"))
    #expect(try JSONDecoder().decode(RemoteEntry.self, from: data).relayed == nil)
  }
}
