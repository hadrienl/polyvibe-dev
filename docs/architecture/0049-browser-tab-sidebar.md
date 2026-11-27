# 0049 — A tab sidebar with automatic groups

- Status: accepted
- Date: 2026-11-27
- Issue: [#648](https://github.com/hadrienl/polyvibe-dev/issues/648)
- Replaces the interface of [#536](https://github.com/hadrienl/polyvibe-dev/issues/536) (tab list in
  a popover); keeps its data (`BrowserTab.isPinned`) and the opening rules of #186.

## Context

#536 put the session's tabs in a vertical list, in a popover under a button above the address
bar. Titles read whole, but the list is flat: a pull request, its files, its CI and the
documentation opened from the CI follow one another with the agent's pages and the terminal's
links. Past ten tabs the user no longer finds their way.

Dia (formerly Arc) answers with a vertical sidebar where a link opened in a new tab joins the
group of the tab it came from. The web view is too narrow for a permanent column, so the sidebar
opens **over the page**, on 80 % of its width, from a button left of the address bar, and closes
when a tab is chosen.

A proof of concept validated the interaction with the user before this was written down. It
kept groups in memory, used French strings verbatim and string keys for drop targets: this
document describes what ships.

## Decisions

### Order is one array; groups are a label on contiguous runs

`SessionBrowser.tabs` stays the single source of order, as #536 left it: pinned tabs first, then
the others. A group is not a nested array but a **label on a contiguous run** of unpinned tabs:

```swift
// VibeDomain
public struct BrowserTabGroupID: Hashable, Codable, Sendable { public let rawValue: UUID }

public struct BrowserTabGroup: Identifiable, Hashable, Codable, Sendable {
  public enum Origin: Hashable, Codable, Sendable {
    /// Made when a tab opened a link: the two are its first members.
    case opener
    /// Made from a tab the user pinned, which stays pinned: the group gathers that tab's links and
    /// lives on with one tab while its opener is pinned.
    case pinnedOpener(BrowserTabID)
    /// Made from the ticket's page. The ticket's tab is made again at each launch under another
    /// identifier, so the group is the ticket's, not a tab's: it goes once empty.
    case ticket
    /// Made by the user (« Nouveau groupe »): lives on with one tab.
    case user
  }
  public let id: BrowserTabGroupID
  public var name: String
  public var isCollapsed: Bool
  public var origin: Origin
}

public struct BrowserTab { …; public var groupID: BrowserTabGroupID? }
public struct SessionBrowserState { …; public var groups: [BrowserTabGroup] }
```

Why not a tree (`[Item]` with `.group([Tab])`): every existing path — ⌃⇥, `tab(named:)`, the
agent's tools, the companion mirror, persistence, the #186 opening runs — walks a flat list of
tabs. A label keeps them unchanged and puts the whole cost of groups in one place.

**Invariants**, restored by `normalize()` after every change and after restore:

1. Pinned tabs come first and belong to no group (the ticket's tab is outside `tabs`, as today).
2. The members of a group are contiguous. A group sits where its first member is.
3. Every `groupID` names a group in `groups`; every group has at least one member.
4. A group of origin `.opener` with fewer than two members is dissolved: its last tab is loose.
   `.ticket` and `.user` groups go only when empty.
5. A `.pinnedOpener` group is unique per opener; it keeps one tab while its opener is pinned, and
   needs two once the opener is closed or unpinned.

`normalize()` is a stable gather: members of a group are moved next to its first member, in their
relative order. It is idempotent, and is what makes a file written by hand or by a crash safe.

### The arrangement is a pure value, tested without WebKit

The rules live in a value type with no `WKWebView`, so they are tested like the session order of
ADR 0027:

```swift
// VibeDomain/BrowserTabArrangement.swift
public struct BrowserTabArrangement: Equatable, Sendable {
  public struct Entry { let id: BrowserTabID; var isPinned: Bool; var groupID: BrowserTabGroupID? }
  public enum Place { case start, before(BrowserTabID), after(BrowserTabID), end }
  public enum Destination {
    case pinned(Place)                        // .start: right after the ticket's tab
    case group(BrowserTabGroupID, Place)
    case loose(Place)                         // next to a loose tab or a whole group
  }
  public enum Item { case group(BrowserTabGroup, [BrowserTabID]), tab(BrowserTabID) }

  public private(set) var entries: [Entry]
  public private(set) var groups: [BrowserTabGroup]
  public var ticketID: BrowserTabID?

  public mutating func insert(_ id: BrowserTabID, at position: Int)               // loose
  public mutating func insertOpened(_ id: BrowserTabID, at position: Int, from opener: BrowserTabID, name: String)
  public mutating func move(_ id: BrowserTabID, to: Destination)
  public mutating func move(_ id: BrowserTabID, by offset: Int)                   // keyboard, VoiceOver
  public mutating func moveGroup(_ id: BrowserTabGroupID, to: Place)
  public mutating func moveGroup(_ id: BrowserTabGroupID, by offset: Int)
  public mutating func newGroup(with id: BrowserTabID, name: String) -> BrowserTabGroupID?
  public mutating func rename(_:to:), setCollapsed(_:_:), dissolve(_:), remove(_:), normalize()
  public var items: [Item] { get }                                                 // what the sidebar draws
}
```

`SessionBrowser` stores no arrangement: it builds one from its tabs (`isPinned`, `groupID` on
each `BrowserTabModel`) and its `groups`, applies the change, and puts the tabs back in the
arrangement's order (`arrange`), then calls `stateDidChange`. Every public change (`setPinned`,
`move`, `moveTab(by:)`, `remove`, `append`, the group operations) goes through it, so the
invariants hold whatever the caller. The `move(_:nextTo:after:)` and `setPinned` of #536 are kept
as thin wrappers over `move(_:to:)`: a drop on a tab row lands in that row's container.

The UI never builds string keys: drop targets carry a `Destination` or a `BrowserSidebarItemID`
(`.group(id)` / `.tab(id)`).

### Grouping follows the opener, as in Dia

A tab joins a group only when **a page opened it**: the paths that already pass `isOpener: true`
to `SessionBrowser.append` since #186.

| How the tab opens | Origin passed | Grouped |
|---|---|---|
| ⌘-click, ⇧⌘-click, middle click on a link (`BrowserLinkGestures`) | the page's tab | yes |
| `target=_blank`, `window.open` (`adoptPopup`) | the page's tab | yes |
| ⌘T, address typed, « Ouvrir dans un nouvel onglet » of a session link | none | no, loose |
| Link from the terminal, conversation, notes (`openLink`) | none (placed after the tab in front) | no, loose |
| `tab_open` by an agent | none | no, loose |
| A popup the agent's page opens | the agent's tab | yes (same rule) |

Rules in `insertOpened`:

- The opener is in a group → the new tab joins it.
- The opener is loose → a group of origin `.opener` is made with both, named after the opener.
- The opener is pinned → the `.pinnedOpener(opener)` group is reused or made; the opener stays
  pinned. The ticket's tab → the `.ticket` group, the same way. Once that group exists, its new
  links go last in it, in the order they were opened. A new ticket group is placed first among the
  unpinned items, right under the ticket.
- **Position** inside the group follows #186 unchanged: after the opener and after the run of tabs
  it already opened since the user last turned to a tab. Since the opener is in the group and the
  group is contiguous, that place is always inside it — no clamp needed. (The proof of concept
  appended at the end of the group, which broke the #186 test « Turning to another tab ends the
  run »; that rule is dropped.)
- `BrowserWorkspace.anchor(_:in:)` keeps returning `nil` for the ticket's tab (it stays first);
  `open` and `adoptPopup` pass the real origin to `insertOpened` separately, so the ticket's links
  are grouped too.

**Name.** The opener's `displayTitle` at creation, else its host, else « Groupe ». It is frozen:
the opener navigating away does not rename the group. Double-click or « Renommer… » changes it; an
empty name restores the default.

### « Épinglés » is a static group made of `isPinned`

The pinned group is not a `BrowserTabGroup`: it is drawn from the ticket's tab plus
`tabs.prefix(pinnedCount)`, as #536 already computes it. It is always first, always shown (empty,
it shows a dashed drop zone), never collapsed, renamed, moved or dissolved. Pinning is
`move(id, to: .pinned(before:))`: it clears `groupID`. No migration is needed: a file of 1.2
restores its pinned tabs into the group.

