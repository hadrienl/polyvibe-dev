import Foundation
import Testing
import VibeApplication

@testable import VibeTerminalUI

/// Claude Code draws each frame inside a synchronized update once the terminal says it knows them,
/// as SwiftTerm does (#580): `ESC[?2026h`, the screen cleared and written again over several
/// reads, then `ESC[?2026l`. A view shows the frame once it has ended; the screen read before an
/// answer is typed must too.
@Suite("A frame half drawn is not read off the history (#580)")
struct SynchronizedFrameReplayTests {
  /// The screen of the report of #580 (Claude Code 2.1.332): a question of a subagent, its words
  /// wrapped behind `│`, its options under them.
  static let reportedDialog = """
          1029      assert.strictEqual(turns.length, 1);
          1030      ws.close();
      ⎿ \u{A0}(timeout 5m)
      ⎿ \u{A0}Allowed by auto mode

    ⏺ Plafond en place, tests verts. Je vérifie qu'ils échouent sans le plafond et sans
      la remise à zéro, puis je lance la suite voix complète.

      Ran 3 shell commands

    ⏺ Main n'est pas formaté par prettier non plus, ce n'est donc pas un critère. Je
      committe le plafond et je lance la revue de code.

      Ran 1 shell command

    ⏺ code-review(Review voice approval branch)
      ⎿ \u{A0}Backgrounded agent (↓ to manage · ctrl+o to expand)

    ⏺ Pendant la revue, je cherche si la doc publique (branche dev) décrit ce
      comportement.

      Ran 3 shell commands

    ⏺ La doc de voice-mode dit qu'un agent qui n'a pas compris redemande, mais elle ne
      précise pas le plafond de 3 relances. Je vérifie la note de version du ticket #504
      pour le confirmer. ·\u{A0}summary

      Ran 1 shell command

    ⏺ Skill(shipping-changes)
      ⎿ \u{A0}Loaded skill

      Ran 1 shell command

    ⏺ Les approbations vocales étant publiées depuis la v27.11.0, la mention « fonction
      non publiée » de la description est fausse. J'attends la revue de code avant de te
      soumettre la note de version. ·\u{A0}summary

      Ran 1 shell command

    › Message from @code-review (ctrl+o to expand)
    ─────────────────────────────────────────────────────────────────────────────────────
     ☐ Release note

    │ Note de version de !1385. Les approbations vocales sont dans la v27.11.0, mais la
    │ note de #504 n'est pas encore publiée (ticket ouvert, state::merged,
    │ type::feature). Je propose d'ajouter cette ligne dans la section « ## Release note
    │ » de prismeai-platform#504, que la MR cite par « Related to » : « Agent Factory: In
    │ voice mode, when your answer to an approval cannot be heard, the agent asks the
    │ question again instead of staying silent, up to three times in a row. » Je l'ajoute
    │ ?

    ❯ 1. Oui, ajouter à #504
         J'ajoute la ligne à la section Release note de #504, et la description de la MR
         la reprend.
      2. Couverte par #504
         La ligne existante de #504 (« a spoken yes or no answers it ») suffit : rien
         n'est ajouté au ticket.
      3. Type something.
    ─────────────────────────────────────────────────────────────────────────────────────
      4. Chat about this

    Enter to select · ↑/↓ to navigate · Esc to cancel
    """

  /// What the report read once nothing could be typed: the next frame, its first lines written,
  /// the dialog cleared away.
  static let halfDrawn = """
          1021        await tick();
          1022      }
          1023      // Heard, but neither a yes nor a no: asked again, and the count starts over.
          1024 -    userSays('Euh, attends.');
          1025 -    await tick(); console.log('DBG0', JSON.stringify(metrics.map((m) => [m.reason, m.status])), turns.length, JSON.stringify(turns[1]?.request));
          1024 +    userSays('Quel mail ?');
    """

  static let size = TerminalSize(columns: 160, rows: 63)
  static let begin = "\u{1B}[?2026h"
  static let end = "\u{1B}[?2026l"

  /// A frame as Claude Code begins one: the screen cleared, then its lines from the top.
  static func begun(_ text: String) -> String {
    begin + "\u{1B}[2J\u{1B}[H" + text.replacingOccurrences(of: "\n", with: "\r\n")
  }

  static func bytes(_ text: String) -> [UInt8] {
    Array(text.utf8)
  }

