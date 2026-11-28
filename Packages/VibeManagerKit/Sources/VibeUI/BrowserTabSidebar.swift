import AppKit
import SwiftUI
import VibeBrowser
import VibeConversationUI
import VibeDomain

// The session's tabs in a sidebar over the page (#648, ADR 0049): the pinned group, then the
// groups and loose tabs, as Dia shows them. It opens from the button left of the address bar, on
// 80 % of the web view, and closes once a tab is chosen.

/// Left of the address bar: shows or hides the tabs, and how many there are.
struct BrowserTabSidebarButton: View {
  let model: AppModel
  let browser: SessionBrowser

  var body: some View {
    Button {
      model.toggleTabSidebar()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "sidebar.left")
        // Lit while tabs opened behind wait to be seen (#186): the sidebar hides them.
        Text(verbatim: "\(browser.allTabs.count)")
          .font(.caption2.weight(.semibold))
          .monospacedDigit()
          .contentTransition(.numericText())
          .foregroundStyle(hasUnseenTabs ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(
            Capsule().fill(hasUnseenTabs ? Color.accentColor : Color.primary.opacity(0.08)))
        // An agent acting in a tab behind: seen without opening the sidebar.
        if isAgentActingBehind {
          Image(systemName: "sparkle")
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 6)
      .frame(height: 24)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(
            model.isTabSidebarShown
              ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .instantTooltip(
      model.isTabSidebarShown
        ? Text("Hide Tabs", bundle: .module, comment: "Hides the web view's sidebar of tabs.")
        : Text(
          "Show Tabs (⇧⌘S)", bundle: .module,
          comment: "Shows the web view's sidebar of tabs; ⇧⌘S is its shortcut."))
    .accessibilityLabel(Text("Tabs", bundle: .module))
    .accessibilityValue(Text(verbatim: "\(browser.allTabs.count)"))
    .accessibilityAddTraits(model.isTabSidebarShown ? .isSelected : [])
  }

  private var hasUnseenTabs: Bool { !browser.unseenTabIDs.isEmpty }

  private var isAgentActingBehind: Bool {
    browser.allTabs.contains { $0.isAgentActing && $0.id != browser.activeTab?.id }
  }
}

/// The sidebar over the page, on 80 % of the web view's width, and a veil over the rest.
struct BrowserTabSidebarOverlay: View {
  let model: AppModel
  let workspace: BrowserWorkspace
  let browser: SessionBrowser
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static func width(in available: CGFloat) -> CGFloat {
    max(available * 0.8, min(260, available))
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        if model.isTabSidebarShown {
          Color.black.opacity(0.18)
            .contentShape(Rectangle())
            .onTapGesture { model.closeTabSidebar() }
            .accessibilityHidden(true)
            .transition(.opacity)
          BrowserTabSidebar(model: model, workspace: workspace, browser: browser)
            .frame(width: Self.width(in: proxy.size.width))
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)
            // Alone in an overlay, a Divider lies flat across the middle: in an HStack it
            // stands up as the sidebar's edge.
            .overlay(alignment: .trailing) { HStack(spacing: 0) { Divider() } }
            .shadow(color: .black.opacity(0.2), radius: 12, x: 4)
            .transition(.move(edge: .leading))
        }
      }
      .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.isTabSidebarShown)
    }
  }
}

/// A row of the sidebar the keyboard can be on.
private enum SidebarRow: Hashable {
  case tab(BrowserTabID)
  case group(BrowserTabGroupID)
}

/// What is dragged in the sidebar.
private enum SidebarDragged: Equatable {
  case tab(BrowserTabID)
  case group(BrowserTabGroupID)
}

/// What a dragged row is over.
private enum SidebarTarget: Hashable {
  case pinned
  case tab(BrowserTabID)
  case group(BrowserTabGroupID)
  /// Below every row.
  case end
}

/// Where a dragged row would land on its target.
private struct SidebarMark: Equatable {
  enum Place: Equatable {
    case before
    case after
    case into
  }

  let target: SidebarTarget
  let place: Place
}

