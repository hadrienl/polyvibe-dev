import Foundation
import VibeApplication

/// The permission `agy` asks before running a command, read off its screen (#541).
///
/// Its status line says only that a tool waits for review (`tool_confirmation_pending`), never
/// which: the dialog itself shows the command, as 1.5.18 draws it.
///
/// ```
/// Requesting permission for:
///    ls -la
///
/// Run this command?
/// > 1. Yes, run command
///   2. Yes, and always allow in this conversation for commands that start with 'ls'
///   3. Yes, and always allow for commands that start with 'ls' (Persist to settings.json)
///   4. No, cancel
///
///   ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
/// esc to cancel
/// ```
///
/// Each line of the command is drawn three spaces in; a line wrapped at the terminal's width goes
/// on at its left edge. A command of many lines is folded to its first four, then
/// `⋯ (26 lines hidden)`: what would be run is then not all on screen. A file's creation or edit
/// draws its path cut at the terminal's width, with no mark of it: it is not read, and answered in
/// the terminal. So are `ask_question`'s questions, which its status line does not report at all.
enum AntigravityDialogReading {
  static let title = "Requesting permission for:"
  static let question = "Run this command?"
  static let allowOnce = "Yes, run command"
  static let deny = "No, cancel"
  /// Under the options: what only the terminal does — amend the command, open it in an editor.
  static let hint = "↑/↓ Navigate"
  /// The last line, the model's name after it.
  static let footer = "esc to cancel"
  /// agy points at an option with `>`.
  static let pointers = AgentDialogScreen.defaultPointers.union([">"])
  /// The rows of a command a request's card shows (`lineLimit(6)`): more may only be refused.
  static let shownRows = 6
  /// The command's own lines are drawn this far in.
  static let indent = "   "

  /// The dialog the screen ends on: its title, the command, its question, the options, the hint,
  /// the footer — each where agy draws it, nothing else between, so that words the agent wrote
  /// above cannot pass for it.
  struct Dialog: Hashable {
    /// The command's lines as drawn, their indent taken off, a wrapped line on a line of its own.
    let command: String
    /// Whether the command is folded — some of its lines are not drawn — or too tall for a card.
    let isFolded: Bool
    /// The prefix both "always" options name, when they are drawn.
    let prefix: String?
    /// Whether the options are the ones a command's permission offers.
    let hasPersistentOption: Bool
  }

  /// Where agy draws them: the title, the question and the footer at the left edge — the
  /// command's own lines are drawn further in.
  static func dialog(onScreen text: String) -> Dialog? {
    guard let screen = AgentDialogScreen(screen: text, pointers: pointers) else { return nil }
    // Only the spaces a terminal pads its rows with are taken off: a row of the command filled
    // with other blanks — no-break spaces — is not empty, and must not pass for the blank line the
    // title follows.
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
      String($0.reversed().drop(while: { $0 == " " }).reversed())
    }
    let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
    guard let last = trimmed.lastIndex(where: { !$0.isEmpty }),
      lines[last].hasPrefix(footer),
      let ask = lines[..<last].lastIndex(of: question),
      let start = lines[..<ask].lastIndex(of: title),
      // The command is the agent's: a line of it wrapped at the terminal's width goes on at the
      // left edge, and may read as the title. The title is drawn once: two on screen, and which
      // one starts the command is not known. It follows a blank line, as no line of a command at
      // the left edge does — that one goes on from a full row.
      lines.filter({ $0 == title }).count == 1,
      start > 0, lines[start - 1].isEmpty,
      // The options right under the question, numbered from 1 with nothing between.
      ask + 1 < last, isOption(trimmed[ask + 1], numbered: 1),
      let hint = trimmed[(ask + 1)..<last].firstIndex(where: { $0.hasPrefix(Self.hint) }),
      trimmed[(hint + 1)..<last].allSatisfy(\.isEmpty)
    else { return nil }
    // Every option drawn there is one the screen reads, and no other is.
    let drawn = trimmed[(ask + 1)..<hint].filter { isOption($0, numbered: nil) }
    guard drawn.count == screen.options.count,
      screen.options.first?.label == allowOnce,
      screen.options.last?.label == deny
    else { return nil }
    var body = Array(lines[(start + 1)..<ask])
    while body.last?.isEmpty == true { body.removeLast() }
    guard let first = body.first, first.hasPrefix(indent),
      !first.dropFirst(indent.count).trimmingCharacters(in: .whitespaces).isEmpty,
      // A line at the left edge goes on with the one above it, never after a blank one.
      body.indices.allSatisfy({ index in
        body[index].isEmpty || body[index].hasPrefix(indent) || !body[index - 1].isEmpty
      })
    else { return nil }
    var isFolded = false
    let command = body.map { line -> String in
      if line.trimmingCharacters(in: .whitespaces).wholeMatch(of: #/⋯ \(\d+ lines? hidden\)/#)
        != nil
      {
        isFolded = true
      }
      return line.hasPrefix(indent) ? String(line.dropFirst(indent.count)) : line
    }.joined(separator: "\n")
    // A card shows six lines of a command: past them, what would be allowed is not all seen.
    // Whether agy itself shortens a very long line without its fold is not verified either.
    if body.count > shownRows { isFolded = true }
    let session = screen.options.lazy.compactMap { sessionPrefix(of: $0.label) }.first
    let persistent = screen.options.lazy.compactMap { persistentPrefix(of: $0.label) }.first
    // Both name the same prefix, or neither is offered: an option that says otherwise is not read.
    let known = screen.options.allSatisfy {
      [allowOnce, deny].contains($0.label) || sessionPrefix(of: $0.label) != nil
        || persistentPrefix(of: $0.label) != nil
    }
    guard known, persistent == nil || persistent == session else { return nil }
    return Dialog(
      command: command, isFolded: isFolded, prefix: session,
      hasPersistentOption: persistent != nil)
  }

