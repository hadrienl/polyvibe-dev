# Ticket validation report — #541 (command permissions)

Antigravity's command permission, answered from the conversation's card and the palette.

**Verified version: `agy` 1.5.18** (Gemini 4 Hydrogen, 2026-11-27), Manual mode as Polyvibe
launches it (`--settings '{"agentMode":"","toolPermission":"request-review"}'`).

## Method

- `agy` driven through a pty 60, 100 and 110 columns wide in throwaway folders, its screen
  rendered by a terminal emulator, a recording status command beside it (state and
  `tool_confirmation_pending` only). agy's `settings.json` was restored byte for byte afterwards;
  only the throwaway folders' trust had been added.
- Recorded: `ls -la`, a one-line command of sixty words, a two-line command, a thirty-line
  command, `git status --short` at 60 columns, a file creation, an `ask_question` question, a
  digit for each option, `4. No, cancel`, Escape, and text pasted into an open dialog.
- The transcript was copied while the dialog was open, to see what it holds.

## Observations of the CLI

| What | Observed |
|---|---|
| Status while a command waits | `agent_state: tool_use`, `tool_confirmation_pending: true`; `working` once answered |
| Status during `ask_question` | `tool_use`, **no** pending flag: nothing says a question waits |
| Digit | Takes its option at once (`2` ran the command, rule kept for the conversation only) |
| Digit beyond the options | Ignored; pasted text ignored; the Return after it took the highlighted option |
| `4. No, cancel` | `User declined the tool call`, then `Interrupted`: the turn ends |
| Escape | `Interrupted` without a refusal line: the turn ends |
| Command lines | Three spaces in; a wrapped line goes on at the left edge, unindented |
| Many lines | First four, then `⋯ (26 lines hidden)` |
| Narrow terminal | Option labels wrap at the left edge |
| Prefix | agy's own: `ls`, `echo`, `printf`, `git status` |
| File creation | Its path cut at the terminal's width, with no mark |
| Transcript | The pending `run_command` call, with its `CommandLine`, is written before the answer |

## Requirements checklist (second comment of #541)

| Requirement | Status | Evidence |
|---|---|---|
| Answer from the conversation's card, four choices and their words | IMPLEMENTED | `ToolBlockView` / `RequestPalette`: Allow, Always ▸ (this session / everywhere, the prefix named), Refuse; `AntigravityDialogTests.command` |
| Prefix taken from the screen | IMPLEMENTED | `AntigravityDialogReading.sessionPrefix` / `persistentPrefix`; two prefixes that disagree are not read |
| Command and options checked before each key, dialog checked closed | IMPLEMENTED | Shared #283/#558 path: two readings must name the request, keys read off the dialog, confirmation of the change after; `DialogOnScreenTests.unreportedOverAnnouncedPermission` |
| `tab Amend` and `ctrl+g` in the terminal | IMPLEMENTED | Never typed; documented in the keymap |
| Automatic mode and this dialog | NOT RE-VERIFIED | 1.5.5 showed Auto running a sandboxed write unasked (ADR 0045); unchanged here |

## Ticket bullets

| Bullet | Status |
|---|---|
| MCP tools and instructions per session | NOT AVAILABLE on 1.5.18: `--settings` has no MCP key; servers live in global `mcp_config.json` or plugins (global, or in the project). Still not offered |
| Questions and permissions | PARTIAL: command permissions answered from outside; file creation/edit and `ask_question` stay in the terminal (reasons above) |
| Transcripts: tool results | Done in #561 |
| Usage and cost | Done in #599 |
| Commands/skills, attachments, shell mode | NOT VERIFIED, unchanged |
| Data folder override | Not exposed, unchanged |

## Tests

- `AntigravityDialogTests`: screens recorded on 1.5.18 (account and folder replaced): reading,
  digits, prefix checks, wrapped and two-line commands, folded command (refusal only), narrow
  terminal, file creation, question, running screen, forged options and forged title.
- `AntigravityTests`: the pending flag announces a permission; the decoder carries the keymap.
- `DialogOnScreenTests.unreportedOverAnnouncedPermission`: an announced permission read off the
  screen, answered, then settled by the status line.
