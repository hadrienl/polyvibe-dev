import Foundation
import Testing
import VibeApplication

@testable import VibeAgents

/// Synthetic transcripts in the shapes `agy` 1.5.10 writes (#561): every argument is JSON text,
/// every result a `GENERIC` step whose content starts with time lines written twice.
@Suite("Antigravity tools in the conversation")
struct AntigravityToolTests {
  private let conversation = "1d8f5b60-305e-4ebd-ab57-fc8a990f673f"

  private final class Transcript {
    let decoder = AntigravityConversationDecoder()

    func line(_ object: [String: Any]) {
      decoder.consume(try! JSONSerialization.data(withJSONObject: object))
    }

    func prompt(_ step: Int, _ text: String) {
      line([
        "step_index": step, "type": "USER_INPUT", "source": "USER_EXPLICIT",
        "content": "<USER_REQUEST>\n\(text)\n</USER_REQUEST>",
      ])
    }

    /// A response calling tools, each argument written as JSON text the way `agy` does.
    func calls(_ step: Int, _ calls: [(String, [String: Any])], text: String = "") {
      let encoded = calls.map { name, arguments -> [String: Any] in
        let args = arguments.mapValues { value -> String in
          let data = try! JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
          return String(decoding: data, as: UTF8.self)
        }
        return ["name": name, "args": args]
      }
      line([
        "step_index": step, "type": "PLANNER_RESPONSE", "status": "DONE", "content": text,
        "tool_calls": encoded,
      ])
    }

    func result(_ step: Int, _ content: String, status: String = "DONE", error: String? = nil) {
      let times = "Created At: 2026-11-17T13:13:41+01:00\nCompleted At: 2026-11-17T13:13:41+01:00\n"
      var object: [String: Any] = [
        "step_index": step, "type": "GENERIC", "status": status,
        "content": times + times + content,
      ]
      if let error { object["error"] = error }
      line(object)
    }

    func message(_ step: Int, from sender: String, _ content: String) {
      line([
        "step_index": step, "type": "SYSTEM_MESSAGE", "status": "DONE",
        "content":
          "The following is a <SYSTEM_MESSAGE> not actually sent by the user. It is provided by the system as important information to pay attention to.\n\n<SYSTEM_MESSAGE>\n[Message] timestamp=2026-11-17T12:14:17Z sender=\(sender) priority=MESSAGE_PRIORITY_HIGH content=\(content)\n</SYSTEM_MESSAGE>",
      ])
    }

    var tools: [ToolCall] { decoder.entries.compactMap(\.toolCall) }

    var notices: [String] {
      decoder.entries.compactMap { entry in
        guard case .notice(.information(let text)) = entry.content else { return nil }
        return text
      }
    }
  }

  // MARK: - Commands

  @Test("A command's arguments are decoded once and its result is tied to it, without time lines")
  func command() {
    let transcript = Transcript()
    transcript.calls(
      1,
      [
        (
          "run_command",
          ["CommandLine": "ls -la", "WaitMsBeforeAsync": 5000, "toolSummary": "List"]
        )
      ])
    #expect(transcript.tools.first?.state == .running)
    transcript.result(
      2, "Command exited with code 0.\n\nCommand output:\ntotal 16\r\nnotes.txt\r\n")
    let call = transcript.tools[0]
    #expect(call.kind == .shell)
    #expect(call.parameter(.command) == "ls -la")
    #expect(call.summary == "List")
    #expect(call.state == .succeeded)
    #expect(call.output?.text == "total 16\nnotes.txt")
    #expect(call.facts.exitCode == 0)
    #expect(transcript.notices.isEmpty)
    #expect(transcript.decoder.entries.count == 1)
  }

