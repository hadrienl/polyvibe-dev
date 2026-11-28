import Foundation
import Observation
import VibeApplication
import VibeDomain

/// One session's web view: its tabs, the ticket's pinned tab, the one in front, and what agents did
/// there (#69).
@MainActor
@Observable
public final class SessionBrowser {
  public let sessionID: SessionID
  /// The tabs after the ticket's, in the order shown: the pinned ones first (#536).
  public private(set) var tabs: [BrowserTabModel] = []
  /// The ticket's tab, first and pinned, when the session has a ticket.
  public private(set) var ticketTab: BrowserTabModel?
  public private(set) var ticket: TicketResolution.Resolved?
  /// `nil` puts the ticket's tab in front.
  public private(set) var activeTabID: BrowserTabID?
  public private(set) var isVisible = false
  public private(set) var actionLog = BrowserActionLog()
  /// Agent actions recorded since the trace was last looked at: the badge on its button.
  public private(set) var unseenActionCount = 0
  /// Tabs opened behind — a link ⇧⌘-clicked in a page (#186), an agent’s page — since the user last
  /// looked at the list of tabs (#536): the tab button says so, the list hiding them.
  public private(set) var unseenTabIDs: Set<BrowserTabID> = []
  /// An agent opened a page while the session was not on screen: its row says so.
  public internal(set) var hasUnseenAgentPage = false
  /// Whether what was kept has been read back yet.
  public internal(set) var isRestored = false
  /// The sites away from this Mac the user let this session's agent read (#239), by
  /// `BrowserOrigin.grantKey`. Kept for this run only: a relaunch asks again. Shown in the trace,
  /// where the user takes one back (#288).
  public private(set) var readableSites: Set<String> = []
  /// The sites the user refused to let this session's agent read: not asked again this session,
  /// so that an agent cannot ask until the user gives in — unless the user takes it back (#288).
  public private(set) var refusedSites: Set<String> = []
  /// The groups of the sidebar (#648), kept with the tabs.
  public private(set) var groups: [BrowserTabGroup] = []

  @ObservationIgnored var stateDidChange: (@MainActor () -> Void)?
  @ObservationIgnored var logDidChange: (@MainActor () -> Void)?

  init(sessionID: SessionID) {
    self.sessionID = sessionID
  }

  /// Every tab, the ticket's first.
  public var allTabs: [BrowserTabModel] {
    (ticketTab.map { [$0] } ?? []) + tabs
  }

  public var activeTab: BrowserTabModel? {
    guard let activeTabID else { return ticketTab ?? tabs.first }
    return tabs.first { $0.id == activeTabID } ?? ticketTab ?? tabs.first
  }

  public func tab(_ id: BrowserTabID) -> BrowserTabModel? {
    allTabs.first { $0.id == id }
  }

  /// How many tabs the user pinned: the first ones of `tabs`.
  public var pinnedCount: Int {
    tabs.prefix { $0.isPinned }.count
  }

  /// A tab named by an agent: its short id, or its whole identifier.
  func tab(named name: String) -> BrowserTabModel? {
    let name = name.trimmingCharacters(in: .whitespaces).lowercased()
    guard !name.isEmpty else { return nil }
    return allTabs.first {
      $0.id.description == name || $0.id.rawValue.uuidString.lowercased() == name
    }
  }

  var persisted: SessionBrowserState {
    SessionBrowserState(
      tabs: tabs.map(\.persisted),
      activeTabID: activeTabID.flatMap { id in tabs.contains { $0.id == id } ? id : nil },
      isVisible: isVisible, groups: groups)
  }

  // MARK: - Arrangement (#648)

  /// The order, pins and groups of `tabs`, as rules of their own.
  public var arrangement: BrowserTabArrangement {
    BrowserTabArrangement(
      entries: tabs.map { .init(id: $0.id, isPinned: $0.isPinned, groupID: $0.groupID) },
      groups: groups, ticketID: ticketTab?.id)
  }

  /// The loose tabs and the groups under the pinned group, in order.
  public var sidebarItems: [BrowserTabArrangement.Item] {
    arrangement.items
  }

  public func group(of id: BrowserTabID) -> BrowserTabGroup? {
    tab(id)?.groupID.flatMap { groupID in groups.first { $0.id == groupID } }
  }

  /// Changes the arrangement, then puts the tabs in its order. `adding`: a tab not yet among them.
  private func arrange(
    adding added: BrowserTabModel? = nil, _ change: (inout BrowserTabArrangement) -> Void
  ) {
    var arrangement = self.arrangement
    change(&arrangement)
    var pool = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
    if let added { pool[added.id] = added }
    tabs = arrangement.entries.compactMap { entry in
      guard let tab = pool[entry.id] else { return nil }
      if tab.isPinned != entry.isPinned { tab.isPinned = entry.isPinned }
      if tab.groupID != entry.groupID { tab.groupID = entry.groupID }
      return tab
    }
    if groups != arrangement.groups { groups = arrangement.groups }
  }

