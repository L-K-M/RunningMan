# Architecture

RunningMan has three Swift package targets:

| Target | Responsibility |
| --- | --- |
| RunningManCore | Foundation-only models, bounded installation discovery, incremental diagnostics parsing, history reconciliation and credential redaction. |
| RunningManServices | Owned subprocess execution, user launchd service management, GitHub/Forgejo installation and remote workload APIs. |
| RunningMan | SwiftUI/AppKit windows and menu-bar view, observed application model, user confirmations, activity persistence and diagnostics export. |

## Discovery and live state

Discovery is read-only and does not recursively crawl the user's home. It considers immediate child directories, RunningMan's managed installation root, explicitly imported directories, installation paths referenced by user LaunchAgents, and Forgejo daemons in system LaunchDaemons whose `UserName` is the current user. Canonical paths deduplicate installations. A folder used by a system service is monitored only, even if it also has a user LaunchAgent or a public descriptor, because stopping either could interrupt the system daemon. System scanning is opt-in at construction so tests with a synthetic home never see the machine's services.

GitHub's runner metadata can have a UTF-8 byte-order mark. The service marker can contain an absolute plist path rather than a service label. Both are supported. The runner dependency manifest supplies its version without executing the binary.

Every live refresh batches process and launchd observations off the UI actor. Worker processes indicate a busy runner. A listener or loaded service PID indicates a running runner. Failed, truncated or timed-out observations produce uncertain state rather than an assertion that the runner is idle.

Installations carry a GitHub or Forgejo provider. Forgejo's registration and YAML files contain persistent credentials, so discovery never opens them. Managed installations have a bounded, non-secret public descriptor; imported user LaunchAgents can supply executable/configuration paths without reading their contents. Unknown runner registration files are not assumed to be GitHub metadata.

The UI polls every three seconds while automatic refresh, a pending stop-after-job request or keep-awake monitoring needs it. Log reads are incremental and bounded; unchanged logs are not reparsed. Process state is local evidence, separate from GitHub's remote online/offline state.

## Independent service controls

The service controller validates that a runner's service plist lives in the current user's LaunchAgents directory and points to that runner. It never uses sudo or broad process-name killing.

System LaunchDaemon runners are observed, never controlled. Their state comes from unprivileged `launchctl print system/<label>` and `print-disabled system`; exit status 113 means not loaded. Every mutating operation refuses a system-domain runner before running any command.

- Startup edits update RunAtLoad atomically without restarting a live service. Simple imported KeepAlive policies are backed up privately and disabled on disk when login startup is off; restoration checks the service identity and other settings. External edits win, and complex conditions are refused.
- Start loads and kickstarts only the selected enabled service, without a kill/restart flag.
- Stop unloads that service without changing its persistent enabled or startup policy. Only `launchctl print` exit status 113 counts as not loaded; any other failure refuses before unloading or signalling. A listener or daemon still present ten seconds after its SIGTERM (time for a busy runner to cancel its job) is reported as an error, not as stopped. When the signal itself fails, one process read decides.
- Disable persists launchd's disabled override first, then rechecks activity and stops the selected runner; a busy runner or a failed stop is reported as such, with the runner already disabled. Enable clears that override without starting it.
- Creating a missing service for a manually installed runner defaults to startup disabled; opting into login startup is a separate action. A `.service` marker naming a missing plist counts as no service (Stop still unloads a service launchd reports as loaded from exactly that path), and a matching plist without a marker is reconnected with its startup policy instead of being reinstalled.
- Busy or uncertain observations refuse interruption unless the caller supplies the explicitly confirmed force option.

Removal requests a short-lived GitHub removal token, stops the selected runner, removes its service metadata and unregisters it with GitHub. Failure restores local service metadata and says that the runner remains stopped. Files remain by default; the service API supports an explicitly requested move to macOS Trash after successful unregister.

## Registration

Only exact GitHub.com repository or organization URLs are accepted. All API calls use the signed-in GitHub CLI session. No permanent access token is extracted from that session.

The installer selects a matching macOS release asset from the official actions/runner repository. It checks the exact official download URL and SHA-256 digest, validates archive paths and symbolic links, and extracts into an owned temporary directory before publishing to a new installation folder. Existing destinations are never overwritten.

Short-lived runner tokens use ACTIONS_RUNNER_INPUT_TOKEN, which the official runner treats as a secret. Explicit tokens are scrubbed from errors. Subprocesses have bounded output and deadlines; a private process group ensures a timed-out shell cannot leave registration running in a child.

