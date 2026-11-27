import Foundation
import Testing

@testable import VibeDomain

/// The sidebar's order, pins and groups (#648).
@Suite("Arranging web tabs in the sidebar")
struct BrowserTabArrangementTests {
  /// Tabs `t[0]`…`t[count-1]`, loose, in that order.
  private func make(_ count: Int, ticket: BrowserTabID? = nil) -> (
    BrowserTabArrangement, [BrowserTabID]
  ) {
    let ids = (0..<count).map { _ in BrowserTabID() }
    return (BrowserTabArrangement(entries: ids.map { .init(id: $0) }, ticketID: ticket), ids)
  }

  @Test("A link opened from a loose tab makes a group of the two, named after the opener")
  func openerMakesGroup() throws {
    var (arrangement, t) = make(2)
    let child = BrowserTabID()
    arrangement.insertOpened(child, at: 1, from: t[0], name: "PR #12")

    #expect(arrangement.ids == [t[0], child, t[1]])
    let group = try #require(arrangement.group(of: t[0]))
    #expect(group.name == "PR #12")
    #expect(group.origin == .opener)
    #expect(arrangement.members(of: group.id) == [t[0], child])
    #expect(arrangement.items.map(\.id) == [.group(group.id), .tab(t[1])])
  }

  @Test("Links opened from a grouped tab join its group, at the place #186 gives them")
  func joinsGroup() throws {
    var (arrangement, t) = make(1)
    let a = BrowserTabID()
    let b = BrowserTabID()
    let c = BrowserTabID()
    arrangement.insertOpened(a, at: 1, from: t[0], name: "")
    arrangement.insertOpened(b, at: 2, from: t[0], name: "")
    // Opened from `a`, right after it: inside the group.
    arrangement.insertOpened(c, at: 2, from: a, name: "")

    let group = try #require(arrangement.group(of: t[0]))
    #expect(arrangement.members(of: group.id) == [t[0], a, c, b])
    #expect(arrangement.groups.count == 1)
  }

  @Test("A pinned opener and the ticket gather their links in a group of their own, in order")
  func pinnedOpenerGroup() throws {
    let ticket = BrowserTabID()
    var (arrangement, t) = make(2, ticket: ticket)
    arrangement.move(t[0], to: .pinned(.end))
    let a = BrowserTabID()
    let b = BrowserTabID()
    arrangement.insertOpened(a, at: 1, from: ticket, name: "Ticket")
    arrangement.insertOpened(b, at: 1, from: ticket, name: "Ticket")

    let group = try #require(arrangement.group(of: a))
    #expect(group.origin == .pinnedOpener(ticket))
    #expect(arrangement.members(of: group.id) == [a, b])
    #expect(arrangement.entry(t[0])?.isPinned == true)
    #expect(arrangement.entry(t[0])?.groupID == nil)

    // Down to one tab, the ticket's group stays.
    arrangement.remove(b)
    #expect(arrangement.group(of: a)?.id == group.id)

    // A user-pinned opener's group goes with its pin, once it has one tab.
    let c = BrowserTabID()
    arrangement.insertOpened(c, at: 1, from: t[0], name: "Pinned")
    let pinnedGroup = try #require(arrangement.group(of: c))
    #expect(pinnedGroup.origin == .pinnedOpener(t[0]))
    arrangement.move(t[0], to: .loose(.end))
    #expect(arrangement.group(of: c) == nil)
  }

  @Test("An opener's group left with one tab goes; a user's stays until empty")
  func dissolution() throws {
    var (arrangement, t) = make(2)
    let child = BrowserTabID()
    arrangement.insertOpened(child, at: 1, from: t[0], name: "")
    arrangement.remove(child)
    #expect(arrangement.groups.isEmpty)
    #expect(arrangement.entry(t[0])?.groupID == nil)

    let made = arrangement.newGroup(with: t[1], name: "Mine")
    let group = try #require(made)
    #expect(arrangement.group(of: t[1])?.id == group)
    arrangement.move(t[1], to: .loose(.end))
    #expect(arrangement.groups.isEmpty)
  }

  @Test("Every place a tab is dropped on in the sidebar")
  func dropTable() throws {
    let ticket = BrowserTabID()
    var (arrangement, t) = make(5, ticket: ticket)
    // t0 t1 grouped as G; t2 t3 t4 loose.
    arrangement.insertOpened(BrowserTabID(), at: 1, from: t[0], name: "G")
    let g = try #require(arrangement.group(of: t[0])).id
    arrangement.move(t[1], to: .group(g, .end))
    let extra = arrangement.members(of: g)[1]
    #expect(arrangement.members(of: g) == [t[0], extra, t[1]])

    // On a tab row, before it, in its group.
    arrangement.move(t[3], to: .group(g, .before(extra)))
    #expect(arrangement.members(of: g) == [t[0], t[3], extra, t[1]])

    // On the ticket's row: first pinned.
    arrangement.move(t[4], to: .pinned(.start))
    arrangement.move(t[2], to: .pinned(.start))
    #expect(arrangement.ids.prefix(2) == [t[2], t[4]])
    #expect(arrangement.pinnedCount == 2)

    // Under the list: loose, last.
    arrangement.move(t[3], to: .loose(.end))
    #expect(arrangement.ids.last == t[3])
    #expect(arrangement.entry(t[3])?.groupID == nil)

    // Before a grouped tab, as loose: before the whole group.
    arrangement.move(t[4], to: .loose(.before(t[1])))
    #expect(arrangement.items.map(\.id) == [.tab(t[4]), .group(g), .tab(t[3])])
  }