  @Test("Read while the next frame is half drawn, the screen is the dialog still shown")
  func halfDrawnFrame() {
    let drawn = Self.begun(Self.reportedDialog) + Self.end
    let history = Self.bytes(drawn + Self.begun(Self.halfDrawn))
    let screen = TerminalText.screen(replaying: history, size: Self.size)
    #expect(screen == TerminalText.screen(replaying: Self.bytes(drawn), size: Self.size))
    #expect(!screen.contains("userSays('Quel mail ?');"))
    let dialog = AgentDialogScreen(screen: screen)
    #expect(dialog?.options.map(\.number) == [1, 2, 3, 4])
    #expect(dialog?.pointedOption == 1)
    #expect(dialog?.options.first?.label.hasPrefix("Oui, ajouter à #504 ") == true)
    #expect(dialog?.options.last?.label == "Chat about this")

    // Its update ended, the next frame is what shows.
    let ended = TerminalText.screens(replaying: history + Self.bytes(Self.end), size: Self.size)
    #expect(ended.shown.contains("userSays('Quel mail ?');"))
    #expect(AgentDialogScreen(screen: ended.shown) == nil)
    #expect(
      TerminalText.screens(replaying: history, size: Self.size).shown == screen)
  }

  @Test("Read again and again, a frame half drawn is fed once its update has ended")
  func followedHalfDrawnFrame() async {
    let drawn = Self.bytes(Self.begun(Self.reportedDialog) + Self.end)
    let lines = Self.halfDrawn.split(separator: "\n", omittingEmptySubsequences: false)
    let opened = drawn + Self.bytes(Self.begun(lines.prefix(3).joined(separator: "\n")))
    let follower = TerminalScreenFollower()

    let first = await follower.screen(
      of: TerminalHistorySnapshot(bytes: opened, droppedByteCount: 0), size: Self.size)
    #expect(first == TerminalText.screen(replaying: drawn, size: Self.size))
    #expect(AgentDialogScreen(screen: first) != nil)

    let finished =
      opened + Self.bytes("\r\n" + lines.dropFirst(3).joined(separator: "\r\n") + Self.end)
    let second = await follower.screen(
      of: TerminalHistorySnapshot(bytes: finished, droppedByteCount: 0), size: Self.size)
    #expect(second == TerminalText.screen(replaying: finished, size: Self.size))
    #expect(second.contains("      1021        await tick();"))
    #expect(second.contains("userSays('Quel mail ?');"))
  }

  @Test("Where the frames drawn end: before the update still open, its first beginning")
  func drawnThrough() {
    func drawn(_ text: String) -> Int {
      TerminalText.drawnThrough(Self.bytes(text)[...])
    }
    for whole in ["plain\r\n\u{1B}[2Jtext", Self.begin + "frame" + Self.end] {
      #expect(drawn(whole) == whole.utf8.count)
    }
    #expect(drawn("ab" + Self.begin + "half") == 2)
    #expect(drawn("ab" + Self.begin + "x" + Self.begin + "y") == 2)
    #expect(drawn(Self.begin + "a" + Self.end + "b" + Self.begin + "c") == 18)
    // Cut short by the read, it may begin one: held back until the next read tells.
    #expect(drawn("ab\u{1B}[?2026") == 2)
    #expect(drawn("ab\u{1B}[?20") == 2)
    #expect(drawn("ab\u{1B}") == 2)
    for whole in ["ab\u{1B}[31m", "ab\u{1B}[?2004h", "ab\u{1B}[?2026$p"] {
      #expect(drawn(whole) == whole.utf8.count)
    }
    // Of a slice, an index of the whole.
    let whole = Self.bytes("frame " + Self.begin + "half")
    #expect(TerminalText.drawnThrough(whole[3...]) == 6)
  }

  @Test("A begin cut short between two reads is waited on, the history trimmed in between")
  func followedSplitBegin() async {
    let drawn = Self.bytes(Self.begun(Self.reportedDialog) + Self.end)
    let cut = Self.bytes("\u{1B}[?2026")
    let rest = Self.bytes("h\u{1B}[2J\u{1B}[H" + Self.halfDrawn)
    let follower = TerminalScreenFollower()
    // Bytes before these were dropped from the history: where they stand in the stream counts.
    let first = await follower.screen(
      of: TerminalHistorySnapshot(bytes: drawn + cut, droppedByteCount: 500, startOffset: 500),
      size: Self.size)
    #expect(first == TerminalText.screen(replaying: drawn, size: Self.size))
    let second = await follower.screen(
      of: TerminalHistorySnapshot(
        bytes: drawn + cut + rest, droppedByteCount: 500, startOffset: 500),
      size: Self.size)
    #expect(second == first)
    #expect(AgentDialogScreen(screen: second) != nil)
  }

  @Test("A frame no longer waited on reads as it stands, as a view shows it after a while")
  func frameNoLongerWaitedOn() async {
    let history = Self.bytes(
      Self.begun(Self.reportedDialog) + Self.end + Self.begun(Self.halfDrawn))
    let screen = TerminalText.screen(replaying: history, size: Self.size, waitingOnFrame: false)
    #expect(screen.contains("userSays('Quel mail ?');"))
    #expect(AgentDialogScreen(screen: screen) == nil)
    #expect(
      TerminalText.screens(replaying: history, size: Self.size, waitingOnFrame: false).shown
        == screen)

    let follower = TerminalScreenFollower()
    let snapshot = TerminalHistorySnapshot(bytes: history, droppedByteCount: 0)
    let waited = await follower.screen(of: snapshot, size: Self.size)
    #expect(AgentDialogScreen(screen: waited) != nil)
    let given = await follower.screen(of: snapshot, size: Self.size, waitingOnFrame: false)
    #expect(given == screen)
  }

  @Test("An update that never ends is read as drawn, past the longest frame")
  func endlessUpdate() {
    let filler = String(repeating: "a", count: TerminalText.longestFrame)
    let history = Self.bytes("ab" + Self.begin + filler)
    #expect(TerminalText.drawnThrough(history[...]) == history.count)
    let shorter = Self.bytes("ab" + Self.begin + filler.dropLast(10))
    #expect(TerminalText.drawnThrough(shorter[...]) == 2)
  }
}