  // MARK: - Changes

  func restore(
    _ state: SessionBrowserState, records: [BrowserActionRecord],
    make: (BrowserTab) -> BrowserTabModel
  ) {
    // Whatever was opened before the file was read stays, after what was kept.
    let opened = tabs
    tabs = state.tabs.map(make) + opened
    groups = state.groups + groups
    // Pinned first and groups whole, whatever the file said (#536, #648).
    arrange { _ in }
    if activeTabID == nil {
      activeTabID = state.activeTabID
      // In front only because no tab was: sent behind by the one kept, it has not been seen.
      for tab in opened where tab.id != activeTab?.id { unseenTabIDs.insert(tab.id) }
    }
    if !isVisible { isVisible = state.isVisible }
    actionLog = BrowserActionLog(records: records + actionLog.records)
    isRestored = true
  }

  /// A new tab after `anchor`, and after the tabs `anchor` opened before it since the user last
  /// turned to a tab: three links ⇧⌘-clicked in a page line up in the order they were clicked (#186).
  /// `opener`: the tab whose page opened it — a link, a window — which it joins the group of
  /// (#648); the ticket's tab, which is no anchor, gathers its own. Without one — a terminal's link,
  /// an agent's page — the tab is only placed after `anchor`, in no group.
  func append(
    _ tab: BrowserTabModel, activate: Bool, after anchor: BrowserTabID? = nil,
    opener: BrowserTabID? = nil
  ) {
    var position = tabs.count
    if let anchor, let index = tabs.firstIndex(where: { $0.id == anchor }) {
      // Opened from a pinned tab, it goes first among the others: it is not pinned itself.
      position = max(index + 1, pinnedCount)
      while position < tabs.count, tabs[position].openerID == anchor { position += 1 }
      if opener != nil { tab.openerID = anchor }
    } else if opener != nil, opener == ticketTab?.id {
      // The ticket's links, right after the pinned group: the ticket heads it.
      position = pinnedCount
    }
    arrange(adding: tab) { arrangement in
      if let opener, let from = self.tab(opener) {
        arrangement.insertOpened(tab.id, at: position, from: opener, name: from.displayTitle)
      } else {
        arrangement.insert(tab.id, at: position)
      }
    }
    if activate {
      activeTabID = tab.id
    } else if activeTab?.id != tab.id {
      // The first of a web view with no tab in front is shown all the same.
      unseenTabIDs.insert(tab.id)
    }
    stateDidChange?()
  }

  func remove(_ id: BrowserTabID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let removed = tabs[index]
    arrange { $0.remove(id) }
    removed.discard()
    unseenTabIDs.remove(id)
    if activeTabID == id {
      // The neighbour on the right, as browsers do, else the one on the left, else the ticket.
      activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
    }
    // The tab brought forward is seen.
    if let shown = activeTab?.id { unseenTabIDs.remove(shown) }
    stateDidChange?()
  }

  /// `byUser`: the user turned to the tab — a click, ⌃⇥ — and its folded group opens on it. An
  /// agent turning to it leaves the user's folding as it was: groups are the user's (#648).
  public func activate(_ id: BrowserTabID, byUser: Bool = true) {
    guard tab(id) != nil else { return }
    // Turning to a tab ends the run of tabs opened from the one before: the next ones line up
    // after their opener again.
    for tab in tabs { tab.openerID = nil }
    unseenTabIDs.remove(id)
    // The tab the user turned to is a row the sidebar shows (#648).
    if byUser, let groupID = tab(id)?.groupID { arrange { $0.setCollapsed(groupID, false) } }
    activeTabID = ticketTab?.id == id ? nil : id
    stateDidChange?()
  }

  /// Pins a tab, last of the pinned ones, or unpins it, first of the others (#536).
  public func setPinned(_ id: BrowserTabID, _ isPinned: Bool) {
    guard let tab = tabs.first(where: { $0.id == id }), tab.isPinned != isPinned else { return }
    move(id, to: isPinned ? .pinned(.end) : .loose(.start))
  }

  /// Moves a tab where it was dropped: before or after `target`, in `target`'s group, pinned when
  /// `target` is (#536, #648). Dropped on the ticket's, it becomes the first pinned tab.
  public func move(_ id: BrowserTabID, nextTo target: BrowserTabID, after: Bool) {
    guard id != target, tabs.contains(where: { $0.id == id }) else { return }
    if target == ticketTab?.id {
      move(id, to: .pinned(.start))
      return
    }
    guard let anchor = tabs.first(where: { $0.id == target }) else { return }
    let place: BrowserTabArrangement.Place = after ? .after(target) : .before(target)
    if anchor.isPinned {
      move(id, to: .pinned(place))
    } else if let groupID = anchor.groupID {
      move(id, to: .group(groupID, place))
    } else {
      move(id, to: .loose(place))
    }
  }

