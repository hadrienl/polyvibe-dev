import Foundation
import VibeApplication
import VibeDomain

extension AntigravityAgentProvider: AgentConversationReporting {
  public func conversationFiles(
    for conversation: SessionAgentConfiguration, in session: WorkSession, hint: AgentActivityEvent?
  ) -> [URL] {
    guard let identifier = conversation.resumeIdentifier,
      let file = Self.transcript(identifier: identifier, home: home),
      FileManager.default.fileExists(atPath: file.path)
    else { return [] }
    return [file]
  }

  public func conversationDecoder(for file: URL) -> any ConversationDecoding {
    AntigravityConversationDecoder()
  }

  /// A sub-agent is a conversation of its own, `brain/<conversation>/…/transcript.jsonl` beside
  /// the parent's: found by the conversation `invoke_subagent` returned (#561).
  public func subagentTranscripts(beside root: URL, agentIDs: Set<String>)
    -> [SubagentTranscriptInfo]
  {
    Self.subagentTranscripts(beside: root, agentIDs: agentIDs)
  }

  static func subagentTranscripts(beside root: URL, agentIDs: Set<String>)
    -> [SubagentTranscriptInfo]
  {
    // `brain/<conversation>/.system_generated/logs/transcript.jsonl`
    let brain = root.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    return agentIDs.sorted().compactMap { agent in
      guard let uuid = UUID(uuidString: agent) else { return nil }
      let file = brain.appendingPathComponent(
        "\(uuid.uuidString.lowercased())/.system_generated/logs/transcript.jsonl")
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      return SubagentTranscriptInfo(agentID: agent, file: file)
    }
  }

  public var promptFormat: AgentPromptFormat { AgentPromptFormat() }
}

/// The exported transcript is a sequence of numbered steps, not Claude messages (#538). A
/// `PLANNER_RESPONSE` holds the calls of a turn; each call's result is a `GENERIC` step that does
/// not name it (#541). 1.5.10 numbers the results of a response's K calls right after it, in the
/// order of the calls: call `i` of step `N` is answered by step `N + 1 + i` (#561). A result is tied
/// to its call only while that holds — every step in that range a result, a command's result
/// reading like one — and shown apart otherwise. Tasks and sub-agents, which end later, are found
/// again by the identifier their start returned. Unknown step types are left alone.
public final class AntigravityConversationDecoder: ConversationDecoding {
  public private(set) var entries: [ConversationEntry] = []
  /// The step of each entry: entries are kept in the order of their steps.
  private var entrySteps: [Int] = []
  private var steps: [Int: Step] = [:]
  /// The step whose call started a task or a sub-agent, by the identifier it returned.
  private var starters: [String: Int] = [:]
  /// What was said of a task or a sub-agent once it started: the last word stands.
  private var ends: [String: End] = [:]
  /// Sub-agents `manage_subagents` killed, by role, and the step that did.
  private var killedRoles: [String: Int] = [:]
  /// The last prompt of the user: a call without a result before it never got one.
  private var lastPrompt = -1
  /// The last step written, and the errors met on the way: an error is shown only while nothing
  /// follows it — agy retries after it, and a step written after is the retry that worked.
  private var lastStep = -1
  private var failures: Set<Int> = []
  /// Responses with a call still waiting for its result, before any later prompt.
  private(set) var openResponses: Set<Int> = []
  /// Responses whose results are shown apart from their calls.
  private var unlinked: Set<Int> = []
  private var background: [String: Date] = [:]
  /// Steps rendered so far: what reading the transcript costs.
  private(set) var renderCount = 0

  private struct Step {
    let date: Date?
    let kind: Kind
  }

  private enum Kind {
    case prompt(String?)
    case response(text: String, thinking: String?, calls: [AntigravityTools.Call])
    case result(AntigravityTools.Result)
    case message(AntigravityTools.Message?)
    /// `ERROR_MESSAGE`: what the model's API answered, such as `API error (attempt 1):
    /// RESOURCE_EXHAUSTED (code 429): You have exhausted your capacity on this model.`
    case failure(String)
    case other

    var isResult: Bool {
      if case .result = self { return true }
      return false
    }

    var calls: [AntigravityTools.Call]? {
      if case .response(_, _, let calls) = self { return calls }
      return nil
    }
  }

  private enum End {
    case finished(String)
    case cancelled
    case message(String)
  }

  public init() {}

  public var backgroundWork: [Date] { Array(background.values) }