  /// `> 1. Yes, run command`, `  2. No, cancel`: an option, of this number when one is given.
  static func isOption(_ line: String, numbered number: Int?) -> Bool {
    guard let match = line.wholeMatch(of: #/(?:>\s*)?(\d{1,2})\. .+/#) else { return false }
    return number.map { Int(match.1) == $0 } ?? true
  }

  /// `Yes, and always allow in this conversation for commands that start with 'ls'` gives `ls`.
  static func sessionPrefix(of label: String) -> String? {
    label.wholeMatch(
      of: #/Yes, and always allow in this conversation for commands that start with '(.+)'/#
    ).map { String($0.1) }
  }

  /// `Yes, and always allow for commands that start with 'ls' (Persist to settings.json)` gives
  /// `ls`.
  static func persistentPrefix(of label: String) -> String? {
    label.wholeMatch(
      of:
        #/Yes, and always allow for commands that start with '(.+)' \(Persist to settings\.json\)/#
    ).map { String($0.1) }
  }

  /// The permission the screen asks, or `nil` when it does not end on a command's dialog.
  static func request(onScreen text: String) -> AgentRequestNotice? {
    guard let dialog = dialog(onScreen: text) else { return nil }
    let session = dialog.prefix.map {
      AgentAlwaysAllow(rules: [.commandsStartingWith($0)], scope: .session)
    }
    let everywhere = dialog.prefix.flatMap {
      dialog.hasPersistentOption
        ? AgentAlwaysAllow(rules: [.commandsStartingWith($0)], scope: .user) : nil
    }
    return AgentRequestNotice(
      content: .permission(
        AgentToolPermission(
          tool: .shell, toolName: toolName, subject: dialog.command, alwaysAllow: session,
          alwaysAllowEverywhere: everywhere, isComplete: !dialog.isFolded)),
      reference: AgentToolReference(tool: toolName), isShown: true)
  }

  /// The tool agy runs a command with, as its transcript names it.
  static let toolName = "run_command"
}

/// Antigravity's command permission, answered from outside its terminal (#541): a digit picks an
/// option at once — verified on 1.5.18, as on Claude Code. Every digit is the one the screen draws
/// for the option's words, and "always" only for the prefix the request names. `4. No, cancel`
/// refuses the call and stops the turn; Escape does too, but only the digit says it refused.
///
/// The request is the screen's own: nothing else reports it, so it is answered only while the
/// screen still shows that command. Amending it (`tab`) or opening it in an editor (`ctrl+g`) is
/// left to the terminal. A folded command may only be refused.
public struct AntigravityAnswerKeymap: AgentAnswerKeymap {
  public init() {}

  public func answers(for content: AgentRequestContent) -> Set<AgentAnswerKind> {
    guard case .permission(let permission) = content, permission.tool == .shell,
      permission.toolName == AntigravityDialogReading.toolName
    else { return [] }
    var kinds: Set<AgentAnswerKind> = [.allowOnce, .deny]
    if permission.alwaysAllow != nil { kinds.insert(.allowAlways) }
    if permission.alwaysAllowEverywhere != nil { kinds.insert(.allowEverywhere) }
    return kinds
  }

  public var readsRequestOnScreen: Bool {
    true
  }

  public var optionPointers: Set<Character> {
    AntigravityDialogReading.pointers
  }

  public func drawnDialog(onScreen text: String) -> AgentDrawnDialog? {
    AntigravityDialogReading.dialog(onScreen: text).map {
      AgentDrawnDialog(.shownCommand($0.command))
    }
  }

  public func unreportedRequest(onScreen text: String) -> AgentRequestNotice? {
    AntigravityDialogReading.request(onScreen: text)
  }

  public func keystrokes(
    for answer: AgentAnswer, to content: AgentRequestContent, screen: AgentDialogScreen?
  ) -> [[UInt8]]? {
    guard case .permission(let permission) = content, !answers(for: content).isEmpty else {
      return nil
    }
    let prefix = { (allow: AgentAlwaysAllow?) -> String? in
      guard case .commandsStartingWith(let prefix)? = allow?.rules.first else { return nil }
      return prefix
    }
    switch answer {
    case .allowOnce:
      return ClaudeCodeAnswerKeymap.digit(
        of: screen?.option { $0 == AntigravityDialogReading.allowOnce })
    case .allowAlways:
      guard let expected = prefix(permission.alwaysAllow) else { return nil }
      return ClaudeCodeAnswerKeymap.digit(
        of: screen?.option { AntigravityDialogReading.sessionPrefix(of: $0) == expected })
    case .allowEverywhere:
      guard let expected = prefix(permission.alwaysAllowEverywhere) else { return nil }
      return ClaudeCodeAnswerKeymap.digit(
        of: screen?.option { AntigravityDialogReading.persistentPrefix(of: $0) == expected })
    case .deny:
      return ClaudeCodeAnswerKeymap.digit(
        of: screen?.option { $0 == AntigravityDialogReading.deny })
    default:
      return nil
    }
  }
}
