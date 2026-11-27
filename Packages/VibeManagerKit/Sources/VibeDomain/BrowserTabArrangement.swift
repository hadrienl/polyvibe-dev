import Foundation

/// How a session's tabs are arranged in the sidebar (#648): their order, which are pinned, and
/// their groups. The ticket's tab is not among them: it heads the pinned group on its own.
///
/// One array gives the order; a group is a label on a run of its tabs. After every change:
/// - the pinned tabs come first, and are in no group;
/// - the tabs of a group follow one another, where its first one was;
/// - every group named by a tab exists, and a group with too few tabs goes (`BrowserTabGroup.Origin`).
/// So the order of `entries` is the order the sidebar shows, and the one ⌃⇥ follows.
public struct BrowserTabArrangement: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public let id: BrowserTabID
    public var isPinned: Bool
    public var groupID: BrowserTabGroupID?

    public init(id: BrowserTabID, isPinned: Bool = false, groupID: BrowserTabGroupID? = nil) {
      self.id = id
      self.isPinned = isPinned
      self.groupID = groupID
    }
  }

  /// A place next to a tab, or at either end of where a tab goes.
  public enum Place: Equatable, Sendable {
    case start
    case before(BrowserTabID)
    case after(BrowserTabID)
    case end
  }

  /// Where a tab goes.
  public enum Destination: Equatable, Sendable {
    /// In the pinned group. `.start` is right after the ticket's tab.
    case pinned(Place)
    /// In a group, next to one of its tabs, or at either end of it.
    case group(BrowserTabGroupID, Place)
    /// In no group: next to a loose tab or a whole group (named by any of its tabs).
    case loose(Place)
  }

  /// What the sidebar shows under the pinned group, in order.
  public enum Item: Equatable, Sendable, Identifiable {
    case group(BrowserTabGroup, [BrowserTabID])
    case tab(BrowserTabID)

    public var id: ItemID {
      switch self {
      case .group(let group, _): .group(group.id)
      case .tab(let id): .tab(id)
      }
    }
  }

  public enum ItemID: Hashable, Sendable {
    case group(BrowserTabGroupID)
    case tab(BrowserTabID)
  }

  public private(set) var entries: [Entry]
  public private(set) var groups: [BrowserTabGroup]
  /// The ticket's tab, whose links gather in the `.ticket` group.
  public var ticketID: BrowserTabID?

  public init(
    entries: [Entry] = [], groups: [BrowserTabGroup] = [], ticketID: BrowserTabID? = nil
  ) {
    self.entries = entries
    self.groups = groups
    self.ticketID = ticketID
    normalize()
  }

  // MARK: - Reading

  public var ids: [BrowserTabID] { entries.map(\.id) }

  public var pinnedCount: Int { entries.prefix { $0.isPinned }.count }

  public func entry(_ id: BrowserTabID) -> Entry? {
    entries.first { $0.id == id }
  }

  public func group(_ id: BrowserTabGroupID) -> BrowserTabGroup? {
    groups.first { $0.id == id }
  }

  public func group(of id: BrowserTabID) -> BrowserTabGroup? {
    entry(id)?.groupID.flatMap(group)
  }

  public func members(of group: BrowserTabGroupID) -> [BrowserTabID] {
    entries.filter { $0.groupID == group }.map(\.id)
  }

  public var items: [Item] {
    var items: [Item] = []
    for entry in entries.dropFirst(pinnedCount) {
      if let groupID = entry.groupID, let group = group(groupID) {
        if case .group(let last, _) = items.last, last.id == groupID { continue }
        items.append(.group(group, members(of: groupID)))
      } else {
        items.append(.tab(entry.id))
      }
    }
    return items
  }

  // MARK: - Opening

  /// A tab opened in no group, at `position` among the tabs: kept out of the pinned tabs, and out
  /// of a group it would split — after it.
  public mutating func insert(_ id: BrowserTabID, at position: Int) {
    let position = min(max(position, pinnedCount), entries.count)
    entries.insert(Entry(id: id), at: position)
    normalize(placingAfterGroups: id)
  }

  /// A tab a page opened (#648): in its opener's group, at `position` — after the opener and the
  /// tabs it opened before (#186). An opener in no group makes one with it, named `name`; a pinned
  /// opener, or the ticket's tab, gathers its links in a group of their own, after which they line
  /// up in the order they were opened.
  public mutating func insertOpened(
    _ id: BrowserTabID, at position: Int, from opener: BrowserTabID, name: String
  ) {
    let position = min(max(position, pinnedCount), entries.count)
    if let index = entries.firstIndex(where: { $0.id == opener }), !entries[index].isPinned {
      let groupID: BrowserTabGroupID
      if let existing = entries[index].groupID {
        groupID = existing
      } else {
        let group = BrowserTabGroup(name: name, origin: .opener)
        groups.append(group)
        entries[index].groupID = group.id
        groupID = group.id
      }
      entries.insert(Entry(id: id, groupID: groupID), at: position)
    } else if let group = groups.first(where: { $0.origin == pinnedOrigin(of: opener) }),
      let last = entries.lastIndex(where: { $0.groupID == group.id })
    {
      entries.insert(Entry(id: id, groupID: group.id), at: last + 1)
    } else {
      let group = BrowserTabGroup(name: name, origin: pinnedOrigin(of: opener))
      groups.append(group)
      entries.insert(Entry(id: id, groupID: group.id), at: position)
    }
    normalize()
  }

  private func pinnedOrigin(of opener: BrowserTabID) -> BrowserTabGroup.Origin {
    opener == ticketID ? .ticket : .pinnedOpener(opener)
  }

  // MARK: - Moving

  public mutating func move(_ id: BrowserTabID, to destination: Destination) {
    guard let from = entries.firstIndex(where: { $0.id == id }) else { return }
    var entry = entries.remove(at: from)
    let index: Int
    switch destination {
    case .pinned(let place):
      entry.isPinned = true
      entry.groupID = nil
      let pinned = pinnedCount
      index = self.index(of: place, within: 0..<pinned, item: false) ?? pinned
    case .group(let groupID, let place):
      guard group(groupID) != nil else {
        entries.insert(entry, at: from)
        return
      }
      entry.isPinned = false
      entry.groupID = groupID
      let members = entries.indices.filter { entries[$0].groupID == groupID }
      if let first = members.first, let last = members.last {
        index = self.index(of: place, within: first..<(last + 1), item: false) ?? last + 1
      } else {
        // Its only tab, dropped on it: where it was.
        index = min(max(from, pinnedCount), entries.count)
      }
    case .loose(let place):
      entry.isPinned = false
      entry.groupID = nil
      index = self.index(of: place, within: pinnedCount..<entries.count, item: true) ?? entries.count
    }
    entries.insert(entry, at: index)
    normalize()
  }

  /// Moves a whole group before or after the item a tab is in, among the unpinned items.
  public mutating func moveGroup(_ groupID: BrowserTabGroupID, to place: Place) {
    if case .before(let target) = place, entry(target)?.groupID == groupID { return }
    if case .after(let target) = place, entry(target)?.groupID == groupID { return }
    let moved = entries.filter { $0.groupID == groupID }
    guard !moved.isEmpty else { return }
    entries.removeAll { $0.groupID == groupID }
    let index =
      self.index(of: place, within: pinnedCount..<entries.count, item: true) ?? entries.count
    entries.insert(contentsOf: moved, at: index)
    normalize()
  }

  /// One place up (`-1`) or down (`1`) among what is beside it — the pinned tabs, the tabs of its
  /// group, or the loose tabs and groups: what the keyboard and VoiceOver do instead of dragging.
  public mutating func move(_ id: BrowserTabID, by offset: Int) {
    guard let target = neighbour(of: id, by: offset), let entry = entry(id) else { return }
    let place: Place = offset < 0 ? .before(target) : .after(target)
    if entry.isPinned {
      move(id, to: .pinned(place))
    } else if let groupID = entry.groupID {
      move(id, to: .group(groupID, place))
    } else {
      move(id, to: .loose(place))
    }
  }

  public func canMove(_ id: BrowserTabID, by offset: Int) -> Bool {
    neighbour(of: id, by: offset) != nil
  }

  /// A group one item up or down among the loose tabs and groups.
  public mutating func moveGroup(_ groupID: BrowserTabGroupID, by offset: Int) {
    guard let target = neighbour(of: .group(groupID), by: offset) else { return }
    moveGroup(groupID, to: offset < 0 ? .before(target) : .after(target))
  }

  public func canMoveGroup(_ groupID: BrowserTabGroupID, by offset: Int) -> Bool {
    neighbour(of: .group(groupID), by: offset) != nil
  }

  // MARK: - Groups

  /// A group of the user's with the tab, where the tab was — after the pinned tabs if it was one.
  @discardableResult
  public mutating func newGroup(with id: BrowserTabID, name: String) -> BrowserTabGroupID? {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
    let group = BrowserTabGroup(name: name, origin: .user)
    groups.append(group)
    if entries[index].isPinned {
      var entry = entries.remove(at: index)
      entry.isPinned = false
      entry.groupID = group.id
      entries.insert(entry, at: pinnedCount)
    } else {
      entries[index].groupID = group.id
      // Out of the group it was in: after it, rather than splitting it.
      let id = entries[index].id
      normalize(placingAfterGroups: id)
      return group.id
    }
    normalize()
    return group.id
  }

  public mutating func rename(_ id: BrowserTabGroupID, to name: String) {
    guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
    groups[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public mutating func setCollapsed(_ id: BrowserTabGroupID, _ isCollapsed: Bool) {
    guard let index = groups.firstIndex(where: { $0.id == id }),
      groups[index].isCollapsed != isCollapsed
    else { return }
    groups[index].isCollapsed = isCollapsed
  }

  /// The group goes; its tabs stay where they are, in no group.
  public mutating func dissolve(_ id: BrowserTabGroupID) {
    groups.removeAll { $0.id == id }
    normalize()
  }

  public mutating func remove(_ id: BrowserTabID) {
    entries.removeAll { $0.id == id }
    normalize()
  }

  // MARK: - Rules

  /// Puts back what every change keeps true: see the type's comment.
  public mutating func normalize() {
    normalize(placingAfterGroups: nil)
  }

  /// `loose`: a tab in no group that may have landed inside a group's run — it goes after it.
  private mutating func normalize(placingAfterGroups loose: BrowserTabID?) {
    let known = Set(groups.map(\.id))
    var pinned: [Entry] = []
    var others: [Entry] = []
    for var entry in entries {
      if entry.isPinned {
        entry.groupID = nil
        pinned.append(entry)
      } else {
        if let groupID = entry.groupID, !known.contains(groupID) { entry.groupID = nil }
        others.append(entry)
      }
    }
    // A loose tab dropped inside a group's run goes after that run, rather than split it.
    if let loose, let index = others.firstIndex(where: { $0.id == loose }),
      others[index].groupID == nil, index > 0, let groupID = others[index - 1].groupID,
      let last = others.lastIndex(where: { $0.groupID == groupID }), last > index
    {
      let entry = others.remove(at: index)
      others.insert(entry, at: last)
    }
    // The tabs of a group gathered where its first one is, in their order.
    var gathered: [Entry] = []
    var placed: Set<BrowserTabGroupID> = []
    for entry in others {
      if let groupID = entry.groupID {
        guard placed.insert(groupID).inserted else { continue }
        gathered.append(contentsOf: others.filter { $0.groupID == groupID })
      } else {
        gathered.append(entry)
      }
    }
    entries = pinned + gathered

    // Groups with too few tabs go.
    let pinnedIDs = Set(pinned.map(\.id))
    var counts: [BrowserTabGroupID: Int] = [:]
    for entry in entries { if let groupID = entry.groupID { counts[groupID, default: 0] += 1 } }
    let kept = groups.filter { group in
      let count = counts[group.id] ?? 0
      switch group.origin {
      case .opener:
        return count >= 2
      case .pinnedOpener(let opener):
        return count >= (pinnedIDs.contains(opener) ? 1 : 2)
      case .ticket, .user:
        return count >= 1
      }
    }
    if kept.count != groups.count {
      groups = kept
      let left = Set(kept.map(\.id))
      for index in entries.indices {
        if let groupID = entries[index].groupID, !left.contains(groupID) {
          entries[index].groupID = nil
        }
      }
    }
  }

  /// Where `place` falls within `range`. `item`: next to a tab is next to its whole group.
  private func index(of place: Place, within range: Range<Int>, item: Bool) -> Int? {
    switch place {
    case .start:
      return range.lowerBound
    case .end:
      return range.upperBound
    case .before(let target), .after(let target):
      guard var index = entries.firstIndex(where: { $0.id == target }), range.contains(index)
      else { return nil }
      let isAfter = if case .after = place { true } else { false }
      if item, let groupID = entries[index].groupID {
        let run = entries.indices.filter { entries[$0].groupID == groupID }
        index = (isAfter ? run.last : run.first) ?? index
      }
      return isAfter ? index + 1 : index
    }
  }

  /// The tab next to `id` among what is beside it, `offset` places away, or `nil` past the end.
  private func neighbour(of id: BrowserTabID, by offset: Int) -> BrowserTabID? {
    guard let entry = entry(id) else { return nil }
    if entry.isPinned || entry.groupID != nil {
      let siblings = entries.filter { $0.isPinned == entry.isPinned && $0.groupID == entry.groupID }
      guard let index = siblings.firstIndex(where: { $0.id == id }),
        siblings.indices.contains(index + offset), offset != 0
      else { return nil }
      return siblings[index + offset].id
    }
    return neighbour(of: .tab(id), by: offset)
  }

  /// A tab of the item `offset` items away from `item`, among the loose tabs and groups.
  private func neighbour(of item: ItemID, by offset: Int) -> BrowserTabID? {
    let items = self.items
    guard offset != 0, let index = items.firstIndex(where: { $0.id == item }),
      items.indices.contains(index + offset)
    else { return nil }
    switch items[index + offset] {
    case .tab(let id): return id
    case .group(_, let members): return offset < 0 ? members.first : members.last
    }
  }
}
