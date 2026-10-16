# Architecture

RunningMan has three Swift package targets:

| Target | Responsibility |
| --- | --- |
| RunningManCore | Foundation-only models, bounded installation discovery, incremental diagnostics parsing, history reconciliation and credential redaction. |
| RunningManServices | Owned subprocess execution, user launchd service management and GitHub runner installation/removal. |
| RunningMan | SwiftUI/AppKit windows and menu-bar view, observed application model, user confirmations, activity persistence and diagnostics export. |

## Discovery and live state

Discovery is read-only and does not recursively crawl the user's home. It considers immediate child directories, RunningMan's managed installation root, explicitly imported directories and installation paths referenced by user LaunchAgents. Canonical paths deduplicate installations.

GitHub's runner metadata can have a UTF-8 byte-order mark. The service marker can contain an absolute plist path rather than a service label. Both are supported. The runner dependency manifest supplies its version without executing the binary.

Every live refresh batches process and launchd observations off the UI actor. Worker processes indicate a busy runner. A listener or loaded service PID indicates a running runner. Failed, truncated or timed-out observations produce uncertain state rather than an assertion that the runner is idle.

The UI polls every three seconds while automatic refresh, a pending stop-after-job request or keep-awake monitoring needs it. Log reads are incremental and bounded; unchanged logs are not reparsed. Process state is local evidence, separate from GitHub's remote online/offline state.

## Independent service controls

The service controller validates that a runner's service plist lives in the current user's LaunchAgents directory and points to that runner. It never uses sudo or broad process-name killing.

- Startup edits update RunAtLoad atomically without restarting a live service.
- Start loads and kickstarts only the selected enabled service, without a kill/restart flag.
- Stop unloads that service without changing its persistent enabled or startup policy.
- Disable stops the selected runner and persists launchd's disabled override. Enable clears that override without starting it.
- Creating a missing service for a manually installed runner defaults to startup disabled; opting into login startup is a separate action.
- Busy or uncertain observations refuse interruption unless the caller supplies the explicitly confirmed force option.

Removal requests a short-lived GitHub removal token, stops the selected runner, removes its service metadata and unregisters it with GitHub. Failure restores local service metadata. Files remain by default; the service API supports an explicitly requested move to macOS Trash after successful unregister.

## Registration

Only exact GitHub.com repository or organization URLs are accepted. All API calls use the signed-in GitHub CLI session. No permanent access token is extracted from that session.

The installer selects a matching macOS release asset from the official actions/runner repository. It checks the exact official download URL and SHA-256 digest, validates archive paths and symbolic links, and extracts into an owned temporary directory before publishing to a new installation folder. Existing destinations are never overwritten.

Short-lived runner tokens use ACTIONS_RUNNER_INPUT_TOKEN, which the official runner treats as a secret. Explicit tokens are scrubbed from errors. Subprocesses have bounded output and deadlines; a private process group ensures a timed-out shell cannot leave registration running in a child.

Partial installations are preserved because remote registration may already have succeeded. Failure messages provide the recovery location.

## History and diagnostics

The log monitor correlates listener dispatch/completion events and worker job context. Raw job context and private-key blocks are excluded from live tails. Known credential shapes are redacted before presentation or persistence.

History merges retain confirmed completion results and enrich names, repositories and workflow links. Reconciliation only calls a job running when its runner is positively busy and it is that runner's newest unfinished record. Other unfinished records become unknown without fabricated end times. A stale historical record is never allowed to turn an idle runner into a busy one.

History has a 2,000-job and 6 MiB encoded limit. Activity has a 500-event limit and stable logical identities, so reparsing historical diagnostics after app relaunch does not duplicate activity. Both are private local files written atomically. Clearing saved history does not remove runner diagnostics.

## Verification

Core and service tests use synthetic metadata, diagnostic lines, fake command executors and temporary home directories. They must not start, stop, disable or unregister a real runner.

App-model tests cover busy-job confirmation, demo isolation, in-memory preview creation and activity deduplication across relaunch. Preview screenshots exercise real SwiftUI views with synthetic data. They validate rendering, not a real GitHub release.

Real-machine discovery can be inspected read-only. Actual GitHub registration and control of installed runners happen only through an explicit user operation in the app.
