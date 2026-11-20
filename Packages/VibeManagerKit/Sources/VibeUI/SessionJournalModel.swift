import Foundation
import Observation
import VibeApplication
import VibeDomain

/// The journal of every session (#36): the tickets, requests, branches and worktrees it used, for
/// Open Quickly and for a coordinator reading its children. No pane shows it any more (#572).
@MainActor
@Observable
public final class SessionJournalModel {
  /// One cell per session (#254): reading one session's journal is not told of another's.
  @ObservationIgnored let journals = ObservedCells<SessionID, SessionJournal>()

  @ObservationIgnored private let monitor: SessionJournalMonitor
  @ObservationIgnored private var updates: Task<Void, Never>?
  /// The last list of sessions handed to the monitor. Each waits for the one before it: an older
  /// list arriving after a newer one would follow a session just closed again.
  @ObservationIgnored private var tracking: Task<Void, Never>?
  /// Told of every journal that arrives, for Open Quickly's index (#37).
  @ObservationIgnored var journalDidChange: ((SessionID, SessionJournal) -> Void)?

  /// Reads the journal of any session, off the main thread: for the index of Open Quickly.
  var reader: @Sendable (SessionID) async -> SessionJournal? {
    let monitor = monitor
    return { await monitor.journal(for: $0) }
  }

  public init(monitor: SessionJournalMonitor) {
    self.monitor = monitor
  }

  // MARK: - Following the monitor

  func start() async {
    guard updates == nil else { return }
    let stream = await monitor.updates()
    updates = Task { [weak self] in
      for await update in stream {
        guard let self else { return }
        // Open Quickly indexes a journal again only when it changed.
        if self.journals.set(update.journal, for: update.sessionID) {
          self.journalDidChange?(update.sessionID, update.journal)
        }
      }
    }
  }

  /// Hands the monitor a list of sessions, after the lists handed before it. Chained here, on the
  /// main actor, so that the order the lists were made in is the order they arrive in.
  func track(_ sessions: [WorkSession]) {
    let previous = tracking
    tracking = Task { [monitor] in
      await previous?.value
      await monitor.track(sessions)
    }
  }

  func refresh() async {
    await monitor.refresh()
  }

  func stop() async {
    updates?.cancel()
    updates = nil
    await monitor.stop()
  }

  func journal(for id: SessionID) -> SessionJournal? {
    journals.value(for: id)
  }
}
