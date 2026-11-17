import Foundation
import VibeApplication

/// The tools of `agy` as its exported transcript writes them, read into the conversation's own
/// entries (#561). Measured against 1.5.10: see `docs/validation/0561-antigravity-tools.md`.
///
/// A call is `{"name": …, "args": {…}}` where every argument is itself JSON text —
/// `"CommandLine": "\"ls -la\""`, `"WaitMsBeforeAsync": "5000"`: each is decoded once, here. Its
/// result is a later `GENERIC` step whose content starts with `Created At` / `Completed At` lines,
/// written twice; they are left out.
enum AntigravityTools {
  // MARK: - Calls

  /// One call of a `PLANNER_RESPONSE`, its arguments decoded.
  struct Call {
    let name: String
    let arguments: [String: Any]

    init(name: String, arguments: [String: Any]) {
      self.name = name
      self.arguments = arguments
    }

    /// `nil` for a call without a name.
    init?(_ object: [String: Any]) {
      guard let name = object["name"] as? String, !name.isEmpty else { return nil }
      self.name = name
      arguments = (object["args"] as? [String: Any] ?? [:]).mapValues(AntigravityTools.decoded)
    }

    func string(_ key: String) -> String? {
      switch arguments[key] {
      case let text as String: return text.isEmpty ? nil : text
      case let number as NSNumber: return number.stringValue
      default: return nil
      }
    }

    func flag(_ key: String) -> Bool { (arguments[key] as? NSNumber)?.boolValue == true }

    func integer(_ key: String) -> Int? {
      (arguments[key] as? NSNumber)?.intValue ?? string(key).flatMap { Int($0) }
    }
  }