/// What a group carries while it is dragged: a prefix no drop on a session takes for text (#42).
enum BrowserTabGroupDrag {
  static let prefix = "vibe-manager-browser-group:"

  static func text(for id: BrowserTabGroupID) -> String {
    prefix + id.rawValue.uuidString
  }

  static func isGroup(_ text: String) -> Bool {
    text.hasPrefix(prefix)
  }
}

struct BrowserTabSidebar: View {
  let model: AppModel
  let workspace: BrowserWorkspace
  let browser: SessionBrowser
  @State private var highlighted: SidebarRow?
  @State private var dragged: SidebarDragged?
  @State private var mark: SidebarMark?
  @State private var renaming: BrowserTabGroupID?
  @FocusState private var hasKeyboard: Bool

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            pinnedGroup
            let spaced = tabsAfterBlocks
            ForEach(browser.sidebarItems) { item in
              switch item {
              case .group(let group, let ids):
                groupSection(group, tabs: ids.compactMap { browser.tab($0) })
              case .tab(let id):
                if let tab = browser.tab(id) {
                  row(tab).padding(.top, spaced.contains(id) ? sidebarBlockGap : 0)
                }
              }
            }
            endDropZone
          }
          .padding(8)
        }
        .onChange(of: highlighted) { _, row in
          if let row { proxy.scrollTo(row) }
        }
        .onAppear {
          if let id = browser.activeTab?.id { proxy.scrollTo(SidebarRow.tab(id), anchor: .center) }
        }
      }
      Divider()
      Button {
        model.closeTabSidebar(returningFocus: false)
        model.newWebTab()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "plus").frame(width: 18)
          Text("New Tab", bundle: .module)
          Spacer(minLength: 8)
          Text(verbatim: "⌘T").foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .focusable()
    .focusEffectDisabled()
    .focused($hasKeyboard)
    .onKeyPress(.downArrow) { keyboard { moveHighlight(by: 1) } }
    .onKeyPress(.upArrow) { keyboard { moveHighlight(by: -1) } }
    .onKeyPress(.rightArrow) { keyboard { expandHighlighted(true) } }
    .onKeyPress(.leftArrow) { keyboard { expandHighlighted(false) } }
    .onKeyPress(.return) { keyboard { performHighlighted() } }
    .onKeyPress(keys: [.delete], phases: .down) { press in
      guard hasKeyboard, press.modifiers.contains(.command), case .tab(let id) = highlighted
      else { return .ignored }
      close(id)
      return .handled
    }
    .onExitCommand { model.closeTabSidebar() }
    // A group renamed: the keyboard comes back to the sidebar, on that group.
    .onChange(of: renaming) { previous, current in
      guard current == nil, let previous else { return }
      highlighted = .group(previous)
      hasKeyboard = true
    }
    .clearsWhenDragEnds(dragged != nil || mark != nil) {
      dragged = nil
      mark = nil
    }
    .onAppear {
      highlighted = browser.activeTab.map { .tab($0.id) }
      hasKeyboard = true
      browser.markTabsSeen()
    }
    // A tab opened behind while the sidebar is open is seen as it comes in.
    .onChange(of: browser.unseenTabIDs) { _, unseen in
      if !unseen.isEmpty { browser.markTabsSeen() }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Web tabs", bundle: .module))
  }

  // MARK: - The pinned group

  private var pinnedGroup: some View {
    let pinned = (browser.ticketTab.map { [$0] } ?? []) + browser.tabs.prefix(browser.pinnedCount)
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Image(systemName: "pin.fill").font(.caption2)
        Text("Pinned", bundle: .module)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(mark?.target == .pinned ? Color.accentColor.opacity(0.2) : .clear)
      )
      .accessibilityAddTraits(.isHeader)
      .onDrop(of: [.text], delegate: dropDelegate(.pinned) { _ in .into })

      // Empty, it is where a tab is dropped to pin it.
      if pinned.isEmpty {
        Text("Drag a tab here to pin it", bundle: .module)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
              .foregroundStyle(
                mark?.target == .pinned ? Color.accentColor : Color.secondary.opacity(0.4))
          )
          .onDrop(of: [.text], delegate: dropDelegate(.pinned) { _ in .into })
      }
      ForEach(pinned) { row($0) }
    }
    .padding(6)
    .background(BrowserTabBlockBackground(isLit: false))
  }

  /// The loose tabs that come right after a block — the pinned group, or a group.
  private var tabsAfterBlocks: Set<BrowserTabID> {
    var spaced: Set<BrowserTabID> = []
    var afterBlock = true
    for item in browser.sidebarItems {
      switch item {
      case .group:
        afterBlock = true
      case .tab(let id):
        if afterBlock { spaced.insert(id) }
        afterBlock = false
      }
    }
    return spaced
  }

  // MARK: - Groups

  /// A block (#666): its header — chevron, name, count, Close All under the pointer — then its
  /// tabs unless it is collapsed.
  private func groupSection(_ group: BrowserTabGroup, tabs: [BrowserTabModel]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      BrowserTabGroupHeader(
        group: group, name: BrowserTabGroupName.shown(group), count: tabs.count,
        isHighlighted: highlighted == .group(group.id),
        isRenaming: Binding(
          get: { renaming == group.id },
          set: { renaming = $0 ? group.id : nil }),
        mark: mark?.target == .group(group.id) ? mark?.place : nil,
        // A click on the header or on Close All: the sidebar takes the keyboard back, on the
        // group or the row after it, the button it might have been on gone.
        toggle: {
          browser.setCollapsed(group.id, !group.isCollapsed)
          highlighted = .group(group.id)
          hasKeyboard = true
        },
        closeAll: {
          closeGroup(group.id, movingHighlight: true)
          hasKeyboard = true
        },
        rename: { browser.renameGroup(group.id, to: $0) }
      )
      .id(SidebarRow.group(group.id))
      .onDrag {
        dragged = .group(group.id)
        return NSItemProvider(object: BrowserTabGroupDrag.text(for: group.id) as NSString)
      }
      .onDrop(
        of: [.text],
        delegate: dropDelegate(.group(group.id)) { y in
          if case .group = dragged { return y > 14 ? .after : .before }
          return .into
        }
      )
      .contextMenu { groupMenu(group) }
      .accessibilityActions { groupActions(group) }

      if !group.isCollapsed {
        ForEach(tabs) { row($0) }
      }
    }
    .padding(6)
    .background(BrowserTabBlockBackground(isLit: highlighted == .group(group.id)))
    // A plain container: its header is the heading VoiceOver reads (#666).
    .accessibilityElement(children: .contain)
    .padding(.top, sidebarBlockGap)
  }

  @ViewBuilder
  private func groupMenu(_ group: BrowserTabGroup) -> some View {
    Button {
      renaming = group.id
    } label: {
      Text("Rename…", bundle: .module)
    }
    Button {
      browser.setCollapsed(group.id, !group.isCollapsed)
    } label: {
      group.isCollapsed ? Text("Expand", bundle: .module) : Text("Collapse", bundle: .module)
    }
    Divider()
    Button {
      browser.dissolveGroup(group.id)
    } label: {
      Text("Ungroup", bundle: .module, comment: "Dissolves a group of web tabs; its tabs stay.")
    }
    Button {
      closeGroup(group.id)
    } label: {
      Text("Close Group", bundle: .module)
    }
  }

  /// What VoiceOver and Full Keyboard Access do instead of dragging a group (#230).
  @ViewBuilder
  private func groupActions(_ group: BrowserTabGroup) -> some View {
    Button(group.isCollapsed ? expandTitle : collapseTitle) {
      browser.setCollapsed(group.id, !group.isCollapsed)
    }
    Button(String(localized: "Rename…", bundle: .module)) { renaming = group.id }
    if browser.canMoveGroup(group.id, by: -1) {
      Button(String(localized: "Move Up", bundle: .module)) { browser.moveGroup(group.id, by: -1) }
    }
    if browser.canMoveGroup(group.id, by: 1) {
      Button(String(localized: "Move Down", bundle: .module)) { browser.moveGroup(group.id, by: 1) }
    }
    Button(String(localized: "Ungroup", bundle: .module)) { browser.dissolveGroup(group.id) }
    Button(String(localized: "Close Group", bundle: .module)) { closeGroup(group.id) }
  }

  private var expandTitle: String { String(localized: "Expand", bundle: .module) }
  private var collapseTitle: String { String(localized: "Collapse", bundle: .module) }

  // MARK: - Below the rows

  /// A tab dropped under every row leaves its group, last; a group goes last.
  private var endDropZone: some View {
    Color.clear
      .frame(height: 40)
      .frame(maxWidth: .infinity)
      .overlay(alignment: .top) {
        if mark?.target == .end {
          Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6)
        }
      }
      .contentShape(Rectangle())
      .onDrop(of: [.text], delegate: dropDelegate(.end) { _ in .into })
      .accessibilityHidden(true)
  }

  // MARK: - Tabs

  private func row(_ tab: BrowserTabModel) -> some View {
    BrowserTabSidebarRow(
      tab: tab, browser: browser, model: model,
      isActive: browser.activeTab?.id == tab.id,
      isHighlighted: highlighted == .tab(tab.id),
      mark: mark?.target == .tab(tab.id) ? mark?.place : nil,
      activate: { activate(tab.id) },
      close: { close(tab.id) }
    )
    .id(SidebarRow.tab(tab.id))
    .modifier(BrowserTabSidebarRowDrag(tab: tab, dragged: $dragged))
    .onDrop(
      of: [.text],
      delegate: dropDelegate(.tab(tab.id)) { y in
        // Dropped on the ticket's, a tab becomes the first pinned one: after it, always.
        tab.isPinnedTicket ? .after : y > 22 ? .after : .before
      }
    )
    .contextMenu { tabMenu(tab) }
    .accessibilityActions { tabActions(tab) }
  }

  @ViewBuilder
  private func tabMenu(_ tab: BrowserTabModel) -> some View {
    Button {
      tab.reload()
    } label: {
      Text("Reload", bundle: .module)
    }
    Button {
      model.openOutside(tab.url)
    } label: {
      Text("Open in Browser", bundle: .module)
    }
    .disabled(!model.opensOutside(tab.url))
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(tab.url.absoluteString, forType: .string)
    } label: {
      Text("Copy Address", bundle: .module)
    }
    if !tab.isPinnedTicket {
      if let id = model.selectedSessionID {
        Button {
          Task { await model.setTicket(tab.url.absoluteString, for: id) }
        } label: {
          Text("Set as Ticket", bundle: .module)
        }
      }
      Divider()
      Menu {
        Button {
          browser.move(tab.id, to: .pinned(.end))
        } label: {
          Text("Pinned", bundle: .module)
        }
        .disabled(tab.isPinned)
        Divider()
        ForEach(browser.groups) { group in
          Button {
            browser.move(tab.id, to: .group(group.id, .end))
          } label: {
            Text(verbatim: BrowserTabGroupName.shown(group))
          }
          .disabled(tab.groupID == group.id)
        }
        Button {
          browser.newGroup(with: tab.id)
        } label: {
          Text("New Group", bundle: .module)
        }
        Divider()
        Button {
          browser.move(tab.id, to: .loose(.end))
        } label: {
          Text("No Group", bundle: .module, comment: "Moves a web tab out of its group.")
        }
        .disabled(tab.groupID == nil && !tab.isPinned)
      } label: {
        Text("Move To", bundle: .module, comment: "A submenu of a web tab: its group.")
      }
      if tab.groupID != nil {
        Button {
          browser.removeFromGroup(tab.id)
        } label: {
          Text("Remove from Group", bundle: .module)
        }
      }
      // What the list of #536 offered: kept beside dragging.
      Button {
        browser.setPinned(tab.id, !tab.isPinned)
      } label: {
        tab.isPinned ? Text("Unpin Tab", bundle: .module) : Text("Pin Tab", bundle: .module)
      }
      Button {
        browser.moveTab(tab.id, by: -1)
      } label: {
        Text("Move Up", bundle: .module)
      }
      .disabled(!browser.canMoveTab(tab.id, by: -1))
      Button {
        browser.moveTab(tab.id, by: 1)
      } label: {
        Text("Move Down", bundle: .module)
      }
      .disabled(!browser.canMoveTab(tab.id, by: 1))
      Divider()
      Button {
        close(tab.id)
      } label: {
        Text("Close Tab", bundle: .module)
      }
    }
  }

  /// What VoiceOver and Full Keyboard Access do instead of dragging a tab (#230).
  @ViewBuilder
  private func tabActions(_ tab: BrowserTabModel) -> some View {
    if !tab.isPinnedTicket {
      Button(String(localized: "Close Tab", bundle: .module)) { close(tab.id) }
      if tab.isPinned {
        Button(String(localized: "Unpin Tab", bundle: .module)) {
          browser.setPinned(tab.id, false)
        }
      } else {
        Button(String(localized: "Pin Tab", bundle: .module)) {
          browser.move(tab.id, to: .pinned(.end))
        }
      }
      if browser.canMoveTab(tab.id, by: -1) {
        Button(String(localized: "Move Up", bundle: .module)) { browser.moveTab(tab.id, by: -1) }
      }
      if browser.canMoveTab(tab.id, by: 1) {
        Button(String(localized: "Move Down", bundle: .module)) { browser.moveTab(tab.id, by: 1) }
      }
      if tab.groupID != nil {
        Button(String(localized: "Remove from Group", bundle: .module)) {
          browser.removeFromGroup(tab.id)
        }
      }
      ForEach(browser.groups.filter { $0.id != tab.groupID }) { group in
        Button(String(localized: "Move to \(BrowserTabGroupName.shown(group))", bundle: .module)) {
          browser.move(tab.id, to: .group(group.id, .end))
        }
      }
      Button(String(localized: "New Group", bundle: .module)) { browser.newGroup(with: tab.id) }
    }
  }

  private func activate(_ id: BrowserTabID) {
    browser.activate(id)
    model.closeTabSidebar()
  }

  private func close(_ id: BrowserTabID) {
    // The keyboard stays on a row: the next one, else the one before.
    if highlighted == .tab(id) {
      let rows = visibleRows
      if let index = rows.firstIndex(of: .tab(id)) {
        highlighted = rows.indices.contains(index + 1) ? rows[index + 1] : rows[safe: index - 1]
      }
    }
    workspace.close(id, in: browser.sessionID)
  }

  /// Every tab of the group, each as its close button would (#241). The keyboard, if it was on
  /// the group — or always, from the group's own Close All — goes on to the row after the group,
  /// else the one before.
  private func closeGroup(_ id: BrowserTabGroupID, movingHighlight: Bool = false) {
    let members = Set(browser.members(of: id).map { SidebarRow.tab($0.id) } + [.group(id)])
    if movingHighlight || highlighted.map(members.contains) == true {
      let rows = visibleRows
      let first = rows.firstIndex { members.contains($0) }
      let last = rows.lastIndex { members.contains($0) }
      highlighted =
        last.flatMap { rows[safe: $0 + 1] } ?? first.flatMap { rows[safe: $0 - 1] }
    }
    workspace.closeGroup(id, in: browser.sessionID)
  }

  // MARK: - Keyboard

  /// The rows the arrows go through: tabs and group headers, not the tabs of a collapsed group.
  private var visibleRows: [SidebarRow] {
    var rows: [SidebarRow] = []
    if let ticket = browser.ticketTab { rows.append(.tab(ticket.id)) }
    rows += browser.tabs.prefix(browser.pinnedCount).map { .tab($0.id) }
    for item in browser.sidebarItems {
      switch item {
      case .group(let group, let ids):
        rows.append(.group(group.id))
        if !group.isCollapsed { rows += ids.map { .tab($0) } }
      case .tab(let id):
        rows.append(.tab(id))
      }
    }
    return rows
  }

  /// Only while the sidebar itself has the keyboard: with Full Keyboard Access on a row's button,
  /// or a group being renamed, the keys are theirs.
  private func keyboard(_ action: () -> Void) -> KeyPress.Result {
    guard hasKeyboard, renaming == nil else { return .ignored }
    action()
    return .handled
  }

  private func moveHighlight(by offset: Int) {
    let rows = visibleRows
    guard !rows.isEmpty else { return }
    let current = highlighted.flatMap { rows.firstIndex(of: $0) }
    let next = current.map { min(max($0 + offset, 0), rows.count - 1) } ?? 0
    highlighted = rows[next]
  }

  /// → opens the group, ← closes it — or, on one of its tabs, goes to its header.
  private func expandHighlighted(_ expand: Bool) {
    switch highlighted {
    case .group(let id):
      browser.setCollapsed(id, !expand)
    case .tab(let id):
      if !expand, let group = browser.group(of: id) { highlighted = .group(group.id) }
    case nil:
      return
    }
  }

  private func performHighlighted() {
    switch highlighted {
    case .tab(let id):
      activate(id)
    case .group(let id):
      if let group = browser.groups.first(where: { $0.id == id }) {
        browser.setCollapsed(id, !group.isCollapsed)
      }
    case nil:
      return
    }
  }

  // MARK: - Dropping

  private func dropDelegate(
    _ target: SidebarTarget, place: @escaping (CGFloat) -> SidebarMark.Place
  ) -> BrowserTabSidebarDropDelegate {
    BrowserTabSidebarDropDelegate(
      target: target, place: place, accepts: { accepts($0, on: target) },
      dragged: $dragged, mark: $mark,
      perform: { dragged, place in perform(dragged, on: target, place: place) })
  }

  /// A group is never pinned: it is refused over the pinned group.
  private func accepts(_ dragged: SidebarDragged, on target: SidebarTarget) -> Bool {
    guard case .group = dragged else { return true }
    switch target {
    case .pinned: return false
    case .tab(let id):
      guard let tab = browser.tab(id) else { return false }
      return !tab.isPinned && !tab.isPinnedTicket
    case .group, .end: return true
    }
  }

  private func perform(
    _ dragged: SidebarDragged, on target: SidebarTarget, place: SidebarMark.Place
  ) {
    let isAfter = place == .after
    switch (dragged, target) {
    case (.tab(let id), .pinned):
      browser.move(id, to: .pinned(.end))
    case (.tab(let id), .end):
      browser.move(id, to: .loose(.end))
    case (.tab(let id), .group(let group)):
      browser.move(id, to: .group(group, .end))
    case (.tab(let id), .tab(let target)):
      browser.move(id, nextTo: target, after: isAfter)
    case (.group(let group), .end):
      browser.moveGroup(group, to: .end)
    case (.group(let group), .group(let target)):
      let members = browser.members(of: target)
      guard let anchor = isAfter ? members.last : members.first else { return }
      browser.moveGroup(group, to: isAfter ? .after(anchor.id) : .before(anchor.id))
    case (.group(let group), .tab(let target)):
      browser.moveGroup(group, to: isAfter ? .after(target) : .before(target))
    case (.group, .pinned):
      return
    }
  }
}

