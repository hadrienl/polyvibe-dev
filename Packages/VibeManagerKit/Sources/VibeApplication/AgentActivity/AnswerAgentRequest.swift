import Foundation
import VibeDomain

/// Answers a request of an agent from outside its terminal (#40), by typing into that terminal
/// exactly what the user would.
///
/// No other way to the agent exists: no hook that decides, no API. What the terminal shows stays
/// true, and the answer reads in it afterwards as if it had been typed. The keys go to the
/// terminal of the request's own session, looked up when they are written — the session in front
/// of the user is never touched.
public struct AnswerAgentRequest: Sendable {
  public struct Failure: Sendable {
    public let requestID: String
    public let outcome: Outcome
    public let request: String
    public let answer: String
    public let before: String
    public let after: String
    public let keys: [[UInt8]]
    public let writtenKeys: [[UInt8]]

    public init(
      requestID: String, outcome: Outcome, request: String, answer: String,
      before: String, after: String, keys: [[UInt8]], writtenKeys: [[UInt8]]
    ) {
      self.requestID = requestID
      self.outcome = outcome
      self.request = request
      self.answer = answer
      self.before = before
      self.after = after
      self.keys = keys
      self.writtenKeys = writtenKeys
    }
  }
  public enum Outcome: String, Hashable, Sendable, DiagnosticTokenConvertible {
    case sent
    /// The request is no longer the one on screen: answered, refused or gone meanwhile.
    case requestGone
    /// The request is there, but this answer cannot be given to it from outside.
    case notAnswerable
    /// The session has no running terminal to type into.
    case terminalUnavailable
    /// The request went away between two keystrokes of a longer answer, or its dialog did not move
    /// on to what the next one answers: the rest was not typed.
    case interrupted
    /// The dialog drawn in the terminal does not offer this answer, or could not be read: nothing
    /// was typed (#273).
    case notOnScreen
    /// The dialog drawn in the terminal is not known to be the request's: it shows another's, or
    /// one more request's, or cannot be read whole. Nothing was typed (#283).
    case otherDialog
  }

  /// How long a terminal must stay silent before the next keystroke, and how long it is waited for
  /// at most: an interface redraws after each key, and the next one must reach the redrawn dialog.
  public static let quietPeriod: Duration = .milliseconds(80)
  public static let settleLimit: Duration = .seconds(1)

  private let tracker: TrackAgentActivity
  private let write: @Sendable (SessionID, [UInt8]) async -> Bool
  private let lastOutput: @Sendable (SessionID) async -> ContinuousClock.Instant?
  private let screen: @Sendable (SessionID) async -> String?
  private let redraw: @Sendable (SessionID) async -> Bool
  private let sleep: @Sendable (Duration) async throws -> Void
  private let diagnostics: Diagnostics
  private let confirmsDelivery: Bool
  private let unreadKeyLimit: Duration
  private let failed: @Sendable (Failure) async -> Void

  /// - Parameters:
  ///   - write: types bytes into the session's running terminal; `false` when none runs.
  ///   - lastOutput: when the session's terminal last wrote something.
  ///   - screen: what the session's terminal shows now, as text; `nil` when it cannot be told.
  ///   - redraw: has the session's agent draw its whole screen again, when what `screen` reads
  ///     cannot be all of it — its history trimmed (#563); `false` when nothing was asked.
  public init(
    tracker: TrackAgentActivity,
    write: @escaping @Sendable (SessionID, [UInt8]) async -> Bool,
    lastOutput: @escaping @Sendable (SessionID) async -> ContinuousClock.Instant? = { _ in nil },
    screen: @escaping @Sendable (SessionID) async -> String? = { _ in nil },
    redraw: @escaping @Sendable (SessionID) async -> Bool = { _ in false },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    diagnostics: Diagnostics = .disabled,
    confirmsDelivery: Bool = false,
    unreadKeyLimit: Duration = AnswerAgentRequest.unreadKeyLimit,
    failed: @escaping @Sendable (Failure) async -> Void = { _ in }
  ) {
    self.tracker = tracker
    self.write = write
    self.lastOutput = lastOutput
    self.screen = screen
    self.redraw = redraw
    self.sleep = sleep
    self.diagnostics = diagnostics
    self.confirmsDelivery = confirmsDelivery
    self.unreadKeyLimit = unreadKeyLimit
    self.failed = failed
  }

