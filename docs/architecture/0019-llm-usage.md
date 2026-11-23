# 0019 — Tracking what the agents use

- Status: accepted
- Date: 2026-09-24
- Issue: [#18](https://github.com/hadrienl/vibe-manager/issues/18)

## Context

A user running several agents wants an idea of what each session consumed: how long its agent ran,
how often it was started or resumed, with which model, and how many tokens it spent. The figures are
indicative, not a bill, and three constraints frame them: nothing leaves the Mac, what the agents
were asked or answered is never read, and the user can turn tracking off and erase it.

What the CLIs expose was measured before anything was designed (`claude` 2.1.281, `codex-cli`
0.156.1, keys only):

- Claude Code writes `message.usage` on each answer (`input_tokens`, `cache_creation_input_tokens`,
  `cache_read_input_tokens`, `output_tokens`) and the model that answered in `message.model`. An
  answer with several blocks is written over several lines that repeat the same usage — 46 answers
  out of 55 in one transcript.
- Codex writes a `token_usage_record` per response, named by `response_id`, and the model in each
  `turn_context`. Older rollouts only have per-turn `token_count` events.
- Claude Code's `cost-state` lines carry a `totalCostUSD`, but it is not a counter: within one
  `startTime` it goes down as well as up (519 then 494), and `startTime` itself goes backwards.
  Codex reports no cost. Codex's cumulative `total_token_usage` drifts from the sum of its
  responses after a compaction (12.58 M against 12.81 M).

## Decisions

### Three kinds of figure, never confused

- **Measured** by the application: running time and runs.
- **Reported** by a CLI: tokens and responses, shown with `≈` and their source.
- **Unavailable**: said with its reason — not reported by this agent, no transcript, tracking off,
  not reliable — and never shown as zero.

### No cost

Neither CLI reports one that holds together, and computing one would mean shipping a price list that
is wrong within weeks (ADR 0005 and 0006 already refuse hard coded model lists for that reason) and
means nothing on a subscription. The cost is shown as unavailable, with that sentence.

### Running time is the life of the process, sleep excluded

`SessionLauncher` is the one road to a process, so it is where runs are recorded: `start` once a
process exists and the session was reopened, `end` from the exit watch (`exited`) or from `detach`
(`stopped`), `detach` from `handOff` when the terminal host keeps the agent (ADR 0017). Each start
says what it was — `start`, `resume`, `restartWithSummary`, `restartFresh` — and whether it came from
the restoration after a relaunch (`attemptRestart`) or from a switch (`launchSwitch`). The model is
the one the session asks for; `nil` is the CLI's default.

The start is written before the exit is watched: a process that ends at once — a resume the CLI
refuses — would otherwise see its exit handled first, and leave a run nothing closes.

Sleep is not running time: `NSWorkspace` sleep and wake notifications write `suspend` and `resume`,
and a `resume` always follows a written `suspend`, even when every run ended in between. A sleep
whose wake never came — the battery died, the application died asleep — is dropped at the next
`start` or `suspend` rather than stretched to the next wake, which would erase the runs between.
Time spent waiting for the user is running time: telling the two apart needs the agent state of #45.

### The journal is appended to, one file a month

`Usage/runs-YYYY-MM.jsonl`, one event per line, opened with `O_APPEND`, synchronized after each line.
A line costs the same whatever the history, and a month holds a few kilobytes. A last line cut short
by a crash is ignored. `UsageRecorder` is the only writer, so a session has at most one open run.

### A heartbeat bounds what a crash loses

`Usage/heartbeat.json` names the open runs and is rewritten every minute while one exists. At the
next launch, a run the journal never saw end is closed at the last heartbeat that names it, or at its
own start: a crash loses at most a minute. Reading the journal writes nothing; closing those runs is
`settleLaunch`, called once the launch has settled the terminal host, and never by a copy of the
application that found another one working in the same data (ADR 0011): that copy's recorder is
sealed, like its runtime recorder, and writes nothing at all. A line per minute in the journal would have cost ~20 MB a
year for a value only the last one matters for.

### Runs the terminal host kept

A run handed off at quit stays open (`detach`). Once the next launch has adopted what the host still
runs, it is settled: a session running again kept its run, which ran all along, and an `attach` says
so in the journal, so that a crash afterwards closes it at a heartbeat rather than at the hand-off; any other ended while the
application was away and is closed when the detection closed its session, never before the hand-off
and never after now. Whether the Mac slept meanwhile cannot be known, so that time counts.

### Tokens are read from the transcripts, and only their counters are kept

`AgentUsageReader` reads the files `AgentTranscriptLocator` finds — the same locator the activity
reader of #13 now uses — incrementally, from where the last reading stopped, whole lines only. A file
that shrank or changed inode is read again from the start.

What was said is never read. A line is decoded only when its bytes hold `"usage":` (Claude Code) or
`"token_usage_record"`, `"turn_context"`, `"token_count"` (Codex): in JSON a quote inside a string is
always escaped, so these can only match a key, never text typed by the user. It is then decoded into
types that declare nothing but counters, identifiers, a model and a date, the recipe of
`ClaudeCodeAuthenticationStatus` (ADR 0006); a test holds their field list.

Answers are counted once — Claude Code by `message.id` and `requestId`, Codex by `response_id` — with
the last 64 identifiers kept per file, since repeats are consecutive. Claude Code's `<synthetic>`
lines are skipped. Codex counts cached input inside its input, Claude Code beside it: both are
reported the way Claude Code does. A Codex rollout counts its records, or its per-turn events when it
has no record — skipping an event that repeats the previous running total, which an older Codex
writes when only its rate limits changed (198 of 863 events in the rollouts measured).

Totals are kept by file — keyed by a SHA-256 of its path, since a Claude Code project folder is
named after the repository — local day and model in `Usage/tokens.json`, because the transcripts belong
to the CLIs and they delete them (Claude Code after 30 days by default): a deleted transcript keeps
what it reported, and says so.

Transcripts are read only while a session's usage or the Usage window is on screen — the session
shown, or every session for the window — every thirty seconds, off the main thread. A reading that
a clear or the tracking switch overtook is dropped rather than saved.

### Off means nothing is counted, and cleared means nothing comes back

`Usage/tracking.json` holds the intervals tracking was on; without it, tracking is on and always
was, so the transcripts of existing sessions are counted from the first launch. Turning it off
closes what runs, stops writing and reading, and any token dated outside an interval is ignored when
a transcript is read later. **Clear Usage Data…** deletes the journal, the heartbeat and the token
totals, and starts a new interval now: reading the transcripts again brings nothing back from before
it. The agents' transcripts are never touched.

### Where it shows

- The Session pane of the inspector: a Usage section inside "Agent, usage & initial prompt".
- Window › Usage (⌥⌘U): a period (today, 7 days, 30 days, this month, previous month, all time), a
  grouping by session, agent or model, a daily chart, and a table. By model, time goes to the
  configured model and tokens to the declared one, and the column headers say so.
- Settings › General › Usage: **Track agent usage** and **Clear Usage Data…**.

## Consequences

- `AgentCapabilities.reportsUsage` is now true for Claude Code and Codex, false for the mock agent
  and any unknown provider.
- Running time and runs start with the version that ships this ADR; tokens go back as far as the
  transcripts that still exist.
- Sessions started outside Vibe Manager are never counted, even when their transcripts are on disk.
- The files hold session identifiers, provider and model slugs, dates and counters, the response
  identifiers used to count answers once, and digests of the transcript paths. No prompt, output,
  path or session name.
- A sleep during which the application was closed and the host kept an agent cannot be seen, and
  counts as running time.
- A CLI that changes the shape of its usage lines makes its tokens read as missing, not wrong.

## Rejected alternatives

- Claude Code's `cost-state` and Codex's `total_token_usage`: neither is a counter that survives a
  resume or a compaction.
- A price list, shipped or typed by the user: stale, and meaningless on a subscription.
- One document rewritten at each event: it grows with every launch.
- Reading the terminal output: it is the content the ticket forbids analysing, and its layout is not
  a contract.
- Reading `~/.claude.json`'s `lastCost`: it describes only the last session of a folder and sits next
  to data the application has no business reading.

## Amendment — the context window of the current conversation (#407)

Measured on Claude Code 2.1.311 and Codex 0.131 to 0.164, 2026-10-27.

- **What is shown.** In the Usage section only, a **Context** line: the context of the last answer
  of the current conversation, and how far it is from the **automatic compaction** — what a user
  watches — as a bar and a share: “≈ 92 k / 167 k · 55 %”. The window itself and how both were
  found are on hover. Above 80 % the bar turns red and says compaction is near — never orange,
  which means an agent waits (ADR 0024). The last compaction is said with the context before and
  after it.
- **Codex.** Every `token_count` event of the rollouts measured carries
  `info.last_token_usage.total_tokens` (the context) and `info.model_context_window` (the window).
  Codex compacts at `auto_compact_token_limit`, which no model of its catalogue sets in 0.164: it
  then takes nine tenths of the window. The rollouts agree — every automatic compaction measured
  came between 207 k and 231 k of a 258.4 k window, under 232.6 k. The threshold is therefore
  an estimate, and said to be one. A compaction is a `compacted` line; only its type and date are
  decoded, never its payload, which holds the history it replaced.
- **Claude Code.** The context of the last main answer is
  `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`; lines with
  `isSidechain` and the `<synthetic>` model are left out. The window is in no transcript, but the
  model is: an `attachment` of type `model` names it at the start and at each change, with
  `[1m]` for the million-token variant (only its `identity.modelId` is decoded, not its text). The
  window is deduced from it — 1 000 000 for `[1m]`, or when the conversation already went past
  200 000; 200 000 otherwise — and the threshold from Claude Code's own rule, read in the 2.1.311
  bundle: the window, less the output kept for the answer (`min(maxOutputTokens, 20 000)`), less
  13 000. That is 167 k of 200 k and 967 k of a million, where the `preTokens` of its compactions
  (968 k to 979 k) sit. A `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` or an `autoCompactWindow` setting is
  not seen: the figure is said to be an estimate.
- **Endpoints.** The window an endpoint model declares (`contextWindow`, ADR 0035) wins; its
  threshold follows the rule of the CLI that runs it, which is given that window at launch.
- **Deduced, not tabled.** Only the two variants Claude Code itself distinguishes are known; no
  table of models is kept (ADR 0005, 0006).
- **The same guarantees.** A line is decoded only when its bytes hold `"usage":`,
  `"compact_boundary"`, `"modelId":`, `"token_count"` or `"type":"compacted"`, into types that
  declare counters, a model, dates and markers. A test holds the list of their fields.
- **Nothing on disk.** The context is a value of the moment: where each transcript was left is
  kept in memory, never in `tokens.json`. It is read only for the sessions shown, at each end of
  turn of their agent (#45) and every thirty seconds otherwise, and not at all while tracking is
  off — the line then says so.
- **Never a zero.** Before any answer, for the mock agent or an agent that writes nothing, the line
  shows a dash and the reason.

## Amendment — an API-equivalent cost, and the usage in the status bar (#574)

Decided 2026-11-20. It replaces the decision **No cost** and the price list of the rejected
alternatives; the rest stands.

- **What the cost is.** An API equivalent: the tokens each model reported, at its public price per
  token — input, cache read, cache write, output — summed over the models of a session, an agent
  or a period. It is shown with `≈` and the words “API equivalent”: on a subscription it is what the
  work would have cost paid by the token, not what was paid. It is never a CLI's own figure: Claude
  Code's `totalCostUSD` still is not a counter, and Codex still reports none.
- **What is approximated.** The tokens are kept as daily totals per model (`TokenUsageFile.Tally`),
  so a price that depends on each request is out of reach: the long-context price above 200 k
  tokens is ignored, and Claude Code's cache writes, whose five-minute and one-hour variants
  `TokenCounts` keeps together, are paid at the five-minute price. Codex's input already leaves out
  its cache reads and its reasoning is part of its output: neither is counted twice. A price that
  lists no cache price of its own pays the cache as input — no discount is made up.
- **Never a zero.** A model without a known price — the CLI's default model, whose name is unknown,
  or a model the list does not have — is said, in a warning colour that is not orange (ADR 0024),
  and left out of the total. A session none of whose models has a price shows no cost.
- **Finding a price.** The model's own name, then without its date (`claude-opus-4-5-20251101` ↔
  `claude-opus-4-5`), then either with its provider's prefix (`anthropic/`, `openai/`, `gemini/`).
  Nothing closer is guessed: a close name is another model.
- **Where the prices come from.** LiteLLM's public `model_prices_and_context_window.json`, the list
  ccusage uses, kept by its community. The objection of ADR 0005 and 0006 to a hard coded list — it
  is wrong within weeks — is met by fetching it: at most once a day (an hour between failed
  attempts), with a plain `GET` of the public file, no cookie and a generic `User-Agent`, nothing
  about the user or the sessions. A 15-second limit, and an answer that is not a list of chat
  models with prices is refused. Only the chat and responses models with an input and an output
  price are kept, with their four prices, in `Prices/model-prices.json` beside the session store
  (`{ "version": 1, "fetchedAt": …, "prices": {…} }`, written atomically, `0600`). A failed fetch
  keeps the last good list.
- **A copy in the application.** `VibePersistence` ships a filtered copy (`model-prices.json`, the
  providers the agents reach, about 40 KB), regenerated by `Scripts/update-model-prices.sh` before
  each release (docs/release-checklist.md), for a first launch offline. The newer of the copy and
  the kept list is used.
- **Tracking off means no fetch.** The switch **Track agent usage** covers the cost: off, no list
  is downloaded. A copy that only reads the data downloads nothing either.
- **Where it shows.** The inspector's Usage section is gone. Its figures moved to a **Usage** button
  in the status bar of the session, under the terminal and under the conversation, between the
  Effort menu and the drawer: a ring of the context, its share and the cost (“◔ 55 % · 4,82 $”),
  and a popover with every figure the section had, the cost of each model, and where and when the
  prices were read. The transcripts are read while the session is the one shown, as they were while
  the section was on screen. The Usage window has a **Cost** column, by session, agent or model.
  An inspector arrangement saved with the section keeps its entry, and shows nothing for it.
- **Currency.** Dollars, written the way the user's language writes them, never converted: the
  prices are in dollars, and a rate would be one more figure to keep fresh. A cost that rounds to
  nothing without being nothing is “< $0.01”.

## Amendment — Antigravity's usage, context and quota (#599)

Measured on agy 1.5.14, 2026-11-22.

- **Usage.** Each `PLANNER_RESPONSE` step of agy's transcript carries `model`, `input_tokens`,
  `cache_read_tokens` and `output_tokens`; input leaves the cache out, as Claude Code's does. A
  `CHECKPOINT`, the call that compacts the conversation, carries the same counters without a model:
  it counts for the last model named. Steps are counted once by `step_index`. A line is decoded only
  when its bytes hold `"input_tokens":`, into a type that declares nothing but those counters, the
  step's type, index, date and model. `AgentCapabilities.reportsUsage` is now true for Antigravity.
- **Context.** The input with the cache read of the last response. agy writes no window in its
  transcript, so none is said; a `CHECKPOINT` is a compaction, its own input the context before it.
- **Quota.** agy writes the error that ends a turn on a spent quota to its terminal only. Its status
  line carries `quota.<bucket>.remaining_fraction` and `reset_time`, which the status command keeps
  (see the security review). agy does not say which model a turn used: a turn that fails while
  every bucket is spent becomes an account notice naming them and their reset; one spent among
  others is said beside an ordinary failure, the error may be another. A bucket whose reset has
  passed is no longer named.

## Amendment — the quotas of the accounts, and costs in another currency (#599)

Decided on 2026-11-22, with a mock-up validated by the user.

- **Live shares, asked to each CLI.** `account/rateLimits/read` of Codex's app-server,
  `claude -p /usage` and `agy -p /usage`, measured on codex-cli 0.169.0, claude 2.1.330 and agy
  1.5.14: none calls a model or spends a turn. Each is asked through the agent's own launch plan,
  so an extra account of #478 is asked with its folder. The formats are not contracts: an answer
  that does not read says so, never a zero; a failure keeps the last figures with their age. What
  is read is never written to disk.
- **The Quotas button**, always in the toolbar: a dial, no badge. Its needle points at the window
  nearest its limit, every account together; its colour is green under 80 % used, orange up to the
  limit, red at it, grey without a figure. These colours belong to the dial alone: elsewhere,
  orange still means an agent is waiting (ADR 0024). Its popover lists every account, its windows
  and its last thirty days at public prices.
- **Used or left** is one setting for every agent; Antigravity's share left is shown as used =
  1 − left. The colour always follows what was used.
- **Thirty days per account.** The API equivalent of #574, summed over the last thirty days, today
  included, by the conversation's agent identifier (`claude-code`, `codex`, `account.<uuid>`),
  from the tallies `TokenUsageFile` already keeps. Only the sessions run in Vibe Manager count; a
  model without a price is said, never counted.
- **Currency.** This amends “dollars, never converted” of #574: costs can be shown in a currency
  chosen in Settings, converted from the dollar through the euro at the European Central Bank's
  rate of the day, fetched at most once a day (see the security review). Without a rate, costs stay
  in dollars. The rate is said under the costs.
- **Not done here.** A quota reached in a conversation does not yet ask the account again at once;
  the next popover or background reading does.

