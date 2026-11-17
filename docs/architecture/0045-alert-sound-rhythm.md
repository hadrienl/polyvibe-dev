# 0045 — The alert sound's rhythm on the trackpad

- Status: accepted
- Date: 2026-11-16
- Issue: [#555](https://github.com/hadrienl/vibe-manager/issues/555)
- Builds on: [0042](0042-alert-sounds.md), whose sound it follows

## Context

The alert sound (#393) can be accompanied by a rhythm the user feels on the trackpad, played with
the sound and following it, and turned off apart from it. A trackpad's taps are felt only through
a finger resting on it; the sound plays mostly while the application is not in front.

## Decisions

### The rhythm comes from the sound

One sound, one rhythm, nothing composed apart (`AlertSoundRhythm`): a tap at the start of each
note of a voice heard, for a sound with a recipe — composed by an agent, or shipped; a tap at each
attack of the samples otherwise — imported, of macOS, or the alert sound of System Settings for
the default (`com.apple.sound.beep.sound`). An attack is a window of 20 ms, every 10 ms, at least
12 % as loud as the loudest and 1.8 times the quietest of the 60 ms before. Two taps closer than
90 ms are one, 24 at most; a sound without an attack, or unreadable, is a single tap — the default
too while the user has never picked an alert sound in System Settings, which then writes no file.
For the shipped sounds both ways agree within 20 ms, which a test holds. A recipe's rhythm is made
each time it plays (a composed sound changes); one read from samples is kept — read with the
outline the Sounds page draws, from the same samples —, the default's until System Settings names
another file. Nothing is read for it while the rhythm is off.

### When it plays: where the sound plays

`AlertSoundLibraryModel.playAlert()` plays the sound and its rhythm, the rhythm once the sound has
started: a shipped sound is made the first time it plays, a sound gone is neither heard nor felt.
When macOS plays the sound — a notification, or the one posted for the floating panel and taken
away — `SystemRequestNotifier` asks `feelAlert()` once the notification is added, unless the
sounds of the application's notifications are turned off in System Settings or the application
came to the front meanwhile (nothing is presented then); it feels what the notification plays, the
system's default until the sound in use is copied where the notifications find it. Several alerts
in a second are felt once, on a second of their own: the rhythm, on or off, never changes what is
heard. A rhythm read late never replaces one felt since — a version of a composed sound included. A
Focus keeps the notification's sound quiet without the application knowing (ADR 0042): the rhythm
still plays, accepted for now — a finger must rest on the trackpad to feel it. Selecting a sound
in Settings, or a version of a composed one, lets it be felt too. "None" is neither heard nor felt.
One switch, on by default, under the alert sound in Settings › Notifications.

### MultitouchSupport, AppKit's feedback as a fallback

Measured on 2026-11-16 by a process never in front, five taps sent, those felt counted:

| | 120 ms apart | 400 ms apart |
|---|---|---|
| `NSHapticFeedbackManager`, `.generic` | 2 | 5 (0 on an earlier pass) |
| `MTActuatorActuate(actuator, 6, 0, 0, 0)` | 5 | 5 |

`.levelChange` was not felt at all. The public API loses close taps and, now and then, a whole
rhythm: it cannot play one. `TrackpadRhythmPlayer` loads MultitouchSupport, a private framework,
by name (`dlopen`, `dlsym`), opens the actuator of every `AppleMultitouchDevice` that says
`ActuationSupported` (a Magic Mouse is a multitouch device too), and taps actuation 6. A symbol
missing or no actuator opened, and AppKit's feedback plays instead, its taps kept 400 ms apart,
while the trackpads are looked for again every 30 seconds at most: a Magic Trackpad connects after
launch. Trackpads open are kept while the registry lists the same ones, which each rhythm checks:
one plugged in is opened at the next alert. A tap refused looks for the trackpads again, once per
rhythm, the old ones let go first; refused again, AppKit's feedback plays, for 30 seconds before
the trackpads are tried again. Taps closer than what the tapper playing renders are left out, the
tapper changing mid-rhythm included. The application alone taps: a test, the scenarios included,
has no trackpad player.

What a private framework costs: the App Store would refuse it, and the application is distributed
with Developer ID; notarization looks for malware, not private symbols. A later macOS may change
it: a symbol gone falls back; an actuation that no longer taps goes unnoticed; a function whose
arguments changed could crash at the alert, which nothing guards — these functions have not
changed since 2015, and no list of macOS versions is kept to turn them off.

The actuators open on a thread of their own at launch: the first call took 1.5 s on a loaded
machine. Each rhythm runs on its own thread, which sleeps between taps, timed from the moment it
was asked, however long the trackpads take to open; a late tap keeps at least
60 % of its time to the one before, so that a busy machine never merges two taps into one. A newer
rhythm wakes the one playing, which stops before its next tap.