  @discardableResult
  public func callAsFunction(_ answer: AgentAnswer, to id: AgentRequestID) async -> Outcome {
    let request = await tracker.state(for: id.sessionID)?.requests.first { $0.id == id }
    var before = await screen(id.sessionID)
    var keys =
      await tracker.keystrokes(
        for: answer, to: id, screen: await tracker.dialogScreen(before, in: id.sessionID)) ?? []
    var written: [[UInt8]] = []
    var redrawn: String?
    let outcome = await give(answer, to: id, written: &written, redrawn: &redrawn)
    // Drawn again before anything was typed: the report shows what the keys were read off.
    if let redrawn {
      before = redrawn
      keys =
        await tracker.keystrokes(
          for: answer, to: id, screen: await tracker.dialogScreen(redrawn, in: id.sessionID)) ?? []
    }
    if [.notOnScreen, .otherDialog, .interrupted].contains(outcome), let request {
      await failed(
        Failure(
          requestID: String(describing: id), outcome: outcome,
          request: String(reflecting: request.content), answer: answer.reported,
          before: answer.withoutTypedText(before ?? "<unavailable>"),
          after: answer.withoutTypedText(await screen(id.sessionID) ?? "<unavailable>"),
          keys: keys, writtenKeys: written))
    }
    diagnostics.record(
      .session, outcome == .sent ? .info : .notice, "request.answered",
      [
        "session": diagnostics.pseudonym(id.sessionID), "outcome": .token(DiagnosticToken(outcome)),
        "answer": .token(answer.diagnosticToken),
      ])
    return outcome
  }