  @Test("A whole group moves before or after a loose tab or another group")
  func moveGroup() throws {
    var (arrangement, t) = make(4)
    arrangement.insertOpened(BrowserTabID(), at: 1, from: t[0], name: "A")
    arrangement.insertOpened(BrowserTabID(), at: 4, from: t[2], name: "B")
    let a = try #require(arrangement.group(of: t[0])).id
    let b = try #require(arrangement.group(of: t[2])).id
    #expect(arrangement.items.map(\.id) == [.group(a), .tab(t[1]), .group(b), .tab(t[3])])

    arrangement.moveGroup(a, to: .after(t[2]))
    #expect(arrangement.items.map(\.id) == [.tab(t[1]), .group(b), .group(a), .tab(t[3])])
    arrangement.moveGroup(a, to: .end)
    #expect(arrangement.items.map(\.id) == [.tab(t[1]), .group(b), .tab(t[3]), .group(a)])
    arrangement.moveGroup(a, by: -1)
    #expect(arrangement.items.map(\.id) == [.tab(t[1]), .group(b), .group(a), .tab(t[3])])
    #expect(arrangement.canMoveGroup(b, by: -1))
    #expect(!arrangement.canMoveGroup(b, by: -2))
  }

  @Test("Up and down stay among the tabs beside it, and step over a whole group")
  func keyboardMoves() throws {
    var (arrangement, t) = make(3)
    arrangement.insertOpened(BrowserTabID(), at: 2, from: t[1], name: "")
    let g = try #require(arrangement.group(of: t[1])).id
    let child = arrangement.members(of: g)[1]

    #expect(!arrangement.canMove(t[1], by: -1))
    arrangement.move(child, by: -1)
    #expect(arrangement.members(of: g) == [child, t[1]])

    arrangement.move(t[0], by: 1)
    #expect(arrangement.items.map(\.id) == [.group(g), .tab(t[0]), .tab(t[2])])
  }

  @Test("A loose tab opened inside a group's run goes after it")
  func looseInsertKeepsGroupsWhole() throws {
    var (arrangement, t) = make(1)
    arrangement.insertOpened(BrowserTabID(), at: 1, from: t[0], name: "")
    let g = try #require(arrangement.group(of: t[0])).id
    let loose = BrowserTabID()
    arrangement.insert(loose, at: 1)
    #expect(arrangement.items.map(\.id) == [.group(g), .tab(loose)])
  }

  @Test("Scattered, unknown and pinned group tabs are put right, and twice is once")
  func normalize() throws {
    let g = BrowserTabGroup(name: "G", origin: .user)
    let ids = (0..<5).map { _ in BrowserTabID() }
    let arrangement = BrowserTabArrangement(
      entries: [
        .init(id: ids[0], groupID: g.id),
        .init(id: ids[1]),
        .init(id: ids[2], groupID: g.id),
        .init(id: ids[3], isPinned: true, groupID: g.id),
        .init(id: ids[4], groupID: BrowserTabGroupID()),
      ],
      groups: [g, BrowserTabGroup(name: "Empty", origin: .opener)])

    #expect(arrangement.ids == [ids[3], ids[0], ids[2], ids[1], ids[4]])
    #expect(arrangement.entry(ids[3])?.groupID == nil)
    #expect(arrangement.entry(ids[4])?.groupID == nil)
    #expect(arrangement.groups == [g])
    var again = arrangement
    again.normalize()
    #expect(again == arrangement)
  }

  @Test("Groups are kept with the tabs, and an unknown origin reads as the user's")
  func persistence() throws {
    let group = BrowserTabGroup(name: "Docs", isCollapsed: true, origin: .pinnedOpener(BrowserTabID()))
    let tab = BrowserTab(url: URL(string: "https://example.com")!, openedBy: .user, groupID: group.id)
    let state = SessionBrowserState(tabs: [tab], groups: [group])
    let data = try JSONEncoder().encode(state)
    let read = try JSONDecoder().decode(SessionBrowserState.self, from: data)
    #expect(read.groups == [group])
    #expect(read.tabs.first?.groupID == group.id)

    let id = UUID().uuidString
    let later = Data(
      #"{"tabs":[],"groups":[{"id":"\#(id)","name":"X","origin":{"stack":{}}},{"bad":1}]}"#.utf8)
    let lenient = try JSONDecoder().decode(SessionBrowserState.self, from: later)
    #expect(lenient.groups.count == 1)
    #expect(lenient.groups.first?.origin == .user)

    let before648 = Data(#"{"tabs":[],"isVisible":true}"#.utf8)
    #expect(try JSONDecoder().decode(SessionBrowserState.self, from: before648).groups.isEmpty)
  }
}
