import AppKit
import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeBrowser

/// Tabs opened from a page gather in its group, as Dia does (#648).
@Suite("Grouped web tabs")
@MainActor
struct BrowserTabGroupingTests {
  private let session = SessionID()

  private func page(_ name: String) -> URL {
    URL(string: "data:text/html,<title>\(name)</title><p>\(name)</p>")!
  }

  @Test("Links opened from a page join its group, in the order they were clicked")
  func linksFromAPage() throws {
    _ = NSApplication.shared
    let workspace = BrowserWorkspace()
    let pr = workspace.open(page("pr"), in: session, openedBy: .user)
    let other = workspace.open(page("other"), in: session, openedBy: .user, activate: false)
    browserActivates(pr, in: workspace)
    let links = (0..<10).map {
      workspace.open(page("l\($0)"), in: session, openedBy: .user, activate: false, from: pr.id)
    }
    let browser = workspace.browser(for: session)

    let group = try #require(browser.group(of: pr.id))
    #expect(group.origin == .opener)
    #expect(browser.members(of: group.id).map(\.id) == [pr.id] + links.map(\.id))
    #expect(browser.groups.count == 1)
    #expect(browser.sidebarItems.map(\.id) == [.group(group.id), .tab(other.id)])
  }

  @Test("A terminal's link, a typed address and an agent's page stay in no group")
  func looseOpenings() {
    _ = NSApplication.shared
    let workspace = BrowserWorkspace()
    let first = workspace.open(page("a"), in: session, openedBy: .user)
    workspace.openLink(page("terminal"), in: session)
    workspace.open(page("agent"), in: session, openedBy: .agent)
    let browser = workspace.browser(for: session)
    #expect(browser.groups.isEmpty)
    #expect(browser.tabs.allSatisfy { $0.groupID == nil })
    #expect(browser.tabs.first?.id == first.id)
  }

  @Test("The ticket's links gather in its group, first after the pinned tabs")
  func ticketLinks() async throws {
    _ = NSApplication.shared
    let workspace = BrowserWorkspace()
    let repository = RepositoryWebAddress(forge: .github, host: "github.com", path: "o/r")
    workspace.updateTicket(stored: nil, branch: "feat/12-x", repository: repository, for: session)
    let browser = await workspace.restoredBrowser(for: session)
    let loose = workspace.open(page("loose"), in: session, openedBy: .user)
    let ticket = try #require(browser.ticketTab)

    let first = workspace.open(
      page("ci"), in: session, openedBy: .user, activate: false, from: ticket.id)
    let second = workspace.open(
      page("files"), in: session, openedBy: .user, activate: false, from: ticket.id)

    let group = try #require(browser.group(of: first.id))
    #expect(group.origin == .ticket)
    #expect(browser.tabs.map(\.id) == [first.id, second.id, loose.id])
  }

  @Test("⌃⇥ goes through a collapsed group, and opens it on the tab it turns to")
  func neighboursThroughCollapsedGroups() throws {
    _ = NSApplication.shared
    let workspace = BrowserWorkspace()
    let a = workspace.open(page("a"), in: session, openedBy: .user)
    let child = workspace.open(page("b"), in: session, openedBy: .user, activate: false, from: a.id)
    let browser = workspace.browser(for: session)
    let group = try #require(browser.group(of: a.id))
    browser.setCollapsed(group.id, true)

    browser.activateNeighbour(offset: 1)
    #expect(browser.activeTab?.id == child.id)
    #expect(browser.group(of: child.id)?.isCollapsed == false)
  }

  @Test("An agent turning to a tab of a folded group leaves it folded")
  func agentLeavesFolding() async throws {
    _ = NSApplication.shared
    let workspace = BrowserWorkspace()
    let a = workspace.open(page("a"), in: session, openedBy: .user)
    let child = workspace.open(page("b"), in: session, openedBy: .user, activate: false, from: a.id)
    let browser = workspace.browser(for: session)
    let group = try #require(browser.group(of: a.id))
    browser.setCollapsed(group.id, true)

    _ = await workspace.run(
      tool: "tab_activate", arguments: ["tab": .string(child.id.description)], session: session)
    #expect(browser.activeTab?.id == child.id)
    #expect(browser.group(of: child.id)?.isCollapsed == true)
  }

  @Test("Closing a group closes each of its tabs, and the group goes with them")
  func closeGroup() throws {
    _ = NSApplication.shared
    let workspace = BrowserWorkspace()
    let a = workspace.open(page("a"), in: session, openedBy: .user)
    workspace.open(page("b"), in: session, openedBy: .user, activate: false, from: a.id)
    let kept = workspace.open(page("c"), in: session, openedBy: .user, activate: false)
    let browser = workspace.browser(for: session)
    let group = try #require(browser.group(of: a.id))

    workspace.closeGroup(group.id, in: session)
    #expect(browser.tabs.map(\.id) == [kept.id])
    #expect(browser.groups.isEmpty)
  }

  @Test("Groups, their names and collapsing are kept between launches")
  func keptBetweenLaunches() async throws {
    let store = InMemoryBrowserStateStore()
    let group = BrowserTabGroup(name: "Docs", isCollapsed: true, origin: .user)
    let loose = BrowserTab(url: URL(string: "https://example.com")!, openedBy: .user)
    let one = BrowserTab(url: URL(string: "https://a.dev")!, openedBy: .user, groupID: group.id)
    let two = BrowserTab(url: URL(string: "https://b.dev")!, openedBy: .user, groupID: group.id)
    // Out of order, as a hand-edited file could be: the group comes back whole.
    await store.save(
      SessionBrowserState(tabs: [one, loose, two], groups: [group]), for: session)

    let workspace = BrowserWorkspace(stateStore: store)
    let browser = await workspace.restoredBrowser(for: session)
    #expect(browser.tabs.map(\.id) == [one.id, two.id, loose.id])
    #expect(browser.groups == [group])
    #expect(browser.persisted.groups == [group])
    #expect(browser.persisted.tabs.map(\.groupID) == [group.id, group.id, nil])
  }

  @Test("tabs_list tells the agent the group the user keeps a tab in")
  func listedGroup() async throws {
    _ = NSApplication.shared
    let workspace = BrowserWorkspace()
    let a = workspace.open(URL(string: "about:blank#a")!, in: session, openedBy: .user)
    workspace.open(
      URL(string: "about:blank#b")!, in: session, openedBy: .user, activate: false, from: a.id)
    let browser = workspace.browser(for: session)
    let group = try #require(browser.group(of: a.id))
    browser.renameGroup(group.id, to: "Review")

    let result = await workspace.run(tool: "tabs_list", arguments: [:], session: session)
    guard case .text(let text) = try #require(result.content.first) else {
      Issue.record("No text")
      return
    }
    let tabs = try #require(
      JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
    #expect(tabs.compactMap { ($0["group"] as? [String: Any])?["name"] as? String } == [
      "Review", "Review",
    ])
  }

  private func browserActivates(_ tab: BrowserTabModel, in workspace: BrowserWorkspace) {
    workspace.browser(for: session).activate(tab.id)
  }
}