  private func give(
    _ answer: AgentAnswer, to id: AgentRequestID, written: inout [[UInt8]],
    redrawn: inout String?
  ) async -> Outcome {
    guard await tracker.offers(answer, to: id) else {
      return await tracker.isFirstRequest(id) ? .notAnswerable : .requestGone
    }
    let read = await readScreen(answering: answer, to: id)
    if read.isRedrawn { redrawn = read.text }
    var text = read.text
    // Whose dialog is drawn is read off the screen, against every request the agent reported
    // before drawing it (#283). The screen is read first: every dialog on it was reported by then,
    // and once the log is read up to its end, every report is known. Read again after, it must
    // show the same dialog — the keys are taken from that last reading.
    if await tracker.readsRequestsOnScreen(id.sessionID) {
      let before = text
      guard await tracker.catchUp(id.sessionID), let before else {
        return await tracker.isFirstRequest(id) ? .otherDialog : .requestGone
      }
      text = await screen(id.sessionID)
      if read.isRedrawn { redrawn = text }
      guard let text, await tracker.dialogOnScreen(text, readBefore: before, isFor: id) else {
        let isFirst = await tracker.isFirstRequest(id)
        // A dialog no hook reports may be the one drawn: its card takes this one's place, to be
        // answered from there (#603).
        if let text,
          await tracker.dialogUnreportedOnScreen(text, readBefore: before, in: id.sessionID)
        {
          return .requestGone
        }
        return isFirst ? .otherDialog : .requestGone
      }
    }
    // Which key takes the answer is read off the dialog as drawn now (#273).
    let drawn = await tracker.dialogScreen(text, in: id.sessionID)
    guard let steps = await tracker.keystrokes(for: answer, to: id, screen: drawn),
      !steps.isEmpty
    else {
      return await tracker.isFirstRequest(id) ? .notOnScreen : .requestGone
    }
    var finalScreen = text
    var typed = ContinuousClock.now
    for (index, step) in steps.enumerated() {
      if index > 0 {
        await settle(id.sessionID)
        // Whatever the agent said meanwhile may have taken the dialog away: the next key would
        // then land in its prompt.
        guard await tracker.isFirstRequest(id) else { return .interrupted }
        // A key the dialog has not taken yet, or has taken otherwise: the rest is not typed, and
        // the request still waits — never shown answered while the terminal asks on.
        if await tracker.rereadsScreen(beforeStep: index, of: answer, for: id),
          await !screenAsks(Array(steps[index...]), of: answer, to: id)
        {
          return .interrupted
        }
      }
      // Earlier answers may already have advanced to a review. Only leaving the
      // dialog that awaits the final key proves the whole interaction completed.
      if confirmsDelivery, index == steps.count - 1 {
        finalScreen = await screen(id.sessionID)
        // Before the write: what the agent draws after it, however quick, answers the key.
        typed = ContinuousClock.now
      }
      guard await write(id.sessionID, step) else { return .terminalUnavailable }
      written.append(step)
    }
    if confirmsDelivery {
      let original = await tracker.dialogScreen(finalScreen, in: id.sessionID)
      // Counted from the agent's first redraw after the last key: an agent too busy to read its
      // input, on a loaded Mac, read that key more than fifteen seconds late, and the same answer
      // given again from its card left its digit in the prompt (#653).
      var firstRedraw: ContinuousClock.Instant?
      var outputRead: ContinuousClock.Instant?
      var changedReadings = 0
      while await tracker.isFirstRequest(id) {
        await settle(id.sessionID)
        var reading: String?
        if firstRedraw == nil, let finalScreen, let output = await lastOutput(id.sessionID) {
          // Nothing drawn since the key, or nothing that changed the screen typed into — output
          // read late, or drawn before it: the key is still unread. The screen is read again only
          // once the terminal has written something new.
          if output >= typed, output != outputRead {
            outputRead = output
            reading = await screen(id.sessionID)
            if let reading, reading != finalScreen { firstRedraw = ContinuousClock.now }
          }
          if firstRedraw == nil {
            guard ContinuousClock.now - typed < unreadKeyLimit, !Task.isCancelled else {
              return .interrupted
            }
            continue
          }
        }
        let since = firstRedraw ?? typed
        if reading == nil { reading = await screen(id.sessionID) }
        if let current = reading {
          let dialog = await tracker.dialogScreen(current, in: id.sessionID)
          let changed =
            original == nil
            ? finalScreen.map { current != $0 } ?? false
            : (dialog?.options != original?.options
              || dialog?.confirmation?.server != original?.confirmation?.server
              || dialog?.confirmation?.message != original?.confirmation?.message
              || dialog?.folderTrust?.folder != original?.folderTrust?.folder)
          changedReadings =
            changed && !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? changedReadings + 1 : 0
          if changedReadings >= 2 { break }
        }
        guard ContinuousClock.now - since < Self.confirmationLimit,
          !Task.isCancelled
        else {
          return .interrupted
        }
      }
    }
    await tracker.answerSent(id)
    return .sent
  }

  /// How long a dialog redrawn after the last key may still show what that key answers.
  public static let confirmationLimit: Duration = .seconds(3)
  /// How long an agent that has drawn nothing since the last key is waited for: until then, the
  /// key is still to be read, and the dialog it answers still drawn (#653). A key a dialog takes
  /// without drawing anything is reported only then: a card waiting costs less than a digit
  /// typed twice, the second one left in the prompt.
  public static let unreadKeyLimit: Duration = .seconds(60)

