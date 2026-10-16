# RunningMan

A native macOS home for your self-hosted GitHub Actions runners.

See what is installed, what is working, what ran, and what will start when you log in. RunningMan discovers existing installations in place and keeps their configuration and workspaces where they are.

![RunningMan dashboard with fictional preview runners](docs/images/overview.png)

The preview above uses fictional runners and jobs.

## A little mission control for your Mac

- **Live fleet overview.** Running, busy, stopped and disabled runners, with job counts, success rate and recent activity.
- **Independent controls.** Start and stop now, enable or disable a runner, and choose whether it starts at login.
- **Finish the job first.** Stop a busy runner after its current job finishes; cancel that request any time. RunningMan must remain open until it stops the runner.
- **Create and remove.** Register a repository or organization runner from its GitHub URL, download and verify the official runner, and install its user service. Unregister existing runners without deleting their workspaces.
- **Job history.** Search and filter locally recorded jobs, see outcomes and durations, and jump to their GitHub run when its URL is available.
- **Live diagnostics.** Search and follow redacted logs, reveal installations in Finder, and export a diagnostic report.
- **Menu-bar access.** Check the fleet and manage runners even after closing the main window.
- **Keep builds awake.** Optionally prevent idle sleep while a job is running. Closing the lid can still put a laptop to sleep.

RunningMan is an independent personal project. It uses SwiftUI and AppKit, with no third-party dependencies.

## Download

Requires macOS 14 or later.

<!-- latest-release -->[RunningMan-v0.1.0.zip](https://github.com/L-K-M/RunningMan/releases/download/v0.1.0/RunningMan-v0.1.0.zip)<!-- /latest-release --> (or an older one from the [releases](https://github.com/L-K-M/RunningMan/releases) list), unzip, and copy **RunningMan.app** to Applications. The build is ad-hoc signed, not notarized: open it once, click Done, then System Settings → Privacy & Security → Open Anyway (Control-click → Open on macOS 14).

Once installed, RunningMan checks a small public manifest file once a day and shows a banner when a newer release exists. Turn it off in Settings → Updates.

## Build and open

Requires macOS 14 or later and Xcode 16 or later with its command-line tools selected.

~~~sh
swift test
scripts/build-app.sh --universal --zip
open dist/RunningMan.app
~~~

The build creates an ad-hoc signed app, a ZIP and its SHA-256 checksum in **dist/**. Copy **RunningMan.app** to Applications if you want to keep it there. This is a development build; Developer ID signing and notarization are not configured.

For a faster native development build:

~~~sh
scripts/build-app.sh --debug
open dist/RunningMan.app
~~~

## Existing runners

Open RunningMan. It checks runner installation folders immediately below your home directory, its own managed runner directory, and your user LaunchAgents. Use **Import existing runner…** for installations elsewhere.

Discovery reads non-secret runner metadata and local diagnostics. It never executes a discovered runner or reads its credential files. Opening the app does not start, stop or reconfigure runners.

The three controls mean different things:

| Control | Effect |
| --- | --- |
| Start / Stop | Changes whether the runner is running now. Stopping preserves the next-login setting. |
| Enabled / Disabled | Determines whether the runner can be started. Disabling also stops it; enabling does not start it. |
| Start at login | Sets the user service's next-login policy. Changing it does not restart a live runner. |

These are macOS user LaunchAgents: automatic startup happens **after you sign into that Mac account**, rather than before login. See [GitHub's macOS service instructions](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/configure-the-application?platform=mac).

Local process state is shown as **running**, not as a claim that GitHub can currently reach the runner. Stop, disable and removal refuse uncertain or busy process state unless you explicitly confirm an interruption.

## Create a runner

Install and sign into the GitHub CLI once:

~~~sh
brew install gh
gh auth login
~~~

Choose **New Runner**, enter a GitHub.com repository or organization URL, a runner name and any custom labels, then create it. Repository registration requires repository administration access; organization registration requires organization ownership. Both private and public GitHub.com repositories are supported, subject to their organization policies. GitHub Enterprise Server registration is not yet supported.

RunningMan uses the existing GitHub CLI session, downloads the matching official macOS runner, verifies its published SHA-256 and archive paths, and requests a short-lived registration token. The token is passed through the runner's secret input environment and is never saved by RunningMan or placed in command arguments.

Managed installations live in **~/Library/Application Support/RunningMan/Runners/**. Creation starts the runner immediately; the checkbox separately controls startup at future logins. Setup errors preserve the installation and report its path. If registration completed, import that folder to inspect it; if it did not, move the incomplete folder to Trash before retrying.

Registering a runner does not rewrite repository workflows. Use the runner's labels in the relevant job's runner selection, for example:

~~~yaml
runs-on: [self-hosted, macOS]
~~~

## History and privacy

History is recovered from available local Runner and Worker diagnostics, then saved in **~/Library/Application Support/RunningMan/**. It is not a complete GitHub audit log. Rotated or deleted diagnostics cannot recover jobs that RunningMan has never seen.

Unfinished jobs without evidence of a current worker show **Unknown**, with no invented completion time. Records with confirmed outcomes keep them when older logs are scanned again. Up to 2,000 jobs and 500 activity events are retained, with bounded log tails and incremental background reads.

Registration credentials are never read. Common credential formats and explicit operation tokens are redacted from displayed or exported logs. Diagnostic exports include runner names, repository names and local paths.

## Development

~~~sh
scripts/build.sh            # swift test + release app build
scripts/build.sh --debug    # or a debug build
scripts/smoke-test.sh
~~~

`scripts/build.sh` also accepts `--universal`, `--zip`, `--run`, `--install` (replaces `/Applications/RunningMan.app`) and `--clean`. To cut a release, run `scripts/release.sh 1.2.0` on a clean, pushed `main` (`--dry-run` checks first): it updates the marked download link above, commits, tags `v1.2.0` and pushes both, after which the release workflow builds and publishes the zip and announces it to installed apps.

The smoke test opens a clearly labelled synthetic preview workspace and saves four screenshots under **.local/screenshots/**. It never controls installed runners. You can explore that preview manually:

~~~sh
open -na dist/RunningMan.app --args --demo
~~~

The [architecture notes](docs/architecture.md) describe discovery, service semantics, history and testing. Pull requests run the test suite, build the universal app, check its signature and render the preview UI on a GitHub-hosted Mac. The workflow can also be started manually.

## License

[The Unlicense](LICENSE).