  public func move(_ id: BrowserTabID, to destination: BrowserTabArrangement.Destination) {
    arrange { $0.move(id, to: destination) }
    stateDidChange?()
  }

  /// Moves a tab one place up (`-1`) or down (`1`) among the pinned tabs, the tabs of its group,
  /// or the loose tabs and groups: the keyboard's and VoiceOver's way to do what dragging it does
  /// (#230).
  public func moveTab(_ id: BrowserTabID, by offset: Int) {
    guard canMoveTab(id, by: offset) else { return }
    arrange { $0.move(id, by: offset) }
    stateDidChange?()
  }

  /// Whether `moveTab(_:by:)` has somewhere to go.
  public func canMoveTab(_ id: BrowserTabID, by offset: Int) -> Bool {
    arrangement.canMove(id, by: offset)
  }

  // MARK: - Groups (#648)

  public func moveGroup(_ id: BrowserTabGroupID, to place: BrowserTabArrangement.Place) {
    arrange { $0.moveGroup(id, to: place) }
    stateDidChange?()
  }

  public func moveGroup(_ id: BrowserTabGroupID, by offset: Int) {
    guard canMoveGroup(id, by: offset) else { return }
    arrange { $0.moveGroup(id, by: offset) }
    stateDidChange?()
  }

  public func canMoveGroup(_ id: BrowserTabGroupID, by offset: Int) -> Bool {
    arrangement.canMoveGroup(id, by: offset)
  }

  /// A group of the user's with the tab, named after it.
  public func newGroup(with id: BrowserTabID) {
    guard let tab = tabs.first(where: { $0.id == id }) else { return }
    arrange { $0.newGroup(with: id, name: tab.displayTitle) }
    stateDidChange?()
  }

  /// An empty name gives the group back the one the sidebar makes up.
  public func renameGroup(_ id: BrowserTabGroupID, to name: String) {
    arrange { $0.rename(id, to: name) }
    stateDidChange?()
  }

  public func setCollapsed(_ id: BrowserTabGroupID, _ isCollapsed: Bool) {
    arrange { $0.setCollapsed(id, isCollapsed) }
    stateDidChange?()
  }

  public func dissolveGroup(_ id: BrowserTabGroupID) {
    arrange { $0.dissolve(id) }
    stateDidChange?()
  }

  /// Out of its group, right after it.
  public func removeFromGroup(_ id: BrowserTabID) {
    guard let groupID = tab(id)?.groupID,
      let last = tabs.last(where: { $0.groupID == groupID && $0.id != id })
    else {
      move(id, to: .loose(.end))
      return
    }
    move(id, to: .loose(.after(last.id)))
  }

  public func members(of id: BrowserTabGroupID) -> [BrowserTabModel] {
    tabs.filter { $0.groupID == id }
  }

  /// The tab after, or before, the one in front, around the ends.
  public func activateNeighbour(offset: Int) {
    let all = allTabs
    guard !all.isEmpty else { return }
    let current = activeTab.flatMap { tab in all.firstIndex { $0.id == tab.id } } ?? 0
    let next = (current + offset % all.count + all.count) % all.count
    activate(all[next].id)
  }

  func setVisible(_ isVisible: Bool) {
    guard self.isVisible != isVisible else { return }
    self.isVisible = isVisible
    stateDidChange?()
  }

  func setTicket(_ ticket: TicketResolution.Resolved?, make: (URL) -> BrowserTabModel) {
    guard ticket != self.ticket else { return }
    let wasInFront = activeTabID == nil
    self.ticket = ticket
    guard let ticket else {
      ticketTab?.discard()
      ticketTab = nil
      return
    }
    if let ticketTab {
      if ticketTab.url != ticket.url { ticketTab.load(ticket.url) }
    } else {
      ticketTab = make(ticket.url)
      // A session that had its own tab in front keeps it there.
      if !wasInFront { return }
    }
  }

  func allowReading(_ site: String) {
    readableSites.insert(site)
    refusedSites.remove(site)
  }

  /// The latest answer wins: a site is never both readable and refused.
  func refuseReading(_ site: String) {
    readableSites.remove(site)
    refusedSites.insert(site)
  }

  /// The user took back what they answered for a site: the next read asks again (#288).
  func forgetReading(_ site: String) {
    readableSites.remove(site)
    refusedSites.remove(site)
  }

  func forgetReadableSites() {
    readableSites = []
    refusedSites = []
  }

  func record(_ record: BrowserActionRecord, isRead: Bool) {
    actionLog.append(record, isRead: isRead)
    unseenActionCount += 1
    logDidChange?()
  }

  /// The list of tabs was opened: every tab is seen.
  public func markTabsSeen() {
    if !unseenTabIDs.isEmpty { unseenTabIDs.removeAll() }
  }

  public func markTraceSeen() {
    unseenActionCount = 0
  }

  func clearTrace() {
    actionLog.clear()
    unseenActionCount = 0
    logDidChange?()
  }

  func discardAll() {
    for tab in allTabs { tab.discard() }
  }
}
