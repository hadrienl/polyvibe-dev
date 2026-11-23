import SwiftUI
import VibeApplication
import VibeConversationUI
import VibeDomain

/// The session's notes, from the toolbar (#578): a sheet with lines when there are notes, an empty
/// one otherwise. It opens the editor under it, or shows and hides the floating panel.
struct NotesToolbarButton: View {
  let model: AppModel

  var body: some View {
    let presentation = model.notesPresentation
    let hasNotes = model.selectedSessionHasNotes
    Button {
      model.toggleNotes()
    } label: {
      Label {
        Text("Session Notes", bundle: .module)
      } icon: {
        Image(systemName: hasNotes ? "doc.text" : "doc")
      }
    }
    .disabled(!model.canShowNotes && !presentation.isShown)
    .instantTooltip(Text("Session Notes", bundle: .module))
    .accessibilityValue(accessibilityValue(hasNotes: hasNotes, presentation: presentation))
    .background(NotesPopoverAnchor(presentation: presentation).allowsHitTesting(false))
  }

  /// Whether there are notes; in the panel's placement, first whether the panel is shown, the
  /// button being its switch.
  private func accessibilityValue(hasNotes: Bool, presentation: NotesPresentation) -> Text {
    let notes =
      hasNotes
      ? Text("Contains notes", bundle: .module, comment: "Said of the toolbar's Notes button.")
      : Text("Empty", bundle: .module, comment: "Said of a session's notes that hold nothing.")
    guard presentation.placement == .panel else { return notes }
    let shown =
      presentation.isPanelShown && presentation.active?.sessionID == model.selectedSessionID
      ? Text("Shown", bundle: .module, comment: "The notes' floating window is shown.")
      : Text("Hidden", bundle: .module, comment: "The notes' floating window is hidden.")
    return shown + Text(verbatim: ", ") + notes
  }
}

/// The editor under the toolbar's button: the notes as the column showed them, with their state,
/// and the way out to a floating window.
struct NotesPopoverContent: View {
  let model: AppModel
  let session: WorkSession

  var body: some View {
    let document = model.notes.document(for: session.id)
    // As it is named now: a rename while the notes are open shows at once.
    let session = model.session(withID: session.id) ?? session
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text("Notes", bundle: .module, comment: "The heading of a session's notes.")
          .font(.headline)
        Text(session.name)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 8)
        NotesStateLabel(document: document)
        Button {
          model.detachNotes()
        } label: {
          Image(systemName: "pip.enter")
        }
        .buttonStyle(.borderless)
        .instantTooltip(Self.detach)
        .accessibilityLabel(Self.detach)
        .accessibilityIdentifier("notes-detach")
      }
      .padding(.horizontal, 12)
      .padding(.top, 10)
      .padding(.bottom, 2)
      SessionNotesSection(
        session: session, document: document, notes: model.notes,
        ticketTitles: model.ticketTitles, leave: { model.leaveNotes() })
    }
    .frame(width: 380, height: 440)
  }

  static var detach: Text {
    Text("Detach to a Floating Window", bundle: .module)
  }
}

/// The panel captures its session once, together with the document it edits. Its name is read as
/// it is now, and handed to the window's title when it changes.
struct NotesPanelContent: View {
  let model: AppModel
  let session: WorkSession
  var retitle: (String) -> Void = { _ in }

  var body: some View {
    let document = model.notes.document(for: session.id)
    let session = model.session(withID: session.id) ?? session
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Spacer(minLength: 0)
        NotesStateLabel(document: document)
      }
      .padding(.horizontal, 12)
      .padding(.top, 6)
      SessionNotesSection(
        session: session, document: document, notes: model.notes,
        ticketTitles: model.ticketTitles, leave: { model.leaveNotes() })
    }
    .id(session.id)
    .frame(minWidth: 260, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
    .onChange(of: session.name) { _, name in retitle(name) }
  }
}

/// In the panel's title bar: back to the popover under the toolbar's button.
struct NotesReattachButton: View {
  let model: AppModel

  var body: some View {
    Button {
      model.attachNotes()
    } label: {
      Image(systemName: "pip.exit")
    }
    .buttonStyle(.borderless)
    .instantTooltip(Self.reattach)
    .accessibilityLabel(Self.reattach)
    .accessibilityIdentifier("notes-reattach")
    .padding(.horizontal, 8)
  }

  static var reattach: Text {
    Text("Reattach to the Toolbar", bundle: .module)
  }
}

/// A stable native anchor in the toolbar. The controller, rather than a SwiftUI presentation
/// binding, owns the NSPopover and dismisses its window before opening the panel.
private struct NotesPopoverAnchor: NSViewRepresentable {
  let presentation: NotesPresentation

  func makeNSView(context: Context) -> AnchorView {
    let view = AnchorView()
    view.presentation = presentation
    return view
  }

  func updateNSView(_ view: AnchorView, context: Context) {}

  final class AnchorView: NSView {
    weak var presentation: NotesPresentation?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else { return }
      Task { @MainActor [weak self] in
        guard let self, self.window != nil, let presentation = self.presentation else { return }
        presentation.anchor = self
        presentation.changed?()
      }
    }
  }
}
