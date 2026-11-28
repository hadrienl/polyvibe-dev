import Foundation
import Testing
import VibeDomain

@testable import VibeUI

@Suite("What the sidebar calls a group of web tabs (#666)")
struct BrowserTabGroupNameTests {
  @Test("A group not named yet is « Group N », N its own number; a name shows as it is")
  func shown() {
    #expect(BrowserTabGroupName.shown(BrowserTabGroup(number: 3, origin: .opener)) == "Group 3")
    let named = BrowserTabGroup(
      name: "Polyvibe release", nameSource: .generated, number: 3, origin: .opener)
    #expect(BrowserTabGroupName.shown(named) == "Polyvibe release")
  }

  @Test("VoiceOver hears how many tabs a group holds")
  func count() {
    #expect(BrowserTabGroupName.count(2) == "2 tabs")
    #expect(BrowserTabGroupName.count(1) == "1 tab")
  }
}
