import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

struct RelayedMessageTests {
  private let childID = SessionID(
    rawValue: UUID(uuidString: "F208D4A6-8093-4464-B141-4D613EE52EC0")!)

  @Test func vibeManagerNewsNameEachChildWithoutItsIdentifier() throws {
    let events = [
      CoordinationEvent(
        childID: childID, childName: "#476 failles actives des connecteurs", kind: .turnEnded,
        date: .now),
      CoordinationEvent(childID: childID, childName: "a*b", kind: .stopped, date: .now),
    ]
    let message = try #require(RelayedMessage(CoordinationInbox.message(for: events)))
    #expect(message.sender == .application)
    #expect(message.children == ["#476 failles actives des connecteurs", "a*b"])
    #expect(
      message.body == """
        - **\\#476 failles actives des connecteurs** finished its turn.
        - **a\\*b** stopped: its agent is no longer running.
        """)
  }

  @Test func oneEvent() throws {
    let wake = CoordinationEvent.wake("is #12 merged?", at: .now)
    let message = try #require(RelayedMessage(CoordinationInbox.message(for: [wake])))
    #expect(message.body == "- Wake-up you asked for: is #12 merged?")
    #expect(message.children.isEmpty)
  }

  @Test func coordinatorMessage() throws {
    let text = CoordinationPolicy.fromCoordinator(
      "Rebase on main.\n\nThen push.", coordinatorName: "V2")
    let message = try #require(RelayedMessage(text))
    #expect(message.sender == .coordinator("V2"))
    #expect(message.body == "Rebase on main.\n\nThen push.")
  }

  @Test func theUsersWordsAreNotRelayed() {
    #expect(RelayedMessage("Fix the tests") == nil)
    #expect(RelayedMessage("[Coordinator] not a mark") == nil)
    #expect(RelayedMessage(CoordinatorInstructions.turnedOn + "\n\nPlan milestone V2") == nil)
  }
}