  /// Observe the real dialog after a permission hook, without typing any answer. Automatic
  /// review can finish without one; terminal input approvals may draw without an OSC notice.
  /// A form only announced is read too, for a while: the dialog drawn may be one no hook reports
  /// (#603). Made a request off the screen, that dialog is read until it goes.
  public func followPermissionDialog(_ id: AgentRequestID) async {
    var formReadings = 0
    while !Task.isCancelled, let reading = await tracker.screenReading(for: id) {
      if reading == .announcedForm {
        // Computer Use draws its form as Codex announces it: a form still unread by then is
        // another, filled in the terminal.
        guard formReadings < Self.announcedFormReadings else { return }
        formReadings += 1
      }
      if let before = await screen(id.sessionID), await tracker.catchUp(id.sessionID),
        !Task.isCancelled, let after = await screen(id.sessionID)
      {
        if reading == .unreportedDialog {
          // Another app asked in its place, or its form gone.
          if await !tracker.dialogUnreportedOnScreen(after, readBefore: before, in: id.sessionID) {
            await tracker.unreportedDialogGone(after, readBefore: before, isFor: id)
          }
          do { try await sleep(Self.startupDialogPollInterval) } catch { return }
          continue
        }
        if await tracker.dialogOnScreen(after, readBefore: before, isFor: id) { return }
        if await tracker.dialogUnreportedOnScreen(after, readBefore: before, in: id.sessionID) {
          return
        }
        // Drawn, but not to be told apart: shown to be answered in the terminal, and still read
        // until it is told apart, or settled.
        await tracker.dialogUnnamedOnScreen(after, readBefore: before, isFor: id)
      }
      do { try await sleep(Self.startupDialogPollInterval) } catch { return }
    }
  }

  /// Reads which dialog of its start a session waits on, off its screen: one its keymap answers
  /// — an update offered — takes the place of the request that only guessed one is there.
  ///
  /// Whether the screen shows a dialog: options numbered, one pointed at, near the bottom — or an
  /// MCP server's confirmation, or a folder to trust. Anything else is an agent still starting:
  /// Claude Code draws its banner before its hooks run, and on a busy Mac, dozens of sessions
  /// resumed together take far longer than the guess waits to draw their prompt (#474).
  @discardableResult
  public func readStartupDialog(_ id: AgentRequestID) async -> Bool {
    guard let text = await screen(id.sessionID) else { return false }
    await tracker.startupDialogOnScreen(text, isFor: id)
    return AgentDialogScreen(screen: text) != nil
  }

  /// Reads the dialog of a session's start again and again, as long as it waits: it may be drawn
  /// after the guess, and it goes when answered in the terminal — the card with it.
  /// `dialogDrawn` is called once, when the screen first shows a dialog: only then is one known
  /// to wait there.
  public func followStartupDialog(
    _ id: AgentRequestID, dialogDrawn: @escaping @Sendable () async -> Void = {}
  ) async {
    var isDrawn = false
    while await tracker.waitsOnStartupDialog(id), !Task.isCancelled {
      if await readStartupDialog(id), !isDrawn {
        isDrawn = true
        await dialogDrawn()
      }
      do {
        try await sleep(Self.startupDialogPollInterval)
      } catch {
        return
      }
    }
  }

  /// How often the screen of a start that waits is read again.
  public static let startupDialogPollInterval: Duration = .seconds(1)
  /// How many times a form only announced is read for a dialog no hook reports (#603).
  static let announcedFormReadings = 10

  /// How long a redraw is given before the screen is read again: the terminal is held a row
  /// shorter for a quarter of a second, then given its size back, and the agent draws for both.
  public static let redrawWait: Duration = .milliseconds(400)

  /// How many times the screen is read again after a redraw, `redrawWait` apart, until it shows
  /// the dialog: a hosted session's redraw is only asked of its host, and a busy Mac's agent may
  /// draw long after its terminal was given its size back.
  public static let redrawReadings = 3