/// Shows where a dragged row would go, and moves it there when it is let go. Only a row dragged
/// from the sidebar is taken: text or a link from elsewhere is refused.
private struct BrowserTabSidebarDropDelegate: DropDelegate {
  let target: SidebarTarget
  let place: (CGFloat) -> SidebarMark.Place
  let accepts: (SidebarDragged) -> Bool
  @Binding var dragged: SidebarDragged?
  @Binding var mark: SidebarMark?
  let perform: (SidebarDragged, SidebarMark.Place) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    dragged.map(accepts) ?? false
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    guard let dragged, accepts(dragged) else {
      if mark?.target == target { mark = nil }
      return DropProposal(operation: .forbidden)
    }
    let next = SidebarMark(target: target, place: place(info.location.y))
    // Once per change, not on every move of the pointer: each write draws the sidebar again.
    if mark != next { mark = next }
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    if mark?.target == target { mark = nil }
  }

  func performDrop(info: DropInfo) -> Bool {
    let place = place(info.location.y)
    mark = nil
    guard let item = dragged, accepts(item) else { return false }
    dragged = nil
    perform(item, place)
    return true
  }
}

/// A row dragged elsewhere in the sidebar: marked, so that a tab let go over the session is not
/// typed into its agent (#42). The ticket's tab stays where it is.
private struct BrowserTabSidebarRowDrag: ViewModifier {
  let tab: BrowserTabModel
  @Binding var dragged: SidebarDragged?

