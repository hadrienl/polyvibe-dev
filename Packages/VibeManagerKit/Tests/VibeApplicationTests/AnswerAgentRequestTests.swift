import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

private let t1 = Date(timeIntervalSince1970: 4_000_000)

/// The terminals of every session, recording what each is sent.
private actor Terminals {
  private(set) var written: [SessionID: [[UInt8]]] = [:]
  var running: Set<SessionID> = []
  /// Called after each write, as a CLI would react to a key.
  var onWrite: (@Sendable (SessionID) async -> Void)?

  func write(_ bytes: [UInt8], to id: SessionID) async -> Bool {
    guard running.contains(id) else { return false }
    written[id, default: []].append(bytes)
    await onWrite?(id)
    return true
  }

  func run(_ id: SessionID) {
    running.insert(id)
  }

  func setOnWrite(_ action: @escaping @Sendable (SessionID) async -> Void) {
    onWrite = action
  }
}

/// Reads permissions as Claude Code reports them, and answers them with its digits.
private struct PermissionDecoder: AgentSignalDecoding {
  let approvalAnswerKeys: Set<[UInt8]> = [[0x31]]
  var keymap: any AgentAnswerKeymap = TwoStepKeymap()
  var isShown = true

  var answerKeymap: (any AgentAnswerKeymap)? {
    keymap
  }

  func signal(for event: AgentActivityEvent) -> AgentSignal? {
    switch event.name {
    case "start": return .channelConfirmed
    case "ask":
      let command = event.payload.map { String(decoding: $0, as: UTF8.self) } ?? ""
      return .questionAsked(
        .approval, tool: "Bash",
        notice: AgentRequestNotice(
          content: .permission(
            AgentToolPermission(tool: .shell, toolName: "Bash", subject: command)),
          reference: AgentToolReference(tool: "Bash", subject: command), isShown: isShown))
    case "done":
      let command = event.payload.map { String(decoding: $0, as: UTF8.self) }
      return .toolFinished("Bash", subject: command)
    case "end": return .turnEnded
    default: return nil
    }
  }
}

/// Allows with one key, refuses with two, to see what happens between two keystrokes.
private struct TwoStepKeymap: AgentAnswerKeymap {
  func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> {
    [.allowOnce, .deny]
  }

  func keystrokes(
    for answer: AgentAnswer, to content: AgentRequestContent, screen: AgentDialogScreen?
  ) -> [[UInt8]]? {
    switch answer {
    case .allowOnce: return [[0x31]]
    case .deny: return [[0x33], [0x0D]]
    default: return nil
    }
  }
}

/// Allows with the digit its dialog shows beside "Yes", as Claude Code's keymap does (#273).
private struct ScreenKeymap: AgentAnswerKeymap {
  func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> {
    [.allowOnce, .deny]
  }

  func keystrokes(
    for answer: AgentAnswer, to content: AgentRequestContent, screen: AgentDialogScreen?
  ) -> [[UInt8]]? {
    guard answer == .allowOnce, let yes = screen?.option(where: { $0 == "Yes" }) else {
      return nil
    }
    return [Array(String(yes.number).utf8)]
  }
}

/// Refuses by moving the pointer onto `No`, then Return — which waits for the screen to show it
/// moved, as Claude Code's folder trust does.
private struct PointerKeymap: AgentAnswerKeymap {
  func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> {
    [.deny]
  }

  func keystrokes(
    for answer: AgentAnswer, to content: AgentRequestContent, screen: AgentDialogScreen?
  ) -> [[UInt8]]? {
    guard answer == .deny, let screen, screen.options.count == 2 else { return nil }
    return screen.options[1].label == "No (pointed)"
      ? [TerminalKeys.enter] : [TerminalKeys.downArrow, TerminalKeys.enter]
  }

  func rereadsScreen(
    beforeStep step: Int, of answer: AgentAnswer, to content: AgentRequestContent
  ) -> Bool {
    true
  }
}

