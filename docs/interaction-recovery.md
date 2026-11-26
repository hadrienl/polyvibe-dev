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

If the dialog cannot be read or identified (`notOnScreen`, `otherDialog`), or an answer cannot be
completed/confirmed (`interrupted`), the app opens the affected session in terminal view. It leaves
the request pending and never automatically retries input. A request already settled elsewhere is
not treated as a bug.

The same failure queues a GitHub issue in `hadrienl/polyvibe-dev`, labelled `bug`. The report includes
the request content, selected answer, planned and successfully written key groups, terminal text
before/after, timestamp, app build, OS and recovery behavior. Common credential forms (including AWS environment variables and Basic/Bearer authorization) are masked;
pasted text is omitted from key traces. The terminal text and request content are included so a
maintainer can reproduce the case without an image.

`InteractionFailureReporter` stores its outbox under `logs/interaction-failures` in the app's data
directory. It uses the installed `gh` CLI and its existing GitHub authentication. Failed submissions
are retried every minute, and pending entries are retried on app launch. Pending reports from older versions are sanitized again
before they are submitted. Each request has a stable
SHA-256 fingerprint: an existing local result or a matching GitHub issue prevents another post,
including after a crash between issue creation and saving its URL. Completed entries retain the
issue URL in their JSON file. Network/API failures do not delay the terminal fallback.

Regression case: [#558](https://github.com/hadrienl/polyvibe-dev/issues/558), Claude Code 2.1.326,
Parcourses “Liens #120”, a single-choice question with a preview taller than the option list.