  public func consume(_ record: TranscriptRecord) {
    let object = record.object
    // A number no transcript reaches is not a step: counting from it would overflow.
    guard let index = object["step_index"] as? Int, (0...AntigravityTools.lastLine).contains(index),
      let type = object["type"] as? String
    else { return }
    let previous = steps[index]
    let step = Step(
      date: (object["created_at"] as? String).flatMap(TranscriptDates.parse),
      kind: Self.kind(of: type, object))
    steps[index] = step
    var dirty: Set<Int> = [index]
    if case .failure = step.kind { failures.insert(index) } else { failures.remove(index) }
    if index > lastStep {
      // The errors before it were retried: they are shown no more.
      dirty.formUnion(failures.filter { $0 < index && $0 >= lastStep })
      lastStep = index
    }
    if let calls = step.kind.calls {
      let count = max(calls.count, previous?.kind.calls?.count ?? 0)
      if count > 0 { dirty.formUnion(index + 1...index + count) }
    }
    // Any step, a response too, may take the place of an earlier response's result: that
    // response is read again, and its results with it when they stop or start being its own.
    if let response = response(covering: index) {
      dirty.insert(response)
      if isLinked(response) == unlinked.contains(response) {
        dirty.formUnion(results(of: response))
      }
    }
    switch step.kind {
    case .prompt(.some) where index > lastPrompt:
      lastPrompt = index
      dirty.formUnion(openResponses)
    case .result(let result):
      if let task = AntigravityTools.cancelledTask(in: result.text) {
        ends[task] = .cancelled
        if let starter = starters[task] { dirty.insert(starter) }
      }
      if let roles = Self.killedRoles(in: result.text) {
        for role in roles where (killedRoles[role] ?? -1) < index { killedRoles[role] = index }
        dirty.formUnion(starters.values)
      }
    case .message(let message?):
      ends[message.sender] =
        message.taskEnd.map { $0.cancelled ? .cancelled : .finished($0.result) }
        ?? .message(message.content)
      if let starter = starters[message.sender] { dirty.insert(starter) }
    default: break
    }
    for step in dirty.sorted() { render(step) }
  }

  // MARK: - Steps

  private static func kind(of type: String, _ object: [String: Any]) -> Kind {
    let content = object["content"] as? String ?? ""
    switch type {
    case "USER_INPUT":
      guard object["source"] as? String == "USER_EXPLICIT" else { return .prompt(nil) }
      return .prompt(ToolOutput.bounded(request(in: content) ?? content).text)
    case "PLANNER_RESPONSE":
      // A call without a name keeps its place: the results of the next ones follow it.
      let calls = ((object["tool_calls"] as? [[String: Any]]) ?? []).prefix(100).map {
        AntigravityTools.Call($0) ?? AntigravityTools.Call(name: "", arguments: [:])
      }
      return .response(
        text: ToolOutput.bounded(content).text,
        thinking: (object["thinking"] as? String).map { ToolOutput.bounded($0).text },
        calls: calls)
    case "GENERIC": return .result(AntigravityTools.Result(object))
    case "SYSTEM_MESSAGE": return .message(AntigravityTools.Message(content))
    case "ERROR_MESSAGE":
      let error = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let error, !error.isEmpty else { return .other }
      return .failure(ToolOutput.bounded(error).text)
    default: return .other
    }
  }

  /// The response whose calls' results would take step `index`, whether they do or not.
  private func response(covering index: Int) -> Int? {
    var candidate = index - 1
    while candidate >= 0, candidate >= index - 101 {
      defer { candidate -= 1 }
      // A step never written — one the export leaves out — keeps its place.
      guard let step = steps[candidate] else { continue }
      if let calls = step.kind.calls { return index <= candidate + calls.count ? candidate : nil }
      if !step.kind.isResult { return nil }
    }
    return nil
  }

  /// How many calls of a response come before a prompt of the user taking the place of a result.
  private func answerable(_ response: Int) -> Int {
    let count = steps[response]?.kind.calls?.count ?? 0
    for offset in 0..<count {
      if case .prompt(.some) = steps[response + 1 + offset]?.kind { return offset }
    }
    return count
  }

  private func results(of response: Int) -> ClosedRange<Int> {
    let count = max(1, steps[response]?.kind.calls?.count ?? 0)
    return response + 1...response + count
  }

  /// Whether the steps after a response are its results, one per call in order. A prompt of the
  /// user among them ends them: the calls left had no result when the user spoke again.
  private func isLinked(_ response: Int) -> Bool {
    guard let calls = steps[response]?.kind.calls else { return false }
    for (offset, call) in calls.enumerated() {
      guard let step = steps[response + 1 + offset] else { continue }
      if case .prompt(.some) = step.kind { return true }
      guard case .result(let result) = step.kind else { return false }
      if call.name == "run_command", !result.isFailure,
        AntigravityTools.commandExit(result.text) == nil,
        AntigravityTools.task(startedBy: result.text) == nil
      {
        return false
      }
    }
    return true
  }

  // MARK: - Entries

