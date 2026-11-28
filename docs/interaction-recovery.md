# Recovery from failed agent interactions

An answer submitted through a conversation card, the request palette or the companion uses the
same `AnswerAgentRequest` service. In the application composition, delivery confirmation is enabled.
After the last key, the service waits up to three seconds for the request to settle through the
activity tracker or for two readings of the terminal to show that the dialog awaiting the final key has changed.
Earlier transitions between questions and their review do not count as delivery. Moving
the highlight alone does not confirm delivery. An unreadable terminal does not confirm it either.

For Claude questions with previews, the selected option must be visibly highlighted before Return
is written. Tall previews are recognized by their frame and Notes footer, rather than the distance
between the last numbered choice and the bottom of the screen.

The terminal is read as a view shows it. A frame drawn inside a synchronized update
(`ESC[?2026h` … `ESC[?2026l`, which Claude Code uses once SwiftTerm reports the mode) is read only
once the update has ended, or a second after it began, as SwiftTerm's view stops waiting then;
until then the previous frame is what reads. Claude Code clears the screen and writes each frame
over several reads, so a frame read half drawn had lost its dialog.

If the dialog cannot be read or identified (`notOnScreen`, `otherDialog`), or an answer cannot be
completed/confirmed (`interrupted`), the app opens the affected session in terminal view. It leaves
the request pending and never automatically retries input. A request already settled elsewhere is
not treated as a bug.

If the user turned on **Settings › Notifications › Problem Reports › Report failed answers on
GitHub** (off by default), the same failure queues a **public** GitHub issue in
`hadrienl/polyvibe-dev`, labelled `bug`, opened under the user's own GitHub account. Turned off,
nothing is written to the outbox and nothing waiting in it is sent. The report includes the
request content, selected answer, planned and successfully written key groups, terminal text
before/after, timestamp, app build, OS and recovery behavior. Common credential forms (including
AWS environment variables, Basic/Bearer authorization, `*_TOKEN` variables, passwords in URLs,
GitHub, GitLab, Slack and Google keys, JWTs and private keys), the user name in `/Users/<name>`
and the user's short and full names and the Mac's own (`Alice's MacBook Pro`, `Alices-MacBook-Pro`)
wherever they show as a word (a prompt, `~name`, an author line) are masked; a typed or pasted text is reported by its length only, in the selected answer
and in key traces, and taken out of the terminal text where it shows whole, from three
characters (a `y` taken out would take every `y` of the screen with it). The terminal text and request content are included so a maintainer can reproduce the
case without an image. Each block is cut at 9,000 characters and the body at 60,000, within
GitHub's limit.

`InteractionFailureReporter` stores its outbox under `logs/interaction-failures` in the app's data
directory. It uses the installed `gh` CLI and its existing GitHub authentication. A failed
submission is retried after a minute, the delay doubling up to an hour, and pending entries are
retried on app launch. A report is given up after 10 failed attempts or 3 days, so a missing or
signed-out `gh` is not run forever; an attempt `gh` could not make for want of a network is not
counted, so a report waits out a time offline. At most 3 issues are opened in 24 hours; the
others are tried again, the delay still doubling up to an hour, and go out as the slots free.
Pending reports from older versions are sanitized again before they are submitted. Each request has a stable
SHA-256 fingerprint: an existing local result or a matching GitHub issue prevents another post,
including after a crash between issue creation and saving its URL. Completed entries retain the
issue URL in their JSON file. Network/API failures do not delay the terminal fallback.

Regression cases:

- [#558](https://github.com/hadrienl/polyvibe-dev/issues/558), Claude Code 2.1.326,
  Parcourses “Liens #120”, a single-choice question with a preview taller than the option list.
- [#580](https://github.com/hadrienl/polyvibe-dev/issues/580), Claude Code 2.1.332, a subagent's
  question answered from its card while the next frame was being drawn (`notOnScreen`).
