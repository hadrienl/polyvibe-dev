# 0045 — Antigravity CLI

- Status: proposed, implemented for local testing
- Date: 2026-11-11
- Issue: [#538](https://github.com/hadrienl/vibe-manager/issues/538)

## Scope

Antigravity (`agy`), verified on 1.5.5, is a third CLI provider. It uses the existing executable
locator, bounded availability probes, login-shell environment, PTY, terminal host, restart and
agent-switch machinery. It is neither Gemini CLI nor an alias for Claude Code.

This first build supports the account's models, initial prompts, structured activity, exact native
resume and the numbered conversation export. Approval and question dialogs were answered in the
terminal; since #541 a command's permission is answered from outside it (below). Usage/cost accounting, grouped tool results, subagent conversations, dynamic command
discovery, injected Vibe Manager MCP tools and auxiliary generators are not advertised as supported.
The CLI's own existing hooks and MCP configuration still apply. Advanced integration is tracked in
[#541](https://github.com/hadrienl/vibe-manager/issues/541).

## Launch

The process directory is the workspace. `--prompt-interactive <text>` is an option value, so a
leading dash is literal; `--prompt` would instead choose noninteractive mode. Arguments never
pass through a shell. The shared limits reject NUL and prompts above 16 KiB, without typing a
partial multiline prompt into the terminal. Slash commands use the common ready-to-type path.
The model default is left to the CLI. Approval is chosen in Settings › Agents › Antigravity,
through the same translated Manual / Automatic picker as #543. A namespaced, per-provider
preference is read again on every launch and native resume; old configurations are Manual.
One store keeps every agent's mode under its identifier, with #543's `codex.approvalMode.<id>.v1`
keys and raw values, and one `approvalMode` field of the launch request carries it to Codex and
Antigravity alike.

Manual sets `agentMode: ""` and `toolPermission: "request-review"` for this process, so a global
automatic setting cannot override the user's Manual choice. `--mode` has no value for the default
mode; `""` is the CLI's explicit Default (what `/config` saves since Auto became the default), not
an absent value. On 1.5.6, with a global `agentMode: "auto"`, a headless write ran unasked without
the override and was held for review — refused, headless — with it. Automatic sets `--mode auto`,
`--sandbox` and `toolPermission: "proceed-in-sandbox"`, keeping native review of commands outside
the sandbox. `--dangerously-skip-permissions` is never used. Native allow/ask/deny rules still
apply. The picker explains the personal-account/sandbox requirement; where unavailable the CLI
falls back to its default mode, as documented by its vendor.

Approval and activity are merged into one `--settings` JSON object. The option parser skips
prompt values (including a literal `--settings`) rather than treating user text as options.
No global configuration is changed. The user's existing status command is preserved as before.

`agy models` is bounded to 15 seconds by the shared process probe. A catalog actor coalesces
concurrent requests, caches success for five minutes and failure for fifteen seconds, and reads
only validated tab-separated identifiers and labels. An absent list leaves the CLI's default.
No authentication command is guessed: an unknown account status remains launchable.

## Per-process identity and activity

The CLI supports a structured status command supplied through session-only `--settings`. That
command appends to the existing per-session activity log and works while the application is
closed. No hooks, plugins, settings or MCP files are installed globally or in the project.

The status command reads at most 4 MiB and drains the rest; one `plutil` conversion and one `awk`
pass read the fields and the time, two processes per refresh. It retains only a validated
conversation UUID, an allowlisted agent state, whether a tool confirmation is pending and whether
a background task/subagent is still running. Account details, prompts, model output and subagent
names never enter this log. The user's own enabled status command receives the input too and
keeps its output; padding and stack preference are preserved. Without an enabled custom command,
the built-in status line stays visible. A status line the user turned off stays invisible: the
reporter runs alone, without the built-in line, and draws nothing. Scripts are carried inline so moving the app does not
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
a new answer. Working and tool use are one turn. A turn that starts from rest or after an error is
the user's: what the failure asked is behind it. Idle after a pending confirmation ends the turn,
since the approval and the rest of the turn can fall between two snapshots. Background work keeps the session working. A pending confirmation is signalled as
a permission announced without inferred choices: its screen says which, if it is a command's (#541).

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
Palette answering of command permissions is verified and enabled (#541, below); questions,
file permissions, MCP injection and custom CLI configuration roots require separate verification
before being enabled. They must not be inferred from the success of a launch/resume smoke test.

## Command permissions answered from outside (#541)

Verified on 1.5.18, in Manual mode, in a pty 60, 100 and 110 columns wide. agy has no hook that
reports a request: its status line only sets `tool_confirmation_pending` (with `agent_state:
tool_use`) while a tool waits for review. The decoder announces that as a permission
(`AgentTerminalPrompt.Kind.permission`), and the screen is read for a while, as for Codex's
Computer Use (#603). When it ends on the command dialog — `Requesting permission for:`, the
command three spaces in, `Run this command?`, the options, the `↑/↓ Navigate` hint and
`esc to cancel` last — that dialog becomes the request, `run_command` with the command as drawn.

- The four options are offered: `Yes, run command`, always for commands starting with the prefix
  agy names in this conversation, the same persisted to agy's `settings.json` (shown as
  "everywhere"; the new `AgentAnswer.allowEverywhere`), and `No, cancel`. A digit takes its option
  at once; each digit is read off the dialog, an "always" one only for the prefix the request
  names. `No, cancel` refuses the call and ends the turn (`User declined the tool call`); Escape
  would only interrupt it. `tab Amend` and `ctrl+g` stay in the terminal.
- Before every key the screen is read twice and must still show that command; after it, the
  dialog must change (#558). Once the dialog goes, answered in the terminal or taken away, the
  card goes; the status line's return to work settles it too.
- A line wrapped at the terminal's width goes on at the left edge, unindented: the request keeps
  the lines as drawn (they `fit` the command they wrap). The title must follow a blank line, which
  no line of the command can produce at the left edge, so a command forging the title is not read.
- A command of many lines is folded (`⋯ (26 lines hidden)`): it is incomplete and may only be
  refused. Options wrapped at the left edge (about 90 columns and less, by the prefix's length) are
  not read: answered in the terminal.
- Not read, answered in the terminal: a file's creation or edit (its path is cut at the
  terminal's width with no mark), and `ask_question`, whose dialog the status line does not
  report at all (`tool_use`, no pending flag). The transcript holds the pending call (with its
  `CommandLine`) before the answer; it is not used yet.

MCP injection stays unavailable on 1.5.18: `--settings` takes `settings.json` keys only, MCP
servers live in `mcp_config.json` (global) or plugins (global or in the project), and no option
adds one for a process. Commands/skills, attachments, shell mode and a custom data folder are
unchanged: not verified, not offered.

## Endpoints driven by Antigravity

An endpoint (ADR 0035) can be driven by `agy`: Settings › Endpoints › Driven by › Antigravity. It
is never the automatic choice. `agy` 1.5.6 reaches an "enterprise model gateway" through
`AGY_LLM_GATEWAY_URL`, `AGY_LLM_GATEWAY_API_KEY`, `AGY_LLM_GATEWAY_WIRE_PROTOCOL` and
`AGY_LLM_GATEWAY_MODELS`, without any Google sign-in. With the `openai` wire it sends a streamed
`POST <URL>/v1/chat/completions`, the key as a bearer token, `stream_options.include_usage`, a
system message first, `function` tools, assistant `tool_calls` and `tool` results; plain HTTP is
accepted for a gateway on the same machine only. The other wire, `genai`
(`v1beta/models/<model>:streamGenerateContent`), is not used.

So the gateway gains a third harness protocol, Chat Completions (`ChatCompletionsServer`), the
mirror of the Chat Completions client it already had: read into the canonical request, answered as
`chat.completion.chunk` objects, the finish reason, the usage in a last chunk and `[DONE]`; a cut
stream ends with an `error` object and no `[DONE]`. A Chat Completions endpoint is passed through
untouched but for its model and credentials. The session's URL is `…/s/<token>`, the token is its
API key, and the endpoint model is the only one listed. Whatever else would choose the model or the
credentials — the user's own gateway variables, `GEMINI_API_KEY`, `GOOGLE_GEMINI_*`,
`AGY_ADC_AUTH` — is removed from the session's environment. Approval is Manual, explicitly: the
native agent's Automatic needs a personal account, which a gateway session is not.

Activity, resume capture (recorded under the endpoint with `antigravity` as harness), conversation
reading and the resume refusal of a conversation another harness wrote are relayed as for the other
harnesses. MCP tools and instructions are not injected, as for the native agent (#541): such an
endpoint is an `AntigravityEndpointAgentProvider`, which does not claim them, so coordination is
not offered to it. `agy` asks
4,096 output tokens of a gateway model it does not know: a very long single file write may be cut.

A second Antigravity *account* (ADR 0035's accounts, #478) is not offered: a hidden `--gemini_dir`
moves the configuration and the conversations, but 1.5.6 keeps one sign-in in the keychain for
every folder, so the second account would be the first one under another name.

## Local verification

Experiments on the installed CLI established version, tab-separated models, interactive startup,
folder-trust prompt, exact native resume with retained context, literal multiline startup prompt,
bracketed paste, structured status reporting and transcript location/shape. A shell-like prompt
containing `$(touch …)` stayed literal and created no file. The normal permission policy remained
in force throughout the original recipe. A subsequent 1.5.5 experiment verified that native Auto
created a synthetic workspace file with the sandbox active, while Manual showed the file-creation
approval and left that file absent. That edit dialog did not set `tool_confirmation_pending` in
the status payload: detailed dialog reporting remains part of #541. Build and test results are
recorded with the ticket/build handoff.

On 1.5.6, `agy -p` against the real gateway (Chat Completions harness) in front of a scripted
Messages endpoint read a workspace file through `read_file`, sent the tool result back in a second
turn, and printed the endpoint's final answer.

References: [CLI options](https://antigravity.google/docs/cli/reference),
[resume](https://antigravity.google/docs/cli/commands/resume),
[status command](https://antigravity.google/docs/cli/statusline/),
[hooks](https://antigravity.google/docs/hooks/), [MCP](https://antigravity.google/docs/mcp/).