  /// An argument as the model meant it: the JSON text `agy` wrote it as, decoded, or the text
  /// itself when it is not JSON.
  static func decoded(_ value: Any) -> Any {
    guard let text = value as? String, let data = text.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return value }
    return object
  }

  /// The entry a call reads as before its result, if any, is known.
  static func toolCall(_ call: Call, id: String) -> ToolCall {
    var parameters: [ToolParameter] = []
    func add(_ key: ToolParameter.Key, _ value: String?) {
      if let value, !value.isEmpty { parameters.append(ToolParameter(key, value)) }
    }
    var tool = ToolCall(callID: id, kind: .other(call.name))
    switch call.name {
    case "run_command":
      tool.kind = .shell
      add(.command, call.string("CommandLine"))
      add(.workingDirectory, call.string("Cwd"))
      tool.summary = call.string("toolSummary")
    case "read_file":
      tool.kind = .read
      add(.path, call.string("Path"))
      add(.lines, lines(from: call.integer("StartLine"), to: call.integer("EndLine")))
    case "write_file":
      let path = call.string("Path") ?? ""
      add(.path, path)
      let appended = call.flag("Append")
      tool.kind = appended || call.flag("Overwrite") ? .edit : .create
      tool.changes = [
        written(
          call.string("Content") ?? "", to: path, appended: appended,
          replacing: call.flag("Overwrite"))
      ]
    case "edit_file":
      tool.kind = .edit
      let path = call.string("Path") ?? ""
      add(.path, path)
      add(.description, call.string("Description"))
      tool.changes = [
        replacement(of: call.string("Target") ?? "", by: call.string("Replacement") ?? "", in: path)
      ]
    case "search_web":
      tool.kind = .webSearch
      add(.query, call.string("query") ?? call.string("Query"))
    case "call_mcp_tool":
      tool.kind = .mcp(server: call.string("ServerName") ?? "", tool: call.string("ToolName") ?? "")
      add(.arguments, call.arguments["Arguments"].flatMap(readable))
    case "list_resources", "read_resource":
      tool.kind = .mcp(server: call.string("ServerName") ?? "", tool: call.name)
      add(.url, call.string("Uri"))
    case "ask_question":
      tool.kind = .question
      for question in call.arguments["questions"] as? [[String: Any]] ?? [] {
        add(.question, question["question"] as? String)
        if (question["is_multi_select"] as? NSNumber)?.boolValue == true {
          add(.multipleChoices, "true")
        }
        for option in question["options"] as? [Any] ?? [] {
          add(.arguments, option as? String ?? (option as? [String: Any])?["label"] as? String)
        }
      }
    case "invoke_subagent":
      tool.kind = .subagent
      add(.description, call.string("Role"))
      add(.prompt, call.string("Prompt"))
      tool.subagent = SubagentRun(type: call.string("TypeName"), mode: .background)
    default:
      parameters = generic(call.arguments)
    }
    tool.parameters = parameters
    return tool
  }

  /// The arguments of a tool with no view of its own, one per line, values as written: never JSON
  /// around them. The words the agent wrote for a person — a prompt, a message — apart.
  static func generic(_ arguments: [String: Any]) -> [ToolParameter] {
    var parameters: [ToolParameter] = []
    var lines: [String] = []
    // One name says what the call is about; a description beside it is one more argument.
    var named = false
    let keys = arguments.keys.sorted { lhs, rhs in
      (nameKeys.contains(lhs) ? 0 : 1, lhs) < (nameKeys.contains(rhs) ? 0 : 1, rhs)
    }
    for key in keys {
      guard let value = arguments[key], let text = readable(value), !text.isEmpty else { continue }
      switch key {
      case _ where nameKeys.contains(key) && !named:
        named = true
        parameters.append(ToolParameter(.description, text))
      case "Prompt", "Message", "SystemPrompt", "brief", "Script", "Input":
        parameters.append(ToolParameter(.prompt, text))
      default:
        lines.append("\(key): \(text)")
      }
    }
    if !lines.isEmpty {
      parameters.append(ToolParameter(.arguments, lines.joined(separator: "\n")))
    }
    return parameters
  }

  private static let nameKeys: Set<String> = ["Name", "Role", "title", "name"]

  /// A value shown as text: a string as itself — a task's identifier shortened — anything else as
  /// compact JSON.
  static func readable(_ value: Any) -> String? {
    switch value {
    case let text as String: return shorteningTasks(text)
    case let number as NSNumber:
      return CFGetTypeID(number) == CFBooleanGetTypeID()
        ? (number.boolValue ? "true" : "false") : number.stringValue
    default: return ClaudeCodeConversationDecoder.compactJSON(value)
    }
  }

  static func lines(from start: Int?, to end: Int?) -> String? {
    switch (start, end) {
    case (let start?, let end?): return "\(start)–\(end)"
    case (let start?, nil): return "\(start)–"
    case (nil, let end?): return "1–\(end)"
    default: return nil
    }
  }

  // MARK: - Diffs

  /// What `write_file` wrote. Its result says only `Created file.`: the content is the call's. An
  /// append adds lines at an end whose number is not known.
  static func written(_ content: String, to path: String, appended: Bool, replacing: Bool = false)
    -> FileDiff
  {
    let (hunks, omitted) = UnifiedDiffParser.addition(of: content)
    guard appended else {
      // Written over a file whose old content the export does not hold: the new one, whole.
      return FileDiff(
        path: path, kind: replacing ? .modified : .added, hunks: hunks, omittedLineCount: omitted)
    }
    let unnumbered = hunks.map { hunk in
      DiffHunk(
        oldStart: 0, newStart: 0,
        lines: hunk.lines.map {
          DiffLine(kind: .added, text: $0.text, oldNumber: nil, newNumber: nil)
        }
      )
    }
    return FileDiff(path: path, kind: .modified, hunks: unnumbered, omittedLineCount: omitted)
  }

  /// What `edit_file` replaced: its target, removed, then its replacement. Numbered from the line
  /// the result names, once it does.
  static func replacement(
    of target: String, by replacement: String, in path: String, at line: Int? = nil
  )
    -> FileDiff
  {
    func split(_ text: String) -> [String] {
      text.isEmpty ? [] : text.components(separatedBy: "\n")
    }
    let removed = split(target)
    let added = split(replacement)
    var lines: [DiffLine] = []
    for (offset, text) in removed.prefix(DiffHunk.lineLimit).enumerated() {
      lines.append(
        DiffLine(kind: .removed, text: text, oldNumber: line.map { $0 + offset }, newNumber: nil))
    }
    for (offset, text) in added.prefix(max(0, DiffHunk.lineLimit - lines.count)).enumerated() {
      lines.append(
        DiffLine(kind: .added, text: text, oldNumber: nil, newNumber: line.map { $0 + offset }))
    }
    return FileDiff(
      path: path, kind: .modified,
      hunks: [DiffHunk(oldStart: line ?? 0, newStart: line ?? 0, lines: lines)],
      omittedLineCount: removed.count + added.count - lines.count)
  }

  // MARK: - Results

  /// A `GENERIC` step: what a call returned.
  struct Result {
    enum Status { case done, running, error, invalid, other }

    let status: Status
    /// The content without its time lines, its line ends made `\n`.
    let text: String
    /// What `agy` left out of the middle of a long output, in bytes.
    let omittedByteCount: Int
    /// The error a step that failed names on its own.
    let error: String?

    init(status: Status, text: String, omittedByteCount: Int = 0, error: String? = nil) {
      self.status = status
      self.text = text
      self.omittedByteCount = omittedByteCount
      self.error = error
    }

    init(_ object: [String: Any]) {
      switch object["status"] as? String {
      case "DONE": status = .done
      case "RUNNING": status = .running
      case "ERROR": status = .error
      case "INVALID": status = .invalid
      default: status = .other
      }
      let cleaned = AntigravityTools.cleaned(object["content"] as? String ?? "")
      text = cleaned.text
      omittedByteCount = cleaned.omitted
      error = (object["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var isFailure: Bool { status == .error || status == .invalid }

    /// The words of a failure: the step's own error, else its content.
    var failure: String {
      if let error { return error }
      for prefix in ["Encountered error in step execution: ", "Error invalid tool call: "]
      where text.hasPrefix(prefix) {
        return String(text.dropFirst(prefix.count))
      }
      return text
    }

    /// A refusal of the user, or of a rule of the CLI.
    var isRefusal: Bool {
      isFailure && failure.contains("denied permission")
    }
  }

  static let truncationPreview = "Here is a preview with the middle of the output truncated:\n"

  /// The content of a step without the metadata `agy` puts around it, and without the note of a
  /// truncated output, which says where the whole is kept: the middle it left out is counted.
  static func cleaned(_ content: String) -> (text: String, omitted: Int) {
    var text = droppingTimes(content)
    if text.hasPrefix("The tool's output was truncated"),
      let preview = text.range(of: truncationPreview)
    {
      text = droppingTimes(String(text[preview.upperBound...]))
    }
    text = text.replacingOccurrences(of: "\r\n", with: "\n")
    var omitted = 0
    if let marker = text.range(of: #"\n?<truncated (\d+) bytes>\n?"#, options: .regularExpression) {
      let digits = text[marker].filter(\.isNumber)
      omitted = Int(digits) ?? 0
      text.replaceSubrange(marker, with: "\n…\n")
    }
    return (text, omitted)
  }

  private static func droppingTimes(_ text: String) -> String {
    var rest = text[...]
    while rest.hasPrefix("Created At: ") || rest.hasPrefix("Completed At: ") {
      guard let newline = rest.firstIndex(of: "\n") else { return "" }
      rest = rest[rest.index(after: newline)...]
    }
    return String(rest)
  }

  /// What a result says of the call it answers, applied to it. `call` is the call as `toolCall`
  /// read it.
  static func apply(_ result: Result, to tool: inout ToolCall, date: Date?) {
    if result.isFailure {
      tool.state = result.isRefusal ? .refused : .failed(exitCode: nil)
      tool.output = ToolOutput.bounded(shorteningTasks(result.failure), isError: true)
      if tool.kind == .edit || tool.kind == .create { tool.changes = [] }
      if tool.kind == .subagent { tool.subagent?.failure = result.failure }
      return
    }
    tool.state = result.status == .running ? .running : .succeeded
    // Sent to the background, a task or a timer: its end comes later, its note says nothing more.
    if result.text.hasPrefix(backgroundPrefix), tool.kind != .subagent {
      tool.state = .running
      return
    }
    switch tool.kind {
    case .shell: applyCommand(result.text, omitted: result.omittedByteCount, to: &tool)
    case .read:
      let (header, body) = headed(result.text)
      tool.output = ToolOutput.bounded(body)
      tool.facts.lineCount = header.flatMap(shownLineCount)
    case .edit, .create: applyEdit(result.text, to: &tool)
    case .question:
      tool.parameters = ClaudeCodeConversationDecoder.answering(
        tool.parameters, with: answers(result.text, to: tool.parameters))
      // Every question skipped, the user dismissed the call: Escape on its card.
      let lines = result.text.split(separator: "\n")
      if !lines.isEmpty, lines.allSatisfy({ $0.hasSuffix(": User Skipped") }) {
        tool.state = .interrupted
      }
    case .subagent:
      tool.subagent?.agentID = subagentConversation(in: result.text)
      tool.subagent?.startedAt = date
      tool.state = .running
    default:
      tool.output = result.text.isEmpty ? nil : output(result)
    }
  }

  private static func output(_ result: Result) -> ToolOutput {
    let bounded = ToolOutput.bounded(shorteningTasks(result.text))
    return ToolOutput(
      text: bounded.text, omittedByteCount: bounded.omittedByteCount + result.omittedByteCount)
  }

  // MARK: Commands

  static let backgroundPrefix = "Tool is running as a background task with task id: "

  /// `Command exited with code 1.\n\nCommand output:\n…`, `… No output from the command.`, or the
  /// note of a command sent to the background, whose task ends later.
  static func applyCommand(_ text: String, omitted: Int, to tool: inout ToolCall) {
    if text.hasPrefix(backgroundPrefix) {
      tool.state = .running
      return
    }
    guard let exit = commandExit(text) else {
      tool.output = text.isEmpty ? nil : ToolOutput.bounded(text)
      return
    }
    tool.facts.exitCode = exit.code
    tool.state = exit.code == 0 ? .succeeded : .failed(exitCode: exit.code)
    if let printed = exit.output {
      let bounded = ToolOutput.bounded(printed, isError: exit.code != 0)
      tool.output = ToolOutput(
        text: bounded.text, omittedByteCount: bounded.omittedByteCount + omitted,
        isError: exit.code != 0)
      tool.facts.tests = TestOutcomeRecognizer.outcome(
        of: tool.parameter(.command) ?? "", output: printed)
    } else {
      tool.output = nil
    }
  }

  /// The exit code and the output of a finished command; `nil` for any other text.
  static func commandExit(_ text: String) -> (code: Int32, output: String?)? {
    let prefix = "Command exited with code "
    guard text.hasPrefix(prefix) else { return nil }
    let digits = text.dropFirst(prefix.count).prefix { $0.isNumber || $0 == "-" }
    guard let code = Int32(digits) else { return nil }
    guard let marker = text.range(of: "\n\nCommand output:\n") else { return (code, nil) }
    let output = text[marker.upperBound...].trimmingCharacters(in: .newlines)
    return (code, output.isEmpty ? nil : output)
  }

  /// The task a command sent to the background, or a schedule's timer, runs as.
  static func task(startedBy text: String) -> String? {
    guard text.hasPrefix(backgroundPrefix) else { return nil }
    let rest = text.dropFirst(backgroundPrefix.count)
    let task = rest.prefix { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
    return task.isEmpty ? nil : task
  }

  /// `Task "<task>" cancelled.`: what `manage_task` says of a task it killed.
  static func cancelledTask(in text: String) -> String? {
    guard text.hasPrefix("Task \""), text.hasSuffix("\" cancelled.") else { return nil }
    let task = text.dropFirst("Task \"".count).dropLast("\" cancelled.".count)
    return task.isEmpty || task.contains("\"") ? nil : String(task)
  }

  /// `<conversation>/task-22` reads `task-22`: the conversation is the one shown.
  static func shorteningTasks(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(task-\d+)"#,
      with: "$1", options: .regularExpression)
  }

  // MARK: Files

  /// `Showing lines 1-3 of 3` or `Partial read (…)` first, then the numbered lines.
  static func headed(_ text: String) -> (header: String?, body: String) {
    guard text.hasPrefix("Showing lines ") || text.hasPrefix("Partial read (") else {
      return (nil, text)
    }
    let newline = text.firstIndex(of: "\n") ?? text.endIndex
    let body = newline < text.endIndex ? String(text[text.index(after: newline)...]) : ""
    return (String(text[..<newline]), body)
  }

  /// `Showing lines 2-3 of 3` and `Partial read (lines 1-100 of 352)` show 2 and 100 lines.
  static func shownLineCount(_ header: String) -> Int? {
    guard let match = header.range(of: #"(\d+)-(\d+) of \d+"#, options: .regularExpression)
    else { return nil }
    let numbers = header[match].split { !$0.isNumber }.compactMap { Int($0) }
    guard numbers.count >= 2, numbers[1] >= numbers[0] else { return nil }
    return numbers[1] - numbers[0] + 1
  }

  /// `Made 1 replacement in <path> starting at line 2 (+1/-1 lines).` numbers the diff and counts
  /// the lines of every replacement.
  static func applyEdit(_ text: String, to tool: inout ToolCall) {
    guard tool.kind == .edit, tool.changes.count == 1,
      let start = text.range(of: #"starting at line (\d+)"#, options: .regularExpression)
    else {
      countLines(of: &tool)
      return
    }
    let line = Int(text[start].filter(\.isNumber)) ?? 0
    let change = tool.changes[0]
    if change.hunks.first?.lines.contains(where: { $0.kind == .removed }) == true {
      let removed = change.hunks[0].lines.filter { $0.kind == .removed }.map(\.text)
      let added = change.hunks[0].lines.filter { $0.kind == .added }.map(\.text)
      tool.changes = [
        replacement(
          of: removed.joined(separator: "\n"), by: added.joined(separator: "\n"), in: change.path,
          at: line)
      ]
    }
    countLines(of: &tool)
    if let counts = text.range(of: #"\(\+(\d+)/-(\d+) lines\)"#, options: .regularExpression) {
      let numbers = text[counts].split { !$0.isNumber }.compactMap { Int($0) }
      if numbers.count == 2 {
        tool.facts.addedLines = numbers[0]
        tool.facts.removedLines = numbers[1]
      }
    }
  }

  static func countLines(of tool: inout ToolCall) {
    guard !tool.changes.isEmpty else { return }
    tool.facts.addedLines = tool.changes.reduce(0) { $0 + $1.addedLineCount }
    tool.facts.removedLines = tool.changes.reduce(0) { $0 + $1.removedLineCount }
  }

  // MARK: Questions

  /// `A1: red\nA2: (Recommended) apple, pear`: each question's answer, by question. A question
  /// skipped — `User Skipped` — or left without an answer has none.
  static func answers(_ text: String, to parameters: [ToolParameter]) -> [String: String] {
    let questions = parameters.filter { $0.key == .question }.map(\.value)
    var answers: [String: String] = [:]
    for line in text.components(separatedBy: "\n") {
      guard line.hasPrefix("A"), let colon = line.firstIndex(of: ":"),
        let number = Int(line[line.index(after: line.startIndex)..<colon]),
        number >= 1, number <= questions.count
      else { continue }
      let answer = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !answer.isEmpty, answer != "User Skipped" else { continue }
      answers[questions[number - 1]] = answer
    }
    return answers
  }

  // MARK: Sub-agents and messages

  /// `Created the following subagent:\n{"conversationId": …}`: the sub-agent's own conversation.
  static func subagentConversation(in text: String) -> String? {
    guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
      let object = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8))
        as? [String: Any],
      let conversation = object["conversationId"] as? String,
      UUID(uuidString: conversation) != nil
    else { return nil }
    return conversation.lowercased()
  }

  /// A `SYSTEM_MESSAGE`: `[Message] timestamp=… sender=<who> priority=… content=<text>`, between
  /// `<SYSTEM_MESSAGE>` tags. The sender is a task or a sub-agent's conversation.
  struct Message {
    let sender: String
    let content: String

    init?(_ text: String) {
      // The preface names the tag too: the message is the one that opens on `[Message]`.
      guard let start = text.range(of: "<SYSTEM_MESSAGE>\n[Message] ") else { return nil }
      var body = text[start.upperBound...]
      if let end = body.range(of: "</SYSTEM_MESSAGE>", options: .backwards) {
        body = body[..<end.lowerBound]
      }
      guard let senderRange = body.range(of: " sender="),
        let contentRange = body.range(of: " content=")
      else { return nil }
      let sender = body[senderRange.upperBound...].prefix { !$0.isWhitespace }
      guard !sender.isEmpty, senderRange.upperBound < contentRange.lowerBound else { return nil }
      self.sender = String(sender)
      content = body[contentRange.upperBound...].trimmingCharacters(in: .newlines)
    }

    /// What the end of a task says: `Task id "<task>" finished with result:\n<result>\n\nLog: …`,
    /// or `… was canceled with result:` for one stopped.
    var taskEnd: (cancelled: Bool, result: String)? {
      for (marker, cancelled) in [
        ("\" finished with result:\n", false), ("\" was canceled with result:\n", true),
      ] {
        guard content.hasPrefix("Task id \""), let range = content.range(of: marker) else {
          continue
        }
        var result = String(content[range.upperBound...])
        if let log = result.range(of: "\n\nLog: file://", options: .backwards) {
          result = String(result[..<log.lowerBound])
        } else if let log = result.range(of: "\nLog: file://", options: .backwards) {
          result = String(result[..<log.lowerBound])
        }
        return (cancelled, result.replacingOccurrences(of: "\r\n", with: "\n"))
      }
      return nil
    }
  }
}
