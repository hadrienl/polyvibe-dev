import Foundation
import Testing

@testable import VibeDomain

@Suite("The name of a web tab group (#666)")
struct BrowserTabGroupNameRuleTests {
  @Test("A name is due at two tabs, once more at four, and never once the user named the group")
  func due() {
    var group = BrowserTabGroup(origin: .opener)
    #expect(!group.needsTitle(count: 1))
    #expect(group.needsTitle(count: 2))
    group.titledAtCount = 2
    #expect(!group.needsTitle(count: 3))
    #expect(group.needsTitle(count: 4))
    group.titledAtCount = 4
    #expect(!group.needsTitle(count: 6))

    let made = BrowserTabGroup(origin: .user)
    var arrangement = BrowserTabArrangement(
      entries: [.init(id: BrowserTabID(), groupID: made.id)], groups: [made])
    let id = made.id
    arrangement.rename(id, to: "Mine")
    #expect(!arrangement.groups[0].needsTitle(count: 2))
    #expect(arrangement.groups[0].nameSource == .user)
    // Emptied by the user: « Group N » again, and still no name made for it.
    arrangement.rename(id, to: "  ")
    #expect(arrangement.groups[0].nameSource == .placeholder)
    #expect(!arrangement.groups[0].needsTitle(count: 4))
  }

  @Test("A made name is trimmed, at most 32 characters, and never one of the tabs' titles")
  func accepted() {
    let tabs = ["Pull request #664", "Checks"]
    #expect(BrowserTabGroup.acceptedTitle(" «Polyvibe release» ", tabTitles: tabs) == "Polyvibe release")
    #expect(BrowserTabGroup.acceptedTitle("checks", tabTitles: tabs) == nil)
    #expect(BrowserTabGroup.acceptedTitle("voice model update", tabTitles: tabs) == "Voice model update")
    #expect(BrowserTabGroup.acceptedTitle("", tabTitles: tabs) == nil)
    #expect(BrowserTabGroup.acceptedTitle(nil, tabTitles: tabs) == nil)
    #expect(BrowserTabGroup.acceptedTitle(String(repeating: "a", count: 33), tabTitles: []) == nil)
    #expect(BrowserTabGroup.acceptedTitle(String(repeating: "a", count: 32), tabTitles: []) != nil)
  }

  @Test("A group written before #666 keeps its name as the user's, and has no number yet")
  func legacy() throws {
    let id = UUID()
    let json = #"{"id":"\#(id.uuidString)","name":"[Apps] Lot F","isCollapsed":false,"origin":{"opener":{}}}"#
    let group = try JSONDecoder().decode(BrowserTabGroup.self, from: Data(json.utf8))
    #expect(group.name == "[Apps] Lot F")
    #expect(group.nameSource == .user)
    #expect(group.number == 0)
    #expect(!group.needsTitle(count: 4))
    let unnamed = #"{"id":"\#(id.uuidString)","name":"","origin":{"user":{}}}"#
    let placeholder = try JSONDecoder().decode(BrowserTabGroup.self, from: Data(unnamed.utf8))
    #expect(placeholder.nameSource == .placeholder)
    #expect(placeholder.displayName == "Group 0")
  }
}