The row pin of #536 goes: one pins by dragging into the group or with « Déplacer vers ▸ Épinglés »
and VoiceOver's action of the same name. ⌘W still closes a pinned tab; protecting it from agents
stays [#587](https://github.com/hadrienl/polyvibe-dev/issues/587).

### The sidebar is a SwiftUI overlay, not a popover

```
BrowserPanel
├─ BrowserAddressBar   [sidebar button] ← → ⟳ [address field] [⧉ Open] [+] [agent trace] […]
├─ Divider
└─ ZStack(content)
   ├─ page / device mirror / empty / failure
   ├─ BrowserPermissionBanner
   └─ BrowserTabSidebarOverlay(isShowing)
        ├─ veil (click → close)
        └─ BrowserTabSidebar  width = max(80 % × panel width, min(260, panel width))
```

- **No `NSPopover`.** #536 needed an AppKit popover of its own (`BrowserTabListPopover`) with its
  key window, hover tracker and close-on-mouse-down workarounds. An overlay inside the panel has
  none of those problems: it goes with the session, cannot outlive its button, and keeps the
  session's window key. The permission banner already proves SwiftUI content draws and takes
  clicks above `BrowserWebViewHost`.
- **The 36-point tab row goes.** The sidebar button sits left of ← in the address bar; + and the
  agent trace move to the right of the address field. At the narrowest panel (~340 pt) the field
  keeps about 110 pt; « Ouvrir dans le navigateur » moves into the « … » menu if that is too
  little (to be checked on the build).
- **Closing.** A click on a tab (activate + close), on the veil, Escape, the button again, or the
  shortcut. Closing gives the keyboard back to the page (`model.webViewFocusRequest`), or to the
  address field when the tab is blank.
- **State.** `AppModel.isTabSidebarShown`, so that the button, the overlay and the menu agree;
  `toggleTabSidebar()` shows the web view first if it was hidden; `closeTabSidebar()` gives the
  keyboard back. The panel closes it when the session changes.
- **Shortcut.** ⇧⌘S, free in the app's menus, declared in the Web menu (« Show Tabs » /
  « Hide Tabs »), not on the button, so that it works wherever the keyboard is and shows in the
  menu.
