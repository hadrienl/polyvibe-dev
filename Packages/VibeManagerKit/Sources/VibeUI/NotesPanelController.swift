import AppKit
import SwiftUI
import VibeDomain

/// The notes' floating window (#578): a utility panel above the application's windows, moved and
/// resized as any window. It hides while another application is in front, like every panel.
final class NotesPanel: NSPanel {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
      styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
    level = .floating
    hidesOnDeactivate = true
    // Typed into: it takes the keyboard on a click, not only when a field asks for it.
    becomesKeyOnlyIfNeeded = false
    isReleasedWhenClosed = false
    minSize = NSSize(width: 260, height: 220)
    collectionBehavior = [.fullScreenAuxiliary]
    isExcludedFromWindowsMenu = true
    setAccessibilityIdentifier("notes-panel")
  }

  // The workspace window stays the main one: its menus and ⇧⌘W still talk to the session.
  override var canBecomeMain: Bool { false }
}

/// Puts on screen what `NotesPresentation.active` says, and nothing else: the popover under the
/// toolbar's button or the floating panel, for one session.
///
/// Both are AppKit's, owned here rather than by SwiftUI bindings, so that a change is one
/// synchronous step: the window showing the previous request closes and lets go of its editor,
/// then a new one opens on the next request's session. Each window is built for one session and
/// never retargeted — its title and its document are that session's for as long as it is open;
/// the panel following the selection is a new panel, at the same place.
///
/// The panel's place and size are AppKit's to keep, under its frame name: the user finds it where
/// they left it, from one launch to the next.
@MainActor
public final class NotesPanelController: NSObject, NSWindowDelegate {
  /// Where AppKit keeps the panel's place. A name a test gives its own controller: AppKit lends a
  /// name to one window at a time, and tests run side by side.
  let frameName: String

  private let model: AppModel
  private(set) var panel: NotesPanel?
  /// Under the toolbar's button, as the simulators' list.
  let toolbarPopover = ToolbarPopover()
  var popover: NSPopover? { toolbarPopover.popover }
  /// The request the window on screen shows; `nil` with nothing on screen, including a popover
  /// waiting for the toolbar's button to be back in the toolbar.
  private(set) var displayed: NotesPresentation.Request?
  /// Puts the panel on screen, with the keyboard or without. Tests keep it off the screen and read
  /// the panel instead.
  var showPanel: (NotesPanel, Bool) -> Void = { panel, takesKeyboard in
    if takesKeyboard { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
  }

  public init(model: AppModel, frameName: String = "VibeNotesPanel") {
    self.model = model
    self.frameName = frameName
    super.init()
    model.notesPresentation.returnFromPanel = { [weak self] in self?.returnKeyboard() }
    model.notesPresentation.changed = { [weak self] in self?.update() }
    model.notesPresentation.pressEndsClosingClick = { [weak self] in
      self?.toolbarPopover.pressEndsClosingClick() ?? false
    }
    toolbarPopover.identifier = "notes-popover"
    // A click elsewhere, or Escape outside the editor.
    toolbarPopover.didClose = { [weak self] in
      guard let self, let request = self.displayed else { return }
      self.model.notesPresentation.dismiss(request.id)
    }
    update()
  }

  private func update() {
    let request = model.notesPresentation.active
    guard request != displayed else { return }
    let wasKey = panel?.isKeyWindow == true
    // Put away, the popover fades as the simulators' does; replaced, it goes at once.
    closeCurrent(animated: request == nil)
    guard let request,
      let session = model.sessions.first(where: { $0.id == request.sessionID })
    else { return }
    switch request.placement {
    case .panel:
      displayed = request
      let panel = makePanel(session: session)
      self.panel = panel
      showPanel(panel, request.activates || wasKey)
    case .popover:
      toolbarPopover.anchor = model.notesPresentation.anchor
      displayed = request
      if !toolbarPopover.show(NotesPopoverContent(model: model, session: session)) {
        displayed = nil
      }
    }
  }

  /// The workspace window's content, for a popover whose button is in no window. Tests give
  /// their own.
  var workspaceContent: () -> NSView? {
    get { toolbarPopover.fallbackView }
    set { toolbarPopover.fallbackView = newValue }
  }

  /// Closes whatever is on screen and destroys its editor: hidden but alive, an editor would still
  /// answer focus requests, and bring its window back.
  private func closeCurrent(animated: Bool) {
    displayed = nil
    toolbarPopover.close(animated: animated)
    if let panel {
      self.panel = nil
      panel.delegate = nil
      if panel.isKeyWindow { returnKeyboard() }
      // Its place written, and its name given up: the window kept alive below would still hold
      // it, and AppKit gives a name to one window at a time — the replacement would open where
      // the first panel was, and never write where it is moved to.
      panel.saveFrame(usingName: frameName)
      panel.setFrameAutosaveName("")
      panel.orderOut(nil)
      panel.contentView = nil
      panel.close()
      // The Reattach button, in the panel's title bar, closing its own window.
      DispatchQueue.main.async { withExtendedLifetime(panel) {} }
    }
  }

  /// The panel and everything in it, never shown here: tests read it without a window on screen.
  func makePanel(session: WorkSession) -> NotesPanel {
    let panel = NotesPanel()
    panel.delegate = self
    panel.contentView = NSHostingView(
      rootView: NotesPanelContent(model: model, session: session) { [weak panel] name in
        panel?.title = Self.title(of: name)
      })
    let accessory = NSTitlebarAccessoryViewController()
    let button = NSHostingView(rootView: NotesReattachButton(model: model))
    button.frame.size = button.fittingSize
    accessory.view = button
    accessory.layoutAttribute = .trailing
    panel.addTitlebarAccessoryViewController(accessory)
    panel.title = Self.title(of: session.name)
    if !panel.setFrameUsingName(frameName) {
      place(panel)
    }
    panel.setFrameAutosaveName(frameName)
    return panel
  }

  static func title(of name: String) -> String {
    String(
      localized: "Notes · \(name)", bundle: .module,
      comment: "The title of the notes' floating window: the session's name.")
  }

  /// The first time: at the top right of the workspace window, over the conversation.
  private func place(_ panel: NotesPanel) {
    guard let main = NSApp.mainWindow else {
      panel.center()
      return
    }
    let size = panel.frame.size
    panel.setFrameOrigin(
      NSPoint(x: main.frame.maxX - size.width - 24, y: main.frame.maxY - size.height - 72))
  }

  /// The workspace window takes the keyboard back: Escape in the panel's editor, a second Edit
  /// Notes, the panel put away.
  private func returnKeyboard() {
    let workspace = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
    workspace?.makeKeyAndOrderFront(nil)
  }

  // MARK: NSWindowDelegate

  /// Its own button, or ⌘W.
  public func windowWillClose(_ notification: Notification) {
    guard let closing = notification.object as? NSWindow, closing === panel,
      let request = displayed
    else { return }
    // Already closing: `closeCurrent` must not close it again from its own delegate.
    closing.delegate = nil
    closing.contentView = nil
    panel = nil
    displayed = nil
    model.notesPresentation.dismiss(request.id)
  }

  public func windowDidBecomeKey(_ notification: Notification) {
    if notification.object as? NSWindow === panel { model.notesPresentation.isPanelKey = true }
  }

  public func windowDidResignKey(_ notification: Notification) {
    if notification.object as? NSWindow === panel { model.notesPresentation.isPanelKey = false }
  }
}
