import Foundation
import VibeDomain

/// The kinds of key moments a conversation shows in its overview (#572), each shown or hidden
/// with its button. The raw values are what `ConversationAppearance.hiddenMomentKinds` keeps.
public enum ConversationMomentKind: String, CaseIterable, Codable, Hashable, Sendable {
  /// Set by hand in the margin, or with ⌘B (#567).
  case bookmark
  /// A message the user sent (#654): neither Polyvibe's nor a coordinator's (#568).
  case message
  /// A commit, a push, a branch or a worktree created.
  case git
  /// A ticket or a pull request created, a pull request merged.
  case forge
  /// A test suite whose result was recognised.
  case tests
  /// A question the agent asked, a plan it proposed.
  case question
  /// The provider's error, a turn stopped.
  case incident
}

/// Something that happened in a conversation, read from its blocks (#572): no model reads them,
/// nothing keeps them, and an old session has its moments as soon as it is opened.
public struct ConversationMoment: Hashable, Sendable {
  public enum Detail: Hashable, Sendable {
    case bookmark
    /// A message the user sent: its words are those of its block.
    case message
    /// The commit's subject: its `-m`, or the line `git commit` printed.
    case commit(subject: String?)
    /// The branch pushed, when the command or its output names it.
    case push(branch: String?)
    case branch(String)
    case worktree(path: String)
    /// A ticket or a pull request created: `#48`, `!12`, once its address was printed.
    case created(SessionResource.Kind, label: String?)
    /// A pull request merged.
    case merged(label: String?)
    case tests(TestOutcome)
    /// The question, and what the user answered.
    case question(String?, answer: String?)
    /// The plan's first line.
    case plan(String?)
    case error(String)
    case interrupted
  }

  public let unit: Int
  public let detail: Detail
  /// The entry it happened in, never the block: it finds its block whether tools are grouped.
  public let entryID: String
  public let date: Date?

  public init(_ detail: Detail, entryID: String, date: Date?, unit: Int = 0) {
    self.unit = unit
    self.detail = detail
    self.entryID = entryID
    self.date = date
  }

  public var kind: ConversationMomentKind {
    switch detail {
    case .bookmark: .bookmark
    case .message: .message
    case .commit, .push, .branch, .worktree: .git
    case .created, .merged: .forge
    case .tests: .tests
    case .question, .plan: .question
    case .error, .interrupted: .incident
    }
  }

  /// Tests of which one failed: drawn in the failure's colour.
  public var isFailure: Bool {
    if case .tests(let outcome) = detail { return outcome.failed > 0 }
    return false
  }
}

/// Reads the moments of a conversation from its blocks (#572), and places them.
public enum ConversationMoments {
  /// A moment and the block that shows it.
  public struct Placed: Hashable, Sendable {
    public var unitOffset: Double = 0
    public var unitFraction: Double = 0
    public let blockIndex: Int
    public let moment: ConversationMoment

    public init(blockIndex: Int, moment: ConversationMoment) {
      self.blockIndex = blockIndex
      self.moment = moment
    }
  }

  /// The moments of the entries, in their order. Only the conversation's own: what a sub-agent did
  /// stays inside it.
  public static func moments(in entries: [ConversationEntry]) -> [ConversationMoment] {
    entries.flatMap(moments(of:))
  }

  /// The moments a block shows, bookmarks aside: they are the user's, not the block's.
  public static func moments(of block: ConversationBlock) -> [ConversationMoment] {
    switch block {
    case .entry(let entry): return moments(of: entry)
    case .toolGroup(_, let entries): return entries.flatMap(moments(of:))
    case .subagentGroup: return []
    }
  }

  /// The moments of the blocks from `start`, each block's bookmark first.
  public static func placed(
    in blocks: [ConversationBlock], bookmarks: Set<String>, from start: Int = 0
  ) -> [Placed] {
    guard start < blocks.count else { return [] }
    var placed: [Placed] = []
    for index in blocks.indices.dropFirst(max(start, 0)) {
      let block = blocks[index]
      let first = placed.count
      placed.append(contentsOf: self.bookmarks(of: block, at: index, in: bookmarks))
      for moment in moments(of: block) {
        placed.append(Placed(blockIndex: index, moment: moment))
      }
      placed.replaceSubrange(first..., with: ordered(placed[first...]))
    }
    return placed
  }

