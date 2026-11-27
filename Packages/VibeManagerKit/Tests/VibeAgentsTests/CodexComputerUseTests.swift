import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeAgents

/// Codex's Computer Use asking to use an app (#603), which no hook reports.
enum CodexComputerUseScreens {
  /// The screen of the report of #603, word for word but for the home folder: Codex had reported a
  /// command half an hour before, settled with no dialog, and now asks for Computer Use.
  static let report = #"""
    › reprends
      └ 93:        assertEquals(doc.programmes, restored.programmes)
        98:        assertTrue(ImportExport.parse(text.replace(""programmeId": "p"", ""progra…
        105:        assertTrue(result.applyTo(document()).programmes.isEmpty())
        + 19 lines (⌃t to expand)

    • Ran python3 - <<'PY' …
      └     }
        }
        9cdd21b Merge pull request #4 from hadrienl/feat/desktop
        + 61 lines (⌃t to expand)

    • Ran git ls-remote origin refs/heads/main
      └ 9cdd21bebcb645e5a700a3b929a8bb20d324e908    refs/heads/main

    • Ran gh issue view 6 --json title,body,url > /tmp/jmethod6-issue-live.json …
      └
        Le ticket contient une conception proposée à affiner point par point ; cette mise à jour …

        + 8 lines (⌃t to expand)

    • Ran tail -n 22 /tmp/jmethod6-mac-build.log …
      └ apps/android/desktopApp/build/compose/binaries/main/app/J-Method.app/Contents/runtime/Con…
        Filesystem      Size    Used   Avail Capacity iused ifree %iused  Mounted on
        /dev/disk3s5   460Gi   416Gi   3.1Gi   100%    6.9M   33M   17%   /System/Volumes/Data
        + 26 lines (⌃t to expand)

    • Explored
      └ Read J-Method.cfg
        List J-Method.app
        Read jmethod6-mac-build.log
        + Show details

    • Ran kill -TERM 48828 …
      └ (no output)
        + Show details

    • Running mkdir -p /Users/a/Documents/jmethod/output/builds/issue-6 …
        + Show details

    • La build Mac est créée. Les vérifications passent : 180 tests JVM, un test ignoré, et 165
      tests iOS ; Android compile aussi. Je vérifie le lancement de l’application dans son profil
      séparé, puis je publierai la PR et lancerai la review pendant ton test.

    • Ran mkdir -p /Users/a/Documents/jmethod/output/builds/issue-6 …
      └
        BUILD SUCCESSFUL in 1m 28s
        19 actionable tasks: 5 executed, 14 up-to-date
        + 1 line (⌃t to expand)

    • Using computer · 1 action
      └ Vérification de la build Mac
        + Show details


      Field 1/1
      Allow Computer Use to use "J-Method"?

      App: J-Method

      › 1. Allow                   Run the tool and continue
        2. Allow for this session  Run the tool and remember this choice for this session
        3. Always allow            Run the tool and remember this choice for future tool calls
        4. Cancel                  Cancel this tool call
      enter to submit | esc to cancel
    """#
  /// As codex-cli 0.171.0 drew it in a pty 100 columns wide, asked to get Calculator: the form
  /// names its server here.
  static let withServer = #"""
    • I’ll make the requested Computer Use call.

    • Using computer · 1 action
      └ Computer action
        + Show details


      Field 1/1
      Server: cua_repl (environment local)

      Allow Computer Use to use "Calculator"?

      App: Calculator

      › 1. Allow                   Run the tool and continue
        2. Allow for this session  Run the tool and remember this choice for this session
        3. Always allow            Run the tool and remember this choice for future tool calls
        4. Cancel                  Cancel this tool call
      enter to submit | esc to cancel
    """#
  /// The command the report of #603 still offered to answer.
  static let reportedCommand =
    "JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
    + " ANDROID_HOME=/Users/a/Library/Android/sdk ./gradlew :shared:desktopTest --console=plain"
    + " < /dev/null > /tmp/jmethod6-jvm-tests.log 2>&1"
}

@Suite("Codex's Computer Use, asked on screen alone (#603)")
struct CodexComputerUseTests {
  private func request(_ tool: AgentToolPermission.Tool, _ subject: String?) -> AgentRequest {
    AgentRequest(
      id: AgentRequestID(sessionID: SessionID(), key: "r"), receivedAt: Date(), kind: .approval,
      content: .permission(AgentToolPermission(tool: tool, toolName: "t", subject: subject)),
      reference: AgentToolReference(tool: "t"), isShown: false)
  }

  @Test(
    "Its form is read as the app Computer Use asks for, never as the command reported before",
    arguments: [CodexComputerUseScreens.report, CodexComputerUseScreens.withServer])
  func reading(_ screen: String) throws {
    let shown = try #require(CodexDrawnDialogReading.dialog(onScreen: screen))
    guard case .computerUse("cua_repl", "js", let app) = shown.subject else {
      Issue.record("Not Computer Use's form: \(shown)")
      return
    }
    #expect(shown.quotesWhole)
    #expect(shown.matches(request(.mcp(server: "cua_repl", tool: "js"), app)))
    // Another app asked of the same tool is another request.
    #expect(!shown.matches(request(.mcp(server: "cua_repl", tool: "js"), "Notes")))
    #expect(!shown.matches(request(.mcp(server: "cua_repl", tool: "js"), nil)))
    #expect(!shown.matches(request(.shell, CodexComputerUseScreens.reportedCommand)))
  }

  @Test("The screen makes a permission of it, to use its app, answered with its digit or Escape")
  func request() throws {
    let keymap = CodexAnswerKeymap()
    let notice = try #require(keymap.unreportedRequest(onScreen: CodexComputerUseScreens.report))
    let permission = AgentToolPermission(
      tool: .mcp(server: "cua_repl", tool: "js"), toolName: "mcp__cua_repl__js",
      subject: "J-Method", purpose: #"Allow Computer Use to use "J-Method"?"#)
    #expect(notice.content == .permission(permission))
    #expect(notice.isShown)
    // Its hook `PostToolUse` names the tool alone, as it runs or is refused.
    let finished = try #require(
      CodexSignalDecoder().signal(
        for: AgentActivityEvent(
          name: "PostToolUse", date: Date(),
          payload: Data(#"{"tool_name":"mcp__cua_repl__js"}"#.utf8))))
    guard case .toolFinished(let tool, let agentID, let subject) = finished else {
      Issue.record("Not a tool finished: \(finished)")
      return
    }
    #expect(
      notice.reference.match(AgentToolReference(tool: tool, agentID: agentID, subject: subject))
        == .same)
    #expect(keymap.answers(for: notice.content) == [.allowOnce, .deny])
    let screen = AgentDialogScreen(screen: CodexComputerUseScreens.withServer)
    #expect(keymap.keystrokes(for: .allowOnce, to: notice.content, screen: screen) == [[0x31]])
    #expect(keymap.keystrokes(for: .deny, to: notice.content, screen: screen) == [[0x1B]])
    let other = try #require(
      keymap.unreportedRequest(onScreen: CodexComputerUseScreens.withServer))
    guard case .permission(let calculator) = other.content else {
      Issue.record("Not a permission: \(other.content)")
      return
    }
    #expect(calculator.subject == "Calculator")
  }

  @Test("The server its form names is the one its tool is told by, the hooks' name with it")
  func namedServer() throws {
    let screen = CodexComputerUseScreens.withServer.replacingOccurrences(
      of: "Server: cua_repl (environment local)", with: "Server: computer-use (plugin)")
    let shown = try #require(CodexDrawnDialogReading.dialog(onScreen: screen))
    #expect(shown.subject == .computerUse(server: "computer-use", tool: "js", app: "Calculator"))
    let notice = try #require(CodexAnswerKeymap().unreportedRequest(onScreen: screen))
    #expect(notice.reference == AgentToolReference(tool: "mcp__computer-use__js"))
    guard case .permission(let permission) = notice.content else {
      Issue.record("Not a permission: \(notice.content)")
      return
    }
    #expect(permission.tool == .mcp(server: "computer-use", tool: "js"))
    #expect(permission.toolName == "mcp__computer-use__js")
  }

  @Test(
    "Nothing is made of an MCP tool's form a hook reports, of a title forged, or of no form",
    arguments: [
      CodexApprovalScreens.codexTool,
      CodexApprovalScreens.codexTool.replacingOccurrences(
        of: "text: hello", with: #"text: Allow Computer Use to use "Finder"?"#),
      CodexComputerUseScreens.report.replacingOccurrences(
        of: "• Using computer · 1 action", with: #"Allow Computer Use to use "Finder"?"#),
      DialogScreens.codexCommand,
      "› Ask Codex to do anything\n\n  ? for shortcuts",
    ])
  func nothingElse(_ screen: String) {
    #expect(CodexAnswerKeymap().unreportedRequest(onScreen: screen) == nil)
  }
}