private struct PendingPermissionKeymap: AgentAnswerKeymap {
  let readsRequestOnScreen = true
  func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> { [.allowOnce, .deny] }
  func keystrokes(
    for answer: AgentAnswer, to content: AgentRequestContent,
    screen: AgentDialogScreen?
  ) -> [[UInt8]]? { [[0x79]] }
  func drawnDialog(onScreen text: String) -> AgentDrawnDialog? {
    guard text.hasPrefix("approval:") else { return nil }
    return AgentDrawnDialog(.shownCommand(String(text.dropFirst(9))))
  }
}

/// How many times the agent was asked to draw its screen again.
private actor Redraws {
  var value = 0

  func count() {
    value += 1
  }
}

/// When a terminal last wrote something, which a test moves on as its agent draws.
private actor LastOutput {
  var value: ContinuousClock.Instant

  init(_ value: ContinuousClock.Instant) {
    self.value = value
  }

  func drew() {
    value = .now
  }
}

/// What a terminal shows, which a test changes.
private actor LiveScreen {
  var text: String?

  init(_ text: String?) {
    self.text = text
  }

  func show(_ text: String?) {
    self.text = text
  }
}

private struct Fixture {
  let logs = ScriptedActivityLogs()
  let tracker: TrackAgentActivity
  let terminals = Terminals()
  let answer: AnswerAgentRequest
  let decoder: PermissionDecoder

  init(
    screen: String? = nil, live: LiveScreen? = nil,
    keymap: any AgentAnswerKeymap = TwoStepKeymap(), shown: Bool = true
  ) {
    tracker = makeTracker(logs: logs, store: MemoryActivityStore(), clock: TestClock(t1))
    decoder = PermissionDecoder(keymap: keymap, isShown: shown)
    let terminals = terminals
    answer = AnswerAgentRequest(
      tracker: tracker,
      write: { id, bytes in await terminals.write(bytes, to: id) },
      screen: { _ in
        guard let live else { return screen }
        return await live.text
      },
      // Gives the thread up, so that what the test changes meanwhile gets to run.
      sleep: { _ in await Task.yield() })
  }

  /// A running session whose agent asks to run `command`.
  func asking(_ command: String) async -> (SessionID, AgentRequestID) {
    let id = SessionID()
    await terminals.run(id)
    await tracker.processStarted(id, decoder: decoder)
    #expect(await following(logs, id))
    await logs.write("start", at: t1, for: id)
    await logs.write("ask", at: t1, for: id, payload: command)
    #expect(await eventually(tracker, id) { $0?.requests.count == 1 })
    let request = await tracker.state(for: id)?.requests.first?.id
    return (id, request ?? AgentRequestID(sessionID: id, key: "none"))
  }
}