  func body(content: Content) -> some View {
    if tab.isPinnedTicket {
      content
    } else {
      content.onDrag {
        dragged = .tab(tab.id)
        return NSItemProvider(object: BrowserTabDrag.text(for: tab.id) as NSString)
      }
    }
  }
}

/// The ground of a block of the sidebar — a group, or the pinned ones (#666): lighter than the
/// sidebar, as Dia draws them, its edge brighter under the pointer or the keyboard.
private struct BrowserTabBlockBackground: View {
  let isLit: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 10)
      .fill(Color.primary.opacity(0.05))
      .strokeBorder(Color.primary.opacity(isLit ? 0.2 : 0.08), lineWidth: 1)
  }
}

/// Above a group's block, and above the loose tab after a block (#666): with the rows' own 2
/// points, the 10 of the mockup between blocks.
private let sidebarBlockGap: CGFloat = 8

/// A group's header (#648, #666): its chevron, name and count, and Close All under the pointer.
/// A click folds or unfolds the group, a double click renames it; it is what drags the group.
private struct BrowserTabGroupHeader: View {
  let group: BrowserTabGroup
  let name: String
  let count: Int
  let isHighlighted: Bool
  @Binding var isRenaming: Bool
  let mark: SidebarMark.Place?
  let toggle: () -> Void
  let closeAll: () -> Void
  let rename: (String) -> Void
  @State private var draft = ""
  @State private var isHovering = false
  @FocusState private var isEditing: Bool