  /// What the session's terminal shows, and whether it was drawn again first: when the dialog
  /// that takes `answer` is not read off it — none, or another's left over — and the history it
  /// is replayed from was trimmed (#563). A dialog is drawn once; an agent that draws by
  /// differences then sends only what changes — ten hours of a spinner later, the history kept
  /// holds the spinner, not the dialog still drawn under it.
  private func readScreen(answering answer: AgentAnswer, to id: AgentRequestID) async
    -> (text: String?, isRedrawn: Bool)
  {
    var text = await screen(id.sessionID)
    guard await !screen(text, answers: answer, to: id), await redraw(id.sessionID) else {
      return (text, false)
    }
    for _ in 0..<Self.redrawReadings {
      do {
        try await sleep(Self.redrawWait)
      } catch {
        break
      }
      await settle(id.sessionID)
      text = await screen(id.sessionID)
      if await screen(text, answers: answer, to: id) { break }
    }
    return (text, true)
  }

  /// Whether `text` shows a dialog the keys of `answer` are read off.
  private func screen(_ text: String?, answers answer: AgentAnswer, to id: AgentRequestID) async
    -> Bool
  {
    let drawn = await tracker.dialogScreen(text, in: id.sessionID)
    return await !(tracker.keystrokes(for: answer, to: id, screen: drawn) ?? []).isEmpty
  }

  /// Whether the dialog, read again, asks for `keys` and nothing else — waited for up to
  /// `settleLimit`, the key before having to be read and drawn first.
  private func screenAsks(_ keys: [[UInt8]], of answer: AgentAnswer, to id: AgentRequestID) async
    -> Bool
  {
    let start = ContinuousClock.now
    while true {
      let drawn = await tracker.dialogScreen(await screen(id.sessionID), in: id.sessionID)
      let left = await tracker.keystrokesLeft(for: answer, to: id, screen: drawn)
      if left == keys { return true }
      // A preview already pointing at the requested choice still accepts its digit again.
      if keys.count >= 2, keys[1] == TerminalKeys.enter,
        keys[0].count == 1, (49...57).contains(keys[0][0]), left == Array(keys.dropFirst())
      {
        return true
      }
      guard ContinuousClock.now - start < Self.settleLimit else { return false }
      do {
        try await sleep(Self.quietPeriod)
      } catch {
        return false
      }
    }
  }

  /// Returns once the terminal has been silent for `quietPeriod`, or after `settleLimit`.
  private func settle(_ id: SessionID) async {
    let start = ContinuousClock.now
    repeat {
      do {
        try await sleep(Self.quietPeriod)
      } catch {
        return
      }
      guard let last = await lastOutput(id), ContinuousClock.now - last < Self.quietPeriod else {
        return
      }
    } while ContinuousClock.now - start < Self.settleLimit
  }
}

extension AgentAnswer {
  /// The kind of answer, for a diagnostic that must not hold what was answered.
  var diagnosticToken: DiagnosticToken {
    switch self {
    case .allowOnce: return "allowOnce"
    case .allowAlways: return "allowAlways"
    case .allowEverywhere: return "allowEverywhere"
    case .deny: return "deny"
    case .answers: return "answers"
    case .approvePlan: return "approvePlan"
    case .rejectPlan: return "rejectPlan"
    case .skipUpdate: return "skipUpdate"
    case .chatAboutThis: return "chatAboutThis"
    case .trustFolder: return "trustFolder"
    }
  }
}

extension AgentAnswer {
  /// What a failure report says of this answer: a text the user typed by its length only, as
  /// the key traces already do. Options, choices and refusals are kept, to reproduce the case.
  public var reported: String {
    guard case .answers(let answers) = self else { return String(reflecting: self) }
    let each = answers.map { answer -> String in
      guard case .text(let text) = answer else { return String(reflecting: answer) }
      return ".text(<\(text.count) characters omitted>)"
    }
    return ".answers([\(each.joined(separator: ", "))])"
  }

  /// A screen with the text the user typed taken out where it shows whole: what the field of
  /// the dialog echoes. A text wrapped over several lines may still show in part.
  public func withoutTypedText(_ screen: String) -> String {
    guard case .answers(let answers) = self else { return screen }
    return answers.reduce(screen) { screen, answer in
      guard case .text(let text) = answer, !text.isEmpty else { return screen }
      return screen.replacingOccurrences(of: text, with: "<typed text omitted>")
    }
  }
}
