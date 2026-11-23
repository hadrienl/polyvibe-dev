# 0048 — No right column

- Status: accepted
- Date: 2026-11-21
- Issue: [#578](https://github.com/hadrienl/vibe-manager/issues/578)
- Supersedes: [0027](0027-inspector-sections.md); in part [0008](0008-workspace-layout.md) (the
  right column), [0014](0014-git-inspector.md) (the Git pane and its file list) and
  [0016](0016-session-notes.md) (where the notes are edited, and their size limit),
  [0013](0013-live-git-status.md) (the repositories watched)

## Context

The 1.3.0 milestone emptied the right column one section after the other: the activity went into
the conversation as key moments (#572), the usage into the status bar (#574), the agent with it
(#575). What was left — Git, the notes, the initial prompt and the coordination — was not used, and
the column took its width from the conversation, the terminal and the web view.

## Decisions

### The notes open from the toolbar

A **Notes** button, at the right of the toolbar after the simulators, opens the session's notes in
a popover: the same editor, its state, its links, the ticket titles. Its icon says whether there are
notes — `doc`, an empty sheet, or `doc.text`, a sheet with lines — and nothing else: no dot.

The popover **detaches** into a floating utility panel that stays above the application's windows,
is moved and resized like any window and **follows the selected session**; **Reattach**, in its title bar, brings the notes back
under the button. Which of the two the user keeps is part of the workspace layout; the panel's frame
is AppKit's, under a frame autosave name. Neither is open at launch.

**One presentation at a time, bound to one session.** The notes on screen are a single request — a
session and a placement — and AppKit's popover and panel, both owned by one controller, show
exactly that request: changing placement closes the window that showed the previous one, and lets
go of its editor, before the next opens. A window is built for its session and never retargeted:
when the panel follows the selection, a new panel — the next session's, at the same place, without
taking the keyboard — replaces the previous one. A popover closes when another session is
selected. Two editors on the same notes, or a title naming one session over another's text, cannot
happen.

**Edit Notes** (⌥⌘N) opens the editor where the user keeps it and gives it the keyboard; again, or
Escape, gives the keyboard back to the session. Every keystroke was already written a moment later;
closing the popover, closing the panel or leaving the session writes what was waiting.

### Notes have no size limit

The 64 KB of 0016 bounded the memory the search holds. Notes are written by hand and stay far below
anything that matters; the limit only ever refused a pasted log, which the user meant to keep. The
limit, its warning and its refusal are gone.

### Everything else of the column goes

The Git pane, the initial prompt, the coordination section, the column's header, the arrangement
of 0027 and the column in the layout of 0008 are removed, with their toolbar button, their commands
(Show Context ⌥⌘I, Reset Column Layout, Focus Context ⌥⌘3) and the setting that only served them,
the editor changed files open with. What other screens still read stays: the branch report of 0012
and `git status` feed the summary an agent switch hands over, and the request palette names the
branch of a session.

What only the column read goes with it. Coordinators no longer leave a trace of what they did to
their children (0039): it was written for the coordination section alone, and the `*.trace.json`
files an older build left are no longer read.

### Git is read when something needs it

Nothing watches the repositories of the session on screen any more: the monitor of 0013, its file
system events and the branch report it had read again in the background kept up a state only the
column showed. The summary of an agent switch reads the branch report and the `git status` of each
of its repositories when its sheet opens; until they arrive it is written from what the session
recorded, and the user's edits are never overwritten. A request reads the branch of its session
when it arrives in the palette, the branch recorded at creation standing in until then. Every
reading is a full one: the cache of 0012, which spared Git when the fingerprint of the references
had not moved, kept what a reading made in the background could reuse, and none is made any more.
The palette asks only for the branch's name (`git symbolic-ref`), not a whole `git status`.

A layout written by an older build still reads: the column's keys are read past and never written
again.

### Renaming without the column

The column's header was where a session the sidebar does not show — the sidebar hidden, the
session in another column, an archived one — was renamed or given another icon or theme from the
menu bar. That editing now happens in a bar above the session, shown only for as long as it lasts.

## Consequences

- The window has two columns: the sidebar and the session, with the web view beside the session.
  Only the sidebar folds in a narrow window.
- What the session did is in its conversation (key moments), what it used in its status bar, and
  its notes one click away. Git is the agent's to report, and the repository's own tools' to show.