  /// Reading order inside a message, with non-bookmark events at its start.
  public static func ordered(_ placed: some Collection<Placed>) -> [Placed] {
    placed.enumerated().sorted {
      ($0.element.moment.unit, $0.offset) < ($1.element.moment.unit, $1.offset)
    }.map(\.element)
  }

  /// The block's bookmark, named after its first entry marked; `nil` when it has none.
  public static func bookmark(
    of block: ConversationBlock, at index: Int, in bookmarks: Set<String>
  ) -> Placed? {
    self.bookmarks(of: block, at: index, in: bookmarks).first
  }

  public static func bookmarks(
    of block: ConversationBlock, at index: Int, in bookmarks: Set<String>
  ) -> [Placed] {
    let anchors: [BookmarkAnchor]
    switch block {
    case .entry: anchors = ConversationBookmarks.anchors(of: block, in: bookmarks)
    case .toolGroup, .subagentGroup:
      anchors =
        ConversationBookmarks.entryIDs(of: block).first(where: bookmarks.contains).map {
          [BookmarkAnchor(entryID: $0)]
        } ?? []
    }
    return anchors.map { anchor in
      Placed(
        blockIndex: index,
        moment: ConversationMoment(
          .bookmark, entryID: anchor.entryID, date: entry(anchor.entryID, of: block)?.date,
          unit: anchor.unit))
    }
  }

  /// Those of the kinds shown.
  public static func shown(_ placed: [Placed], hiding hidden: Set<String>) -> [Placed] {
    guard !hidden.isEmpty else { return placed }
    return placed.filter { !hidden.contains($0.moment.kind.rawValue) }
  }

  /// The blocks that show one, each once, in order: where Next and Previous go.
  public static func blockIndices(of placed: [Placed]) -> [Int] {
    var indices: [Int] = []
    for item in placed where indices.last != item.blockIndex {
      indices.append(item.blockIndex)
    }
    return indices
  }

  private static func entry(_ id: String, of block: ConversationBlock) -> ConversationEntry? {
    switch block {
    case .entry(let entry): return entry.id == id ? entry : nil
    case .toolGroup(_, let entries), .subagentGroup(_, let entries):
      return entries.first { $0.id == id }
    }
  }

  // MARK: - Entries

  static func moments(of entry: ConversationEntry) -> [ConversationMoment] {
    func moment(_ detail: ConversationMoment.Detail) -> ConversationMoment {
      ConversationMoment(detail, entryID: entry.id, date: entry.date)
    }
    switch entry.content {
    case .userPrompt(let text, let attachments)
    where RelayedMessage(text, attachments: attachments) == nil:
      return [moment(.message)]
    case .notice(.error(let text)):
      return [moment(.error(text.trimmingCharacters(in: .whitespacesAndNewlines)))]
    case .notice(.interrupted):
      return [moment(.interrupted)]
    case .tool(let call):
      return moments(of: call).map(moment)
    default:
      return []
    }
  }

  static func moments(of call: ToolCall) -> [ConversationMoment.Detail] {
    switch call.kind {
    case .question:
      return [.question(call.parameter(.question), answer: call.parameter(.answer))]
    case .plan:
      return [.plan(call.parameter(.plan).flatMap(firstLine))]
    case .shell:
      var found: [ConversationMoment.Detail] = []
      // Only what was done, command by command: a line that failed may have committed before its
      // push was refused. A test run that failed is the point.
      if call.state.isFinished, let command = call.parameter(.command) {
        found += commandMoments(
          command, output: call.output?.text ?? "", succeeded: call.state == .succeeded)
      }
      if call.state.isFinished, let tests = call.facts.tests {
        found.append(.tests(tests))
      }
      return found
    default:
      return []
    }
  }

  /// The first line of a Markdown text that is not blank, without its heading marks.
  static func firstLine(of text: String) -> String? {
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
        .drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }

  // MARK: - Commands