  @Test("Failures, empty and truncated outputs, and arguments the CLI refused")
  func commandOutcomes() {
    let transcript = Transcript()
    transcript.calls(1, [("run_command", ["CommandLine": "cat missing"])])
    transcript.result(
      2, "Command exited with code 1.\n\nCommand output:\ncat: missing: No such file\r\n")
    transcript.calls(3, [("run_command", ["CommandLine": "exit 3"])])
    transcript.result(4, "Command exited with code 3.\n\nNo output from the command.")
    transcript.calls(5, [("run_command", ["CommandLine": "seq 1 3000"])])
    transcript.result(
      6,
      "The tool's output was truncated due to being too long. You can find the full output in a file at file:///x/steps/6/output.txt.\n\nHere is a preview with the middle of the output truncated:\nCreated At: 2026-11-17T13:13:49+01:00\nCompleted At: 2026-11-17T13:13:49+01:00\nCommand exited with code 0.\n\nCommand output:\n1\r\n2\r\n3\n<truncated 6221 bytes>\n\r\n2999\r\n3000\r\n"
    )
    transcript.calls(7, [("run_command", ["CommandLine": "pwd", "Cwd": "/tmp/src"])])
    transcript.result(
      8, "Error invalid tool call: invalid arguments:\n- additional properties 'Cwd' not allowed",
      status: "INVALID", error: "invalid arguments:\n- additional properties 'Cwd' not allowed")
    let tools = transcript.tools
    #expect(tools[0].state == .failed(exitCode: 1))
    #expect(tools[0].output == ToolOutput(text: "cat: missing: No such file", isError: true))
    #expect(tools[1].state == .failed(exitCode: 3))
    #expect(tools[1].output == nil)
    #expect(tools[2].state == .succeeded)
    #expect(tools[2].output?.omittedByteCount == 6221)
    #expect(tools[2].output?.text == "1\n2\n3\n…\n2999\n3000")
    #expect(tools[3].state == .failed(exitCode: nil))
    #expect(tools[3].parameter(.workingDirectory) == "/tmp/src")
    #expect(
      tools[3].output?.text == "invalid arguments:\n- additional properties 'Cwd' not allowed")
  }

  @Test("Parallel calls take the results numbered after them, in order, whatever the tools")
  func parallelCalls() {
    let transcript = Transcript()
    transcript.calls(
      7,
      [
        ("run_command", ["CommandLine": "echo alpha"]),
        ("run_command", ["CommandLine": "echo beta"]),
        ("search_web", ["query": "Observation"]),
      ])
    transcript.result(9, "Command exited with code 0.\n\nCommand output:\nbeta\r\n")
    transcript.result(8, "Command exited with code 0.\n\nCommand output:\nalpha\r\n")
    transcript.result(10, "The search returned the following summary:\nIt observes.")
    let tools = transcript.tools
    #expect(
      tools.map { $0.output?.text } == [
        "alpha", "beta", "The search returned the following summary:\nIt observes.",
      ])
    #expect(tools[2].kind == .webSearch)
    #expect(tools[2].parameter(.query) == "Observation")
    #expect(
      transcript.decoder.entries.map(\.id) == ["agy:7:tool:0", "agy:7:tool:1", "agy:7:tool:2"])
  }

  @Test("Results are kept apart when the steps after a response are not all its results")
  func unsafeLinks() {
    let transcript = Transcript()
    transcript.calls(
      1, [("run_command", ["CommandLine": "echo a"]), ("run_command", ["CommandLine": "echo b"])])
    transcript.result(2, "Command exited with code 0.\n\nCommand output:\na\r\n")
    #expect(transcript.tools.count == 2)
    transcript.message(3, from: "someone", "hello")
    #expect(transcript.tools.isEmpty)
    #expect(
      transcript.notices == [
        "run_command\nCommandLine: echo a", "run_command\nCommandLine: echo b",
        "Command exited with code 0.\n\nCommand output:\na",
      ])
    // A command whose result does not read like one is not taken for it either.
    let other = Transcript()
    other.calls(1, [("run_command", ["CommandLine": "ls"])])
    other.result(2, "Showing lines 1-1 of 1\n1: x")
    #expect(other.tools.isEmpty)
    #expect(other.notices == ["run_command\nCommandLine: ls", "Showing lines 1-1 of 1\n1: x"])
  }

  @Test("A command sent to the background ends with its task's message, or is stopped")
  func backgroundTasks() {
    let transcript = Transcript()
    let task = "\(conversation)/task-11"
    transcript.calls(10, [("run_command", ["CommandLine": "sleep 20 && echo done"])])
    transcript.result(
      11,
      "Tool is running as a background task with task id: \(task)\nTask Description: sleep 20\nTask logs are available at: file:///x/task-11.log\nYOU MUST TAKE ONE OF THE FOLLOWING TWO ACTIONS",
      status: "RUNNING")
    #expect(transcript.tools[0].state == .running)
    #expect(transcript.tools[0].output == nil)
    #expect(transcript.decoder.backgroundWork.count == 1)
    transcript.message(
      12, from: task,
      "Task id \"\(task)\" finished with result:\nCommand exited with code 0.\n\nCommand output:\ndone\r\n\nLog: file:///x/task-11.log"
    )
    #expect(transcript.tools[0].state == .succeeded)
    #expect(transcript.tools[0].output?.text == "done")
    #expect(transcript.decoder.backgroundWork.isEmpty)

    let killed = "\(conversation)/task-21"
    transcript.calls(20, [("run_command", ["CommandLine": "sleep 120"])])
    transcript.result(
      21, "Tool is running as a background task with task id: \(killed)\n", status: "RUNNING")
    transcript.calls(22, [("manage_task", ["Action": "kill", "TaskId": killed])])
    transcript.result(23, "Task \"\(killed)\" cancelled.")
    let tools = transcript.tools
    #expect(tools[1].state == .interrupted)
    #expect(tools[2].kind == .other("manage_task"))
    #expect(tools[2].parameter(.arguments) == "Action: kill\nTaskId: task-21")
    #expect(tools[2].output?.text == "Task \"task-21\" cancelled.")

    let canceled = "\(conversation)/task-30"
    transcript.calls(30, [("run_command", ["CommandLine": "grep -r x /"])])
    transcript.result(
      31, "Tool is running as a background task with task id: \(canceled)\n", status: "RUNNING")
    transcript.message(
      32, from: canceled,
      "Task id \"\(canceled)\" was canceled with result:\nTool execution was canceled")
    #expect(transcript.tools[3].state == .interrupted)
  }

  @Test("A refused command, and one the user stopped before it returned")
  func refusalAndInterruption() {
    let transcript = Transcript()
    transcript.calls(1, [("run_command", ["CommandLine": "ls -la"])])
    transcript.result(
      2,
      "Encountered error in step execution: permission check failed for unsandboxed \"ls -la\": user denied permission to run command:\nls -la",
      status: "ERROR",
      error:
        "permission check failed for unsandboxed \"ls -la\": user denied permission to run command:\nls -la"
    )
    transcript.calls(10, [("run_command", ["CommandLine": "sleep 40"])])
    #expect(transcript.tools[1].state == .running)
    // agy 1.5.11 never writes the stopped command's step (11): the next prompt takes step 12.
    transcript.prompt(12, "Go on")
    #expect(transcript.tools[0].state == .refused)
    #expect(transcript.tools[0].output?.isError == true)
    #expect(transcript.tools[1].state == .interrupted)
    // Parallel calls stopped half way: the prompt takes a result's place and ends the others.
    transcript.calls(
      20, [("run_command", ["CommandLine": "echo a"]), ("run_command", ["CommandLine": "sleep 9"])])
    transcript.result(21, "Command exited with code 0.\n\nCommand output:\na\r\n")
    transcript.prompt(22, "Stop")
    #expect(transcript.tools[2].state == .succeeded)
    #expect(transcript.tools[2].output?.text == "a")
    #expect(transcript.tools[3].state == .interrupted)
    #expect(transcript.decoder.entries.last?.content == .userPrompt("Stop", attachments: []))
  }

  // MARK: - Files

  @Test("Writes show what they wrote: created, appended, written over, refused")
  func writes() {
    let transcript = Transcript()
    let path = "/tmp/w/hello.txt"
    transcript.calls(1, [("write_file", ["Path": path, "Content": "one\ntwo\n"])])
    transcript.result(2, "Created file.")
    transcript.calls(3, [("write_file", ["Path": path, "Content": "four\n", "Append": true])])
    transcript.result(4, "Created file.")
    transcript.calls(5, [("write_file", ["Path": path, "Content": "new", "Overwrite": true])])
    transcript.result(6, "Created file.")
    transcript.calls(7, [("write_file", ["Path": path, "Content": "x"])])
    transcript.result(
      8, "Encountered error in step execution: \(path) already exists.", status: "ERROR",
      error: "\(path) already exists.")
    let tools = transcript.tools
    #expect(tools[0].kind == .create)
    #expect(tools[0].state == .succeeded)
    #expect(tools[0].changes.first?.kind == .added)
    #expect(tools[0].changes.first?.hunks.first?.lines.map(\.newNumber) == [1, 2])
    #expect(tools[0].output == nil)
    #expect(tools[1].kind == .edit)
    #expect(
      tools[1].changes.first?.hunks.first?.lines == [
        DiffLine(kind: .added, text: "four", oldNumber: nil, newNumber: nil)
      ])
    #expect(tools[2].kind == .edit)
    #expect(tools[2].changes.first?.kind == .modified)
    #expect(tools[3].state == .failed(exitCode: nil))
    #expect(tools[3].changes.isEmpty)
    #expect(tools[3].output?.text == "\(path) already exists.")
  }

  @Test("An edit is a diff numbered from the line its result names, counted by its result")
  func edits() {
    let transcript = Transcript()
    let path = "/tmp/w/index.js"
    transcript.calls(
      1, [("edit_file", ["Path": path, "Target": "a\n  b", "Replacement": "c"])])
    #expect(transcript.tools[0].changes.first?.hunks.first?.lines.compactMap(\.oldNumber) == [])
    transcript.result(2, "Made 1 replacement in \(path) starting at line 4 (+1/-2 lines).")
    transcript.calls(3, [("edit_file", ["Path": path, "Target": "line", "Replacement": "LINE"])])
    transcript.result(4, "Made 3 replacements in \(path) starting at line 1 (+3/-3 lines).")
    transcript.calls(5, [("edit_file", ["Path": path, "Target": "zzz", "Replacement": "y"])])
    transcript.result(
      6, "Encountered error in step execution: target content not found in the file",
      status: "ERROR", error: "target content not found in the file")
    let tools = transcript.tools
    #expect(
      tools[0].changes.first?.hunks.first?.lines == [
        DiffLine(kind: .removed, text: "a", oldNumber: 4, newNumber: nil),
        DiffLine(kind: .removed, text: "  b", oldNumber: 5, newNumber: nil),
        DiffLine(kind: .added, text: "c", oldNumber: nil, newNumber: 4),
      ])
    #expect(tools[0].facts.addedLines == 1)
    #expect(tools[0].facts.removedLines == 2)
    #expect(tools[1].facts.addedLines == 3)
    #expect(tools[1].facts.removedLines == 3)
    #expect(tools[2].state == .failed(exitCode: nil))
    #expect(tools[2].changes.isEmpty)
  }

  @Test("A read names its lines and shows them without the header")
  func reads() {
    let transcript = Transcript()
    transcript.calls(
      1, [("read_file", ["Path": "/tmp/w/notes.txt", "StartLine": 2, "EndLine": 3])])
    transcript.result(2, "Showing lines 2-3 of 3\n2: second\n3: third")
    transcript.calls(3, [("read_file", ["Path": "/tmp/w/big.jsonl", "ByteOffset": 0])])
    transcript.result(
      4,
      "Partial read (lines 1-100 of 352). Showing bytes 0-46080 of 574849 in this line range.\n1: {}"
    )
    transcript.calls(5, [("read_file", ["Path": "/tmp/w/missing.txt"])])
    transcript.result(
      6, "Encountered error in step execution: file does not exist", status: "ERROR",
      error: "file does not exist")
    let tools = transcript.tools
    #expect(tools[0].kind == .read)
    #expect(tools[0].parameter(.lines) == "2–3")
    #expect(tools[0].output?.text == "2: second\n3: third")
    #expect(tools[0].facts.lineCount == 2)
    #expect(tools[1].facts.lineCount == 100)
    #expect(tools[1].output?.text == "1: {}")
    #expect(tools[2].output == ToolOutput(text: "file does not exist", isError: true))
  }

  // MARK: - MCP and questions

  @Test("MCP calls name their server and tool, their arguments as compact JSON, decoded once")
  func mcp() {
    let transcript = Transcript()
    transcript.calls(
      2,
      [
        (
          "call_mcp_tool",
          [
            "ServerName": "vmtest", "ToolName": "echo",
            "Arguments": "{\"text\":\"hi\",\"times\":2}",
          ]
        ),
        ("read_resource", ["ServerName": "vmtest", "Uri": "vmtest://readme"]),
      ])
    transcript.result(3, "hi hi")
    transcript.result(4, "[{\"uri\":\"vmtest://readme\", \"text\":{\"text\":\"hello\"}}]")
    transcript.calls(6, [("call_mcp_tool", ["ServerName": "vmtest", "ToolName": "explode"])])
    transcript.result(
      7, "Encountered error in step execution: boom", status: "ERROR", error: "boom")
    let tools = transcript.tools
    #expect(tools[0].kind == .mcp(server: "vmtest", tool: "echo"))
    #expect(tools[0].parameter(.arguments) == "{\"text\":\"hi\",\"times\":2}")
    #expect(tools[0].output?.text == "hi hi")
    #expect(tools[1].kind == .mcp(server: "vmtest", tool: "read_resource"))
    #expect(tools[1].parameter(.url) == "vmtest://readme")
    #expect(tools[2].state == .failed(exitCode: nil))
    #expect(tools[2].output?.text == "boom")
  }

  @Test("Questions get their answers; skipped ones are stopped, unanswered ones left open")
  func questions() {
    let transcript = Transcript()
    let fruits: [String: Any] = [
      "questions": [
        [
          "question": "Which fruits?", "options": ["(Recommended) apple", "pear", "plum"],
          "is_multi_select": true,
        ],
        ["question": "Which size?", "options": ["small", "large"]],
      ]
    ]
    transcript.calls(5, [("ask_question", fruits)])
    transcript.result(6, "A1: (Recommended) apple, pear\nA2: ")
    transcript.calls(
      7, [("ask_question", ["questions": [["question": "Colour?", "options": ["red", "blue"]]]])])
    transcript.result(8, "A1: User Skipped")
    let tools = transcript.tools
    #expect(tools[0].kind == .question)
    #expect(
      tools[0].parameters == [
        ToolParameter(.question, "Which fruits?"), ToolParameter(.multipleChoices, "true"),
        ToolParameter(.arguments, "(Recommended) apple"), ToolParameter(.arguments, "pear"),
        ToolParameter(.arguments, "plum"), ToolParameter(.answer, "(Recommended) apple, pear"),
        ToolParameter(.question, "Which size?"), ToolParameter(.arguments, "small"),
        ToolParameter(.arguments, "large"),
      ])
    #expect(tools[0].state == .succeeded)
    #expect(tools[1].state == .interrupted)
    #expect(!tools[1].parameters.contains { $0.key == .answer })
  }

  // MARK: - Sub-agents and orchestration

  @Test("A sub-agent runs until its message, is stopped by a kill, and fails with its error")
  func subagents() {
    let transcript = Transcript()
    let first = "5741f554-c36f-434a-a1ad-f8cbdd57c9d4"
    let second = "6b811fba-6e19-4c17-8efd-ef5ca1660716"
    func created(_ id: String) -> String {
      "Created the following subagent:\n{\n  \"conversationId\":  \"\(id)\",\n  \"logAbsoluteUri\":  \"file:///x\"\n}\nThe subagent will send you a message when it has completed its task."
    }
    transcript.calls(
      11,
      [
        ("invoke_subagent", ["TypeName": "self", "Role": "Notes Reader", "Prompt": "Read notes"]),
        ("invoke_subagent", ["TypeName": "counter", "Role": "Counter", "Prompt": "Count"]),
        ("invoke_subagent", ["TypeName": "nope", "Role": "Broken", "Prompt": "x"]),
      ])
    transcript.result(12, created(first))
    transcript.result(13, created(second))
    transcript.result(
      14, "Encountered error in step execution: unknown type", status: "ERROR",
      error: "unknown type")
    var tools = transcript.tools
    #expect(tools[0].kind == .subagent)
    #expect(tools[0].state == .running)
    #expect(tools[0].subagent?.agentID == first)
    #expect(tools[0].subagent?.type == "self")
    #expect(tools[0].parameter(.description) == "Notes Reader")
    #expect(tools[0].parameter(.prompt) == "Read notes")
    #expect(transcript.decoder.backgroundWork.count == 2)
    transcript.message(19, from: first, "The first line is: \"first line\"")
    transcript.calls(24, [("manage_subagents", ["Action": "kill_all"])])
    transcript.result(
      25,
      "Successfully killed 2 subagent(s) and their descendants.\nKilled roles: Counter, Notes Reader"
    )
    tools = transcript.tools
    #expect(tools[0].state == .succeeded)
    #expect(tools[0].subagent?.result == "The first line is: \"first line\"")
    #expect(tools[1].state == .interrupted)
    #expect(tools[2].state == .failed(exitCode: nil))
    #expect(tools[2].subagent?.failure == "unknown type")
    #expect(transcript.decoder.backgroundWork.isEmpty)
  }

  @Test("Tools with no view of their own read as their name and their arguments, one per line")
  func otherTools() {
    let transcript = Transcript()
    transcript.calls(
      1,
      [
        (
          "define_subagent",
          [
            "Name": "counter", "Description": "Counts files", "SystemPrompt": "You count.",
            "EnableWriteTools": false,
          ]
        )
      ])
    transcript.result(2, "Subagent \"counter\" defined successfully.")
    transcript.calls(14, [("schedule", ["DurationSeconds": 5, "Prompt": "timer fired"])])
    let timer = "\(conversation)/task-15"
    transcript.result(
      15, "Tool is running as a background task with task id: \(timer)\n", status: "RUNNING")
    transcript.calls(33, [("schedule", ["CronExpression": "* * * * *", "Prompt": "tick"])])
    let cron = "\(conversation)/task-34"
    transcript.result(
      34, "Tool is running as a background task with task id: \(cron)\n", status: "RUNNING")
    transcript.message(36, from: timer, "timer fired")
    transcript.message(37, from: cron, "tick (iteration 2)")
    let tools = transcript.tools
    #expect(tools[0].kind == .other("define_subagent"))
    #expect(
      tools[0].parameters == [
        ToolParameter(.description, "counter"), ToolParameter(.prompt, "You count."),
        ToolParameter(.arguments, "Description: Counts files\nEnableWriteTools: false"),
      ])
    #expect(tools[0].output?.text == "Subagent \"counter\" defined successfully.")
    #expect(tools[1].state == .succeeded)
    #expect(tools[1].output?.text == "timer fired")
    #expect(tools[2].state == .running)
    #expect(tools[2].output?.text == "tick (iteration 2)")
    #expect(!transcript.decoder.entries.contains { "\($0.content)".contains("Created At") })
  }

  @Test("A sub-agent's own transcript is found beside the conversation's by its conversation")
  func subagentTranscripts() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let agent = "5741F554-C36F-434A-A1AD-F8CBDD57C9D4"
    let logs = home.appendingPathComponent(
      ".gemini/antigravity-cli/brain/\(agent.lowercased())/.system_generated/logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let file = logs.appendingPathComponent("transcript.jsonl")
    try Data().write(to: file)
    let root = try #require(
      AntigravityAgentProvider.transcript(identifier: conversation, home: home))
    let found = AntigravityAgentProvider.subagentTranscripts(
      beside: root, agentIDs: [agent, "../escape", "6b811fba-6e19-4c17-8efd-ef5ca1660716"])
    #expect(found.map(\.agentID) == [agent])
    #expect(found.first?.file.standardizedFileURL == file.standardizedFileURL)
  }

  // MARK: - Robustness

  @Test("A call without a name keeps its place: the next call takes its own result")
  func namelessCall() {
    let transcript = Transcript()
    transcript.line([
      "step_index": 1, "type": "PLANNER_RESPONSE", "status": "DONE", "content": "",
      "tool_calls": [
        ["args": ["CommandLine": "\"ls\""]],
        ["name": "run_command", "args": ["CommandLine": "\"pwd\""]],
      ],
    ])
    transcript.result(2, "Command exited with code 0.\n\nCommand output:\nnotes.txt\r\n")
    transcript.result(3, "Command exited with code 0.\n\nCommand output:\n/tmp/w\r\n")
    #expect(transcript.tools.map { $0.parameter(.command) } == ["pwd"])
    #expect(transcript.tools.first?.output?.text == "/tmp/w")
    #expect(transcript.decoder.entries.map(\.id) == ["agy:1:tool:1"])
  }

  @Test("A response written where an earlier response's result belongs unties that response")
  func responseInsideResults() {
    let transcript = Transcript()
    transcript.calls(
      1, [("run_command", ["CommandLine": "echo a"]), ("run_command", ["CommandLine": "echo b"])])
    transcript.result(2, "Command exited with code 0.\n\nCommand output:\na\r\n")
    #expect(transcript.tools.count == 2)
    transcript.calls(3, [("read_file", ["Path": "/tmp/w/notes.txt"])])
    #expect(transcript.tools.map(\.kind) == [.read])
    #expect(
      transcript.notices == [
        "run_command\nCommandLine: echo a", "run_command\nCommandLine: echo b",
        "Command exited with code 0.\n\nCommand output:\na",
      ])
  }

  @Test("An edit past the diff's line limit keeps counting the lines it does not show")
  func longEdit() {
    let transcript = Transcript()
    let target = (0..<1_500).map { "old \($0)" }.joined(separator: "\n")
    let replacement = (0..<1_000).map { "new \($0)" }.joined(separator: "\n")
    transcript.calls(
      1, [("edit_file", ["Path": "/tmp/w/big.txt", "Target": target, "Replacement": replacement])])
    let omitted = 1_500 + 1_000 - DiffHunk.lineLimit
    #expect(transcript.tools[0].changes.first?.omittedLineCount == omitted)
    transcript.result(2, "Made 1 replacement in /tmp/w/big.txt starting at line 10.")
    let change = transcript.tools[0].changes.first
    #expect(change?.omittedLineCount == omitted)
    #expect(change?.hunks.first?.lines.first?.oldNumber == 10)
  }

  @Test("Interrupted calls are read again no more, and results do not re-read their siblings")
  func renderingCost() {
    let transcript = Transcript()
    transcript.calls(1, [("run_command", ["CommandLine": "sleep 9"])])
    transcript.prompt(3, "Go on")
    #expect(transcript.tools[0].state == .interrupted)
    #expect(transcript.decoder.openResponses.isEmpty)

    let wide = Transcript()
    let count = 100
    wide.calls(
      1,
      (0..<count).map { ("run_command", ["CommandLine": "echo \($0)"]) as (String, [String: Any]) })
    for offset in 0..<count {
      wide.result(2 + offset, "Command exited with code 0.\n\nCommand output:\n\(offset)\r\n")
    }
    #expect(wide.tools.map { $0.output?.text } == (0..<count).map { "\($0)" })
    // The response and its results once, then the response again for each result.
    #expect(wide.decoder.renderCount <= 1 + 3 * count)
  }

  @Test("A step number no transcript reaches is left out, as are line numbers past any file")
  func outOfRangeNumbers() {
    let transcript = Transcript()
    transcript.calls(Int.max, [("run_command", ["CommandLine": "ls"])])
    transcript.prompt(Int.max - 1, "Hello")
    #expect(transcript.decoder.entries.isEmpty)
    transcript.calls(
      1, [("edit_file", ["Path": "/tmp/w/a", "Target": "a\nb", "Replacement": "c"])])
    transcript.result(
      2, "Made 1 replacement in /tmp/w/a starting at line \(Int.max) (+1/-1 lines).")
    #expect(transcript.tools[0].state == .succeeded)
    #expect(transcript.tools[0].changes.first?.hunks.first?.lines.first?.oldNumber == nil)
  }
}
