# Ghost Lap

Design note and retrospective for the `claude/ghost-lap` prototype.

To try it, build with `scripts/build-app.sh` and open the preview workspace:
`open dist/RunningMan.app --args --demo`. Quit an installed RunningMan first; both
builds share a bundle identifier. The demo opens mid-race; select `studio-release`
under Runners, or watch the lanes on the Overview.

## Design note

The moment RunningMan shows most often is a job running on a runner you own. The app
knows more about that moment than the job's page on GitHub: this run's step times,
read from the runner's local logs, and how long the same job took the last twenty
times. Each concept below starts from a different quality of the app.

### Concept 1: Ghost Lap

**Inspiration.** Job history. A job's steps repeat every run, so every run is a lap of
the same circuit. Racing games and timing screens already have a language for that: a
ghost of your usual lap, sector splits, purple for a personal best.

**Before.** The runner's card shows a lane. Each step is a sector sized by its usual
duration, ending in a checkered line. A translucent ghost waits at the start.

**During.** The ghost runs the usual lap at constant speed. The live runner keeps the
ghost's pace inside a running step but never crosses into the next sector until the
step really finishes. When it does, the runner surges to the boundary on a spring, with
speed lines, and the sector is painted by its split: soft green on pace, green faster,
orange slower, purple for a personal best. A large readout gives the lead (+0:13
behind, −0:01 ahead); the caption names the step against its usual time and says
"Done about 22:12".

**After.** The tape snaps, the figure throws its arms up, a short confetti burst, and
"Finished in 1:47 · 3rd fastest of 20 runs". A failed job leaves the runner fallen in
the step that failed, its sector hatched red up to where it fell.

**The detail.** A cache miss drops you 13 seconds behind; then a record build passes the
ghost with a glint and a soft whoosh.

**Everyday clarity.** One glance answers "is this run normal, and when will it be
done". Hover or click a sector for its recent durations.

### Concept 2: Breaker Panel

**Inspiration.** RunningMan's controls encode safety rules: start, stop, enable and
login startup are separate; a busy runner is only interrupted after confirmation; "stop
when idle" waits for the job to end.

**Before.** The runner list becomes a panel of breakers, one per runner, each with a
status lamp (steady green idle, slow amber pulse busy) and small rockers for enabled
and login startup.

**During.** A busy runner's breaker sits under a hinged guard, like an aircraft switch.
Lifting it (drag up, or Space) reveals the job that would be interrupted: "Build &
publish macOS app, 1:12 of usually 1:52. Stopping now cancels it." Dragged past 60% of
its travel the guard stays open; released earlier, it snaps shut. Only an open guard
lets the breaker move. "Stop when idle" is a latch that arms with a click.

**After.** When the job ends, the latch drops by itself and the breaker trips with a
thunk; the lamp fades over 300 ms. Flipping it back starts the runner again.

**The detail.** The guard's spring hinge, and the latch releasing on its own at the end
of a job.

**Everyday clarity.** Every state is a lamp readable without hovering, rows stay 44 pt so
seven runners fit at the minimum window size, and interruption takes a deliberate second
action that maps exactly onto the existing confirmation rule.

### Concept 3: Fit Test

**Inspiration.** The queue rule: a runner takes a queued job only if it has every label
the job requires. "Why is my job still queued?" is a real question the app can answer.

**Before.** Queued jobs appear as keys whose teeth are their required labels
(self-hosted, macOS, ARM64), each label with one color and one tooth shape everywhere.
Each runner is a 24 pt lock whose pins are its labels.

**During.** Hovering or dragging a key across the runners tests the fit. Pins drop one by
one, 40 ms apart, with a tick where labels match; a missing label leaves its tooth
standing, highlighted and named ("needs gpu"). A busy runner shows the key fitting and
the lock occupied. Holding Option on a queued job tests it against every runner at once.

**After.** The queue reads "3 jobs need gpu; no runner on this Mac has it", with a way
to add the label when registering a runner.

**The detail.** The key sliding home, pins settling in sequence, and a small refusal
shake when one does not.

**Everyday clarity.** The fit is computed ahead and shown as a plain line in the queue;
keys appear only on demand.

### Committed concept: Ghost Lap

