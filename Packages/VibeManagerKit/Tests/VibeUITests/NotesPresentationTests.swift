import AppKit
import Foundation
import SwiftUI
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

/// The notes from the toolbar (#578): the popover under the button, the floating panel, Edit Notes.
@MainActor
@Suite("Notes in the toolbar", .serialized, .timeLimit(.minutes(2)))
struct NotesPresentationTests {
  private struct Workspace {
    let model: AppModel
    let store: InMemorySessionNotesStore
    let first: WorkSession
    let second: WorkSession
  }

  private func workspace(
    notes: [Int: String] = [:], layout: WorkspaceLayout = WorkspaceLayout()
  ) async -> Workspace {
    let first = WorkSession(name: "First", status: .closed)
    let second = WorkSession(name: "Second", status: .closed)
    let ids = [first.id, second.id]
    let store = InMemorySessionNotesStore(
      notes: Dictionary(uniqueKeysWithValues: notes.map { (ids[$0.key], $0.value) }))
    let model = AppModel(
      repository: WorkspaceRepository(sessions: [first, second]),
      layout: WorkspaceLayoutController(layout: layout), notesStore: store)
    await model.load()
    model.select(first.id)
    return Workspace(model: model, store: store, first: first, second: second)
  }

  /// Types at the end of a session's notes, as the editor would.
  private func type(_ text: String, in document: NotesDocument) {
    document.storage.append(NSAttributedString(string: text, attributes: NotesStyle.attributes))
    document.didChange()
  }

  @Test("Edit Notes opens the popover and hands its editor the keyboard; again, gives it back")
  func editNotesOpensThePopover() async {
    let workspace = await workspace()
    let model = workspace.model

    model.focusNotes()

    // Held by the model, not by the button: a button in the toolbar's overflow menu opens it as
    // soon as it is back in the toolbar.
    #expect(model.notesPresentation.isPopoverShown)
    #expect(!model.notesPresentation.isPanelShown)
    #expect(model.notes.wantsFocus)
    model.notes.focusTaken()

    model.focusNotes()
    #expect(!model.notesPresentation.isPopoverShown)
  }

  @Test("Closing the popover writes what waited for a pause")
  func closingWrites() async throws {
    let workspace = await workspace()
    let model = workspace.model
    let document = model.notes.document(for: workspace.first.id)
    await waitUntil("the notes are read") { document.isLoaded }
    model.toggleNotes()

    type("Check the seam", in: document)
    #expect(document.hasUnsavedChanges)
    model.notesPopoverDismissed()

    await waitUntil("the notes are written") { !document.hasUnsavedChanges }
    #expect(try await workspace.store.notes(for: workspace.first.id).text == "Check the seam")
    #expect(!model.notesPresentation.isPopoverShown)
  }

  @Test("Another session closes the popover")
  func anotherSessionClosesThePopover() async {
    let workspace = await workspace()
    let model = workspace.model
    model.toggleNotes()
    #expect(model.notesPresentation.isPopoverShown)

    model.select(workspace.second.id)

    #expect(!model.notesPresentation.isPopoverShown)
  }

  @Test("The button's sheet has lines once the notes hold more than blanks")
  func iconFollowsTheNotes() async {
    let workspace = await workspace(notes: [1: "Already written"])
    let model = workspace.model
    await waitUntil("the notes are indexed") { model.notes.hasNotes(for: workspace.second.id) }
    #expect(!model.selectedSessionHasNotes)

    let document = model.notes.document(for: workspace.first.id)
    await waitUntil("the notes are read") { document.isLoaded }
    type("  \n", in: document)
    #expect(!model.selectedSessionHasNotes)
    type("A decision", in: document)
    #expect(model.selectedSessionHasNotes)

    model.select(workspace.second.id)
    #expect(model.selectedSessionHasNotes)
  }

  @Test("Detach opens the panel, Reattach the popover again, and the layout keeps the choice")
  func detachAndReattach() async {
    let workspace = await workspace()
    let model = workspace.model
    model.toggleNotes()

    model.detachNotes()
    #expect(model.notesPresentation.isPanelShown)
    #expect(!model.notesPresentation.isPopoverShown)
    #expect(model.layout.intent.notesPlacement == .panel)

    // The button shows and hides the panel from now on.
    model.toggleNotes()
    #expect(!model.notesPresentation.isPanelShown)
    #expect(!model.notesPresentation.isPopoverShown)
    model.toggleNotes()
    #expect(model.notesPresentation.isPanelShown)

    model.attachNotes()
    #expect(model.notesPresentation.isPopoverShown)
    #expect(!model.notesPresentation.isPanelShown)
    #expect(model.layout.intent.notesPlacement == .popover)
  }

