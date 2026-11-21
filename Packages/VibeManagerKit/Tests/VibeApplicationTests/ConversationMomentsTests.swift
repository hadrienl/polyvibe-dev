import Foundation
import Testing
import VibeDomain

@testable import VibeApplication

@Suite("Key moments of a conversation (#572)")
struct ConversationMomentsTests {
  private static func shell(
    _ id: String, _ command: String, output: String = "", state: ToolCallState = .succeeded,
    tests: TestOutcome? = nil
  ) -> ConversationEntry {
    ConversationEntry(
      id: id,
      content: .tool(
        ToolCall(
          callID: id, kind: .shell, state: state, parameters: [.init(.command, command)],
          output: ToolOutput(text: output), facts: ToolFacts(tests: tests))))
  }

  private func details(
    _ command: String, output: String = "", state: ToolCallState = .succeeded
  ) -> [ConversationMoment.Detail] {
    ConversationMoments.moments(in: [Self.shell("s", command, output: output, state: state)])
      .map(\.detail)
  }

  /// What `git commit` prints.
  private static let committed = "[main 1a2b3c4] Subject\n 1 file changed, 1 insertion(+)\n"

  // MARK: - Git

  @Test("A commit is named by its -m, or by the line git printed")
  func commits() {
    #expect(
      details(#"git commit -m "fix(cart): round VAT per line""#, output: Self.committed) == [
        .commit(subject: "fix(cart): round VAT per line")
      ])
    #expect(
      details(#"git commit -am "Second""#, output: Self.committed) == [.commit(subject: "Second")])
    #expect(
      details(#"git commit --message="Third line""#, output: Self.committed) == [
        .commit(subject: "Third line")
      ])
    // What rtk prints of it.
    #expect(
      details("rtk git commit -m Fourth", output: "ok 8b47257\n") == [.commit(subject: "Fourth")])
    #expect(details("git commit -q -m Quiet") == [.commit(subject: "Quiet")])
    let heredoc = """
      git commit -m "$(cat <<'EOF'
      feat(#572): key moments

      Body
      EOF
      )"
      """
    #expect(
      details(heredoc, output: "[feat/572 1a2b3c4] feat(#572): key moments\n 3 files changed") == [
        .commit(subject: "feat(#572): key moments")
      ])
    #expect(details("git commit --dry-run -m x").isEmpty)
  }

  @Test("A commit that failed made none, whatever the line's exit")
  func failedCommit() {
    let entry = Self.shell("s", "git commit -m x", state: .failed(exitCode: 1))
    #expect(ConversationMoments.moments(in: [entry]).isEmpty)
    let nothing = "On branch main\nnothing to commit, working tree clean\n"
    #expect(details("git commit -m x; true", output: nothing).isEmpty)
    #expect(details("git commit -m x || true", output: nothing).isEmpty)
    #expect(details("git commit -q -m x", state: .failed(exitCode: 1)).isEmpty)
  }

  @Test("A commit made before its push was refused is a moment; the push is not")
  func refusedPush() {
    let output = """
      [feat/x 1a2b3c4] Fix X
       2 files changed, 9 insertions(+)
      To github.com:a/b.git
       ! [rejected]        feat/x -> feat/x (fetch first)
      error: failed to push some refs to 'github.com:a/b.git'
      """
    #expect(
      details(
        #"git add -A && git commit -m "Fix X" && git push"#, output: output,
        state: .failed(exitCode: 1)) == [.commit(subject: "Fix X")])
    // What a failed line printed of a push still tells it went.
    #expect(
      details(
        "git push origin a; false", output: "   1a2b3c4..5d6e7f8  a -> a\n",
        state: .failed(exitCode: 1)) == [.push(branch: "a")])
    #expect(details("git switch -c late && false", state: .failed(exitCode: 1)).isEmpty)
  }

  @Test("Commands chained by && each count, their commits read in order")
  func chained() {
    let output = "[main abc1234] First\n[main def5678] Second\n"
    #expect(
      details(#"git add . && git commit -F a.txt; git commit -F b.txt | cat"#, output: output) == [
        .commit(subject: "First"), .commit(subject: "Second"),
      ])
  }

  @Test("A push names its branch from its refspec, or from what it printed")
  func pushes() {
    #expect(details("git push -u origin fix/vat-rounding") == [.push(branch: "fix/vat-rounding")])
    #expect(details("git push origin HEAD:refs/heads/topic") == [.push(branch: "topic")])
    #expect(
      details("git push", output: "To github.com:a/b.git\n   1a2b3c4..5d6e7f8  main -> main\n")
        == [.push(branch: "main")])
    #expect(
      details("rtk git push", output: " * [new branch]      feature -> feature\n") == [
        .push(branch: "feature")
      ])
    #expect(details("git push") == [.push(branch: nil)])
    #expect(details("git push --delete origin old").isEmpty)
    #expect(details("git push origin :old").isEmpty)
    #expect(details("git push -o ci.skip origin feat") == [.push(branch: "feat")])
    #expect(details("git push --tags").isEmpty)
  }

  @Test("Branches and worktrees created, not those only switched to")
  func branches() {
    #expect(details("git switch -c fix/vat-rounding") == [.branch("fix/vat-rounding")])
    #expect(details("git checkout -b topic") == [.branch("topic")])
    #expect(details("git branch topic") == [.branch("topic")])
    #expect(details("git switch main").isEmpty)
    #expect(details("git branch -d topic").isEmpty)
    #expect(
      details("git worktree add -b feat/x /tmp/wt/feat-x") == [
        .worktree(path: "/tmp/wt/feat-x"), .branch("feat/x"),
      ])
    #expect(details(#"git -C "$REPO" switch -c late"#) == [.branch("late")])
  }

  // MARK: - Forges

  @Test("A pull request opened is numbered by the address gh printed")
  func pullRequestCreated() {
    #expect(
      details(
        "gh pr create --fill", output: "https://github.com/acme/shop/pull/48\n") == [
          .created(.pullRequest, label: "#48")
        ])
    #expect(details("gh pr create --fill") == [.created(.pullRequest, label: nil)])
    #expect(
      details(
        "gh issue create -t Bug -b Body", output: "https://github.com/acme/shop/issues/572") == [
          .created(.issue, label: "#572")
        ])
  }

  @Test("glab's merge requests have their own numbers")
  func mergeRequests() {
    #expect(
      details(
        "glab mr create --fill -y",
        output: "Creating merge request\nhttps://gitlab.com/g/p/-/merge_requests/12\n") == [
          .created(.pullRequest, label: "!12")
        ])
    #expect(details("glab mr merge 12 -s") == [.merged(label: "!12")])
  }

  @Test("A pull request merged, by its number or by what gh printed")
  func merged() {
    #expect(details("gh pr merge 48 --squash -d") == [.merged(label: "#48")])
    #expect(
      details("gh pr merge --squash", output: "✓ Squashed and merged pull request acme/shop#48 (x)")
        == [.merged(label: "#48")])
    #expect(
      details("gh pr merge --merge", output: "✓ Merged pull request acme/shop#48 (Title)") == [
        .merged(label: "#48")
      ])
    // Queued until its checks pass: not merged yet.
    #expect(details("gh pr merge 48 --auto --squash").isEmpty)
    #expect(
      details("glab mr merge 12", output: "Merge request !12 will merge when the pipeline succeeds")
        .isEmpty)
    #expect(details("gh pr view 48").isEmpty)
    #expect(details("gh issue close 12").isEmpty)
  }

  // MARK: - Others

  @Test("Each test suite is a moment, passed or failed")
  func tests() {
    let passed = Self.shell("a", "npx vitest run", tests: TestOutcome(total: 13, failed: 0))
    let failed = Self.shell(
      "b", "npx vitest run", state: .failed(exitCode: 1), tests: TestOutcome(total: 17, failed: 1))
    let running = Self.shell("c", "swift test", state: .running)
    let moments = ConversationMoments.moments(in: [passed, failed, running])
    #expect(
      moments.map(\.detail) == [
        .tests(TestOutcome(total: 13, failed: 0)), .tests(TestOutcome(total: 17, failed: 1)),
      ])
    #expect(moments.map(\.isFailure) == [false, true])
    #expect(moments.allSatisfy { $0.kind == .tests })
  }

  @Test("Questions, plans, errors and interruptions")
  func others() {
    let date = Date(timeIntervalSince1970: 1_000)
    let entries = [
      ConversationEntry(
        id: "q", date: date,
        content: .tool(
          ToolCall(
            callID: "q", kind: .question, state: .succeeded,
            parameters: [
              .init(.question, "How to apply discounts?"), .init(.answer, "Line by line"),
            ]))),
      ConversationEntry(
        id: "p",
        content: .tool(
          ToolCall(
            callID: "p", kind: .plan, parameters: [.init(.plan, "\n## Round per line\n\n1. x")]))),
      ConversationEntry(id: "e", content: .notice(.error("API overloaded (529)\n"))),
      ConversationEntry(id: "i", content: .notice(.interrupted)),
      ConversationEntry(id: "c", content: .notice(.compacted)),
    ]
    let moments = ConversationMoments.moments(in: entries)
    #expect(
      moments.map(\.detail) == [
        .question("How to apply discounts?", answer: "Line by line"), .plan("Round per line"),
        .error("API overloaded (529)"), .interrupted,
      ])
    #expect(moments.map(\.kind) == [.question, .question, .incident, .incident])
    #expect(moments.map(\.entryID) == ["q", "p", "e", "i"])
    #expect(moments.first?.date == date)
  }

  @Test("What a sub-agent did stays inside it")
  func subagents() {
    let inner = Self.shell("inner", "git commit -m inside")
    var run = SubagentRun()
    run.activity = .read([inner])
    let call = ToolCall(callID: "sub", kind: .subagent, state: .succeeded, subagent: run)
    let entries = [ConversationEntry(id: "sub", content: .tool(call))]
    #expect(ConversationMoments.moments(in: entries).isEmpty)
    let blocks = ConversationGrouping.blocks(entries)
    #expect(ConversationMoments.placed(in: blocks, bookmarks: []).isEmpty)
  }

  // MARK: - Blocks

  @Test("A moment in a group of tools finds its block, grouped or not")
  func groups() {
    let entries = [
      ConversationEntry(id: "u", content: .userPrompt("Commit", attachments: [])),
      Self.shell("s1", "git status"),
      Self.shell("s2", "git commit -m one"),
      Self.shell("s3", "git push origin main"),
    ]
    let grouped = ConversationGrouping.blocks(entries, grouping: true)
    let placed = ConversationMoments.placed(in: grouped, bookmarks: ["u"])
    #expect(placed.map(\.blockIndex) == [0, 1, 1])
    #expect(placed.map(\.moment.entryID) == ["u", "s2", "s3"])
    #expect(placed.map(\.moment.kind) == [.bookmark, .git, .git])
    #expect(ConversationMoments.blockIndices(of: placed) == [0, 1])

    let ungrouped = ConversationGrouping.blocks(entries, grouping: false)
    let apart = ConversationMoments.placed(in: ungrouped, bookmarks: ["u"])
    #expect(apart.map(\.blockIndex) == [0, 2, 3])
    #expect(
      ConversationMoments.placed(in: ungrouped, bookmarks: ["u"], from: 3).map(\.blockIndex)
        == [3])
  }

  @Test("A bookmark comes before the block's own moments, and a hidden kind is left out")
  func hidden() {
    let entries = [Self.shell("s", "git commit -m one", tests: TestOutcome(total: 2, failed: 0))]
    let placed = ConversationMoments.placed(
      in: ConversationGrouping.blocks(entries), bookmarks: ["s"])
    #expect(placed.map(\.moment.kind) == [.bookmark, .git, .tests])
    let shown = ConversationMoments.shown(placed, hiding: ["git", "unknown"])
    #expect(shown.map(\.moment.kind) == [.bookmark, .tests])
    #expect(ConversationMoments.shown(placed, hiding: []) == placed)
  }
}