Ghost Lap animates the thing people watch most, uses only data the app already has, and
improves with use: every recorded run makes the next split more meaningful. The Breaker
Panel decorates the rarest and most consequential actions, so its best moment sits on
a path that interrupts work, and it adds ceremony to something that should be quick.
Fit Test answers a real question, but only with remote monitoring on and a queue stuck,
which is rare on a personal Mac.

The execution keeps one vocabulary:

- **Composition.** The track replaces the existing working-now card in the runner
  detail. The Overview gains "Running now", one compact lane per busy runner. Nothing
  else in the window changes.
- **Graphics.** A recessed rail with a light lower lip, sectors painted by split, a
  hatch when a step runs more than half again and 15 s past its usual time, a checkered
  finish. The figures are SF Symbols from the family of the menu bar's running man:
  run, stand, arms open, fall.
- **Color.** Status tones keep their meanings. Purple appears only for personal bests,
  borrowed from timing screens, so it never competes with a status.
- **Motion.** The runner strides at 8 frames a second, like the menu bar figure. Smooth
  frames run only during a surge, an overtake or a finish. Reduce Motion drops the bob,
  stride tilt, speed lines, glint and confetti, and redraws once a second.
- **Sound.** Synthesized, with no assets: a wood-block tick pitched by the split, a
  bell a fifth above for a personal best, filtered noise for an overtake, a three-note
  chime at the finish, a low thud for a fall. Only while RunningMan is in front, with
  a setting to turn it off.
- **Keyboard and VoiceOver.** Tab reaches the track; arrows select a step and show its
  history; Return opens the job log at that step; G switches the ghost between usual,
  best and last run; Escape clears. VoiceOver reads one adjustable element: "Lap
  against usual. 13 s behind. Step 5 of 10, Build app bundle, 33 s of usually 49 s.
  Done about 22:12."
- **Honesty.** Only successful runs make a ghost. With fewer than three, it replays the
  last run and claims no bests. A job without step logs, such as a Forgejo job, is paced
  as a whole and shows the time left. A first run says so and shows elapsed time.

### What I deliberately did not do

- No logo, mascot, hero, tagline or new window. The track replaces a card and adds two
  words of copy, "Running now".
- No percentage bar and no second-precise estimate. Step times vary; "Done about" is
  rounded to the minute.
- The runner never gets ahead of the log. Gliding through unfinished steps would look
  smoother and be false.
- No new animation in lists, the sidebar or the menu bar. One moving thing per screen.
- No leaderboards, sharing, streaks or badges. A personal best is a quiet purple.
- No sound in the background, and none that a failure could startle you with.
- Controls, runner state and stop-when-idle are unchanged. The delight sits on top of
  watching, not on top of actions that interrupt work.
- The demo keeps its laps in memory and never reaches live runners.

## Retrospective

Watching it move mattered more than any static review. A local harness, kept out of the
branch, recorded the window with ScreenCaptureKit and drove it with synthetic clicks and
keys. Contact sheets of those frames found what screenshots would not: a click selected
a step and focus then dropped it; a cleanup step after a failure carried the fallen
runner to the finish; purple personal bests appeared so often that they meant nothing
(a best now has to beat usual by 2 s, and "on pace" became a soft green).

The largest surprise was cost. Animating the Canvas with a SwiftUI timeline laid out the
whole window on every frame: 24% of a core on the runner detail, against 3.9% on main.
A nested hosting view made it worse (80%) through constraint updates. Drawing the same
Canvas into a plain AppKit view on its own timer, aligning every readout to one tick a
second and pacing the demo's log writes like live refreshes brought it to 6 to 7%. The
capture also showed a 0.9 s stall at the finish: the audio engine started on the main
thread for the chime. Sounds now play from their own queue.

A Codex review (gpt-6.1-sol) found eight real defects in edge cases, among them a
cancelled job that could celebrate a finish and a store that trusted its file. All are
fixed with regression tests. A Kimi K3 run meant to propose independent concepts
produced no output and was stopped.

Not verified: VoiceOver speech (the accessibility tree was not reachable in-process;
labels and values are set and the adjustable action is wired); hover, because
synthetic mouse moves do not reach SwiftUI hover, although click selection shows the
same inspector; how the sounds sound through speakers; and runs against real runner
logs, since everything was evaluated in demo mode. A 0.1 to 0.3 s hitch remains when a
job finishes, from the app-wide update that finishing causes; the celebration can lose
its first frames to it.
