# 0044 — Antigravity CLI

- Status: proposed, implemented for local testing
- Date: 2026-11-11
- Issue: [#538](https://github.com/hadrienl/vibe-manager/issues/538)

## Scope

Antigravity (`agy`), verified on 1.5.5, is a third CLI provider. It uses the existing executable
locator, bounded availability probes, login-shell environment, PTY, terminal host, restart and
agent-switch machinery. It is neither Gemini CLI nor an alias for Claude Code.

This first build supports the account's models, initial prompts, structured activity, exact native
resume and the numbered conversation export. Approval and question dialogs are answered in the
terminal. Usage/cost accounting, grouped tool results, subagent conversations, dynamic command
discovery, injected Vibe Manager MCP tools and auxiliary generators are not advertised as supported.
The CLI's own existing hooks and MCP configuration still apply. Advanced integration is tracked in
[#541](https://github.com/hadrienl/vibe-manager/issues/541).

## Launch

The process directory is the workspace. `--prompt-interactive <text>` is an option value, so a
leading dash is literal; `--prompt` would instead choose noninteractive mode. Arguments never
pass through a shell. The shared limits reject NUL and prompts above 16 KiB, without typing a
partial multiline prompt into the terminal. Slash commands use the common ready-to-type path.
Normal launches do not override the CLI's mode, sandbox, model default or permission policy.

`agy models` is bounded to 15 seconds by the shared process probe. A catalog actor coalesces
concurrent requests, caches success for five minutes and failure for fifteen seconds, and reads
only validated tab-separated identifiers and labels. An absent list leaves the CLI's default.
No authentication command is guessed: an unknown account status remains launchable.

## Per-process identity and activity

The CLI supports a structured status command supplied through session-only `--settings`. That
command appends to the existing per-session activity log and works while the application is
closed. No hooks, plugins, settings or MCP files are installed globally or in the project.

The status command reads at most 64 KiB and drains the rest. It retains only a validated
conversation UUID, an allowlisted agent state, whether a tool confirmation is pending and whether
a background task/subagent is still running. Account details, prompts, model output and subagent
names never enter this log. The user's own enabled status command receives the input too and
keeps its output; padding and stack preference are preserved. Without an enabled custom command,
the built-in status line stays visible. Scripts are carried inline so moving the app does not
break an existing terminal host's agent.

An observer accepts identity only from that process's status. It never reads the workspace's
last-conversation cache, scans another launch's files or extracts UUIDs from an echoed prompt.
The existing transcript-confirmation capture supplies bounded retries, a last check at process
exit, an unstored-ID state and handover of the pending ID to an adopting instance. The record
operation still checks provider and agent-switch date before mutating the session.

Resume is `--conversation <uuid>`, never `--continue`, and sends no initial prompt. Status snapshots
can also name a new conversation created inside an existing process. An ID becomes resumable only
after its exact transcript exists. If the user disables the status command inside the CLI, new
identity/activity reports stop; the application does not guess a different conversation.

The decoder detects state transitions: repeated idle snapshots do not manufacture unread answers,
and an initial idle snapshot also settles a previously working adopted process without inventing
a new answer. Background work keeps the session working. A pending confirmation is signalled as
a terminal dialog without inferred choices or external answer keys.

## Verified discrepancy and conversation format

On 1.5.5, `transcript_path` from the status command points at
`~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`, whereas the CLI writes
under `~/.gemini/antigravity-cli/brain/<id>/…`. The provider uses the latter exact UUID-derived
path, confirmed by synthetic conversations and native resume. No personal conversation is scanned.

The export has numbered steps: `USER_INPUT`, `PLANNER_RESPONSE` and `GENERIC`. User-request
wrappers and generated time/settings metadata are separated; reasoning and assistant text are
shown as such. Repeated step snapshots replace the previous step. Tool calls and generic output
are information, because the exported results do not identify which parallel call they answer.
No successful tool state or usage totals are invented. Unknown step types are ignored.

## Regression checklist disposition

The issue's Codex/Claude checklist remains the acceptance reference. Shared detection retries,
native executable preference, environment filtering, host adoption, refusal-of-resume handling,
agent switching and atomic persistence are reused. New tests cover argv, unavailable launch,
catalog noise, sensitive-field removal, status-command preservation, activity/background work,
transcript confirmation, final exit check, adoption and export snapshots. Existing capture tests
cover delayed first exchanges, persistence retries and launch changes in the reused machinery.

No terminal-ID parsing, workspace discovery, new global hook-trust flow or transcript directory
scanning is introduced: their false-positive and ordering traps do not apply to this path.
Palette answering, multiple/asynchronous questions, usage deduplication, subagent tool grouping,
MCP injection and custom CLI configuration roots require separate verification before being
enabled. They must not be inferred from the success of a launch/resume smoke test.

## Local verification

Experiments on the installed CLI established version, tab-separated models, interactive startup,
folder-trust prompt, exact native resume with retained context, literal multiline startup prompt,
bracketed paste, structured status reporting and transcript location/shape. A shell-like prompt
containing `$(touch …)` stayed literal and created no file. The normal permission policy remained
in force throughout. Build and test results are recorded with the ticket/build handoff.

References: [CLI options](https://antigravity.google/docs/cli/reference),
[resume](https://antigravity.google/docs/cli/commands/resume),
[status command](https://antigravity.google/docs/cli/statusline/),
[hooks](https://antigravity.google/docs/hooks/), [MCP](https://antigravity.google/docs/mcp/).