@Suite("Answering a request from the palette", .timeLimit(.minutes(2)))
struct AnswerAgentRequestTests {
  @Test(
    "Ignoring the final key keeps a progressed review pending; accepting it completes it",
    arguments: [false, true])
  func finalReview(acceptsSubmit: Bool) async {
    let live = LiveScreen("❯ 1. Yes\n  2. No")
    let fixture = Fixture(live: live)
    let (id, request) = await fixture.asking("review")
    let review = "❯ 1. Submit answers\n  2. Cancel"
    await fixture.terminals.setOnWrite { id in
      let count = await fixture.terminals.written[id]?.count ?? 0
      await live.show(count == 1 || !acceptsSubmit ? review : "Working…")
    }
    let failures = RecordedInteractionFailures()
    let answer = AnswerAgentRequest(
      tracker: fixture.tracker,
      write: { id, bytes in await fixture.terminals.write(bytes, to: id) },
      screen: { _ in await live.text }, confirmsDelivery: true,
      failed: { await failures.append($0) })
    #expect(await answer(.deny, to: request) == (acceptsSubmit ? .sent : .interrupted))
    #expect(await fixture.tracker.isFirstRequest(request) == !acceptsSubmit)
    #expect(await fixture.terminals.written[id] == [[51], [13]])
    let reports = await failures.values
    #expect(reports.count == (acceptsSubmit ? 0 : 1))
    if !acceptsSubmit { #expect(reports.first?.after == review) }
  }

  @Test("Keys ignored by the CLI keep the request pending and report both screens")
  func ignoredAnswer() async {
    let text = "❯ 1. Yes\n  2. No"
    let fixture = Fixture(screen: text, keymap: ScreenKeymap())
    let (id, request) = await fixture.asking("touch a")
    let failures = RecordedInteractionFailures()
    let answer = AnswerAgentRequest(
      tracker: fixture.tracker,
      write: { id, bytes in await fixture.terminals.write(bytes, to: id) },
      screen: { _ in text }, confirmsDelivery: true,
      failed: { await failures.append($0) })
    #expect(await answer(.allowOnce, to: request) == .interrupted)
    #expect(await fixture.tracker.isFirstRequest(request))
    #expect(await fixture.terminals.written[id] == [[49]])
    let reports = await failures.values
    #expect(reports.count == 1)
    #expect(reports.first?.before == text)
    #expect(reports.first?.after == text)
    #expect(reports.first?.writtenKeys == [[49]])
  }

  @Test("An agent silent since the key is waited for past the limit of a redrawn dialog")
  func lateReader() async {
    // #653: on a loaded Mac, Claude Code read the digit long after it was typed; reported as
    // failed, the request was answered again from its card, and the second digit left in its
    // prompt.
    let live = LiveScreen("❯ 1. Yes\n  2. No")
    let fixture = Fixture(live: live, keymap: ScreenKeymap())
    let (id, request) = await fixture.asking("touch a")
    let output = LastOutput(ContinuousClock.now - .seconds(1))
    await fixture.terminals.setOnWrite { _ in
      Task {
        // Output read after the key, but that leaves the screen as it was: not its redraw.
        try? await Task.sleep(for: .milliseconds(500))
        await output.drew()
        try? await Task.sleep(for: AnswerAgentRequest.confirmationLimit + .milliseconds(500))
        await live.show("Working…")
        await output.drew()
      }
    }
    let failures = RecordedInteractionFailures()
    let answer = AnswerAgentRequest(
      tracker: fixture.tracker,
      write: { id, bytes in await fixture.terminals.write(bytes, to: id) },
      lastOutput: { _ in await output.value },
      screen: { _ in await live.text }, confirmsDelivery: true,
      failed: { await failures.append($0) })
    #expect(await answer(.allowOnce, to: request) == .sent)
    #expect(await fixture.terminals.written[id] == [[49]])
    #expect(await failures.values.isEmpty)
  }

  @Test("An agent that never draws after the key fails once its limit is over, typed once")
  func silentAgent() async {
    let text = "❯ 1. Yes\n  2. No"
    let fixture = Fixture(screen: text, keymap: ScreenKeymap())
    let (id, request) = await fixture.asking("touch a")
    let output = LastOutput(ContinuousClock.now - .seconds(1))
    let failures = RecordedInteractionFailures()
    let answer = AnswerAgentRequest(
      tracker: fixture.tracker,
      write: { id, bytes in await fixture.terminals.write(bytes, to: id) },
      lastOutput: { _ in await output.value },
      screen: { _ in text }, confirmsDelivery: true, unreadKeyLimit: .milliseconds(500),
      failed: { await failures.append($0) })
    #expect(await answer(.allowOnce, to: request) == .interrupted)
    #expect(await fixture.tracker.isFirstRequest(request))
    #expect(await fixture.terminals.written[id] == [[49]])
    #expect(await failures.values.count == 1)
  }

  @Test("A confirmed dialog closing completes the request without a failure report")
  func confirmedAnswer() async {
    let live = LiveScreen("❯ 1. Yes\n  2. No")
    let fixture = Fixture(live: live, keymap: ScreenKeymap())
    let (_, request) = await fixture.asking("touch a")
    await fixture.terminals.setOnWrite { _ in await live.show("Working…") }
    let failures = RecordedInteractionFailures()
    let answer = AnswerAgentRequest(
      tracker: fixture.tracker,
      write: { id, bytes in await fixture.terminals.write(bytes, to: id) },
      screen: { _ in await live.text }, confirmsDelivery: true,
      failed: { await failures.append($0) })
    #expect(await answer(.allowOnce, to: request) == .sent)
    #expect(await failures.values.isEmpty)
  }

  @Test("A permission is exposed only when its actual dialog appears, without writing an answer")
  func watchPendingPermission() async {
    let live = LiveScreen("working")
    let fixture = Fixture(live: live, keymap: PendingPermissionKeymap(), shown: false)
    let (id, request) = await fixture.asking("touch a")
    #expect(await fixture.tracker.awaitsPermissionDialog(request))
    let watching = Task { await fixture.answer.followPermissionDialog(request) }
    await live.show("approval:touch a")
    await watching.value
    #expect(await fixture.tracker.state(for: id)?.requests.first?.isShown == true)
    #expect(await fixture.terminals.written[id] == nil)
  }

  @Test("An automatically completed permission leaves no dialog and types no answer")
  func watchAutoApprovedPermission() async {
    let fixture = Fixture(screen: "working", keymap: PendingPermissionKeymap(), shown: false)
    let (id, request) = await fixture.asking("touch a")
    let watching = Task { await fixture.answer.followPermissionDialog(request) }
    await fixture.logs.write("done", at: t1, for: id, payload: "touch a")
    await watching.value
    #expect(await fixture.tracker.state(for: id)?.requests.isEmpty == true)
    #expect(await fixture.terminals.written[id] == nil)
  }

  @Test("A dialog drawn but cut short exposes the pending permission, to answer in the terminal")
  func watchUnreadablePermission() async throws {
    let live = LiveScreen("working")
    let fixture = Fixture(live: live, keymap: PendingPermissionKeymap(), shown: false)
    let (id, request) = await fixture.asking("touch a")
    let watching = Task { await fixture.answer.followPermissionDialog(request) }
    await live.show("[… 9 lines] ctrl+a view all\n\n› 1. Yes, proceed (y)\n  2. No (esc)")
    while await fixture.tracker.state(for: id)?.drawnCandidates.contains(request) != true {
      await Task.yield()
    }
    let state = try #require(await fixture.tracker.state(for: id))
    #expect(state.requests.first?.isShown == false)
    #expect(state.isFirstRequestUncertain)
    // Still read: once told apart, it is armed.
    await live.show("approval:touch a")
    await watching.value
    #expect(await fixture.tracker.state(for: id)?.requests.first?.isShown == true)
    #expect(await fixture.terminals.written[id] == nil)
  }

  /// The foot of the terminal in #637: Codex out of quota, offering a cheaper model.
  static let rateLimitOffer = """
    ■ You’ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://
    chatgpt.com/settings/usage to purchase more credits or try again at 11:27 PM.


      Approaching rate limits
      Switch to gpt-6-luna for lower credit usage?


    › 1. Switch to gpt-6-luna                   Fast and affordable model for easier tasks.
      2. Keep current model
      3. Keep current model (never show again)  Hide future rate limit reminders about switching
                                                models

      enter select · esc back
    """

  @Test("Out of quota, Codex's offer of a model is no permission: the failed turn ends it (#637)")
  func rateLimitOffer() async throws {
    let live = LiveScreen("working")
    let fixture = Fixture(live: live, keymap: PendingPermissionKeymap(), shown: false)
    // Settled by the automatic review and still running: no tool's end comes.
    let (id, request) = await fixture.asking("Scripts/local-build.sh '#598+#636'")
    let watching = Task { await fixture.answer.followPermissionDialog(request) }
    await live.show(Self.rateLimitOffer)
    while await fixture.tracker.state(for: id)?.drawnCandidates.contains(request) != true {
      await Task.yield()
    }
    // As reported: answered from its card, the offer gets nothing typed.
    #expect(await fixture.answer(.allowOnce, to: request) == .otherDialog)
    // Codex runs no `Stop` hook then: its rollout says the turn ended (#637), and the permission
    // goes with it. The offer is answered in the terminal.
    await fixture.logs.write("end", at: t1, for: id)
    await watching.value
    let state = try #require(await fixture.tracker.state(for: id))
    #expect(state.requests.isEmpty)
    #expect(state.activity == .idle)
    #expect(await fixture.terminals.written[id] == nil)
  }

  @Test("A different dialog cannot expose the pending permission")
  func watchOtherPermission() async {
    let fixture = Fixture(
      screen: "approval:touch b", keymap: PendingPermissionKeymap(), shown: false)
    let (id, request) = await fixture.asking("touch a")
    let watching = Task { await fixture.answer.followPermissionDialog(request) }
    await Task.yield()
    watching.cancel()
    await watching.value
    #expect(await fixture.tracker.state(for: id)?.requests.first?.isShown == false)
    #expect(await fixture.terminals.written[id] == nil)
  }

  @Test("The answer is typed into the terminal of the request's session, and nowhere else")
  func routed() async {
    let fixture = Fixture()
    let (first, _) = await fixture.asking("touch a")
    let (second, request) = await fixture.asking("touch b")

    #expect(await fixture.answer(.allowOnce, to: request) == .sent)
    #expect(await fixture.terminals.written[second] == [[0x31]])
    #expect(await fixture.terminals.written[first] == nil)
    // The agent is at work again at once, without waiting for the tool to end.
    #expect(await fixture.tracker.state(for: second)?.activity == .working)
    #expect(await fixture.tracker.state(for: first)?.requests.count == 1)
  }

  @Test("A request answered meanwhile, or not the first, gets nothing typed")
  func gone() async {
    let fixture = Fixture()
    let (id, request) = await fixture.asking("touch a")
    await fixture.logs.write("done", at: t1, for: id, payload: "touch a")
    #expect(await eventually(fixture.tracker, id) { $0?.requests.isEmpty == true })

    #expect(await fixture.answer(.allowOnce, to: request) == .requestGone)
    #expect(await fixture.terminals.written[id] == nil)
  }

  @Test("An answer the request does not offer is not typed")
  func notOffered() async {
    let fixture = Fixture()
    let (id, request) = await fixture.asking("touch a")
    #expect(await fixture.answer(.allowAlways, to: request) == .notAnswerable)
    #expect(await fixture.terminals.written[id] == nil)
  }

  @Test("The key is the one the dialog on screen shows for the answer (#273)")
  func readOffTheScreen() async {
    let fixture = Fixture(
      screen: " Do you want to proceed?\n ❯ 1. Yes, and switch to auto mode\n   2. Yes\n   3. No",
      keymap: ScreenKeymap())
    let (id, request) = await fixture.asking("touch a")
    #expect(await fixture.answer(.allowOnce, to: request) == .sent)
    #expect(await fixture.terminals.written[id] == [Array("2".utf8)])
  }

  @Test("An answer the dialog on screen does not offer, or a screen unread, types nothing (#273)")
  func notOnScreen() async {
    for screen in [" ❯ 1. Yes, and switch to auto mode\n   2. No", nil] {
      let fixture = Fixture(screen: screen, keymap: ScreenKeymap())
      let (id, request) = await fixture.asking("touch a")
      #expect(await fixture.answer(.allowOnce, to: request) == .notOnScreen)
      #expect(await fixture.terminals.written[id] == nil)
      #expect(await fixture.tracker.state(for: id)?.requests.count == 1)
    }
  }

  /// #563: after ten hours of a spinner, the history kept no longer holds the dialog Claude Code
  /// drew once, only what it changed since — replayed, the screen shows no dialog at all.
  static let screenWithoutItsDialog = """
      Called Supabase, ran 1 shell command

    ⏺                  · 10h 35m 37s…
      ⎿  Fulfilling input required by 'tools/call' (round
         1)
    """

  @Test("A screen replayed without its dialog has the agent draw it again, then is read (#563)")
  func redrawnScreen() async {
    let live = LiveScreen(Self.screenWithoutItsDialog)
    let fixture = Fixture(live: live, keymap: ScreenKeymap())
    let (id, request) = await fixture.asking("touch a")
    let redraws = Redraws()
    let answer = AnswerAgentRequest(
      tracker: fixture.tracker,
      write: { id, bytes in await fixture.terminals.write(bytes, to: id) },
      screen: { _ in await live.text },
      redraw: { _ in
        await redraws.count()
        await live.show(Self.screenWithoutItsDialog + "\n\n ❯ 1. Yes\n   2. No")
        return true
      },
      sleep: { _ in await Task.yield() })
    #expect(await answer(.allowOnce, to: request) == .sent)
    #expect(await fixture.terminals.written[id] == [Array("1".utf8)])
    #expect(await redraws.value == 1)
  }

  @Test("Drawn again and still without its dialog: nothing typed, the redrawn screen reported")
  func redrawnWithoutDialog() async {
    let live = LiveScreen(Self.screenWithoutItsDialog)
    let fixture = Fixture(live: live, keymap: ScreenKeymap())
    let (id, request) = await fixture.asking("touch a")
    let failures = RecordedInteractionFailures()
    let answer = AnswerAgentRequest(
      tracker: fixture.tracker,
      write: { id, bytes in await fixture.terminals.write(bytes, to: id) },
      screen: { _ in await live.text },
      redraw: { _ in
        await live.show("  Working…")
        return true
      },
      sleep: { _ in await Task.yield() },
      failed: { await failures.append($0) })
    #expect(await answer(.allowOnce, to: request) == .notOnScreen)
    #expect(await fixture.terminals.written[id] == nil)
    #expect(await failures.values.first?.before == "  Working…")
  }

  @Test("Another dialog left over in what is replayed is drawn again too (#563)")
  func redrawnOverAnotherDialog() async {
    let live = LiveScreen(" ❯ 1. Maybe\n   2. No")
    let fixture = Fixture(live: live, keymap: ScreenKeymap())
    let (id, request) = await fixture.asking("touch a")
    let answer = AnswerAgentRequest(
      tracker: fixture.tracker,
      write: { id, bytes in await fixture.terminals.write(bytes, to: id) },
      screen: { _ in await live.text },
      redraw: { _ in
        await live.show(" ❯ 1. Yes\n   2. No")
        return true
      },
      sleep: { _ in await Task.yield() })
    #expect(await answer(.allowOnce, to: request) == .sent)
    #expect(await fixture.terminals.written[id] == [Array("1".utf8)])
  }

  @Test("A redraw drawn late is waited for: the screen is read again until it shows the dialog")
  func lateRedraw() async {
    let live = LiveScreen(Self.screenWithoutItsDialog)
    let fixture = Fixture(live: live, keymap: ScreenKeymap())
    let (id, request) = await fixture.asking("touch a")
    let waits = Redraws()
    let answer = AnswerAgentRequest(
      tracker: fixture.tracker,
      write: { id, bytes in await fixture.terminals.write(bytes, to: id) },
      screen: { _ in await live.text },
      redraw: { _ in true },
      sleep: { duration in
        if duration == AnswerAgentRequest.redrawWait {
          await waits.count()
          // The agent draws only after the screen was first read again.
          if await waits.value == 2 { await live.show(" ❯ 1. Yes\n   2. No") }
        }
        await Task.yield()
      })
    #expect(await answer(.allowOnce, to: request) == .sent)
    #expect(await fixture.terminals.written[id] == [Array("1".utf8)])
    #expect(await waits.value == 2)
  }

  @Test("A dialog on screen, or a history kept whole, is not drawn again (#563)")
  func noRedraw() async {
    for screen in [" ❯ 1. Yes\n   2. No", Self.screenWithoutItsDialog] {
      let fixture = Fixture(screen: screen, keymap: ScreenKeymap())
      let (id, request) = await fixture.asking("touch a")
      let redraws = Redraws()
      let answer = AnswerAgentRequest(
        tracker: fixture.tracker,
        write: { id, bytes in await fixture.terminals.write(bytes, to: id) },
        screen: { _ in screen },
        // Nothing trimmed: what is replayed is what the terminal shows.
        redraw: { _ in
          await redraws.count()
          return false
        },
        sleep: { _ in await Task.yield() })
      let hasDialog = screen != Self.screenWithoutItsDialog
      #expect(await answer(.allowOnce, to: request) == (hasDialog ? .sent : .notOnScreen))
      #expect(await fixture.terminals.written[id] == (hasDialog ? [Array("1".utf8)] : nil))
      #expect(await redraws.value == (hasDialog ? 0 : 1))
    }
  }

  @Test("A request that goes away between two keystrokes stops the answer halfway")
  func interrupted() async {
    let fixture = Fixture()
    let (id, request) = await fixture.asking("touch a")
    let logs = fixture.logs
    let tracker = fixture.tracker
    await fixture.terminals.setOnWrite { id in
      await logs.write("done", at: t1, for: id, payload: "touch a")
      #expect(await eventually(tracker, id) { $0?.requests.isEmpty == true })
    }
    #expect(await fixture.answer(.deny, to: request) == .interrupted)
    #expect(await fixture.terminals.written[id] == [[0x33]])
  }

  @Test("Return waits for the screen to show the pointer moved: unmoved, it is never typed")
  func rereadBetweenKeys() async {
    let unmoved = " ❯ 1. Yes\n   2. No"
    let moved = "   1. Yes\n ❯ 2. No (pointed)"
    // The arrow moves the pointer: Return follows.
    let live = LiveScreen(unmoved)
    let fixture = Fixture(live: live, keymap: PointerKeymap())
    let (id, request) = await fixture.asking("touch a")
    await fixture.terminals.setOnWrite { _ in await live.show(moved) }
    #expect(await fixture.answer(.deny, to: request) == .sent)
    #expect(await fixture.terminals.written[id] == [TerminalKeys.downArrow, TerminalKeys.enter])
    // The arrow not read yet: Return would take what is still pointed at, and is not typed.
    let stuck = Fixture(live: LiveScreen(unmoved), keymap: PointerKeymap())
    let (stuckID, stuckRequest) = await stuck.asking("touch a")
    #expect(await stuck.answer(.deny, to: stuckRequest) == .interrupted)
    #expect(await stuck.terminals.written[stuckID] == [TerminalKeys.downArrow])
    // The request still waits: never shown answered while its dialog asks on.
    #expect(await stuck.tracker.isFirstRequest(stuckRequest))
  }

  @Test("A session whose terminal is gone is not answered")
  func noTerminal() async {
    let fixture = Fixture()
    let (_, request) = await fixture.asking("touch a")
    let orphan = AgentRequestID(sessionID: SessionID(), key: request.key)
    #expect(await fixture.answer(.allowOnce, to: orphan) == .requestGone)
  }

  @Test("How each request can be answered is published with the session's state")
  func published() async {
    let fixture = Fixture()
    let updates = await fixture.tracker.updates()
    let (_, request) = await fixture.asking("touch a")
    var answering: AgentRequestAnswering?
    for await update in updates where update.answering[request] != nil {
      answering = update.answering[request]
      break
    }
    #expect(answering == .fromPalette([.allowOnce, .deny]))
  }

  @Test("Requests are written for the next launch, and an adopted agent finds them again")
  func persisted() async {
    let logs = ScriptedActivityLogs()
    let store = MemoryActivityStore()
    let tracker = makeTracker(logs: logs, store: store, clock: TestClock(t1))
    let id = SessionID()
    await tracker.processStarted(id, decoder: PermissionDecoder())
    #expect(await following(logs, id))
    await logs.write("start", at: t1, for: id)
    await logs.write("ask", at: t1, for: id, payload: "touch a")
    #expect(await eventually(tracker, id) { $0?.requests.count == 1 })
    await tracker.flush()
    #expect(await store.stored[id]?.requests.count == 1)

    let relaunched = makeTracker(logs: logs, store: store, clock: TestClock(t1))
    await relaunched.processAdopted(id, decoder: PermissionDecoder())
    #expect(await relaunched.state(for: id)?.requests.map(\.reference.subject) == ["touch a"])
  }
}

private actor RecordedInteractionFailures {
  var values: [AnswerAgentRequest.Failure] = []
  func append(_ value: AnswerAgentRequest.Failure) { values.append(value) }
}
