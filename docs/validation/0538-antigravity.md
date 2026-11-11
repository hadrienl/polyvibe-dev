# Ticket validation report — #538

## Requirements checklist

| Requirement | Status | Evidence |
|---|---|---|
| Dedicated Antigravity provider, stable ID, registry entry | IMPLEMENTED | `AntigravityAgentProvider.swift`, `VibeComposition/AppEnvironment.swift` |
| Shared Finder detection, cold-start retries, native executable preference, bounded version probe | IMPLEMENTED | Existing `FileSystemExecutableLocator`, `AgentAvailabilityProbe`; `AntigravityTests.detection` |
| Account model catalog, bounded/coalesced/cached; default model preserved on failure | IMPLEMENTED | `AntigravityModelCatalog`; catalog parsing and shared failure-cache tests |
| Interactive PTY and literal initial prompt | IMPLEMENTED | `AntigravityArgumentBuilder`; actual `agy` 1.5.5 PTY experiments with multiline, accents, leading dash and shell syntax |
| Reject NUL, unsafe model/ID shapes and oversized TUI prompts | IMPLEMENTED | `AntigravityTests.validation`; shared validation and typed errors |
| Capture identity without mixing launches in one directory | IMPLEMENTED | Per-process status command, exact UUID-derived transcript; two-observer test; no workspace discovery or terminal UUID extraction |
| Confirm conversation before persisting; retry delayed persistence; final look at exit; adoption handover | IMPLEMENTED | `AntigravityLaunchObserver`, `AntigravityTranscriptWatcher`; reused `ClaudeCodeSessionIdentifierCapture` and its existing tests; Antigravity capture/adoption tests |
| Explicit resume, no `--continue`, no initial prompt replay | IMPLEMENTED | Argument tests; real CLI restart recovered an earlier marker absent from the follow-up prompt |
| User settings and hooks preserved, no global config writes | IMPLEMENTED | Session-only status settings; wrapper preserves the enabled user command/output and layout; actual shell-command test |
| No secrets/account/prompt data added to activity logs | IMPLEMENTED | Status script allowlist and UUID/state validation; canary test with private values; existing log store protections |
| Activity transitions and background work | IMPLEMENTED | Stateful status decoder, duplicate-idle/background/permission tests; actual CLI status log |
| Basic conversation reading | IMPLEMENTED | Numbered-step decoder, wrapper removal and snapshot replacement; actual synthetic transcripts |
| Full question/permission content and external answering | PARTIAL | Pending dialog signalled, answered in terminal; palette integration deliberately unavailable, follow-up #541 |
| Tool-result grouping, diffs, subagent conversations, attachments and command discovery | PARTIAL | Text/information view only; no inferred result attribution; follow-up #541 |
| MCP injection, coordinator/browser tools, supplemental instructions | MISSING | CLI has separate MCP/hook config files; no verified per-process injection path, follow-up #541 |
| Usage and costs | MISSING | `reportsUsage: false`; semantics/deduplication not established, follow-up #541 |
| Documentation, version floor, security review and translations | IMPLEMENTED | ADR 0044, README, security review; no new localized UI strings; translation checker passes |
| Build available for user testing | IMPLEMENTED | Universal macOS Release build, Developer ID signature verified recursively; isolated launcher and own recipe identity |
| Entire repository CI green | PARTIAL | Checks and builds below; unrelated UI/browser test failures remain, so this is not marked merge-ready |

## Test coverage and observed results

- Final `AntigravityTests`: **12/12 pass**. Includes actual execution of the inline status shell
  command, preservation of user output, secret canaries, exact transcript confirmation, adoption,
  separate launches and shared failed catalog requests.
- Final `Scripts/ci.sh`: package build with warnings-as-errors completed; translation checks,
  external-open checks, release-tools tests and CompanionKit tests passed. The package's **3,784
  tests** ran. All **527 VibeAgents tests** passed. The script stops at failed test targets, so
  its subsequent Debug/macOS and iOS simulator build steps were not reached.
- That CI run reports **21 failed assertions across seven tests**: five in `NewSessionDropTests`
  (19 assertions), `ReturnOnScreenTests`' slow-input case (one) and `BrowserAgentEffectsTests`'
  user-action case (one). These files and implementations are unchanged by #538. The first full
  package run had only the same five drop-test failures; the latter two failures vary between
  runs. A clean baseline was not separately rebuilt, so this report does not claim baseline CI
  is proven green or red.
- Xcode 27.2 emits existing formatting/concurrency warnings outside the changed files. Formatting
  of all changed Swift files and `git diff --check` pass.
- Separate signed Release application build: **BUILD SUCCEEDED**, then a final incremental build
  succeeded. `lipo` confirms `x86_64 arm64`; `codesign --verify --deep --strict` passes on the
  renamed recipe copy. The recipe excludes the iPhone companion and uses a unique app identity.
- Actual CLI experiments: version/model listing, interactive startup and trust screen, native
  resume with context, literal multiline/leading-dash prompt, bracketed paste, structured status,
  synthetic read-tool export and transcript location. No broad parity claim for hooks/ACP/MCP.
- The isolated application's launch and private runtime directory were confirmed. Native UI
  automation initially confused two apps sharing the production bundle ID; the recipe was given
  its own identity. The automation adapter then failed to bind that identity despite listing it
  running. Full create/restart/adopt interactions through the app's UI remain manual recipe steps.

## Verdict

**PARTIAL — ready for local testing, not declared merge-ready.** Core launch/resume/activity and
basic conversation support are implemented and tested. The user recipe is in
`/Users/hadrien/Documents/vibe-manager/.build/Antigravity-538/`, with an isolated `.command`
launcher and `LIRE-MOI.md`. Advanced capabilities are tracked in
[#541](https://github.com/hadrienl/vibe-manager/issues/541); the existing test failures and full
manual app lifecycle recipe still require follow-up before considering #538 complete.

Validation follows the `prisme-ai:ticket-validator` skill. No production sessions or CLI credential
files were modified by the implementation.