- **Motion.** The sidebar slides from the leading edge and the veil fades (`.snappy`, 0.2 s); with
  Reduce Motion, both appear at once.
- **Size.** 80 % of the panel, at least 260 pt or the whole panel when narrower. Rows keep the
  #536 layout: icon, title on two lines, host / LOCAL / agent, close button on hover and on the
  tab in front.

### The button says what it does

`BrowserTabSidebarButton`: `sidebar.left` and the tab count in a capsule, accent-filled while tabs
opened behind are unseen (`unseenTabIDs`, as #536), a sparkle when the agent acts in a tab behind.
Tooltip « Afficher les onglets ⇧⌘S » / « Masquer les onglets »; accessibility label « Onglets »,
value the count, `isSelected` while open. The title of the tab in front, which the #536 button
showed, is now only in the address field and the window: the sidebar is one click away.

### Collapsing

A group header shows a chevron, a folder, its name and its count. A collapsed group hides its
rows. Its tabs stay in ⌃⇥'s order (`allTabs`, in the sidebar's order): turning to a tab in a collapsed group — by
⌃⇥, a click in the address field's history, or an agent's `tab_activate` — expands it, so that the
tab in front is always a visible row when the sidebar opens.

### Dragging

One drop delegate type, parameterised by what the row is, resolves to a `Destination`:

