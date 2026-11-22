import AppKit
import Observation
import VibeApplication
import VibeDomain

/// Where the session's notes are on screen (#578): under the toolbar's button, in a floating
/// window, or nowhere.
///
/// One presentation at a time, for one session: `active` says which session's notes are shown and
/// how. Opening the other placement, or another session's notes, replaces it — the window or the
/// popover that showed the previous one closes before the next opens. A floating window keeps the
/// session it was opened for: selecting another session in the workspace changes neither its title
/// nor what it edits.
///
/// The placement — popover or panel — is the user's and is kept in the layout; whether either is
/// open is not, and a relaunch opens neither.
@MainActor
@Observable
public final class NotesPresentation {
  /// One opening of the notes. A fresh identity each time, so that a window closing late — its
  /// delegate called after its replacement opened — cannot put the replacement away.
  struct Request: Equatable {
    let id = UUID()
    let sessionID: SessionID
    let placement: NotesPlacement
  }

  /// What is on screen, if anything.
  private(set) var active: Request? {
    didSet {
      guard active != oldValue else { return }
      isPanelKey = false
      // Every keystroke is written already; what waits for its pause is written now, so that
      // nothing stays Edited once the notes are out of sight.
      if let oldValue {
        Task { [notes] in await notes.flush(oldValue.sessionID) }
      }
      changed?()
    }
  }

  /// AppKit closes the previous presentation and opens the next one, synchronously. Set by
  /// `NotesPanelController`, which owns both windows.
  @ObservationIgnored var changed: (() -> Void)?
  /// The toolbar button's view, under which the popover opens. `nil` while the button is out of
  /// the toolbar: the popover then opens once it is back.
  @ObservationIgnored weak var anchor: NSView?
  /// Whether the panel holds the keyboard, as its window says: a second Edit Notes hands it back.
  @ObservationIgnored var isPanelKey = false
  /// Gives the keyboard back to the workspace window, for the panel's editor to let go of it. Set
  /// by the panel's controller, which knows the windows.
  @ObservationIgnored var returnFromPanel: (() -> Void)?
  /// When a click on the toolbar's button closed the popover, by the events' clock.
  @ObservationIgnored private var popoverClosedByClickAt: TimeInterval?

  private let layout: WorkspaceLayoutController
  private let notes: NotesModel

  init(layout: WorkspaceLayoutController, notes: NotesModel) {
    self.layout = layout
    self.notes = notes
  }

  /// Where the user keeps the notes.
  public var placement: NotesPlacement { layout.notesPlacement }
  public var isPopoverShown: Bool { active?.placement == .popover }
  public var isPanelShown: Bool { active?.placement == .panel }
  /// Whether the notes are on screen, in whichever placement.
  public var isShown: Bool { active != nil }

  /// Shows a session's notes — where the user keeps them, or in `placement`, which becomes where
  /// they are kept from now on. Whatever showed notes before is replaced.
  func show(for sessionID: SessionID, placement: NotesPlacement? = nil) {
    if let placement { layout.setNotesPlacement(placement) }
    let mode = placement ?? self.placement
    guard active?.sessionID != sessionID || active?.placement != mode else { return }
    active = Request(sessionID: sessionID, placement: mode)
  }

  /// The toolbar's button: puts this session's notes away, or shows them in place of anything
  /// else.
  func toggle(for sessionID: SessionID) {
    // The click that closed the popover, now acting on the button: the notes stay away.
    if let closed = popoverClosedByClickAt {
      popoverClosedByClickAt = nil
      if ProcessInfo.processInfo.systemUptime - closed < 1.5 { return }
    }
    if active?.sessionID == sessionID { dismiss() } else { show(for: sessionID) }
  }

  /// The transient popover closes on the mouse down, before the button acts on the mouse up.
  func closedByButtonClick(at timestamp: TimeInterval) {
    popoverClosedByClickAt = timestamp
  }

  /// Puts the notes away. With `requestID`, only if that opening is still the one on screen.
  func dismiss(_ requestID: UUID? = nil) {
    guard requestID == nil || active?.id == requestID else { return }
    active = nil
  }

  /// Closed by a click elsewhere, Escape, ⌘W, or another session.
  func popoverClosed() {
    if isPopoverShown { dismiss() }
  }

  /// Closed by its own button or ⌘W.
  func panelClosed() {
    if isPanelShown { dismiss() }
  }
}

extension AppModel {
  /// The toolbar's Notes button (#578). Without a session there are no notes to show.
  public var canShowNotes: Bool { selectedSession != nil && !isPresentingNewSession }

  /// Whether the session on screen has notes: what the button's icon says, a sheet with lines or
  /// an empty one.
  public var selectedSessionHasNotes: Bool {
    guard let id = selectedSessionID else { return false }
    return notes.hasNotes(for: id)
  }

  /// The toolbar's button. Showing another session's floating window, it brings this session's
  /// notes in its place.
  public func toggleNotes() {
    guard canShowNotes, let id = selectedSessionID else {
      notesPresentation.dismiss()
      return
    }
    notesPresentation.toggle(for: id)
  }

  /// Edit Notes: the editor opens where the user keeps it and takes the keyboard. Asked again while
  /// it holds the keyboard, the keyboard goes back to the session.
  public func focusNotes() {
    guard canShowNotes, let id = selectedSessionID else { return }
    let presentation = notesPresentation
    if presentation.active?.sessionID == id,
      presentation.isPopoverShown || presentation.isPanelKey
    {
      leaveNotes()
      return
    }
    presentation.show(for: id)
    notes.requestFocus()
  }

  /// Escape in the editor, or a second Edit Notes: the popover closes, the panel stays, and the
  /// session takes the keyboard back.
  public func leaveNotes() {
    if notesPresentation.isPopoverShown { notesPresentation.dismiss() }
    if notesPresentation.isPanelKey { notesPresentation.returnFromPanel?() }
    focusSession()
  }

  /// Detach to a Floating Window: the popover closes, the panel opens on the same session's notes,
  /// and the notes are kept there from now on.
  public func detachNotes() {
    guard let id = notesPresentation.active?.sessionID ?? selectedSessionID else { return }
    notesPresentation.show(for: id, placement: .panel)
    notes.requestFocus()
  }

  /// Reattach: the panel closes and the popover opens under the toolbar's button, from now on.
  public func attachNotes() {
    guard let id = notesPresentation.active?.sessionID ?? selectedSessionID else { return }
    // The popover belongs to the session on screen: the workspace comes back to the panel's
    // session first, never A's notes under B's toolbar.
    if selectedSessionID != id { select(id) }
    notesPresentation.show(for: id, placement: .popover)
    notes.requestFocus()
  }

  /// The popover dismissed by AppKit: a click elsewhere, or Escape outside the editor.
  public func notesPopoverDismissed() { notesPresentation.popoverClosed() }

  /// The panel closed by its own button or ⌘W.
  public func notesPanelClosed() { notesPresentation.panelClosed() }

  /// Another session on screen: the popover closes over the notes it was showing; a floating
  /// window stays, on the session it was opened for.
  func notesSelectionChanged() { notesPresentation.popoverClosed() }
}