  /// What a command line did that is a moment: its `git` commits, pushes, branches and worktrees,
  /// its `gh` and `glab` tickets and pull requests.
  ///
  /// A commit is one only when `git commit` printed its line, a push when what it printed under
  /// its `To` shows a branch pushed — or, when nothing of it is shown, when the line succeeded and
  /// says nothing was refused: `&&`, `;`, `| tail` and `|| true` make the line's exit say little
  /// of each command. The rest counts only once the whole line `succeeded`.
  static func commandMoments(
    _ line: String, output: String, succeeded: Bool = true
  ) -> [ConversationMoment.Detail] {
    // Most commands are neither: their line is not even cut into words.
    guard line.contains("git") || line.contains("gh") || line.contains("glab") else { return [] }
    let line = ResourceRecognizer.withoutHereDocuments(line)
    var found: [ConversationMoment.Detail] = []
    var printed = PrintedLines(output)
    for words in ShellWords.commands(in: line) {
      guard let invocation = Invocation(words) else { continue }
      switch invocation.program {
      case "git":
        found += gitMoments(invocation, succeeded: succeeded, printed: &printed)
      case "gh", "glab": found += forgeMoments(invocation, output: output, succeeded: succeeded)
      default: break
      }
    }
    return found
  }

  private static func gitMoments(
    _ invocation: Invocation, succeeded: Bool, printed: inout PrintedLines
  ) -> [ConversationMoment.Detail] {
    guard let command = ResourceRecognizer.GitCommand(invocation, directory: "/") else {
      return []
    }
    switch command.subcommand {
    case "commit":
      guard !command.rest.contains("--dry-run") else { return [] }
      let message = command.value(of: "m", "--message").flatMap { $0.flatMap(firstLine) }
      // Read in order even when the message is known: the next commit's line is the next one.
      // None printed, none made — unless it was asked to print nothing, and the line succeeded.
      guard let line = printed.nextCommit() else {
        return isQuiet(command) && succeeded ? [.commit(subject: message)] : []
      }
      return [.commit(subject: message ?? line.subject)]
    case "cherry-pick", "revert":
      // They print a commit's line too, of no commit of the line: read past it, not taken for
      // the next commit's.
      for _ in 0..<printedCommits(of: command) { _ = printed.nextCommit() }
      return []
    case "push":
      // Read in order whatever it pushes: the next push's lines are the next ones.
      let section = printed.nextPush()
      if command.rest.contains(where: {
        ["-d", "--delete", "--tags", "--all", "--mirror", "--dry-run", "-n"].contains($0 ?? "")
      }) {
        return []
      }
      let refspec = pushedRefspec(command)
      // `git push origin :old` deletes a branch.
      if refspec?.hasPrefix(":") == true { return [] }
      let pushed: [String]
      if let section {
        pushed = section.pushed
      } else {
        // Nothing of it shown: the line's word, unless the line says something was refused.
        guard succeeded, !printed.tellsOfARefusal else { return [] }
        pushed = []
      }
      guard section == nil || !pushed.isEmpty else { return [] }
      return [.push(branch: refspec.flatMap(destination(of:)) ?? pushed.first)]
    case "checkout", "switch", "branch", "worktree":
      guard succeeded else { return [] }
      // The branches and worktrees it created, as the journal reads them.
      // Wherever it ran: a folder only the shell knows still had its branch made.
      return ResourceRecognizer.gitSightings(
        command.directory == nil ? command.running(in: "/") : command, branch: nil,
        at: .distantPast
      )
      .compactMap { sighting -> ConversationMoment.Detail? in
        switch sighting {
        case .branch(let name, _, .created, _): return .branch(name)
        case .worktree(let path, .created, _): return .worktree(path: path)
        default: return nil
        }
      }
    default:
      return []
    }
  }

  /// Short options of `git commit` that take a value, joined to them or as the next argument.
  private static let commitValueLetters: Set<Character> = ["m", "F", "C", "c", "t", "u", "S"]

  /// Whether `git commit` was asked to print nothing: `-q`, `--quiet`, or a `q` among short
  /// options grouped, before one that takes a value — `-qm x`, `-aq` —, never in a value.
  private static func isQuiet(_ command: ResourceRecognizer.GitCommand) -> Bool {
    var isValue = false
    for argument in command.rest {
      if isValue {
        isValue = false
        continue
      }
      guard let argument else { continue }
      if argument == "--quiet" { return true }
      guard argument.hasPrefix("-"), !argument.hasPrefix("--") else { continue }
      for (offset, letter) in argument.dropFirst().enumerated() {
        if letter == "q" { return true }
        if commitValueLetters.contains(letter) {
          // Its value follows when it ends the group.
          isValue = offset == argument.count - 2
          break
        }
      }
    }
    return false
  }