| Dragged | Dropped on | Result |
|---|---|---|
| tab | a tab row, top/bottom half | before/after it, in its container (pinned, its group, loose) |
| tab | the ticket's row | first of the pinned group |
| tab | a group header | last of that group (header lit) |
| tab | the « Épinglés » header or its empty zone | last of the pinned group |
| tab | the empty space under the list | loose, last |
| group header | a loose tab or another group's header, top/bottom half | the whole group before/after that item |
| group header | a pinned row or « Épinglés » | refused |

The tab payload keeps `BrowserTabDrag` (#42): dropped on a session it is refused there as today.
The group payload has its own prefix (`vibe-manager-browser-group:`), which `DropReader` must
refuse as well, or a group dragged onto a session would be typed into its terminal. A drag ending
anywhere clears the indicator (`clearsWhenDragEnds`, as #536).

### Keyboard and accessibility

- The sidebar takes the keyboard when it opens. ↑ ↓ go through visible rows **and** group headers;
  → expands a group, ← collapses it or goes to its header; ⏎ activates a tab or toggles a group;
  ⌘⌫ closes the highlighted tab; Escape closes the sidebar.
- Full Keyboard Access reaches the button, each header (chevron, name), each tab and its close
  button (#230).
- VoiceOver: headers are headers (« Groupe X, 4 onglets, replié »); rows keep the labels of #536
  (`BrowserTabTitle.accessibilityLabel`). Custom actions replace dragging: « Déplacer vers le
  haut / bas » within the container, « Déplacer vers ▸ … », « Retirer du groupe », « Épingler » /
  « Détacher »; on a header: « Replier / Déplier », « Renommer », « Déplacer le groupe vers le
  haut / bas », « Dissoudre », « Fermer le groupe ».

### Context menus

- Tab: Recharger · Ouvrir dans le navigateur · Copier l'adresse · Définir comme ticket ─
  Déplacer vers ▸ (Épinglés, each group, Nouveau groupe, Aucun groupe) · Retirer du groupe ─
  Fermer l'onglet. The ticket's tab keeps only the first three.
- Group: Renommer… · Replier / Déplier ─ Dissoudre le groupe · Fermer le groupe (closes each
  member through `BrowserWorkspace.close`, so that #241's download refusal applies to each).
- « Close All » of #536 (`closeUnpinnedTabs`) moves to the address bar's « … » menu as « Close
  Unpinned Tabs ».

### Persistence

`BrowserTab.groupID` and `SessionBrowserState.groups` are written in `Browser/<session>.json`,
read leniently like the rest (ADR 0023): an unreadable group is dropped and its tabs come back
loose; a `groupID` naming no group is dropped; `normalize()` runs after `restore`. Collapsing and
renaming are saved like any other change (`stateDidChange`, debounced by the workspace).

A file written by 1.3 and read by 1.2 loses its groups (unknown keys are ignored) and keeps its
tabs, order and pins: no versioning needed.

### Agents

- `tabs_list` gains `"group": {"name"} | null` and lists tabs in the sidebar's order — which
  `allTabs` already is, the arrangement keeping `tabs` in it. Its
  `"pinned"` stays the ticket's only until #587 decides what a user pin means to an agent.
- No tool creates, renames or moves groups: groups are the user's way to find their tabs, not the
  agent's. `tab_open` opens a loose tab; a popup its page opens is grouped like any.
- `tab_activate` on a tab in a collapsed group expands the group (see Collapsing).

### Companion

`CompanionWebMirror` sends `browser.tabs` flat to the iPhone, now in the sidebar's order since
the arrangement keeps `tabs` in it. Groups are not mirrored (out of scope of #648).

### What goes

`BrowserTabPickerButton`, `BrowserTabList`, `BrowserTabRow`'s pin button, `BrowserTabListPopover`,
`PointerHoverTracker` (only the popover needed it), the tab part of `BrowserTabStrip`, and their
strings in the 17 catalogs (« Show Tabs », « Pin Tab », « Unpin Tab », « Pinned Tab »…).
`BrowserTabIcon`, `BrowserTabTitle`, `BrowserLocalBadge` and the drag/drop helpers stay.

## Files

| File | Change |
|---|---|
| `VibeDomain/SessionBrowser.swift` | `BrowserTabGroupID`, `BrowserTabGroup`, `BrowserTab.groupID`, `SessionBrowserState.groups`, lenient decoding |
| `VibeDomain/BrowserTabArrangement.swift` | new: invariants, `normalize`, operations, `items` |
| `VibeBrowser/SessionBrowser.swift` | `groups`; every change through `arrange`; `append(opener:)` → `insertOpened`; `sidebarItems`; group operations; expand on activate |
| `VibeBrowser/BrowserWorkspace.swift` | `open` / `adoptPopup` pass the real origin as `opener` (ticket included); `closeGroup`; `groupID` restored |
| `VibeBrowser/BrowserTabModel.swift` | `persisted` carries `groupID` |
| `VibeBrowser/BrowserWorkspace+Tools.swift` | `tabs_list`: order and `group` |
| `VibeUI/BrowserTabSidebar.swift` | new: button, overlay, sidebar, rows, headers, drop delegate |
| `VibeUI/BrowserPanel.swift` | tab row removed; address bar gets leading/trailing; overlay in the content |
| `VibeUI/BrowserTabList.swift` | reduced to the shared pieces (icon, title, badge) or folded into the sidebar file |
| `VibeUI/DropReader.swift` | refuses the group payload |
| `VibeUI/AppModel.swift`, `AppModel+Browser.swift`, `App/VibeManagerApp.swift` | `isTabSidebarShown`, toggle/close, « Show Tabs » ⇧⌘S in the Web menu |
| `Resources/*.xcstrings` | new strings × 17, obsolete ones removed |

## Tests

- `BrowserTabArrangementTests` (VibeDomainTests): grouping from a loose, grouped, pinned and ticket
  opener; #186 position inside a group; every row of the drag table; `moveGroup` before/after
  loose tabs and groups; dissolution per origin; closing a pinned opener; `normalize` on a
  scattered, dangling and duplicate input (idempotent); `items` order.
- `SessionBrowser` / `BrowserWorkspace` (VibeBrowserTests): a ⇧⌘-click from a page lands in the
  opener's group; ten in a row keep their click order; a terminal link and `tab_open` stay loose;
  ⌃⇥ follows the sidebar's order through collapsed groups and expands them; persistence round trip of
  groups, names and collapsing; a 1.2 file restores without groups; `tabs_list` reports groups.
- The #186 and #536 tests keep passing unchanged (`BrowserLinkGestureTests`,
  `BrowserTabPinningTests`), except the popover-specific ones, rewritten for the sidebar.
- UI smoke (`UITests`): open the sidebar with the button and ⇧⌘S, choose a tab, it closes.
- `Scripts/check-localizations.sh`.

## Steps

1. Domain: arrangement, groups in the state, persistence, tests. No UI change; `append` groups but
   nothing shows it.
2. Sidebar: overlay, button, rows, headers, collapsing, menus; tab row and popover removed.
3. Drag and drop, keyboard, VoiceOver actions.
4. Agents' `tabs_list`, companion order, strings in 17 languages, ADR accepted.

Each step is a commit of the same pull request; 1 can land alone if the PR grows.

## Answered with the user

- Shortcut: ⇧⌘S.
- « Open in Browser » stays in the address bar; to revisit if the field is too narrow at ~340 pt.
- A group's name is frozen at creation, the user renames it.
- Tabs an agent opens with `tab_open` stay loose.
- The width is a fixed 80 % of the web view.