  private func render(_ index: Int) {
    guard let step = steps[index] else { return }
    renderCount += 1
    let prefix = "agy:\(index):"
    var additions: [ConversationEntry] = []
    func append(_ suffix: String, _ content: ConversationEntry.Content) {
      additions.append(ConversationEntry(id: prefix + suffix, date: step.date, content: content))
    }
    switch step.kind {
    case .prompt(let prompt?) where !prompt.isEmpty:
      append("user", .userPrompt(prompt, attachments: []))
    case .response(let text, let thinking, let calls):
      if let thinking, !thinking.isEmpty { append("thinking", .reasoning(thinking)) }
      if !text.isEmpty { append("text", .agentText(text)) }
      let linked = isLinked(index)
      if linked { unlinked.remove(index) } else { unlinked.insert(index) }
      openResponses.remove(index)
      // A snapshot of the response may hold fewer calls than the last one.
      background = background.filter { !$0.key.hasPrefix(prefix) }
      for (offset, call) in calls.enumerated() where !call.name.isEmpty {
        let id = "tool:\(offset)"
        guard linked else {
          append(id, .notice(.information(Self.described(call))))
          continue
        }
        append(id, .tool(tool(call, id: prefix + id, response: index, offset: offset)))
      }
    case .result(let result):
      guard response(covering: index).map(isLinked) != true else { break }
      let text = (result.isFailure ? result.failure : result.text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        append("information", .notice(.information(AntigravityTools.shorteningTasks(text))))
      }
    case .failure(let error) where index == lastStep:
      append("error", .notice(.error(error)))
    default: break
    }
    replaceEntries(of: index, with: additions)
  }

  /// A call, its result applied when it has one, and what was said later of the task or the
  /// sub-agent it started.
  private func tool(_ call: AntigravityTools.Call, id: String, response: Int, offset: Int)
    -> ToolCall
  {
    var tool = AntigravityTools.toolCall(call, id: id)
    guard offset < answerable(response), let step = steps[response + 1 + offset],
      case .result(let result) = step.kind
    else {
      // Stopped for good once the user spoke again; until then the next prompt decides.
      if lastPrompt > response {
        tool.state = .interrupted
      } else {
        tool.state = .running
        openResponses.insert(response)
      }
      if tool.kind == .subagent { tool.subagent?.startedAt = steps[response]?.date }
      return tool
    }
    AntigravityTools.apply(result, of: call, to: &tool, date: step.date)
    guard !result.isFailure,
      let started = AntigravityTools.task(startedBy: result.text) ?? tool.subagent?.agentID
    else { return tool }
    starters[started] = response
    switch ends[started] {
    case .finished(let text):
      finish(&tool, with: text)
    case .message(let text):
      if tool.kind == .subagent {
        tool.subagent?.result = ClaudeCodeConversationDecoder.bounded(text)
        tool.state = .succeeded
      } else {
        // A recurring schedule says each time it fires: it is still running.
        tool.output = ToolOutput.bounded(text)
        tool.state = call.string("CronExpression") == nil ? .succeeded : .running
      }
    case .cancelled:
      tool.state = .interrupted
    case nil:
      if tool.kind == .subagent, let role = call.string("Role"),
        let killed = killedRoles[role], killed > response
      {
        tool.state = .interrupted
      }
    }
    if !tool.state.isFinished { background[id] = step.date ?? .distantPast }
    return tool
  }

  private func finish(_ tool: inout ToolCall, with text: String) {
    if tool.kind == .shell {
      AntigravityTools.applyCommand(text, omitted: 0, to: &tool)
      if !tool.state.isFinished { tool.state = .succeeded }
    } else {
      tool.state = .succeeded
      tool.output = text.isEmpty ? nil : ToolOutput.bounded(text)
    }
  }

  /// A call shown apart from its result: its name and its arguments, decoded.
  static func described(_ call: AntigravityTools.Call) -> String {
    let lines = AntigravityTools.generic(call.arguments).map { $0.value }
    return ToolOutput.bounded(([call.name] + lines).joined(separator: "\n")).text
  }

  /// `Successfully killed 3 subagent(s) …\nKilled roles: File Counter, Notes Reader`.
  static func killedRoles(in text: String) -> [String]? {
    guard text.hasPrefix("Successfully killed "),
      let range = text.range(of: "Killed roles: ")
    else { return nil }
    let line = text[range.upperBound...].prefix { !$0.isNewline }
    return line.components(separatedBy: ", ").filter { !$0.isEmpty }
  }

  /// Puts a step's entries where its number places them, instead of those it had.
  private func replaceEntries(of step: Int, with additions: [ConversationEntry]) {
    var low = 0
    var high = entrySteps.count
    while low < high {
      let middle = (low + high) / 2
      if entrySteps[middle] < step { low = middle + 1 } else { high = middle }
    }
    var end = low
    while end < entrySteps.count, entrySteps[end] == step { end += 1 }
    entries.replaceSubrange(low..<end, with: additions)
    entrySteps.replaceSubrange(low..<end, with: repeatElement(step, count: additions.count))
  }

  /// What the user typed, without the time and settings metadata the export adds around it; `nil`
  /// when the text is not wrapped. The last close marker ends it, so a literal `</USER_REQUEST>`
  /// inside the prompt is kept. An empty request — attachments alone — is an empty prompt.
  static func request(in text: String) -> String? {
    let open = "<USER_REQUEST>\n"
    guard text.hasPrefix(open) else { return nil }
    let body = text.dropFirst(open.count)
    if let end = body.range(of: "\n</USER_REQUEST>", options: .backwards) {
      return String(body[..<end.lowerBound])
    }
    return body.hasPrefix("</USER_REQUEST>") ? "" : nil
  }
}