  /// Options of `git cherry-pick` and `git revert` that take a value.
  private static let pickValueOptions: Set<String> = [
    "-m", "--mainline", "-X", "--strategy-option", "--strategy",
  ]

  /// The lines a `git cherry-pick` or a `git revert` prints: one per commit named, a range as
  /// one; none when it commits nothing, or stops.
  private static func printedCommits(of command: ResourceRecognizer.GitCommand) -> Int {
    let silent = ["-n", "--no-commit", "--abort", "--quit", "--skip"]
    if command.rest.contains(where: { silent.contains($0 ?? "") }) { return 0 }
    // `--continue` goes on with the one it stopped at.
    return max(positional(command, valueOptions: pickValueOptions).count, 1)
  }

  /// Options of `git push` that take a value, which is then neither the remote nor a refspec.
  private static let pushValueOptions: Set<String> = [
    "-o", "--push-option", "--repo", "--receive-pack", "--exec",
  ]

  /// The first refspec of `git push origin feature`, `git push -u origin +HEAD:feature`.
  private static func pushedRefspec(_ command: ResourceRecognizer.GitCommand) -> String? {
    let positional = positional(command, valueOptions: pushValueOptions)
    guard positional.count >= 2, var refspec = positional[1] else { return nil }
    if refspec.hasPrefix("+") { refspec.removeFirst() }
    return refspec
  }

  /// The arguments of a command that are not options, nor the values of `valueOptions`.
  private static func positional(
    _ command: ResourceRecognizer.GitCommand, valueOptions: Set<String>
  ) -> [String?] {
    var positional: [String?] = []
    var index = 0
    while index < command.rest.count {
      let argument = command.rest[index]
      if let option = argument, valueOptions.contains(option) {
        index += 2
        continue
      }
      if argument?.hasPrefix("-") != true { positional.append(argument) }
      index += 1
    }
    return positional
  }

  /// Where a refspec pushes: `HEAD:feature` to `feature`.
  private static func destination(of refspec: String) -> String? {
    let destination = refspec.split(separator: ":", omittingEmptySubsequences: false).last
    return destination.flatMap { ResourceRecognizer.normalizedBranch(String($0)) }
  }