Partial installations are preserved because remote registration may already have succeeded. Failure messages provide the recovery location.

Forgejo registration uses its modern repository, organization, user or administrator runner API. Its official release assets do not include a native Mac binary, so explicit creation installs the checksummed Homebrew core formula, copies that binary into the owned installation and writes a private per-user service. Node.js for JavaScript actions is a separate host prerequisite. The API token stays in the login Keychain; the runner receives its own connection credential in a private file referenced by its configuration. Discovery and diagnostics do not open either credential file.

Forgejo daemon PIDs establish a live process, not an idle worker. Process arguments are matched with the same daemon-command parser as LaunchAgent arguments, so flag order and `--config=` forms do not matter. Because `ps` does not show a working directory, only an absolute configuration path identifies a daemon; one started with a relative path is found through its launchd service PID or not at all. With remote monitoring enabled, bounded, cached server runner status can establish idle or active state. Stop, disable and unregister recheck activity freshly. Without that evidence, activity remains unknown and interruption requires explicit confirmation. A startup checkbox never reloads a live process.

## Workload and utilisation

Remote queue monitoring is off by default and separate from local process polling. GitHub uses the signed-in CLI session; Forgejo uses a Keychain credential bound to one HTTPS origin. Redirects cannot forward authentication to a different origin. Responses, requests, pages and total batch duration are bounded; scope scheduling rotates to avoid starvation, and rate-limit backoff applies across the same server.

Queues are shared compatible pools. GitHub label matching is case insensitive; Forgejo uses exact labels. Unknown labels or unreadable jobs never become a known empty queue. Repositories and organizations are scanned with explicit coverage limits. Forgejo user and administrator scopes use its active queue endpoint, which covers waiting/running jobs but omits dependency/approval-blocked states. Scope identities remain separate even at one origin, while job identities deduplicate overlaps. Missing job timestamps, runner assignment or repository names remain unavailable or use explicit numeric placeholders.

Sampled utilisation is separate from job history. Consecutive known idle/busy observations up to 15 seconds apart contribute monitored time; unknown states, downtime and larger gaps do not. Only intervals busy at both ends receive busy credit. The 24-hour view shows its actual observation coverage and the fraction with at least one active job. This is a conservative estimate, not CPU utilisation or exact occupied slots on a multi-job runner. A private, bounded 48-hour store checkpoints at most every 30 seconds. Local recorded job intervals separately provide completed counts, median durations and capacity-aware recorded busy time.

## History and diagnostics

Release cleanup is performed by the workflow's vendored `release-job.swift`
helper in a uniquely marked temporary source copy, after upload attempts. It
validates ownership before removal and leaves a private JSON report outside the
removed tree. Cleanup status is separate from release status; interruption can
leave an unconfirmed pending report.

`RunnerCleanupMonitor` reads only bounded report metadata from the public GitHub
runner work directory. It rejects receipt symlinks and invalid records, binds
reports to discovered runner identities, redacts text and caches unchanged files.
The app never deletes report paths or infers successful cleanup for old jobs.
The [integration guide](release-cleanup.md) defines the scope and recovery limits.

The log monitor correlates listener dispatch/completion events and worker job context. Raw job context and private-key blocks are excluded from live tails. Known credential shapes are redacted before presentation or persistence.

History merges retain confirmed completion results and enrich names, repositories and workflow links. Reconciliation only calls a job running when its runner is positively busy, keeping at most its configured capacity of newest unfinished records. Other unfinished records become unknown without fabricated end times. A stale historical record is never allowed to turn an idle runner into a busy one.

History has a 2,000-job and 6 MiB encoded limit. Activity has a 500-event limit and stable logical identities, so reparsing historical diagnostics after app relaunch does not duplicate activity. Both are private local files written atomically. Clearing saved history does not remove runner diagnostics.

## Verification

Core and service tests use synthetic metadata, diagnostic lines, fake command executors and temporary home directories. They must not start, stop, disable or unregister a real runner.

App-model tests cover busy/unknown-job confirmation, demo isolation, in-memory GitHub/Forgejo creation and activity deduplication across relaunch. Core and service fixtures cover credential-free discovery, multi-slot reconciliation, observation gaps, scope/label matching, partial API coverage, request limits, Keychain origin boundaries and fresh interruption guards. Preview screenshots exercise real SwiftUI views with synthetic data, including light/dark workload views. They validate rendering, not a real release or live Forgejo registration.

Real-machine discovery can be inspected read-only. Actual GitHub registration and control of installed runners happen only through an explicit user operation in the app.
