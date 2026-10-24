# RunningMan analysis and roadmap

A list of verified problems and shovel-ready improvements for RunningMan, meant as the starting point for future work by people or agents. It was built from a full review of `main` at `7b867cf` (2026-10-17) and from the review rounds of the pull requests that followed it.

## How to use this document

- Each item has an ID, a severity (Critical, High, Medium, Low), an effort (S: hours, M: about a day, L: several days) and a status tag: **[V]** verified in code, by reproduction or by an adversarial check; **[P]** plausible, mechanism confirmed but runtime impact not reproduced; **[I]** idea or proposal.
- "Where" points at files and line numbers on `7b867cf`; line numbers drift, so search for the named symbol.
- Before starting an item, check the [open pull requests](#open-pull-requests) table: some items are already implemented on a branch that is waiting for review. Items marked **Follow-up (PR #N)** came out of a pull request's review and apply once that pull request is merged.
- Follow AGENTS.md: one focused branch per item or small group, a regression test that fails first for bugs, light and dark screenshots for UI changes, and no changes to installed runners or registrations while testing.
- When an item lands on `main`, delete it here. When a listed pull request is closed without merging, move its items from [Appendix A](#appendix-a-items-addressed-by-open-pull-requests) back into the relevant section.

## How the review was done

- All 33 source files, the tests, scripts, workflows and docs were read in full. The app was built and captured in demo mode: all five sections in light and dark, the New Runner sheet and the menu bar panel.
- The built-in snapshot capture (then `--snapshot-dir`, now `RUNNINGMAN_SNAPSHOT_DIR`) produces blank sidebars and blank ScrollView pages (it uses `cacheDisplay`, which misses layer-backed SwiftUI content). A scratch-only patch captured the app's own windows through `CGWindowListCreateImage` with `.optionIncludingWindow` instead; that works without Screen Recording permission but is marked unavailable in the macOS 15 SDK (call it through `dlsym`, or use ScreenCaptureKit). Limits found later: the status item itself cannot be captured (its window number, 2^32, overflows the `UInt32` parameter), panel captures lose their vibrancy backdrop, and `showSettingsWindow:` does not open Settings (opening it through the app menu works).
- Performance claims were measured in release builds with synthetic data, and CPU in demo mode with `ps` CPU time over 20 s after a 6 s warm-up.
- Nine independent reviewers (services, core, app state, performance, UX, security, features, aesthetics, QA) each had an adversarial verifier, plus a completeness critic. Second opinions came from GPT-6.1 (codex) and GLM-5.3 (opencode); their claims were checked against the code before inclusion.
- Each implementation pull request then went through GLM-5.3 review rounds until two consecutive rounds had no agreed important findings.

### Measurements (release build, synthetic data)

| Operation | Cost on `7b867cf` | Status |
| --- | --- | --- |
| `RunnerHistoryStore.merge` of 2,000 unchanged jobs (every 3 s poll) | 124 ms per tick, about 4% of a core | Fixed in PR #11 (CORE-2) |
| `RunnerUsage.calculate` over 2,000 jobs, twice per Workload row per render | 5.4 ms per call, about 40 ms per render with 7 runners | Fixed in PR #18 (PERF-3): 0 ms per render, 5.5 ms rebuild on change |
| First scan of one 1 MB GitHub `_diag` log | 0.87 s (quadratic tail building, per-line redaction) | Fixed in PR #12 (LOG-5) |
| Filter and sort of 2,000 jobs, 3 to 8 times per History render | 2.5 ms per call | Fixed in PR #18 (PERF-3) |
| `SecretRedactor.redact` on 2,000 short strings | 41 ms | Patterns precompiled in PR #9 (SEC-3) |
| 100k `ISO8601DateFormatter.date(from:)` | 3.4 s | Fixed-layout parser in PR #12 (LOG-5) |
| `Job (.+) completed` regex on an 80 KB line | 14.9 s (quadratic) | Bounded in PR #12 (LOG-6) |

Toolchain note: equal-value reassignment of an `@Observable` property does not notify with Swift 6.3, but CI and releases build with Xcode 16.4 (Swift 6.1), whose Observation macro notifies on every assignment. Guard assignments with an equality check rather than relying on the toolchain.

---

## Open pull requests

Opened on 2026-10-17 and left open for maintainer review. Each went through GLM-5.3 review rounds until two consecutive rounds had no agreed important finding; each description records its rounds, what was fixed, what was declined and what was deferred here.

| PR | Branch | Covers |
| --- | --- | --- |
| [#6](https://github.com/L-K-M/RunningMan/pull/6) | `claude/release-pipeline` | REL-1 (workflow), REL-3, REL-7 (clean bundle) |
| [#7](https://github.com/L-K-M/RunningMan/pull/7) | `claude/discovery-privacy` | DISC-1, DISC-2, DISC-7 |
| [#8](https://github.com/L-K-M/RunningMan/pull/8) | `claude/nonblocking-process-executor` | PERF-6, REL-6 |
| [#9](https://github.com/L-K-M/RunningMan/pull/9) | `claude/redactor-coverage` | SEC-1, SEC-2, SEC-3 |
| [#10](https://github.com/L-K-M/RunningMan/pull/10) | `claude/service-control-fixes` | SVC-1, SVC-2, SVC-3, SVC-4 (message), SVC-6, SEC-6 |
| [#11](https://github.com/L-K-M/RunningMan/pull/11) | `claude/resilient-stores` | CORE-1, CORE-2, CORE-3 |
| [#12](https://github.com/L-K-M/RunningMan/pull/12) | `claude/log-reader-hardening` | LOG-1 to LOG-8 |
| [#13](https://github.com/L-K-M/RunningMan/pull/13) | `claude/forgejo-connection` | APP-10, SEC-4 (token cache), PERF-9 (head), clearer Forgejo HTTP errors |
| [#14](https://github.com/L-K-M/RunningMan/pull/14) | `claude/workload-accuracy` | DISC-4 (label sidecar), GitHub label fallback, organization repository selection, budget and rate-limit handling, QA-5 |
| [#15](https://github.com/L-K-M/RunningMan/pull/15) | `claude/launch-lifecycle` | APP-1, PERF-1, APP-7 |
| [#16](https://github.com/L-K-M/RunningMan/pull/16) | `claude/drain-safety` | APP-2 to APP-6, APP-16 (demo stop-after-job) |
| [#17](https://github.com/L-K-M/RunningMan/pull/17) | `claude/notifications` | FEAT-1 (core) |
| [#18](https://github.com/L-K-M/RunningMan/pull/18) | `claude/quiet-polling` | PERF-2, PERF-3, PERF-4, UX-1, UX-17, APP-9 |
| [#19](https://github.com/L-K-M/RunningMan/pull/19) | `claude/visual-refresh` (stacked on #18) | LOOK-1, LOOK-2, LOOK-4 (part), LOOK-7, UX-2 to UX-6, UX-13 to UX-16, UX-30 (part), UX-26 (runner detail), MetricTile (LOOK-3 part) |
| [#20](https://github.com/L-K-M/RunningMan/pull/20) | `claude/menu-bar` (stacked on #19) | UX-21, FEAT-2 (part), FUN-1, FUN-2, UX-22 (menu bar), LOOK-5 (menu bar header) |

Related: [#5](https://github.com/L-K-M/RunningMan/pull/5) (merged on 2026-10-17) fixed the preview smoke-test stall and made the CI preview step blocking again (REL-2, first half). PR #6's release gate relies on it.

### Merge order and conflicts

The service, core and workflow branches (#6 to #14) share some files (`AppModel.swift`, `docs/architecture.md`, `README.md`, `Discovery.swift`, `ProcessExecutor.swift`) but merge without conflicts in any order (checked with `git merge-tree`, pairwise and in sequence). The app-layer branches overlap in `AppModel.swift` with small conflicts (one to three hunks each). A conflict-light order:

1. #6 to #14 in any order. (GitHub reports every listed pull request as mergeable against `main` after #5.)
2. #15 launch-lifecycle, then #16 drain-safety (conflicts with #15 in `AppModel.swift` and `AppModelTests.swift`).
3. #18 quiet-polling (conflicts with #15 and #16 in `AppModel.swift`). It also breaks #15's `AppModelTests.swift` line `XCTAssertFalse(model.isRefreshing)` without a textual conflict, because #18 removes `isRefreshing`; change it to `isManualRefreshing` or the tests stop compiling.
4. #17 notifications (conflicts with #13, #15, #18 in `AppModel.swift` and with #11, #15 in `docs/architecture.md`). After #18, replace its `isRefreshing` capture with the coalesced pass and pass `timestamp:` to any new `JobRow`. After #15, the adaptive polling loop must refresh when `needsBackgroundRefresh` is true (it adds notifications to the automatic refresh, stop-after-job and keep-awake conditions), and the cadence should treat enabled notifications like keep-awake. Since #5, the capture directory comes from `RUNNINGMAN_SNAPSHOT_DIR`; #17's `Notifier(isActive:)` checks `CommandLine.arguments.contains("--snapshot-dir")` in `AppModel.init`, so switch it to the same source (`SnapshotCapture` is private to `RunningManApp.swift`, so it needs an internal accessor). Captures always run with `--demo`, which already disables the notifier, so the impact is small.
5. #19 visual-refresh, then #20 menu-bar. They are stacked: after #18 merges, retarget #19 to `main`; after #19 merges, retarget #20. #20 creates the model in `RunningManApp.init()` so its animator can follow it, and conflicts with #15 in `AppModel.swift` (one hunk) and `RunningManApp.swift` (two hunks): call `animator.follow(model)` on the model instance #15's app delegate owns, and keep #15's `MenuPanelScene` onAppear/onDisappear visibility hooks around #20's panel.

After merging #18, add one sentence about refresh coalescing to the polling paragraph of `docs/architecture.md` and update its app-model test list (both deferred there to avoid conflicts).

---

## Priorities

The most valuable open items, roughly in order. Items already in an open pull request are not repeated here.

1. **REL-1 remainder**: re-run the v0.2.0 release once #6 merges (#5 already has), and stop the README from linking a ZIP before it exists.
2. **APP-18 / QA-1** AppModel dependency injection. It unblocks tests for the refresh, drain, notification and error paths that several pull requests could only cover in demo mode.
3. **SVC-15** Runner services capture the GUI environment (no `LANG`, no shell PATH, `.path` overwritten on Start).
4. **APP-8** Clear saved history has almost no effect.
5. **LOG-12** Forgejo runners created by RunningMan never record a success or show a current job.
6. **SVC-9** GitHub runners supervised by a system LaunchDaemon are treated as user runners.
7. **UX-8** Creation downloads before checking permissions; retrying the same name fails.
8. **SVC-5** A Forgejo runner whose server registration is gone can never be removed.
9. **PERF-8** Workload monitoring can spend half of the user's GitHub rate limit.
10. **FEAT-4** Remote health, **FEAT-5** open at login, **FEAT-3** job detail.

---

## 1. Release, build and CI

**REL-1 remainder: README links a ZIP that does not exist; v0.2.0 never published** (Critical, S) [V]
- Where: `scripts/release.sh:69` (README rewrite), `README.md:30`.
- Problem: tag `v0.2.0` exists but `gh release list` is empty (run 38917523978 was cancelled after 30 minutes at "Render isolated preview"). `release.sh` pushed the README change before any asset existed, so the download link returns 404. PR #6 fixes the workflow ordering only.
- Fix: point the README download line at `https://github.com/L-K-M/RunningMan/releases/latest` (no per-release rewrite), or update the marker only after the upload succeeds. Then re-run the release for `v0.2.0` through `workflow_dispatch` (manual, outward-facing; tick `announce_without_preview` only if the preview still stalls and the build was checked by hand).

**REL-2 The preview smoke test stalls and captures blank pages** (High, M) [V]
- Where: `scripts/smoke-test.sh:12`, `Sources/RunningMan/RunningManApp.swift:99-145`.
- Problem: `--demo --snapshot-dir <dir>` leaves `<dir>` as a bare argument; SwiftUI then does not open the `Window` scene, so `onAppear` never starts the capture and nothing times out (swapping the argument order works). When it does run, `cacheDisplay` produces blank sidebars, blank ScrollView pages and blank dark captures, and `test -s` still passes.
- Status: PR #5 (merged) moved the directory to `RUNNINGMAN_SNAPSHOT_DIR`, bounded the script and made the CI preview step blocking again.
- Still needed: capture through the window server for the app's own window (`CGWindowListCreateImage` with `.optionIncludingWindow` via `dlsym`, or ScreenCaptureKit), a watchdog in `SnapshotCapture`, a pixel-variance check of each PNG, and captures of the New Runner sheet, Settings and the menu bar panel (all verified feasible; see the capture limits under "How the review was done"). Replace fixed sleeps with readiness signals (QA-8). Add a system-service runner and a runner in unknown state to the demo data, so captures cover those states without temporary edits.

**REL-4 Non-release builds report version 0.1.0 and poll the update manifest** (Medium, S) [V]
- Where: `scripts/build-app.sh:23-24`, `AppUpdateChecker.swift:38`.
- Problem: any dotted version counts as a release build, so local and CI builds check for updates and announce "0.2.0 available" to builds that are newer.
- Fix: write an `RMReleaseChannel` Info.plist key (`development` by default, `release` from release.yml) and require it in `isReleaseBuild`; default the local version to the latest tag instead of 0.1.0.

**REL-5 Release checks for tag shape, annotation and main ancestry only run on push events** (Low, S) [V]
- Where: `.github/workflows/release.yml:43-55`.
- Fix: run the checks for every event against `$TAG` explicitly. PR #6 adds the full fetch this needs.

**REL-7 remainder: CI gaps** (Low, S) [V]
- No warnings-as-errors (`swift build --build-tests -Xswiftc -warnings-as-errors` passes today), no shellcheck or actionlint, no `.build` cache, the full macOS pipeline runs for docs-only pushes (add `paths-ignore` for `**/*.md` and `docs/**`), and the toolchain is not pinned (`.swift-version` says 6.4 while CI uses 6.1.2).
- `build.sh --install` replaces `/Applications/RunningMan.app` without checking for a running instance with pending stop-after-job requests (warn using `pgrep -x RunningMan`).

**REL-8 Swift 6 language mode is three test fixes away** (Low, S) [V]
- Sources build cleanly in `.v6`; only `RunnerCleanupTests.compiled`, `ForgejoFixtureProtocol.lastRequest` (non-isolated statics) and one `sending` closure in `WorkloadMonitorTests` block the switch.

**REL-9 Follow-up (PR #6): no tests for the build-number branches** (Low, S) [V]
- `scripts/build-app.sh` gained an override (`RUNNINGMAN_BUILD_NUMBER`, digits without leading zeros), a shallow-clone warning and a no-git fallback to 0. Only the happy path is exercised (the release "Check bundle" step). Also decide whether a build without `.git` should fail unless `RUNNINGMAN_BUILD_NUMBER` is set, instead of silently using 0. Add a small shell test that runs the script against a temporary shallow clone and a copy without `.git`, asserting the warnings, the exit code for `abc` and `00`, and the plist value. The `cancelled` arm of the release failure condition is probably unreachable (a step `if` without a status function implies `success()`); drop it or use `always() && (...)`.

---

## 2. Runner control and services

**SVC-4 remainder: optionally restart a runner after a failed unregister** (Low, S) [I]
- Where: `RunnerServiceController.swift:179-194`, `:435-447`.
- PR #10 appends "The runner was stopped and remains stopped. Start it again to resume taking jobs." to the error. Optionally restart it with the `start()` pattern when it was running before.

**SVC-5 A Forgejo runner whose server registration is already gone can never be removed** (Medium, S) [V]
- Where: `RunnerServiceController.swift:433-447`.
- Problem: the verification GET returns 404, removal fails forever, and the local service keeps restarting at login.
- Fix: on 404 from GET or DELETE, ask for a separate confirmation ("Not found on the server. Remove the local service and keep the files?"), because 404 can also mean the token cannot see the scope. Keep 401 and 403 fatal.

**SVC-7 Stop-when-idle can still interrupt a just-claimed Forgejo job** (Low, S) [V]
- Where: `ForgejoRunnerInstaller.swift:214` (`shutdown_timeout: 0s`), `RunnerServiceController.swift:131-139`.
- Fix: `shutdown_timeout: 15s` plus an `ExitTimeOut` above it in the generated plist; re-check local busy state immediately before `bootout` when not forced.

**SVC-8 `bootout` uses the default 20 s timeout, equal to launchd's ExitTimeOut** (Low, S) [P]
- Fix: give bootout about 45 s; treat status 36 (operation in progress) as pending and poll `launchctl print` for 113.

**SVC-9 GitHub runners supervised by a system LaunchDaemon are treated as user runners** (Medium, M) [V]
- Where: `Discovery.swift:67-81` (the system scan is Forgejo-only), `RunnerServiceController.stop`.
- Problem: Stop kills the listener (the daemon respawns it and the app says "Runner stopped"); Start creates a competing LaunchAgent.
- Fix: also classify system plists with `UserName == user` whose label starts with `actions.runner.` or whose arguments reference `runsvc.sh`, `run.sh` or `bin/Runner.Listener` as `.system`. In `stop`, refuse to kill a listener whose topmost non-launchd ancestor is not the validated user service.

**SVC-10 Removing a GitHub Enterprise runner fails with "Enter a GitHub.com URL"** (Low, S) [V]
- Fix: check the host before `requireIdle` and say that removal for that host is not supported yet (`./config.sh remove` in Terminal); same message in WorkloadMonitor.

**SVC-11 `ps` matching ignores the owning user; kill re-reads the PID without an identity check** (Low, S) [V]
- Fix: `ps -axo pid=,ppid=,uid=,command=`, drop other users' entries, re-verify uid and command right before `kill`.

**SVC-12 Install steps can exceed their own timeouts** (Low, S) [P]
- `curl --max-time 300 --retry 2` under a 330 s executor deadline; `brew install` capped at 600 s although a missing bottle builds from source. Size deadlines from named constants and mention the timeout in the error.

**SVC-13 Imported scripts run without ownership checks** (Low, S) [V]
- `env.sh`, `svc.sh` and `config.sh` from imported folders run as the user without checking owner or group/world-writability (for example `/Users/Shared/runner`). Require regular files owned by the user and not writable by others, for the scripts, the runner root and `bin/`.

**SVC-14 Child processes inherit the whole app environment** (Low, S) [V]
- `GH_TOKEN` from a developer shell silently changes the gh identity used for registration; the inherited PATH is baked into Forgejo LaunchAgents. Build child environments from an allow-list (HOME, USER, LANG, LC_*, TMPDIR, proxy and CA variables) plus a fixed PATH.

**SVC-15 Runner services capture the GUI environment** (High, M) [V]
- Where: `GitHubRunnerInstaller.swift:120`, `RunnerServiceController.swift:309-311`, `:410`.
- Problem: `env.sh` writes `.path` and `.env` from RunningMan's GUI environment: no `LANG` (CocoaPods and fastlane complain) and none of the user's shell PATH additions (mise, asdf, nvm, cargo). Clicking Start on an imported runner configured from Terminal re-runs `env.sh` and silently overwrites its working `.path`.
- Fix: skip `env.sh` when `.path` already exists; on creation pass `LANG` (current locale plus `.UTF-8`) and optionally the login-shell PATH (`/bin/zsh -l -c 'printf %s "$PATH"'`, short timeout); add `LANG` to the Forgejo plist environment; show the captured PATH in the Installation card.

**SVC-16 Managed Forgejo LaunchAgent has no restart policy** (Medium, M) [P]
- A daemon that exits at login (no network yet) stays down. Add `KeepAlive {SuccessfulExit: false}` with `ThrottleInterval 30` for managed services, tied to the startup toggle, and teach `ServiceDescriptor.startsAtLogin` and `hasUncertainStartupPolicy` to recognise exactly that shape for managed labels.

**SVC-17 Managed Forgejo daemon logs grow without bound** (Low, S) [V]
- `_diag/runner.log` and `error.log` are never rotated. Rotate managed logs above 20 MB (copy the last 5 MB to `.1.log`, truncate in place; launchd writes with O_APPEND) from `stop` and at most hourly.

**SVC-18 Generated Forgejo config disables the job cache** (Low, S) [I]
- `cache: enabled: false` makes every `actions/cache` miss. Offer "Cache dependencies between jobs" (default on, `dir` inside the installation).

**SVC-19 Follow-up (PR #10): loaded-path comparison and error precedence in stop** (Low, S) [V]
- `parseLoadedServicePath(state.output) == plist.path` compares launchd's literal path with the marker's standardized path; an equivalent path spelled differently (symlinked home prefix) skips the bootout, and a KeepAlive restart then makes stop fail with "another service restarted it". Compare `resolvingSymlinksInPath()` on both sides.
- When the TERM signal fails and the process remains, the raw `kill` error is reported; the prepared "still running / another service restarted it" message may be more useful in the restart case. Decide which to show (or combine them).
- After a successful `bootout`, stop still signals the shutting-down listener directly and requires it to exit within 10 s. `launchctl bootout` normally waits for the job to exit, so this rarely matters, but a busy listener that outlasts it makes stop report failure although the service is unloaded. Skip the direct signal for the bootout branch, or report the timeout differently there.
- Relative `-c` values are resolved against the runner directory without evidence of the daemon's working directory (ps shows none), so a daemon started by hand from another directory with the same relative path can be counted as this runner (documented tradeoff).
- No test covers a Forgejo daemon (`isDaemon`) that survives a stop and produces the "still running" error.
- Stop boots out a still-loaded service when the marker is stale, but not when the marker is missing while the plist exists and launchd still runs it (marker deleted by hand); Stop then falls through to the direct kill and KeepAlive restarts the listener. Mirror the adoption validation that Start and Disable use.
- No test covers the primary success path (the signal succeeds, the first polls still see the listener, a later poll does not): `FakeExecutor.processesAfterKill` replaces the list for every later `ps`. Use a queue of process lists.
- The package-reveal fix (`revealRunner`) has no regression test. Extract an `isPackageLike(URL)` helper and test a plain folder, an `.app`-named folder and unreadable resource values (must reveal, not open).

**SVC-20 Follow-up (PR #8): executor edge cases** (Low, S) [V]
- A command that exits on its own just as its deadline fires, or just as its task is cancelled, is reported as `timedOut` or as `CancellationError` (the wrapper exited but is not yet reaped, so the signal still succeeds). The wrapper's trap exits with 143, so in `finish` treat a normal exit with any other status as the command's real result. Impact today is small (a cancelled caller may mint a second ephemeral registration token).
- `finish` returns silently when `continuation` is nil; that is unreachable today, but an `assertionFailure` would catch a future ordering mistake instead of hanging the caller.
- No test covers the wrapper's SIGKILL escalation for a command that ignores SIGTERM (`bash -c 'trap "" TERM; exec /bin/sleep 30'` under a short timeout); it is the path that keeps a timed-out registration from running on.
- The early-SIGTERM wrapper race fixed in PR #8 has no deterministic test: the executor's 0.1 s minimum deadline cannot land inside the fork window. A scratch probe sent SIGTERM after random 0 to 20 ms delays: the old wrapper orphaned 24 of 300 children, the new one 0 of 900.
- The guard that ignores a refresh cancelled during process reads (PR #8) has no AppModel test; needs APP-18. `assertProcessGroupExits` polls for 2 s; raise it to about 3 s, like `fixturePIDs`, if CI is slow.
- The 1 s SIGKILL backstop reaches only the bash wrapper; if bash has not entered its trap within the grace period on a loaded system, the command's process group is orphaned. Signal the group, or check it after the grace period.
- Optional: run read-only commands (ps, launchctl print) without the bash process-group wrapper.
- Add a latency test for the common path where both pipes reach EOF at exit (no 0.25 s drain wait).

**SVC-21 Disable installs a LaunchAgent for a Terminal-started runner** (Low, S) [V]
- Where: `RunnerServiceController.setEnabled` (`ensureService` runs before `launchctl disable`; PR #10 keeps that order).
- Problem: disabling a runner that was started from Terminal and has no login service creates one as a side effect.
- Fix: refuse Disable for a runner without a service, or explain that it installs one, instead of creating it silently.

---

## 3. App state and lifecycle

**APP-8 Clear saved history has almost no effect** (High, M) [V]
- Where: `AppModel.swift:565-576`; both log monitors keep cumulative `jobs` dictionaries.
- Problem: every scan returns every job the monitors have seen, so the whole history reappears about 3 s after clearing and `jobs.json` is rewritten; after relaunch the files are reparsed too.
- Fix: `forgetJobs()` on both monitors (keep cursors and tails), plus a persisted `clearedAt` watermark in the history store that drops older incoming jobs; adjust the confirmation copy. Also enable Clear history while a history error exists (CORE-1 follow-up).

**APP-11 One global search string filters every section** (Low, S) [V]
- Only sidebar clicks clear it; Cmd-1 to Cmd-5, cards, "View all" and menu bar rows keep the query, and `filteredRunners`/`filteredJobs` are not section-gated. An Overview query leaves "Your fleet" as an empty grid with no explanation. History search ignores the runner name shown on every row.
- Fix: per-section search state keyed by `section`; include the runner name in job search and labels in runner search; an Overview "No runners match" state.

**APP-12 Errors are reported twice and overwrite each other** (Low, M) [V]
- Sheets show errors inline and the global alert shows them again; multi-folder import, Start All and Stop All When Idle overwrite `errorMessage` per runner (each `didSet` also brings the window forward). Return results from `connectForgejo` and `create*`, show them inline, and aggregate batch failures into one message. Skip `CancellationError` in `connectForgejo`'s catch (PR #13 preserves cancellations).

**APP-13 Activity feed noise** (Low, S) [V]
- Each action records a titled event and the following refresh records "<name> · <status>"; flips to `.unknown` from transient read failures are logged and persisted. Skip status events for runners with a recent user action and debounce `.unknown` over two polls.

**APP-14 Fleet actions target unknown runners** (Low, S) [V]
- `startAll` includes `.unknown` runners (each refused with an alert); `stopAllWhenIdle` requests stops for runners whose activity cannot be verified (after PR #16 each refusal raises its own alert). Filter to `.stopped` and verifiable states and summarise skips in one message.

**APP-15 Forgetting a Forgejo server keeps it as the default and clears unrelated state** (Low, S) [V]
- Reset `defaultForgejoServer`, clear `forgejoAccount` only when no server remains, and force a workload refresh instead of clearing the whole report.

**APP-16 Small state bugs** (Low, S) [V]
- The New Runner sheet shows the previous attempt's progress or error when reopened (`creationProgress` is never reset).
- Selection jumps to the first runner the moment the selected one is missing from one refresh; History and Cleanup runner pickers keep a tag that no longer exists. (PR #18 defers the reset while a follow-up refresh is pending.)
- Keep-awake or a pending stop-after-job silently override "Refresh automatically" being off with full log and cleanup scans; a status-only refresh would do.
- Demo creation allows duplicate runner identities.
- Demo `simulate(.stop)` keeps the runner's process id, so stopped demo runners still count as online in headers and accessibility labels.
- `RunnerStatus.attention` is never produced by the controller; the "Attention" filter and orange styling only apply to `.unknown`.

**APP-17 Queue monitoring toggle also gates Forgejo busy detection** (Low, S) [V, documented design]
- With monitoring off (the default), every running Forgejo runner is `.unknown`: keep-awake ignores Forgejo jobs, stops always need the interruption confirmation, stop-after-job is refused (after PR #16; on `main` it is accepted and never completes), and the detail text says "connect API access" even when a token exists. Add a separate "Verify Forgejo runner activity" preference (default on when a token exists), or clearer copy in Settings and the detail view.

**APP-18 AppModel cannot be tested outside demo mode** (Medium, L) [V]
- All dependencies are created inline with the real home, support directory and `UserDefaults.standard`. Inject the existing internal `RunnerServiceController(homeDirectory:executor:)`, a temporary support directory, a suite `UserDefaults` and a notifier protocol. Then add tests for the paths that the pull requests could only cover in demo mode: automatic stop failure through `runAction`, drain request persistence wiring, the notification seam (a stop within 30 s of a user action posts nothing; one after it does; notified keys are trimmed at 1,000 to 500), refresh coalescing with a real pass, selection deferral after import, and clear-history.

**APP-19 Follow-up (PR #15): launch and polling edge cases** (Low, S) [V]
- The one-shot occlusion correction after launch does nothing if the window identifier is not set yet; a window restored minimized can then keep the 3 s foreground cadence. Retry the lookup for a few main-queue turns or observe `NSWindow.didMiniaturizeNotification`.
- `PollingTimer.sleep`: an old cancelled wait's epilogue can clear a newer wait's sleeper (only reachable through stop then start during teardown). Use a generation counter.
- With "Refresh automatically" off and nothing draining or kept awake, the loop still wakes every 3 s while the UI is visible, only to skip the refresh. Use the dormant interval in that case.
- `AppUpdateChecker`: inject the hourly evaluation interval and wake delay, test a second `checkIfDue`, cancel the `schedule` task and remove the wake observer in `deinit`, and test that `startAutomatic` is idempotent.
- Test the visibility wiring: the `mainWindowVisible` and `menuPanelVisible` setters calling `visibilityChanged` and waking the timer, and the window close and occlusion notifications that set them.
- No fallback opens the main window when no scene has appeared yet and no window exists (not reachable today), and `applicationShouldHandleReopen` (Dock click with no windows) is left to SwiftUI.
- The background and Low Power waits are capped at 10 s while a runner is online only because `RunnerActivityStore` counts samples at most 15 s apart. Making that gap configurable (after #11 and #15 merge) would allow longer background waits. The offline alert says "preview workspace" for every offline mode; say "demo or preview run".

**APP-20 Follow-up (PR #16): stop-after-job and quit edge cases** (Low, S) [V]
- Session-end detection in `applicationShouldTerminate` depends on `kAEQuitReason`; if a logout arrives without it, the quit warning appears modally during logout and can delay it. Treat a reason-less quit from loginwindow as session-ending, or reply with a deadline.
- "Stop All When Idle" raises one alert per refused runner, each bringing the window forward (see APP-12, APP-14).
- `DrainRequestStore` wiring in `AppModel` is untested (needs APP-18), as is the "is not running" refusal.
- A forced stop confirmed from the "Stop with activity unverified?" dialog runs even if the runner became busy while the dialog was open; the user consented to interrupting, but saw the weaker wording. Store the status the dialog was based on in `PendingRunnerAction` and re-present the busy confirmation (which offers Stop when idle) when it changed.
- The failure label shows full controller sentences in a 10 pt row, where they truncate; a short prefix such as "Auto-stop retrying:" would read better.
- A request restored from defaults for a runner that is now discovered as a system LaunchDaemon is retried until the attempt cap (the controller refuses each time). End such requests at once with one explanation, like `cancelForgejoDrainRequests`.
- The "Stopping when idle" explanation for unknown state is a tooltip only; add an accessibility hint.
- The quit warning text is evaluated once before the modal; re-evaluate before returning `.terminateNow` if accuracy matters. The alert itself was only unit-tested (its message logic) and still needs one manual check.

**APP-21 Follow-up (PR #17): notification extras** (Low, M) [I]
- Not in the first version: "stop-after-job completed" and "oldest compatible queued job waiting longer than N minutes" notifications, and clicking a job notification to open that job (the planned notification already carries `jobID`; needs FEAT-3).
- `center.add` errors are discarded; log them.
- User-action suppression starts its 30 s grace when the control command returns. A busy runner that takes longer than that to exit after a stop that reported "still running" can then trigger a false "stopped unexpectedly". Keep a runner suppressed until a refresh observes the stop the user requested.
- Dedup keys: pruning to the last 500 can evict a key whose transition can still replay (clear history, then reparse within 15 minutes), and Forgejo job keys (`forgejo-task-N`) would collide if task numbering repeats in a session. Include `startedAt` in job keys and keep keys younger than the staleness window.
- `threadIdentifier` and `userInfo` carry the runner id, which is the installation path; an opaque per-runner key would keep paths out of the notification store.
- A job the user interrupted with "Stop and interrupt" still notifies "was cancelled". Suppressing it needs the user-action times separate from the busy and stop-after-job set the app passes today (merging them would also hide genuine failures of jobs finishing during a stop-after-job).
- The fallback instance key for a stop without a previous PID is time-derived; it is unique only because refreshes are single-flight. Document that, or derive a stable key.
- Snapshot captures without `--demo` load the developer's real notification preferences; use defaults when a capture directory is set (`RUNNINGMAN_SNAPSHOT_DIR` since #5).
- Clicking a notification whose runner was removed selects a missing id until the next refresh; fall back to the first runner at once.
- End-to-end check from an installed ad-hoc-signed bundle (permission prompt, delivery, click) is still manual.

**APP-22 Follow-up (PR #18): cleanup after quiet polling** (Low, S) [V]
- `AppModel.workloadScope(for:)` is unused by views after PR #18; remove it once no branch needs it.
- The toolbar's manual-refresh rotation and the macOS 14 code path were not visually verified.
- `RefreshCoalescer`'s rule that a pass must never await `run(_:)` is enforced only by comments; a violation would hang the refresh loop for good. Compare the current task's identity with the running pass's and refuse re-entry (an `assertionFailure` plus an early return), noting that unstructured tasks inherit task-locals, so a task-local flag would misfire.
- The AppModel wiring of the coalescer (an interleaved `refresh()` and `refreshNow()`, and the selection deferral while a follow-up is pending) has no test; needs APP-18.
- While follow-up passes keep chaining, a selection pointing at a vanished runner is never repaired (each pass defers to the next). Bound the deferral to one pass or track a "selection pending" flag explicitly.
- `usage(for:)` falls back to `Date()` on a cache miss while cached entries use a window up to 60 s old, so side-by-side counts can differ by a boundary job. Use the cached computation date in the fallback.
- Running jobs use `Text(_, style: .timer)`, which ticks every second and renders `9:42` next to finished rows' `3m 4s`. Intentional per UX-17's fix; revisit if the per-second updates or the mixed format bother anyone.
- `refreshNow()` drops a second manual request while one runs instead of coalescing it like `refresh()`; route it through the coalescer and guard only the progress flag.
- Tests to add: a request arriving during a follow-up pass (exactly one more follow-up), and a drain-triggered stop inside a pass whose trailing refresh is neither dropped nor deadlocked.
- `isSameDisplayedMinute` assumes "Checked" is shown with minute precision; in locales where `.shortened` includes seconds it can be up to 59 s stale.

---

## 4. Logs, history, discovery and stores

**LOG-9 Live tail is assembled by file type, not by time** (Low, M) [V]
- All Runner_ logs first, then Worker_ logs: after launch the tail ends with an old job trace and hides newer listener errors. Merge by timestamp or show listener and worker tails separately.

**LOG-10 Duplicate jobs under synthetic ids** (Low, M) [V]
- A missed `Job request ... received` line (rollover, skipped region) gives the job a synthetic id while the Worker keys it by GUID: the job appears twice and usage double-counts. A stale `pendingID` attaches to the next job. Synthetic ids embed the raw job name. Keep `pendingID` per runner with an age bound, re-key synthetic jobs when the GUID arrives, hash the name in synthetic ids.

**LOG-11 Reconciler can present a week-old unfinished job as the current job** (Low, M) [V]
- Bound live jobs by the runner's process start or last idle observation; jobs older than that are never live.

**LOG-12 Forgejo runners created by RunningMan never record a success or show a current job** (High, M) [V]
- Where: `ForgejoRunnerInstaller.swift:206` (`log.level: info`), `ForgejoLogMonitor.swift:104-135`, `AppModel.swift:198-200`.
- Problem: success results only appear in trace logs, so successful tasks stay Unknown with no end time; tasks start as `.unknown`, and `currentJob` is chosen only from `.running` jobs. Busy Forgejo runners never show "Working now", a timer or a job name; Forgejo utilisation from history is always empty; the fleet success rate counts Forgejo failures but never successes.
- Fix: for busy Forgejo runners, show the newest unfinished tasks as current (display-only); when a runner goes from busy to idle, set `finishedAt` on its unfinished tasks and mark `completionInferred` (decoded with `decodeIfPresent`) so the UI says "finished, result not reported"; exclude provider-unknown outcomes from the success rate with a footnote. Do not raise the daemon to trace level (it logs job context).
- After PR #19, `JobOutcome.unknown` is ochre, so every such success shows an ochre "Unknown" badge in History and the Jobs tab, which makes this more visible.

**LOG-13 Follow-up (PR #12): log reader edge cases** (Low, S) [V]
- `O_NOFOLLOW` guards only the final path component: if `_diag` itself is replaced by a symlink (or a credential file is hard-linked in under a `Runner_` name), the safe open still succeeds. Compare each candidate's parent with the resolved `_diag` path, or open the directory with `O_DIRECTORY|O_NOFOLLOW` and use `openat`; document the hard-link residual risk.
- No test covers the fragment discard across scans: write an unterminated line over 128 KiB, scan, append its remainder plus a job-result line, scan again, and assert the remainder is absent from the tail while the job line is parsed.
- The Forgejo tail silently omits private-key blocks (the GitHub tail shows a marker). Complete Forgejo lines over 128 KiB are still processed (parsing only sees the 8 KiB prefix). GitHub id and result groups and `Running job: (.+)$` stay unbounded on purpose: they are anchored and linear, and bounding them would truncate captures.
- When a later listener result corrects a worker result (for example failure to cancelled), the one-time activity event keeps the first outcome. Consider a correction event.
- The bounded `received task ... of job ([^\n]{1,512}?), ...` pattern does not match a Forgejo job name longer than 512 characters, which then falls back to "Task N". If that matters, locate the literal prefix and cut at `, (be )?triggered by event:` manually, then truncate.

**DISC-3 Discovery reruns in full every poll** (Medium, M) [V]
- Lists four roots, parses every LaunchAgent and LaunchDaemon plist and probes every candidate on each tick. Cache with a cheap fingerprint (directory and marker mtimes) and force a full rescan every 60 s and after create, import and delete.

**DISC-4 remainder: cache server labels** (Low, S) [I]
- PR #14 writes a `.runningman-labels.json` sidecar at creation. Runners created before it have no sidecar and rely on default labels until the remote runner list is readable; cache the labels the workload monitor fetches.

**DISC-5 Forgejo daemons started without `--config` are not discovered** (Low, S) [V]
- `ForgejoDaemonCommand.parse` returns nil when there is no config flag. Return an invocation with an optional configuration path and require an absolute `WorkingDirectory` in that case.

**DISC-6 An unreadable descriptor makes a managed runner vanish** (Low, M) [V]
- Fall back to the LaunchAgent or LaunchDaemon service information, or list a read-only runner with a `discoveryProblem` reason, instead of dropping a runner whose daemon keeps running.

**DISC-8 Follow-up (PR #7): links and labels in discovery** (Low, S) [V]
- A runner folder link under `~/actions-runners` or `~/GitHubRunners` that points into Desktop, Documents or Downloads is followed, which can raise the privacy prompt PR #7 avoids, and the runner silently disappears if access is denied. After `resolvingSymlinksInPath()` (path-only), compare against the protected prefixes and skip with a warning instead of statting.
- LaunchAgent labels are keyed by the standardized, not symlink-resolved, directory, while dedupe is canonical: when a runner is reached both through a link and through its real path, the label can be lost if `.service` is missing. Key labels by the resolved path.
- `~/actions-runners` or `~/GitHubRunners` that are themselves links into a protected folder are still followed, and a link onto a removable volume can raise a one-time privacy prompt (accepted by design for deliberate placements such as `/Volumes/Fast`).
- The standard-folder skip is case-sensitive; on a case-sensitive volume a runner genuinely installed at `~/documents` is skipped. Document it.
- The managed root also follows links, but no test covers it, and the docs only mention the two runner folders.

**DISC-9 Follow-up (PR #14): secret-shaped labels** (Low, S) [V]
- A label such as `token=abc123` passes validation and is stored verbatim in the sidecar, but discovery redacts it to `token=[REDACTED]`, so jobs needing that label never match until the remote runner list replaces it. Reject secret-shaped labels at creation, or drop (not mangle) redacted sidecar labels so the runner shows "labels unknown".

**DISC-10 Follow-up (PR #14): workload inference details** (Low, S) [V]
- `inferredGitHubLabels` uses the compile-time architecture (`#if arch(arm64)`); an x86_64 slice under Rosetta infers `X64` for a hand-registered ARM64 runner. Resolve the host architecture at runtime (`sysctl hw.optional.arm64`).
- The tightened rate-limit matcher only recognises "API rate limit exceeded", "secondary rate limit" and HTTP 429; a differently worded 403 rate limit would be treated as a permission problem. Also treat "rate limit" text with HTTP 403 as a rate limit.
- The label sidecar is written atomically with the default umask and then chmod 0600 (labels are not secret, but redaction treats some as token-like); create it with mode 0600 instead. The read path checks for symlinks before opening and accepts hard links; use `O_NOFOLLOW` plus `fstat` if it ever matters.
- Inferred default labels can also over-include: a manually registered runner with `--no-default-labels` gets `self-hosted, macOS, ARM64`, so jobs it can never claim appear in its compatible list (counts stay unknown). Say so in the message, or add defaults only when the folder shows RunningMan provenance.
- `httpStatus` matches any `HTTP nnn` in gh's stderr, so a name containing "HTTP 403" can produce the admin-access hint and a 300 s backoff. Parse only gh's trailing `(HTTP nnn)` and add a negative test.
- Untested: the repository-scope 403 message, a runner-list failure that is neither 403 nor a stop, and the X64 default set (only exercised on Intel hosts).
- A sidecar keeps winning after the user re-registers the folder by hand with other labels. Record `agentId` in the sidecar and ignore it when it no longer matches `.runner`.

**CORE-4 Follow-up (PR #11): store recovery gaps** (Low, S) [V]
- `takeRecoveryNotice()` is read only after the startup load. If that load fails for a transient reason and recovery happens later inside `merge()`, history is moved aside with no notice. Also take the notice after a refresh, and test the wiring (needs APP-18).
- An unreadable or oversized `observed-activity.json` is moved aside silently; utilisation resets with no notice (history recovery does show one). Mirror `takeRecoveryNotice()` or document the asymmetry.
- `JobOutcome` decodes unknown strings as `.unknown`, but `null` or a missing key still drops the record. Decode with `try?` and fall back to `.unknown`.
- Tests to add: a read error (not bad content) throws and does not move the file aside; the `-2` collision suffix in `copyAside`; load-time dedupe by id.
- If rewriting the recovered file keeps failing (disk full), each launch copies the original aside again. Skip the copy when a newer copy exists, or cap the copies.
- A large backward clock correction (clock a year ahead, then corrected) pauses observation of a runner until the clock passes the saved coverage, because future-dated segments are never pruned. Drop or clamp segments dated after the current time when the gap is large.

**CLEAN-1 Cleanup scan picks "newest 100" from an arbitrary 2,000 entries** (Low, S) [V]
- Keep enumerating metadata past 2,000 (cheap) while keeping a bounded set of the 100 newest.

**CLEAN-2 Stale "Awaiting cleanup" receipts never resolve** (Medium, M) [V]
- A pending receipt from a killed job says "may still be running" forever; failed cleanups drop out of "Needs attention" after 24 hours although the workspace is still on disk. Stat reported paths read-only (a directory under the work directory, not a symlink); show "Abandoned" for pending receipts older than about 6 hours whose runner is idle; count leftovers regardless of age; "Show in Finder" for leftovers.

**UPD-1 Update fetch ignores cancellation and has no size limit** (Low, S) [V]
- Use `session.data(for:)` and cap the manifest at 64 KiB.

**ACT-1 `activity.json` loading is unbounded; every event rewrites the file** (Medium, S) [V]
- Bound bytes before decoding; batch events per refresh and write only when the retained set changed (each launch re-emits historical job events and rewrites about 100 KB per event).

---

## 5. Security and safety hardening

**SEC-4 remainder: Keychain prompts after an update** (Medium, M) [V mechanism, P prompts]
- Ad-hoc signatures tie the login-keychain ACL to the code hash. PR #13 caches tokens per origin and shares one store. Still needed: non-interactive reads for background work (`kSecUseAuthenticationUIFail`), and one "Keychain access needs approval" state that pauses background polling.
- Follow-up (PR #13): after a 401 the cache is dropped, the next request re-reads the same revoked token from the Keychain, gets another 401, and repeats (each re-read can prompt on an ad-hoc build). Add a short cooldown per origin after a 401, or re-read only on the next user-initiated Connect.

**SEC-5 Forgejo removal trusts the local descriptor's id and scope** (Low, S) [V]
- A tampered 0600 descriptor can steer DELETE at another runner (confused deputy; an attacker already runs as the user). Decode the GET body and require the id and raw name to match, and check that the registration path is consistent with the remote URL.

**SEC-7 `openServerLink` trusts any host a runner record mentions** (Low, S) [V]
- Job run URLs are built from the worker context's `server_url`; any runner's remote host joins the allow-list. Scope the allow-list per job (a job may only open its own runner's host).

**SEC-8 Minor hardening** (Low, S)
- History and activity files are written with the default umask and then chmod 0600; write with the final mode.
- Forgejo tokens linger in sheet `@State` after a failed connect; clear them in all outcomes.
- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` has no effect on the file-based login keychain an ad-hoc app uses; remove it or comment it.

**SEC-9 Follow-up (PR #9): redaction gaps** (Low, S) [V]
- Diagnostics export redacts an explicit field list and then runs only the provider token rules over the encoded JSON. Paths, ids, labels in `serviceLabel`/`version` and log keys are therefore covered for token literals but not for `token=` or `user:password@` shapes (realistic only for user-chosen folder names). Running the full `SecretRedactor.redact` on those fields before encoding is safe (the encoder re-escapes the result); redact `runnerID` consistently everywhere it appears, since it is derived from the directory, and route every exported URL field through `exportable`.
- The prose bearer rule requires a digit or symbol in the token, so a letters-only token after a bare "bearer" survives (header forms are still caught). Optionally require 20 or more characters for the all-letter case.
- `exportable` drops a URL whose redaction would change it (for example a `?sig=` query) instead of exporting the redacted form; export `URL(string: SecretRedactor.redact(url.absoluteString))` and test a `?token=` case.
- A quoted value with no closing quote (cut off by the byte-bounded tail, for example `RUNNER_TOKEN="abc`) is not redacted. Let the quoted branch also end at the end of input, and update the `export RUNNER_TOKEN="` expectation in `AppModelTests`.
- Still unmatched: multi-word unquoted values (`password: correct horse battery` keeps every word after the first), JSON escaped inside a string (`\"token\":\"x\"`), and camelCase generic names (`appSecret`, `stripeApiKey`; matching them would also redact `isSecret: true` flags).
- The redactor timing test takes one sample with a 1 s bound; average several runs if it flakes on CI.

**SEC-10 Follow-up (PR #13): Forgejo connection details** (Low, S) [V]
- `connect(serverURL:candidateToken:savingTo:)` accepts any `ForgejoTokenSaving`, independent of the store behind the installer's client; a refactor could save to a different store than the one monitoring reads. Take the shared `ForgejoConnectionStore` so the pairing is enforced by type.
- Every 3xx, including 304 and 300 without `Location`, gets the "server redirected" advice; fall back to the generic status message when there is no redirect target.
- `invalidateToken` ignores invalid origins silently; add a debug assertion. `EphemeralForgejoToken` returning nil for another origin is untested.
- The non-macOS branch buffers the whole body before checking its size (not shipped, macOS-only builds).
- Long Forgejo error copy can be truncated in the New Runner sheet's three-line status; raise the limit or use the error surface.

Refuted for the record: delete always forcing after its explicit confirmation is consistent with AGENTS.md; the Forgejo token file is written into a freshly created 0700 directory, so the non-exclusive create is not exploitable; release ZIPs already ship `.sha256` files.

---

## 6. Performance and stutter

**PERF-1 remainder: thermal pressure** (Low, S) [I]
- PR #15's `PollingCadence` doubles the wait in Low Power Mode only. The review also proposed lengthening it under thermal pressure: read `ProcessInfo.thermalState` and treat `.serious` or worse like Low Power Mode (never for pending stop-after-job requests), observing `thermalStateDidChangeNotification`.

**PERF-5 The live log is one 64 KB selectable `Text`** (Medium, L) [V]
- Fully re-laid out on every change, re-split up to three times per render, scrolled to the end on every tick, and the selection is lost at the 64 KB trim. Use an `NSTextView`-backed log view with incremental appends, non-contiguous layout, follow-only-when-at-bottom and a wrap toggle.

**PERF-7 Per-tick subprocess and file work that rarely changes** (Low, M) [V]
- `launchctl print-disabled` every tick (cache 30 s, bypass on mutating paths); one sequential `launchctl print` per system daemon (run concurrently); every LaunchAgent plist re-read and validated per runner per tick (cache by mtime, size and inode for the snapshot path only); unchanged logs re-opened and stat'ed per tick (skip when size, mtime and identity match); cleanup receipts re-enumerated per tick (cache by directory mtime); `RunnerProcesses` rebuilds prefix strings per entry and walks descendants with repeated filters (index children once).

**PERF-8 Workload monitoring can spend half of the user's GitHub rate limit** (Medium, M) [V]
- Up to 25 `gh` processes per repository per minute (5 status queries plus up to 20 job lists), about 2,400 requests per hour in the worst case. Cache the runner list for 10 minutes, cache job lists per run keyed by `updated_at`, consider conditional requests (`gh api --include -H 'If-None-Match: ...'`; 304s do not count, but verify gh's exit status on 304 first), back off near `X-RateLimit-Remaining`, and poll queues less often when the Workload page and menu are hidden. When the budget runs out, rotate which organization repositories are checked first (PR #14 reports the stop accurately but always starts with the same repositories).

**PERF-9 remainder: byte-wise Forgejo body collection** (Low, S) [V]
- PR #13 decides from the response head and preallocates the buffer, but the body is still read through `URLSession.AsyncBytes` byte iteration. A delegate-based chunk collector removes the remaining overhead. Release build with the test fixture: 1 MiB round trip 0.132 s before PR #13 and 0.097 s after; refusing an undeclared 8 MiB + 1 stream 0.981 s before and 0.701 s after.

**PERF-10 Refresh pipeline is serialized** (Low, S) [V]
- Log and cleanup scans wait for the subprocess snapshot although they only need the discovered runners; reconciliation and warning redaction run on the main actor; activity metrics take one actor hop per runner. Start scans with `async let` before awaiting snapshots; reconcile off the main actor; a bulk metrics call.

**PERF-11 Activity store work per tick** (Low, M) [V]
- Prunes and re-sorts up to 5,000 segments per tick and checkpoints every 30 s whenever anything runs. Group segments per runner, prune only when needed, keep a bounded checkpoint interval.

---

## 7. UX and layout

UX-1 and UX-17 are in PR #18; UX-2 to UX-6, UX-13 to UX-16 and most of UX-30 in PR #19; UX-21 and the menu bar part of UX-22 in PR #20.

**UX-7 New Runner always starts the runner, fixes the directory and pre-fills a personal label** (Medium, M) [V]
- Add "Start the runner now", default labels to empty for GitHub (`local-mac-release` is the author's own label), suggest a name from the host name, and optionally let the user choose the parent directory (still refusing non-empty destinations).

**UX-8 Creation downloads before checking permissions; retrying the same name fails** (High, M) [V]
- GitHub downloads and publishes the 100 to 200 MB runner before the first call that proves admin rights; on failure the folder is preserved and the fixed `Runners/<name>` path blocks a retry with a generic error. Request the registration token (or list runners) first; pick a non-colliding directory; offer to move an incomplete `.runningman-owned` folder without `.runner` to the Trash after confirmation.

**UX-9 Removal never offers Move to Trash; imported folders can never be forgotten** (Medium, M) [V]
- The controller supports `trashFiles`, but the app hard-codes `false`, leaving gigabytes of `_work` in Application Support. Add an opt-in "Also move the installation folder to Trash" for RunningMan-owned folders, "Stop tracking" for imported folders, and a tracked-folders list in Settings.

**UX-10 Custom sidebar instead of a List** (Medium, M) [V]
- No arrow keys, no system selection style or inactive dimming, and it ignores the sidebar icon size setting. Use `List(selection:)` with `.listStyle(.sidebar)`, with branding and footer in safe-area insets.

**UX-11 Runner list has no keyboard navigation, multi-selection or hover feedback** (Medium, M) [V]
- `List(selection:)`, a batch bar for multi-selection (see FEAT-10), a hover state.

**UX-12 Switching runners resets the detail tab** (Medium, S) [V]
- `RunnerDetailView` is recreated with `.id(snapshot.id)` and owns its tab. Keep a `RunnerDetailTab` enum in `@SceneStorage` and pass a binding.

**UX-18 Background errors bring the window forward** (Medium, M) [V]
- PR #16 makes automatic stop-after-job failures quiet. Other background paths (refresh warnings, workload errors) should also become activity events, warnings or notifications instead of the alert that activates the window.

**UX-19 Settings actions open dialogs in the main window** (Medium, M) [V]
- Clear history and Connect Forgejo raise their dialog or sheet in the main window, which comes forward. Host them in Settings.

**UX-20 Confirmation wording** (Medium, S) [V]
- "Delete runner..." (trash icon) opens "Remove ...? Files are kept". The interrupt dialog says "Choose Stop when idle" without offering it. Rename to "Unregister Runner...", add the safe alternative button, and give alerts a contextual title instead of "RunningMan".

**UX-22 Four words for the same states** (Low, S) [V]
- "building", "running · working", "Running a job", "Runners running", "Busy runners". Use Online (process alive), Busy (has a job), Offline. PR #20 applies this to the menu bar and PR #19 renames "Runners running" to "Runners online"; the main window's "Running a job" and "Busy runners" remain.

**UX-23 Live log usability** (Medium, M) [V]
- No wrapping, Follow pulls the view down every tick even after scrolling up, no match highlighting, no "Show log file". See PERF-5.

**UX-24 History and Cleanup header controls** (Low, S) [V]
- The runner picker is labelled on Cleanup but not History, there are three different right edges, and the filter goes stale after a runner disappears. One shared `RunnerFilterPicker` that resets invalid selections.

**UX-25 Workload header** (Low, S) [V]
- Two stacked small buttons; "Connect Forgejo..." always shown; Cmd-R does not refresh queues. One refresh path, a server status pill, and Connect only when a Forgejo runner exists and no server is connected.

**UX-26 remainder: Workload page rows at narrow widths** (Low, S) [V]
- PR #19 fixes the clipped runner detail below about 1200 pt (the detail's Workload row shares its width and hides the repeated name). The Workload page's own rows still use about 557 pt of fixed columns (`RunnerWorkloadRow`, `WorkloadView.swift`); add a `ViewThatFits` 2x2 fallback there. At about 1000 pt the whole window overflows because of the sidebar, list and detail minimum widths; lower those or raise the window's minimum width.

**UX-27 Overview fleet cards** (Medium, S) [V]
- "Started manually" shown for stopped and disabled runners; the 7th runner is silently hidden; alphabetical order can hide busy or failing runners. Priority order, "View all 9", accurate footer text.

**UX-28 Overview warnings** (Low, S) [V]
- Only three are shown and the rest are "in exported diagnostics". Add a disclosure for the rest, copy buttons and "Show runner" links.

**UX-29 The same arrow means "go to page" and "open in browser"** (Low, S) [V]
- Use `arrow.up.right.square` only for external links, "View all" links for internal navigation, and add an activity "View all".

**UX-30 remainder: fixed type sizes** (Low, M) [V]
- PR #19 brings every status and accent text colour to 4.5:1, replaces `.tertiary` for information and raises 8 to 9 pt text to 10 to 11 pt. About 160 fixed `.system(size:)` calls remain (172 on `main`), 48 of them at 10 pt, and they ignore text size preferences. Keep an 11 pt floor for informative text; the "Stopping when idle" label is still orange at 10 pt. Move to a type scale (LOOK-3).

**UX-31 VoiceOver** (Medium, S) [V]
- On `main` there are six accessibility modifiers in the whole app: icon-only buttons have no labels, metric cards read as four stops and menu bar dots are unlabelled. PR #19 combines metric tiles and labels status and outcome badges and runner glyphs; PR #20 labels the menu bar gear, refresh button and status symbols. Still unlabelled after both: the toolbar refresh, fleet actions, runner actions, copy and external-link buttons.

**UX-32 No commands for the selected runner; duplicate key equivalents** (Medium, M) [V]
- Add Start, Stop, Stop When Idle, Show Live Log, Show in Finder and Unregister for the focused runner via `FocusedValue`; remove `.keyboardShortcut` from toolbar buttons that duplicate menu commands.

**UX-33 Empty states and always-on explainers** (Low, S) [V]
- The Runners empty state has no actions; every runner shows a Release cleanup card even when cleanup reporting was never set up; long static explainers on Cleanup and Workload (move them into info popovers).

**UX-34 Overview says "refreshed automatically" when it is off** (Low, S) [V]
- Where: `OverviewView.swift:42` (the "Your fleet" subtitle, still present after PR #19).
- Fix: say that refresh is off when `model.refreshAutomatically` is false. (The duplicate last-checked pill is removed in PR #19.)

**UX-35 Enabled and Start-at-login switches snap back, then jump again** (Medium, S) [V]
- The binding setter starts an async action without changing the observed value. Track pending toggle values in the model and show an inline spinner; revert on error.

**UX-36 Detail header actions** (Low, M) [V]
- An asymmetric "Stop" against a prominent "Start runner", no Restart, and the actions menu far away under the search field. A control group with Stop When Idle, Stop or Start, and the menu; a Restart action that keeps the startup policy.

**UX-37 Small polish** (Low, S) [V]
- The sparkles symbol means both Cleanup and demo mode; `externaldrive.badge.checkmark` reads as a car at 13 pt.
- Settings is fixed at 560x660.
- (The duplicate Overview "Updated" pill is removed in PR #19.)

**UX-38 One definition of "needs attention"** (Low, S) [V]
- PR #20 adds `RunnerSnapshot.needsAttention`, which does not count a running Forgejo daemon whose activity is only unverified. The Overview summary and the Runners "Attention" filter still count every `.unknown` runner, so with server monitoring off the Overview can say "1 needs attention" while the menu bar shows none. Reuse the property there.
- `needsAttention` treats every `.unknown` Forgejo runner with a process id as merely unverified, but `.unknown` also comes from failed local reads (`ps` or `launchctl` errors, timeouts). Carry the controller's existing `activityUnverified` flag on `RunnerSnapshot` and let local read failures count as needing attention.

**UX-39 Follow-ups from the visual and menu bar pull requests** (Low, S) [V]
- A runner card for a system service that needs attention can crowd its top row at the 250 pt minimum card width.
- The menu bar panel's refresh button does not animate during a manual refresh (`RefreshSymbol` is private to `ContentView.swift`).
- The README's menu bar bullet does not describe the new figure, summary capsules or priority order.
- The menu bar label relies on each frame's `accessibilityDescription` because SwiftUI ignored `.accessibilityLabel` on the `MenuBarExtra` label; verify with VoiceOver, and check whether swapping frames 3.5 to 6 times a second makes VoiceOver re-announce while the item has focus (if so, pause the ticker while VoiceOver runs).
- Not visually verified in #19 and #20: the Settings window tint, the New Runner sheet at the default 820 pt window height, the macOS 14 code paths, menu row hover highlights, the gear menu's Settings item and the live status-item animation.
- A Reduce Motion change while the figure runs (the notification path) is untested, and `WrappingRow` measures with `proposal.width ?? .infinity` but wraps at `bounds.width`; document or assert that invariant.
- An unbundled debug build shows a generic icon in the menu bar panel header (`NSApp.applicationIconImage`); the bundled app shows its own.
- Any repeating animation must be measured: PR #19's first version spun every busy symbol and cost 25% of a core; it now bounces once per change.
- The busy bounce also fires when work ends (any change of the value); pass a value that changes only on the rising edge if it should mean "started".
- A row that is already busy when it appears (scrolled into view, window reopened, launch during a job) never bounces; trigger the one-shot bounce on appear for such rows if the bounce should mark busy state.
- `StatusTone.text` and `fill` fall back to building a new dynamic colour when the cache misses (unreachable today); separately built dynamic colours never compare equal, so a future cache bug would cause spurious redraws. Make the cache non-optional or assert, and test that repeated access returns the cached instance.
- The contrast test checks text on the 12% tint, but `RunnerGlyph` uses 14% fill with a 22% stroke, the System badge 10% and the hollow disabled stroke 45%. Test the opacities actually used, or share them as `StatusTone` constants.

---

## 8. Visual design, aesthetics and theming

LOOK-1, LOOK-2 and LOOK-7 are in PR #19.

**LOOK-3 remainder: type, spacing and radius scale** (Low, L) [V]
- PR #19 adds `DesignSystem.swift` with colour tokens, `cardStyle()`, `StatusTone`, `MetricTile` (replacing three near-duplicate tiles) and `RunnerGlyph`. Still ad hoc: font sizes (about 170 fixed calls), spacing and four corner radii. Add a type scale, spacing constants and radii, and migrate one screen at a time with light and dark screenshots.

**LOOK-4 remainder: motion for busy state** (Low, S) [V]
- PR #19 adds numeric content transitions, snappy status changes and a one-shot bounce when a symbol turns busy, all off with Reduce Motion. A continuously rotating busy symbol cost 25% of a core with two busy runners (measured), so it was dropped. If continuous busy motion is wanted, animate a single element (for example the selected runner's header) and measure CPU before and after. Key any animation on status values, not on whole snapshot arrays, which change every poll.

**LOOK-5 The in-app brand ignores the app icon** (Low, S) [I]
- The icon is a warm amber, magenta and midnight-navy 1980s action poster; the UI is cool indigo with a generic SF Symbol wordmark. PR #20 shows `NSApp.applicationIconImage` in the menu bar panel header. Do the same in the sidebar and Settings, and add a subtle amber-magenta-indigo brand gradient on two or three decorative elements only (never on small text).

**LOOK-6 Accent themes** (Low, M) [I]
- Once tokens exist: Indigo (default), VHS Sunset (from the icon palette), Graphite, System accent. Status colours stay fixed. Demo mode must not persist the choice.

**LOOK-8 Update banner blends into the page** (Low, S) [V]
- An accent-tinted background, a prominent "View Release", and Skip and Later as secondary actions.

**LOOK-9 Charts** (Medium, M) [I]
- A 24-hour activity ribbon per runner from the activity store's segments (busy, idle, unobserved shown as gaps) instead of a single filled capsule; sparklines in Overview tiles; an estimate ring for the current job (FUN-7). Swift Charts ships with macOS 14.

**LOOK-10 Empty states** (Low, S) [I]
- A tinted symbol tile, a one-shot bounce and actions in every empty state.

**LOOK-11 Note on the app icon** (Low) [I]
- The artwork closely evokes a well-known actor's likeness from a 1987 film poster. Consider the exposure before wide distribution; the in-app UI should use the palette only, never the face.

---

## 9. Missing features

FEAT-1 (notifications) is in PR #17; its remaining extras are APP-21.

**FEAT-2 remainder: estimate bar in the menu bar** (Medium, S) [I]
- PR #20 adds elapsed timers, priority order, an overflow row and attention, queue and stop-after-job capsules. Still missing: an estimate bar per busy runner from the median of previous successful runs of the same job (median of the last 10, at least 3 samples). Build it on FEAT-17's shared statistics.

**FEAT-3 Job detail** (High, M) [I]
- Clicking a job opens timings, typical duration and delta, the last 10 runs (Swift Charts), a redacted log excerpt from the job's time window (from the existing 64 KB tail only; never read more raw files), Open run, Copy link and Show runner.
- The runner detail's Job log tab now reads `_diag/pages` for the most recent job's step output (see docs/architecture.md). This intentionally goes beyond "never read more raw files" for that one view; job detail can reuse that log for the most recent job instead of the diagnostic tail.

**FEAT-4 Remote health** (High, S) [I]
- The workload monitor already downloads the runner list (`status` online/offline, `busy`). Show "Server sees: Offline" and an attention badge when a locally running runner is offline for two consecutive reads. Annotation only; never change local status from remote data alone.

**FEAT-5 Open RunningMan at login and menu-bar-only mode** (High, M) [I]
- An `SMAppService.mainApp` toggle (separate from per-runner login startup) and a "Show in Dock" toggle that switches the activation policy. Needs APP-1 (PR #15).

**FEAT-6 First-run setup checklist** (High, M) [I]
- gh installed and signed in, Homebrew (a hard blocker for Forgejo), Node.js (existence only), LaunchAgents writable, Forgejo connection; shown in the empty state, in Settings and inline in New Runner.

**FEAT-7 Crash-loop detection from `launchctl list`'s last exit status** (Medium, S) [I]
- `parseServices` discards the exit status. Show "Exited with status 1 at 12:40"; flag "keeps crashing" after three non-signal, non-zero exits in 5 minutes.

**FEAT-8 Runner version awareness** (Medium, M) [I]
- Compare with the latest `actions/runner` release (the same gh call the installer uses). Forgejo binaries are copied into each installation, so `brew upgrade` does not update them; offer "Reinstall binary" or document it. Never auto-update.

**FEAT-9 Workspace disk usage** (Medium, M) [I]
- A bounded, read-only size scan of each work directory by top-level child (no symlink following), "Reveal" for the largest entries, never delete.

**FEAT-10 Multi-select bulk actions with one aggregated confirmation** (Medium, M) [I]
- Calling `perform` in a loop is unsafe (a second busy runner overwrites the first confirmation). Partition into safe, needs-confirmation and system-domain; one confirmation for the busy ones, re-read at confirm time. Pairs with UX-11.

**FEAT-11 `runningman://` URL scheme with a deliberately limited verb set** (Medium, S) [I]
- `open`, `start`, `drain` (stop when idle), `section/...`; no stop-now, disable, delete or force. Automatic refusals become activity warnings, not modals.

**FEAT-12 Quiet hours** (Medium, M) [I]
- A user-defined schedule that requests stop-after-job for opted-in runners at night and restarts only the ones the schedule stopped. Never changes login policy, never forces.

**FEAT-13 Battery, Low Power Mode and thermal awareness** (Medium, M) [I]
- Stop opted-in runners after their jobs on battery or in Low Power Mode and resume on power; a thermal pause only with hysteresis (builds routinely push laptops to `.serious`).

**FEAT-14 Export filtered history as CSV** (Medium, S) [I]
- RFC 4180 quoting, ISO 8601 UTC, formula-injection protection, redacted fields.

**FEAT-15 Command palette (Cmd-K)** (Medium, M) [I]
- Fuzzy commands built from live state; every runner action goes through `perform`; no delete; exclude system-domain runners.

**FEAT-16 Re-run failed jobs or cancel a run from job detail** (Medium, M) [I]
- `gh api -X POST repos/{repo}/actions/runs/{id}/rerun-failed-jobs` and `.../cancel`, validated argv, a confirmation with an appropriate (non-destructive) role for Re-run. Needs FEAT-3.

**FEAT-17 Build-time trends and slowdown detection** (Medium, M) [I]
- One shared Core `JobStatistics` (job key, trailing median, `isSlow`) for the menu bar estimate, job detail and a History "slower than usual" chip.

**FEAT-18 Edit GitHub runner labels in place** (Medium, M) [I]
- `gh api -X PUT .../actions/runners/{id}/labels -f 'labels[]=a'`, then update the label sidecar from PR #14. Forgejo excluded (labels live in credential-bearing files).

**FEAT-19 Manual Forgejo registration (UUID and token) is implemented but unreachable** (Low, S) [V]
- Add a "Paste runner UUID and token" mode to the New Runner sheet for servers or policies that forbid runner-management API tokens.

**FEAT-20 Organization runner groups and update policy** (Low, M) [I]
- A runner group picker (`orgs/<org>/actions/runner-groups`) and a "Let the runner update itself" toggle (`--disableupdate`).

**FEAT-21 Forgejo servers under a URL subpath** (Low, M) [I]
- A `ForgejoServer` value with origin plus normalised base path; redirects must stay under it.

**FEAT-22 Full activity timeline** (Low, S) [I]
- 500 events are stored, five are visible. A sheet from the Activity card with kind and runner filters (an extra sidebar section would shift the Cmd-number shortcuts and snapshot captures).

**FEAT-23 Sidebar and Dock badges** (Low, S) [I]
- Attention (only verifiable unknown states), compatible queue, running jobs; a Dock badge with the busy count.

**FEAT-24 Live log upgrades** (Medium, M) [I]
- Colour-coded ERR and WARN, an errors-only toggle, next and previous error, reveal the diagnostic folder. Build on PERF-5's `NSTextView` to keep multi-line selection.

**FEAT-25 release-job.swift drops Git LFS content and submodules** (Low, S) [V]
- Fail `prepare` explicitly when `.gitmodules` or `filter=lfs` is present (opt-in support later), and document it.

Desktop widgets now ship as a SwiftPM-built extension embedded by `build-app.sh`, with `runningman://` links to Overview and Job history. Spotlight, Quick Look and App Intents remain deferred. An in-app updater would need a manifest contract change in the canonical ajila-tg-app-updates script first and must deliberately set the quarantine attribute.

---

## 10. Delightful and quirky ideas

FUN-1 (a running figure that runs) and FUN-2 (menu bar states with personality) are in PR #20.

**FUN-3 Victory pose** (Low, S) [I]
- When a job longer than 10 minutes succeeds while the window is in front: a 1.2 s accent and teal confetti burst and a toast with the job name and duration; the menu bar figure raises its arms for a few seconds. Reduce Motion shows only the toast.

**FUN-4 Personal bests and green streaks** (Low, S) [I]
- Fastest successful run per job (a trophy on the row that set it, "PB" in job detail), consecutive green jobs and green days on the Overview success tile; a broken streak highlights the first failure after a long green run.

**FUN-5 Mission report** (Low, S) [I]
- An optional daily or weekly recap notification and Overview card: jobs run, success rate, total build time, longest job, busiest runner, new personal bests, cleanup bytes reclaimed. Builds on PR #17's notifier.

**FUN-6 Game-show scoreboard** (Low, S) [I]
- A compact scoreboard strip on Overview in the poster palette: today's jobs survived (succeeded) against eliminated (failed), the current streak, the fastest lap.

**FUN-7 Estimate ring for the current job** (Low, S) [I]
- "About 2 min left (typical 4m 59s)" in the Working Now card; "running longer than usual" past twice the median; phrased as an estimate. Shares FEAT-17's statistics.

**FUN-8 Activity heatmap** (Medium, M) [I]
- A 7x24 hour-of-week heatmap per runner from job history, labelled "no data" where history does not reach.

---

## 11. Tests, tooling and docs

**QA-1 AppModel refresh, drain and error paths are untested** (Medium, L) [V]: see APP-18.
**QA-2 Large-log, budget, rotation and oversized-line paths** (Low, S) [V]: PR #12 adds tests for large first-seen logs, budgets, long lines and key mode; log rotation (identity change mid-scan) is still untested.
**QA-3 WorkloadMonitor uses the wall clock** (Low, M) [V]: inject `now` and test windows, shared GitHub pauses, Retry-After and per-origin backoff.
**QA-4 AppUpdateChecker, ForgejoAPIClient error paths and the Keychain store** (Low, M) [V]: PR #13 covers the Forgejo client's error paths, PR #15 adds AppUpdateChecker tests and PR #8 adds the missing `truncated` assertion to the executor output-limit test; the Keychain store still has no tests.
**QA-6 README screenshots predate the Cleanup section** (Low, S) [V]: regenerate with a script once capture works (REL-2).
**QA-7 No CHANGELOG or CONTRIBUTING** (Low, S) [V]: human contributor rules live only in AGENTS.md; release notes are generated from PR titles.
**QA-8 Snapshot capture relies on fixed sleeps and covers only the main window** (Low, M) [V]: see REL-2.
**QA-9 Docs drift** (Low, S) [V]: the polling paragraph and the app-model test list need updating after PR #18. (The README's "pull requests render the preview UI" is accurate again since PR #5 made the CI preview step blocking.)
**QA-10 Timing-based tests** (Low, S) [V]: tests added in PRs #8, #9 and #12 assert wall-clock bounds: executor concurrency 2.9 s (about 1.0 s today), log scans 1 s (0.02 to 0.1 s today), redaction 1 s. If CI flakes, compare against a measured baseline rather than widening blindly. The executor concurrency test scales with the core count on purpose (capping it would hide the regression it guards).

---

## 12. Rejected or downgraded claims

From the review:
- GLM: "`svc.sh install` loads the service and starts the runner": refuted against the official darwin template (install only writes the plist).
- GLM: "drain never clears": correct, kept as APP-2 (PR #16).
- svc-08 "Start contacts the Forgejo server for a stopped runner": refuted, lookups only run for runners with a live PID.
- sec-10 "delete always forces": consistent with AGENTS.md (explicit confirmation).
- sec-16 "non-exclusive token file create": not exploitable (fresh 0700 directory).
- sec-17 "nothing helps verify downloads": `.sha256` assets exist.
- svc-07 "pipe handler spins at 100% CPU": refuted (the wrapper keeps the pipes open until exit); only a close-versus-handler race remained, addressed by PR #8.
- Spotlight, Quick Look and App Intents: deferred, see section 9.

From pull request reviews (do not re-raise without new evidence):
- PR #12: "the worker job id survives the large-file tail jump and misattributes results". Each GitHub `Worker_` log belongs to exactly one job; keeping its id is what lets the tail's result finish that job (comment added).
- PR #10: "the `.service` symlink check follows links". `URL.resourceValues` reports `isSymbolicLink` and `isRegularFile` for the link itself.
- PR #9: "the cookie rule lacks a left boundary". It starts with `\b`.
- PR #6: "the release gate depends on a stalling smoke test". PR #5 (merged) fixed the stall, and `announce_without_preview` remains for manual runs.
- PR #17: "skip planning while notifications are denied". Job notifications are transition-based, so events from that period would be lost on re-grant anyway.
- PR #19: "adaptive colours resolve to light under Increase Contrast in dark mode". `bestMatch(from: [.aqua, .darkAqua])` maps every high-contrast appearance correctly (probed); the test pins it.

---

## Appendix A: items addressed by open pull requests

One-line summaries, kept so an item can be revived if its pull request is closed without merging. Full problem statements and fixes are in each pull request's description.

| Item | Summary | PR |
| --- | --- | --- |
| REL-1 (workflow) | Release job hung at the preview before uploading; preview now runs after upload, bounded, and a failed preview withholds the announcement | #6 |
| REL-3 | Shallow checkout made every build number 1; full fetch and an exact commit-count check | #6 |
| REL-6 | Flaky timeout test and a wrapper race (TERM trap installed after the fork) | #8 |
| REL-7 (bundle) | `build-app.sh` assembled into a leftover bundle | #6 |
| SVC-1 | A stale `.service` marker blocked Start, Stop and Remove with a misleading symlink error | #10 |
| SVC-2 | Stop could report success while launchd respawned the runner | #10 |
| SVC-3 | Manually started Forgejo daemons with other argument orders were not detected | #10 |
| SVC-4 (message) | A failed unregister left the runner stopped without saying so | #10 |
| SVC-6 | Disable stopped before disabling, so a failed stop left the runner enabled | #10 |
| APP-1 | Monitoring, update checks and the delegate only started when the main window appeared | #15 |
| APP-2 | A leftover stop-after-job flag stopped the runner right after its next start | #16 |
| APP-3 | A failing automatic stop retried every 3 s and stole focus with an alert | #16 |
| APP-4 | Confirmed actions skipped the busy check and used a stale snapshot | #16 |
| APP-5 | A Forgejo stop-after-job could not be cancelled once monitoring was off | #16 |
| APP-6 | Quitting silently dropped pending stop-after-job requests and interrupted installs | #16 |
| APP-7 | Demo mode read and wrote live update state | #15 |
| APP-9 | Refresh requests during a poll were dropped | #18 |
| APP-10 | Connect Forgejo saved the token before verifying it | #13 |
| APP-16 (demo drain) | Demo stop-after-job never completed | #16 |
| CORE-1 | One undecodable record in `jobs.json` disabled history for good | #11 |
| CORE-2 | History merge re-sanitised every job on every poll (124 ms per tick) | #11 |
| CORE-3 | A backward clock jump made the activity store refuse to load | #11 |
| LOG-1 | Large first-seen logs could skip the newest job and leak a partial line | #12 |
| LOG-2 | The GitHub log reader followed symlinks | #12 |
| LOG-3 | A PEM header without an END line froze a runner's log | #12 |
| LOG-4 | Job-context JSON was re-parsed at every nested brace (quadratic) | #12 |
| LOG-5 | Per-line date parsing, redaction and tail copying made first scans take seconds | #12 |
| LOG-6 | Quadratic regexes on long lines could stall the refresh loop | #12 |
| LOG-7 | A job's outcome depended on scan order | #12 |
| LOG-8 | Forgejo completions produced no activity events | #12 |
| DISC-1 | Discovery probed Desktop, Documents and Downloads every poll (privacy prompts) | #7 |
| DISC-2 | Symlinked runner folders were skipped | #7 |
| DISC-4 | GitHub labels were read from `.runner`, which has none; now a public sidecar | #14 |
| DISC-7 | Discovery roots and the 512-entry caps were undocumented and truncated silently | #7 |
| SEC-1 | Exported diagnostics could become invalid JSON | #9 |
| SEC-2 | The redactor missed common credential shapes | #9 |
| SEC-3 | The redactor recompiled a regex on every call | #9 |
| SEC-4 (cache) | Keychain read on every Forgejo request; now cached and shared | #13 |
| SEC-6 | "Show in Finder" opened package-like folders | #10 |
| PERF-1 | The 3 s poll ran all day with the window closed; adaptive cadence | #15 |
| PERF-2 | Every poll invalidated most views | #18 |
| PERF-3 | Expensive derived data recomputed in view bodies | #18 |
| PERF-4 | Per-second relative timers on every job row | #18 |
| PERF-6 | The subprocess executor blocked cooperative-pool threads | #8 |
| PERF-9 (head) | Forgejo responses were read in full before checking the status | #13 |
| UX-1 | The toolbar refresh button turned into a spinner every 3 s | #18 |
| UX-17 | Relative timestamps ticked and duration formats disagreed | #18 |
| QA-5 | WorkloadMonitorTests read the real `/tmp` | #14 |
| FEAT-1 | Notifications for failed and finished jobs and unexpected stops | #17 |
| Workload accuracy | GitHub label fallback, recently pushed organization repositories, budget and rate-limit stops that keep partial results honestly | #14 |
| LOOK-1 | Cards were the same colour as the canvas; adaptive surface tokens | #19 |
| LOOK-2 | One accent and orange meant several things; semantic status tones with 4.5:1 text | #19 |
| LOOK-7 | Ring-in-ring toolbar menu and bright menu chevrons | #19 |
| UX-2 | Every page repeated its title in a 150 pt hero | #19 |
| UX-3 | Marketing copy in a utility | #19 |
| UX-4 | Misaligned service-control switches | #19 |
| UX-5 | Sheets and Settings used system blue | #19 |
| UX-6 | New Runner sheet fixed at 640x760 | #19 |
| UX-13 | Stopped, disabled and unknown shared one grey | #19 |
| UX-14 | The accent was also the busy colour | #19 |
| UX-15 | Every runner used the same glyph; system daemons unmarked | #19 |
| UX-16 | Outcome shown twice per row | #19 |
| UX-21 | Menu bar showed the first 8 runners by name, crowded menus, no Settings item | #20 |
| FUN-1 | Menu bar figure runs while jobs are active, faster with more busy runners | #20 |
| FUN-2 | Menu bar figure stands, runs or falls with the fleet's state | #20 |
| UX-30 (part) | Teal text was 3.8:1 on white and 4.4:1 on dark, `.tertiary` information about 1.9:1, orange text about 2.2:1; status and accent text now reach 4.5:1, `.secondary` replaces `.tertiary` for information, 8 to 9 pt text becomes 10 to 11 pt | #19 |
| LOOK-3 (part) | Three near-duplicate metric tiles (33, 29, 27 pt values) replaced by `MetricTile`; colour tokens, `StatusTone` and `RunnerGlyph` in `DesignSystem.swift` | #19 |
| LOOK-4 (part) | No motion anywhere; numeric transitions, snappy status changes and a one-shot busy bounce, all off with Reduce Motion (the planned macOS 15 rotate / macOS 14 pulse was dropped for CPU cost) | #19 |
| UX-26 (part) | The runner detail's Workload row (about 557 pt of fixed columns in a pane as narrow as 450 pt) clipped the detail below 1200 pt; it now shares its width and hides the repeated name | #19 |
| UX-22 (part) | Menu bar wording unified to online and busy | #20 |
| FEAT-2 (part) | Menu bar elapsed timers, priority order, overflow row, attention, queue and stop-after-job capsules | #20 |
| LOOK-5 (part) | App icon in the menu bar panel header | #20 |