  /// A ticket or a pull request created once the line succeeded or its address was printed; a
  /// merge, only once the line succeeded.
  private static func forgeMoments(
    _ invocation: Invocation, output: String, succeeded: Bool
  ) -> [ConversationMoment.Detail] {
    guard let verb = invocation.forgeVerb else { return [] }
    let isRequest = verb.noun != "issue"
    // The address `create` and `merge` print, of the forge's own shape.
    let printed = ResourceRecognizer.urls(in: output, involvement: .created, at: .distantPast)
      .first { ($0.kind == .pullRequest) == isRequest }
    switch verb.action {
    case "create":
      guard succeeded || printed != nil else { return [] }
      return [.created(isRequest ? .pullRequest : .issue, label: printed?.label)]
    case "merge" where isRequest && succeeded:
      // Queued until checks pass: not merged yet.
      guard !Self.isQueuedMerge(invocation, output: output) else { return [] }
      let number = invocation.forgeNumber(after: verb)
      let label = number.map { "\(invocation.program == "gh" ? "#" : "!")\($0)" }
      return [.merged(label: label ?? printed?.label ?? mergedLabel(in: output))]
    default:
      return []
    }
  }

  static func isQueuedMerge(_ invocation: Invocation, output: String) -> Bool {
    let queued = ["--auto", "--when-pipeline-succeeds", "--auto-merge"]
    if invocation.arguments.contains(where: { queued.contains($0 ?? "") }) { return true }
    let printed = output.lowercased()
    return printed.contains("will merge") || printed.contains("will be automatically merged")
      || printed.contains("when the pipeline succeeds")
  }

  private static let mergedPattern = try? NSRegularExpression(
    pattern: #"merged pull request [^\s#!]*([#!]\d+)"#, options: .caseInsensitive)

  /// `✓ Merged pull request owner/repo#48 (Title)`, what `gh pr merge` prints.
  static func mergedLabel(in output: String) -> String? {
    guard let mergedPattern,
      let match = mergedPattern.firstMatch(
        in: output, range: NSRange(output.startIndex..., in: output)),
      let range = Range(match.range(at: 1), in: output)
    else { return nil }
    return String(output[range])
  }

  /// What a command line printed, read by its commands in their order: each commit its line,
  /// each push its section. Read only once a command asks: most print neither.
  struct PrintedLines {
    let output: String
    private var commits: CommitLines?
    private var pushes: PushLines?

    init(_ output: String) { self.output = output }

    mutating func nextCommit() -> CommitLines.Printed? {
      if commits == nil { commits = CommitLines(output) }
      return commits?.next()
    }

    mutating func nextPush() -> PushLines.Section? {
      if pushes == nil { pushes = PushLines(output) }
      return pushes?.next()
    }

    /// What `git push` says of a ref refused, even with its lines cut: `| tail` keeps its hints.
    var tellsOfARefusal: Bool {
      ["[rejected]", "[remote rejected]", "failed to push", "Updates were rejected"]
        .contains { output.contains($0) }
    }
  }

  /// What `git push` prints of its refs under `To <url>`, one section per push of the line, in
  /// order: `   1a2b3c4..5d6e7f8  main -> main`, ` * [new branch]  feature -> feature`,
  /// ` ! [rejected]  main -> main (fetch first)`. `git fetch` and `git pull` print theirs under
  /// `From`: never read.
  struct PushLines {
    struct Section: Equatable {
      /// The branches it pushed, refused ones aside.
      var pushed: [String] = []
    }

    private var sections: [Section] = []

    private static let refPattern = try? NSRegularExpression(
      pattern: #"^\s*([+*=!-])?\s*(\[[^\]]+\]|[0-9a-f]+\.\.\.?[0-9a-f]+)\s+\S+\s+->\s+(\S+)"#)

    init(_ output: String) {
      guard output.contains("To "), let pattern = Self.refPattern else { return }
      var current: Section?
      for line in output.split(whereSeparator: \.isNewline).map(String.init) {
        if line.hasPrefix("To ") || line.hasPrefix("From ") {
          if let current { sections.append(current) }
          current = line.hasPrefix("To ") ? Section() : nil
          continue
        }
        guard current != nil,
          let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let summary = Range(match.range(at: 2), in: line),
          let destination = Range(match.range(at: 3), in: line)
        else { continue }
        let flag = Range(match.range(at: 1), in: line).map { line[$0] } ?? ""
        // Refused, up to date or deleted: nothing pushed.
        guard !["!", "=", "-"].contains(flag), !line[summary].contains("rejected"),
          let branch = ResourceRecognizer.normalizedBranch(String(line[destination]))
        else { continue }
        current?.pushed.append(branch)
      }
      if let current { sections.append(current) }
    }

    mutating func next() -> Section? {
      sections.isEmpty ? nil : sections.removeFirst()
    }
  }

  /// The lines `git commit` prints, `[main 1a2b3c4] Subject` — `[detached HEAD 1a2b3c4]` in a
  /// rebase —, read one per commit of the line; `ok 1a2b3c4` when `rtk` shortened it.
  struct CommitLines {
    /// A commit made, named when its line says so.
    struct Printed: Equatable {
      let subject: String?
    }

    private var printed: [Printed]

    private static let pattern = try? NSRegularExpression(
      pattern:
        #"^(?:\[(?:detached HEAD|[^\]\s]+)(?: \([^)]*\))? [0-9a-f]{7,}\] (.+)|ok [0-9a-f]{7,})$"#,
      options: .anchorsMatchLines)

    init(_ output: String) {
      guard output.contains("] ") || output.contains("ok "), let pattern = Self.pattern else {
        printed = []
        return
      }
      printed = pattern.matches(in: output, range: NSRange(output.startIndex..., in: output))
        .map { match in
          Printed(subject: Range(match.range(at: 1), in: output).map { String(output[$0]) })
        }
    }

    mutating func next() -> Printed? {
      printed.isEmpty ? nil : printed.removeFirst()
    }
  }
}