  @Test("At launch the panel is closed, and Edit Notes opens it, where the user keeps the notes")
  func placementKept() async {
    let workspace = await workspace(layout: WorkspaceLayout(notesPlacement: .panel))
    let model = workspace.model
    #expect(!model.notesPresentation.isShown)

    model.focusNotes()

    #expect(model.notesPresentation.isPanelShown)
    #expect(!model.notesPresentation.isPopoverShown)
    #expect(model.notes.wantsFocus)
  }

  @Test("The panel follows the session on screen, and the one left has its notes written")
  func panelFollowsTheSelection() async throws {
    let workspace = await workspace()
    let model = workspace.model
    model.detachNotes()
    let document = model.notes.document(for: workspace.first.id)
    await waitUntil("the notes are read") { document.isLoaded }
    type("Left mid-sentence", in: document)

    model.select(workspace.second.id)

    #expect(model.notesPresentation.isPanelShown)
    #expect(model.notesPresentation.active?.sessionID == workspace.second.id)
    await waitUntil("the notes are written") { !document.hasUnsavedChanges }
    #expect(try await workspace.store.notes(for: workspace.first.id).text == "Left mid-sentence")

    // The button now puts the second session's window away.
    model.toggleNotes()
    #expect(!model.notesPresentation.isShown)
  }

  @Test("Reattaching after the panel followed another session opens that session's popover")
  func reattachAfterFollowing() async {
    let workspace = await workspace()
    let model = workspace.model
    model.detachNotes()
    model.select(workspace.second.id)

    model.attachNotes()

    #expect(model.selectedSessionID == workspace.second.id)
    #expect(model.notesPresentation.active?.sessionID == workspace.second.id)
    #expect(model.notesPresentation.isPopoverShown)
  }

  @Test("The panel closed by its own button stays closed, its placement kept")
  func panelClosed() async {
    let workspace = await workspace()
    let model = workspace.model
    model.detachNotes()

    model.notesPanelClosed()

    #expect(!model.notesPresentation.isShown)
    #expect(model.notesPresentation.placement == .panel)
  }

  @Test("Without a session, or behind a new session's draft, the button opens nothing")
  func noSession() async {
    let model = AppModel(repository: WorkspaceRepository(sessions: []))
    await model.load()
    #expect(!model.canShowNotes)

    model.toggleNotes()
    model.focusNotes()

    #expect(!model.notesPresentation.isShown)
  }
}