  var body: some View {
    HStack(spacing: 6) {
      Button(action: toggle) {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
      if isRenaming {
        TextField(text: $draft) { Text("Group Name", bundle: .module) }
          .textFieldStyle(.plain)
          .focused($isEditing)
          .onSubmit(commit)
          .onExitCommand { isRenaming = false }
          .onAppear {
            draft = group.nameSource == .user ? group.name : name
            isEditing = true
          }
          .onChange(of: isEditing) { _, editing in
            if !editing, isRenaming { commit() }
          }
      } else {
        Text(verbatim: name)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 4)
      if isHovering || isHighlighted, !isRenaming {
        Button(action: closeAll) {
          HStack(spacing: 4) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            Text("Close All", bundle: .module, comment: "Closes every tab of a group of web tabs.")
          }
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 7)
          .frame(height: 20)
          .background(Capsule().fill(Color.primary.opacity(0.08)))
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
      Text(verbatim: "\(count)")
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .accessibilityHidden(true)
    }
    .font(.callout.weight(.semibold))
    .padding(.horizontal, 4)
    .frame(height: 28)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(
          mark == .into
            ? Color.accentColor.opacity(0.2)
            : isHovering || isHighlighted ? Color.primary.opacity(0.06) : .clear)
    )
    .overlay(alignment: mark == .after ? .bottom : .top) {
      if mark == .before || mark == .after {
        Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { isRenaming = true }
    .onTapGesture(perform: toggle)
    .onHover { isHovering = $0 }
    // The group's heading to VoiceOver: its name, how many tabs, folded or not. Expand and
    // Collapse are among its actions, said once.
    .accessibilityElement(children: isRenaming ? .contain : .ignore)
    .accessibilityLabel(Text(verbatim: name))
    .accessibilityValue(
      group.isCollapsed
        ? Text(verbatim: BrowserTabGroupName.count(count) + ", ")
          + Text("Collapsed", bundle: .module)
        : Text(verbatim: BrowserTabGroupName.count(count)))
    .accessibilityAddTraits([.isHeader, .isButton])
    .accessibilityAction(.default, toggle)
  }

  /// An empty name gives the group back « Group N »; « Group N » left as it was stays it.
  private func commit() {
    if group.nameSource != .user, draft == name {
      isRenaming = false
      return
    }
    rename(draft)
    isRenaming = false
  }
}

/// One tab of the sidebar: its icon, its title on up to two lines, where it is, and its close
/// button under the pointer, with the keyboard, and on the tab in front.
private struct BrowserTabSidebarRow: View {
  let tab: BrowserTabModel
  let browser: SessionBrowser
  let model: AppModel
  let isActive: Bool
  let isHighlighted: Bool
  let mark: SidebarMark.Place?
  let activate: () -> Void
  let close: () -> Void
  @State private var isHovering = false
  @FocusState private var focus: RowFocus?

  private enum RowFocus: Hashable {
    case tab
    case close
  }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      // A button, so that the keyboard reaches every tab (#230).
      Button(action: activate) {
        HStack(alignment: .top, spacing: 8) {
          BrowserTabIcon(tab: tab)
            .foregroundStyle(.secondary)
            .frame(width: 18)
            .padding(.top, 1)
          VStack(alignment: .leading, spacing: 1) {
            BrowserTabTitle.text(of: tab)
              .font(.callout.weight(isActive ? .semibold : .regular))
              .foregroundStyle(.primary)
              .lineLimit(2)
              .multilineTextAlignment(.leading)
            subtitle
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focused($focus, equals: .tab)
      .instantTooltip(Text(verbatim: tab.url.absoluteString))

      if tab.isPinnedTicket {
        Image(systemName: "ticket")
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
          .frame(width: 20, height: 20)
          .padding(.top, 5)
          .padding(.trailing, 6)
          .accessibilityHidden(true)
      } else {
        closeButton
          .padding(.top, 5)
          .padding(.trailing, 6)
      }
    }
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(background)
        // The tab in front stands out, in light as in dark (#536).
        .strokeBorder(Color.accentColor.opacity(isActive ? 0.55 : 0), lineWidth: 1)
    }
    .overlay(alignment: mark == .after ? .bottom : .top) {
      if mark != nil {
        Capsule()
          .fill(Color.accentColor)
          .frame(height: 2)
          .padding(.horizontal, 6)
          .offset(y: mark == .after ? 1 : -1)
      }
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(BrowserTabTitle.accessibilityLabel(of: tab, in: browser))
    .accessibilityValue(
      tab.isPinned || tab.isPinnedTicket
        ? Text("Pinned Tab", bundle: .module) : Text(verbatim: ""))
    .accessibilityAction { activate() }
  }

  private var background: Color {
    if isActive { return Color.accentColor.opacity(0.28) }
    if isHovering || isHighlighted { return Color.primary.opacity(0.06) }
    return .clear
  }

  private var closeButton: some View {
    let isShown = isActive || isHovering || isHighlighted || focus != nil
    return Button(action: close) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        // At least 20 points to click (#229).
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .focused($focus, equals: .close)
    .opacity(isShown ? 1 : 0)
    .allowsHitTesting(isShown)
    .instantTooltip(Text("Close Tab", bundle: .module))
  }

  /// The ticket, a page of this Mac, and the site.
  private var subtitle: some View {
    HStack(spacing: 5) {
      if tab.isPinnedTicket, let label = browser.ticket?.label {
        Text(verbatim: label)
          .fontWeight(.semibold)
          .foregroundStyle(.primary)
      }
      if tab.origin?.isLocal == true {
        BrowserLocalBadge()
      }
      if let address {
        Text(verbatim: address)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }

  private var address: String? {
    guard !tab.isBlank else { return nil }
    return tab.origin?.description ?? tab.url.absoluteString
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