/// What the popover and the panel hold, in windows never put on screen.
@MainActor
@Suite("The notes' popover and panel", .serialized, .timeLimit(.minutes(2)))
struct NotesPresentationViewTests {
  private static func all<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
    guard let view else { return [] }
    let own = (view as? T).map { [$0] } ?? []
    return own + view.subviews.flatMap { all(type, in: $0) }
  }

  private static func editor(in view: NSView?) -> NSTextView? {
    all(NSTextView.self, in: view).first { $0.accessibilityIdentifier() == "notes-editor" }
  }

  private func model() async -> (AppModel, WorkSession) {
    let session = WorkSession(name: "Views", status: .closed)
    let model = AppModel(
      repository: WorkspaceRepository(sessions: [
        session, WorkSession(name: "Other", status: .closed),
      ]),
      notesStore: InMemorySessionNotesStore())
    await model.load()
    model.select(session.id)
    return (model, session)
  }

  /// The controller with nothing put on screen: the panels it would show, and an anchor for the
  /// popover in a window never shown.
  @MainActor
  private final class Screen {
    let controller: NotesPanelController
    let anchorWindow: NSWindow
    var shownPanels: [NotesPanel] = []
    /// Whether each panel shown took the keyboard.
    var keyboard: [Bool] = []
    var shownPopovers: [NSPopover] = []
    var popoverAnchors: [NSView] = []

    init(model: AppModel) {
      _ = NSApplication.shared
      controller = NotesPanelController(model: model, frameName: "VibeNotesPanel-\(UUID())")
      anchorWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled],
        backing: .buffered, defer: false)
      anchorWindow.isReleasedWhenClosed = false
      let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
      anchorWindow.contentView?.addSubview(anchor)
      controller.showPanel = { [unowned self] panel, takesKeyboard in
        self.shownPanels.append(panel)
        self.keyboard.append(takesKeyboard)
      }
      controller.toolbarPopover.present = { [unowned self] popover, anchor, _ in
        self.shownPopovers.append(popover)
        self.popoverAnchors.append(anchor)
      }
      controller.workspaceContent = { nil }
      model.notesPresentation.anchor = anchor
    }

    /// The popover and the panel alive, whatever their windows: one at most.
    var presentations: Int {
      (controller.popover == nil ? 0 : 1) + (controller.panel == nil ? 0 : 1)
    }

    func close() {
      controller.panel?.close()
      UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(controller.frameName)")
      anchorWindow.contentView = nil
      anchorWindow.close()
    }
  }

  @Test("Detach closes the popover and opens one panel on the same notes; Reattach the reverse")
  func detachAndReattachReplaceThePresentation() async throws {
    let (model, session) = await model()
    let screen = Screen(model: model)
    defer { screen.close() }
    let document = model.notes.document(for: session.id)
    await waitUntil("the notes are loaded") { document.isLoaded }

    model.toggleNotes()
    let popover = try #require(screen.controller.popover)
    #expect(screen.shownPopovers.count == 1)
    #expect(screen.presentations == 1)
    document.storage.append(NSAttributedString(string: "Typed, then detached"))
    document.didChange()

    model.detachNotes()
    #expect(screen.controller.popover == nil)
    #expect(popover.contentViewController == nil)
    let panel = try #require(screen.controller.panel)
    #expect(screen.shownPanels.map(ObjectIdentifier.init) == [ObjectIdentifier(panel)])
    #expect(screen.presentations == 1)
    await waitUntil("the panel's editor") { Self.editor(in: panel.contentView) != nil }
    let editor = try #require(Self.editor(in: panel.contentView))
    #expect(editor.string == "Typed, then detached")
    editor.insertText(
      " and in the panel",
      replacementRange: NSRange(location: editor.string.utf16.count, length: 0))

    model.attachNotes()
    #expect(screen.controller.panel == nil)
    #expect(panel.contentView == nil)
    #expect(!panel.isVisible)
    #expect(screen.controller.popover != nil)
    #expect(screen.shownPopovers.count == 2)
    #expect(screen.presentations == 1)
    // Pending focus requests run: none may bring the closed panel back.
    for _ in 0..<10 { await Task.yield() }
    #expect(!panel.isVisible)
    #expect(screen.shownPanels.count == 1)
    #expect(document.text == "Typed, then detached and in the panel")
  }

  @Test("Another session selected: a new window, that session's, replaces the floating window")
  func panelReplacedOnSelection() async throws {
    let (model, first) = await model()
    let second = try #require(model.sessions.first { $0.name == "Other" })
    let screen = Screen(model: model)
    defer { screen.close() }
    let firstDocument = model.notes.document(for: first.id)
    let secondDocument = model.notes.document(for: second.id)
    await waitUntil("the notes are loaded") { firstDocument.isLoaded && secondDocument.isLoaded }
    firstDocument.storage.append(NSAttributedString(string: "Only in Views"))
    firstDocument.didChange()
    secondDocument.storage.append(NSAttributedString(string: "Only in Other"))
    secondDocument.didChange()
    model.detachNotes()
    let firstPanel = try #require(screen.controller.panel)
    await waitUntil("the editor") { Self.editor(in: firstPanel.contentView) != nil }

    model.showFromSelection(second.id)

    let secondPanel = try #require(screen.controller.panel)
    #expect(secondPanel !== firstPanel)
    #expect(firstPanel.contentView == nil)
    #expect(!firstPanel.isVisible)
    #expect(screen.presentations == 1)
    #expect(secondPanel.title == "Notes · Other")
    // Choosing a session is not writing notes: the keyboard stays where it was.
    #expect(screen.keyboard == [true, false])
    await waitUntil("the editor") { Self.editor(in: secondPanel.contentView) != nil }
    #expect(Self.editor(in: secondPanel.contentView)?.string == "Only in Other")
    #expect(Self.editor(in: secondPanel.contentView)?.accessibilityLabel() == "Notes for Other")
    #expect(firstDocument.text == "Only in Views")

    // Back on the first session: one window again, the first session's.
    model.showFromSelection(first.id)
    let again = try #require(screen.controller.panel)
    #expect(again !== secondPanel)
    #expect(secondPanel.contentView == nil)
    #expect(screen.presentations == 1)
    #expect(again.title == "Notes · Views")
    await waitUntil("the editor") { Self.editor(in: again.contentView) != nil }
    #expect(Self.editor(in: again.contentView)?.string == "Only in Views")
    #expect(secondDocument.text == "Only in Other")
  }

  @Test("A session renamed while its notes are open: the panel's title and the editor's name follow")
  func renameFollowed() async throws {
    let (model, session) = await model()
    let screen = Screen(model: model)
    defer { screen.close() }
    model.detachNotes()
    let panel = try #require(screen.controller.panel)
    await waitUntil("the editor") { Self.editor(in: panel.contentView) != nil }

    #expect(await model.commitRename(session.id, to: "Renamed") == nil)

    await waitUntil("the title follows") {
      panel.contentView?.layoutSubtreeIfNeeded()
      return panel.title == "Notes · Renamed"
    }
    await waitUntil("the editor's name follows") {
      Self.editor(in: panel.contentView)?.accessibilityLabel() == "Notes for Renamed"
    }
  }

  @Test("With the button in no window, the popover opens at the workspace window's corner")
  func popoverWithoutTheButton() async throws {
    let (model, _) = await model()
    let screen = Screen(model: model)
    defer { screen.close() }
    // The button folded into the toolbar's overflow menu: its view is in no window.
    let folded = NSView()
    model.notesPresentation.anchor = folded
    let content = try #require(screen.anchorWindow.contentView)
    screen.controller.workspaceContent = { content }

    model.toggleNotes()

    #expect(screen.controller.popover != nil)
    #expect(screen.popoverAnchors.map(ObjectIdentifier.init) == [ObjectIdentifier(content)])
    #expect(model.notesPresentation.isPopoverShown)
    withExtendedLifetime(folded) {}
  }

  @Test("Each window that replaces the panel keeps its place under the name, where it is moved to")
  func replacementKeepsThePlace() async throws {
    let (model, first) = await model()
    let second = try #require(model.sessions.first { $0.name == "Other" })
    let screen = Screen(model: model)
    defer { screen.close() }
    let key = "NSWindow Frame \(screen.controller.frameName)"
    // Where AppKit wrote the panel's place: the origin, first two numbers of the frame.
    func saved() -> [Substring] {
      (UserDefaults.standard.string(forKey: key) ?? "").split(separator: " ").prefix(2).map { $0 }
    }
    model.detachNotes()
    let firstPanel = try #require(screen.controller.panel)
    firstPanel.setFrameOrigin(NSPoint(x: 140, y: 220))

    model.showFromSelection(second.id)
    let secondPanel = try #require(screen.controller.panel)
    #expect(secondPanel.frameAutosaveName == screen.controller.frameName)
    #expect(saved() == ["140", "220"])
    secondPanel.setFrameOrigin(NSPoint(x: 310, y: 260))

    model.showFromSelection(first.id)
    let again = try #require(screen.controller.panel)
    #expect(again.frameAutosaveName == screen.controller.frameName)
    #expect(saved() == ["310", "260"])
  }

  @Test("The popover closes with another session; the button opens that session's popover")
  func popoverFollowsTheSelection() async throws {
    let (model, _) = await model()
    let second = try #require(model.sessions.first { $0.name == "Other" })
    let screen = Screen(model: model)
    defer { screen.close() }
    model.toggleNotes()
    let first = try #require(screen.controller.popover)

    model.select(second.id)
    #expect(screen.controller.popover == nil)
    #expect(first.contentViewController == nil)
    #expect(screen.presentations == 0)

    model.toggleNotes()
    #expect(screen.controller.popover != nil)
    #expect(model.notesPresentation.active?.sessionID == second.id)
    #expect(screen.presentations == 1)
  }

  @Test("The panel closed by its own button stays closed; the button opens a fresh one")
  func panelClosedAndReopened() async throws {
    let (model, session) = await model()
    let screen = Screen(model: model)
    defer { screen.close() }
    let document = model.notes.document(for: session.id)
    await waitUntil("the notes are loaded") { document.isLoaded }
    document.storage.append(NSAttributedString(string: "Kept"))
    document.didChange()
    model.detachNotes()
    let first = try #require(screen.controller.panel)

    // Its own close button: the window closes, then tells its delegate.
    first.close()
    #expect(!model.notesPresentation.isShown)
    #expect(screen.controller.panel == nil)
    #expect(first.contentView == nil)

    model.toggleNotes()
    let second = try #require(screen.controller.panel)
    #expect(second !== first)
    #expect(screen.presentations == 1)
    await waitUntil("the editor") { Self.editor(in: second.contentView) != nil }
    #expect(Self.editor(in: second.contentView)?.string == "Kept")
  }

  @Test("A window closing late cannot put its replacement away")
  func lateCloseIsIgnored() async throws {
    let (model, _) = await model()
    let screen = Screen(model: model)
    defer { screen.close() }
    model.detachNotes()
    let old = try #require(screen.controller.panel)
    model.attachNotes()
    let popover = try #require(screen.controller.popover)
    model.detachNotes()

    screen.controller.windowWillClose(
      Notification(name: NSWindow.willCloseNotification, object: old))
    screen.controller.toolbarPopover.popoverDidClose(
      Notification(name: NSPopover.didCloseNotification, object: popover))

    #expect(model.notesPresentation.isPanelShown)
    #expect(screen.controller.panel != nil)
    #expect(screen.presentations == 1)
  }

  @Test("The click on the button that closes the popover does not open it again")
  func buttonClickClosingThePopover() async {
    let (model, _) = await model()
    let screen = Screen(model: model)
    defer { screen.close() }
    screen.controller.toolbarPopover.actsOnMouseUp = { true }
    model.toggleNotes()
    // AppKit's transient popover closes on the mouse down; the button acts on the mouse up.
    let closed = ProcessInfo.processInfo.systemUptime
    screen.controller.toolbarPopover.closedByClick(at: closed)
    model.notesPopoverDismissed()
    // The monitor sees that same mouse down: it does not end the click.
    screen.controller.toolbarPopover.clickBegan(at: closed)

    model.toggleNotes()
    #expect(!model.notesPresentation.isShown)
    #expect(screen.presentations == 0)

    model.toggleNotes()
    #expect(model.notesPresentation.isPopoverShown)
  }

  @Test("A click elsewhere closes the popover, and the next click on the button opens it")
  func clickElsewhereThenButton() async {
    let (model, _) = await model()
    let screen = Screen(model: model)
    defer { screen.close() }
    screen.controller.toolbarPopover.actsOnMouseUp = { true }
    model.toggleNotes()
    let closed = ProcessInfo.processInfo.systemUptime
    screen.controller.toolbarPopover.closedByClick(at: closed)
    model.notesPopoverDismissed()
    // Another click begins, this time on the button.
    screen.controller.toolbarPopover.clickBegan(at: closed + 0.2)

    model.toggleNotes()
    #expect(model.notesPresentation.isPopoverShown)
  }

  @Test("A click elsewhere closes the popover; the button pressed from the keyboard opens it")
  func clickElsewhereThenKeyboard() async {
    let (model, _) = await model()
    let screen = Screen(model: model)
    defer { screen.close() }
    screen.controller.toolbarPopover.actsOnMouseUp = { false }
    model.toggleNotes()
    screen.controller.toolbarPopover.closedByClick(at: ProcessInfo.processInfo.systemUptime)
    model.notesPopoverDismissed()

    model.toggleNotes()
    #expect(model.notesPresentation.isPopoverShown)
  }

  @Test("The popover holds the session's editor and the Detach button")
  func popover() async throws {
    let (model, session) = await model()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 460), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer {
      window.contentView = nil
      window.close()
    }
    let host = NSHostingView(rootView: NotesPopoverContent(model: model, session: session))
    window.contentView = host

    await waitUntil("the editor") { Self.editor(in: host) != nil }
    #expect(Self.editor(in: host)?.accessibilityLabel() == "Notes for Views")
  }

  @Test("The panel holds the editor, and Reattach in its title bar; its title names the session")
  func panel() async throws {
    let (model, session) = await model()
    let controller = NotesPanelController(model: model, frameName: "VibeNotesPanel-\(UUID())")
    defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(controller.frameName)") }
    let panel = controller.makePanel(session: session)
    defer {
      panel.contentView = nil
      panel.close()
    }

    #expect(!panel.isVisible)
    #expect(panel.title == "Notes · Views")
    #expect(panel.styleMask.contains(.resizable))
    #expect(panel.level == .floating)
    #expect(panel.titlebarAccessoryViewControllers.count == 1)
    #expect(
      panel.titlebarAccessoryViewControllers.first?.view is NSHostingView<NotesReattachButton>)
    await waitUntil("the editor") { Self.editor(in: panel.contentView) != nil }
  }
}
