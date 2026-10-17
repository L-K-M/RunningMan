import AppKit
import Foundation
import Observation
import RunningManCore
import RunningManServices
import UniformTypeIdentifiers

enum AppSection: String, CaseIterable, Identifiable {
    case overview, runners, workload, history, cleanup
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: return "Overview"; case .runners: return "Runners"; case .workload: return "Workload"; case .history: return "Job history"; case .cleanup: return "Cleanup" }
    }
    var systemImage: String {
        switch self { case .overview: return "square.grid.2x2"; case .runners: return "server.rack"; case .workload: return "chart.bar.xaxis"; case .history: return "clock.arrow.circlepath"; case .cleanup: return "sparkles" }
    }
}

enum RunnerAction { case start, stop, enable, disable, drain, delete }

/// Who asked for an action. Only user-initiated failures raise the alert, which brings the window forward.
enum ActionOrigin { case user, automatic }

/// The last failed automatic stop-after-job attempt for one runner. Retries back off so a stop
/// that keeps failing neither floods the activity log nor runs on every poll.
struct DrainFailure: Equatable {
    static let attemptLimit = 5
    let attempts: Int
    let message: String
    let date: Date
    /// 30 s after the first failure, doubling up to 5 minutes.
    var retryDate: Date { date.addingTimeInterval(min(30 * pow(2, Double(max(attempts, 1) - 1)), 300)) }
    var exhaustsAttempts: Bool { attempts >= Self.attemptLimit }
    static func after(_ previous: DrainFailure?, message: String, at date: Date) -> DrainFailure {
        DrainFailure(attempts: (previous?.attempts ?? 0) + 1, message: message, date: date)
    }
}

struct RunnerConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let buttonTitle: String
}

/// A runner action waiting for confirmation. It keeps the runner's id rather than a snapshot, so
/// confirming re-checks the runner's current state.
struct PendingRunnerAction: Equatable {
    let action: RunnerAction
    let runnerID: String
    let force: Bool
}

enum PendingConfirmation: Equatable {
    case runner(PendingRunnerAction)
    case clearHistory
}

/// Keeps stop-after-job requests across launches, each with the process it was made for. RunningMan
/// must be running to act on them. After launch a request applies only while that process still runs;
/// requests whose runner is gone, stopped or restarted end instead.
struct DrainRequestStore {
    static let key = "drainRequests"
    let defaults: UserDefaults
    /// When the Mac booted. A process id names a run only within one boot.
    let bootTime: TimeInterval?

    init(defaults: UserDefaults, bootTime: TimeInterval? = DrainRequestStore.currentBootTime()) {
        self.defaults = defaults
        self.bootTime = bootTime
    }

    /// Runner ids with the process each request was made for. Runner ids are standardized installation
    /// paths; anything else cannot match a runner. A request saved before the Mac last booted, or without
    /// a known process, comes back with nil, which matches no running process.
    func load() -> [String: Int32?] {
        guard let stored = defaults.dictionary(forKey: Self.key),
              let processes = stored["processes"] as? [String: Int] else { return [:] }
        let sameBoot = bootTime != nil && stored["bootTime"] as? Double == bootTime
        var requests: [String: Int32?] = [:]
        for (id, processID) in processes where id.hasPrefix("/") {
            requests.updateValue(sameBoot && processID > 0 ? Int32(exactly: processID) : nil, forKey: id)
        }
        return requests
    }

    func save(_ requests: [String: Int32?]) {
        guard !requests.isEmpty else { defaults.removeObject(forKey: Self.key); return }
        var stored: [String: Any] = ["processes": requests.mapValues { Int($0 ?? 0) }]
        if let bootTime { stored["bootTime"] = bootTime }
        defaults.set(stored, forKey: Self.key)
    }

    static func currentBootTime() -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000
    }
}

@MainActor @Observable
final class AppModel {
    var runners: [RunnerSnapshot] = []
    var jobs: [RunnerJob] = []
    var events: [ActivityEvent] = []
    var warnings: [String] = []
    var workload: WorkloadReport?
    var observedUsage: [String: ObservedRunnerUsage] = [:]
    var cleanupRecords: [RunnerCleanupRecord] = []
    var cleanupWarnings: [String] = []
    var isRefreshingWorkload = false
    var showingForgejoConnection = false { didSet { if showingForgejoConnection { showMainWindow?() } } }
    var forgejoServers: [URL] = []
    var forgejoAccount: String?
    var defaultForgejoServer = ""
    var remoteMonitoringEnabled = false {
        didSet {
            if !demoMode { UserDefaults.standard.set(remoteMonitoringEnabled, forKey: "remoteMonitoringEnabled") }
            if !remoteMonitoringEnabled {
                workloadTask?.cancel()
                workload = nil
                cancelForgejoDrainRequests()
            }
        }
    }
    var selectedRunnerID: String?
    var section: AppSection = .overview
    var searchText = ""
    var isRefreshing = false
    var busyRunnerIDs: Set<String> = []
    var drainingRunnerIDs: Set<String> = [] {
        didSet {
            if drainingRunnerIDs != oldValue { bindDrainRequests() }
            // Failure records belong to a request; ending the request ends its retry state.
            if drainFailures.keys.contains(where: { !drainingRunnerIDs.contains($0) }) {
                drainFailures = drainFailures.filter { drainingRunnerIDs.contains($0.key) }
            }
            drainUnknownSince = drainUnknownSince.filter { drainingRunnerIDs.contains($0.key) }
        }
    }
    var drainFailures: [String: DrainFailure] = [:]
    var lastUpdated: Date?
    var logText = ""
    var showingNewRunner = false { didSet { if showingNewRunner { showMainWindow?() } } }
    var showingSettings = false
    var errorMessage: String? { didSet { if errorMessage != nil { showMainWindow?() } } }
    var confirmation: RunnerConfirmation? { didSet { if confirmation != nil { showMainWindow?() } } }
    var githubAccount: String?
    var creationProgress = ""
    var isCreating = false
    let demoMode: Bool
    var refreshAutomatically = true {
        didSet { if !demoMode { UserDefaults.standard.set(refreshAutomatically, forKey: "refreshAutomatically") } }
    }
    var keepAwakeWhileBusy = false {
        didSet {
            if !demoMode { UserDefaults.standard.set(keepAwakeWhileBusy, forKey: "keepAwakeWhileBusy") }
            updateSleepPrevention()
        }
    }

    @ObservationIgnored private let discovery = RunnerDiscovery(systemDaemonsDirectory: RunnerDiscovery.systemDaemonsDirectory)
    @ObservationIgnored private let logs = RunnerLogMonitor()
    @ObservationIgnored private let controller = RunnerServiceController()
    @ObservationIgnored private let installer = GitHubRunnerInstaller()
    @ObservationIgnored private let forgejoInstaller = ForgejoRunnerInstaller()
    @ObservationIgnored private let forgejoConnections = ForgejoConnectionStore()
    @ObservationIgnored private let forgejoLogs = ForgejoLogMonitor()
    @ObservationIgnored private let workloadMonitor = WorkloadMonitor()
    @ObservationIgnored private let cleanupMonitor = RunnerCleanupMonitor()
    @ObservationIgnored private let history: RunnerHistoryStore
    @ObservationIgnored private let eventStore: ActivityStore
    @ObservationIgnored private let activitySamples: RunnerActivityStore
    /// Nil in demo mode, which must not write preferences.
    @ObservationIgnored private let drainRequestStore: DrainRequestStore?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var workloadTask: Task<WorkloadReport, Never>?
    @ObservationIgnored private var lastWorkloadAttempt: Date?
    @ObservationIgnored private var pendingConfirmation: PendingConfirmation?
    @ObservationIgnored private var sleepPrevention: Process?
    @ObservationIgnored private var logTails: [String: String] = [:]
    @ObservationIgnored private var importedDirectories: [URL] = []
    @ObservationIgnored private var observedEventKeys: Set<ActivityIdentity> = []
    @ObservationIgnored var showMainWindow: (() -> Void)?
    /// How long a busy demo runner takes to finish its job after stop-after-job; tests shorten it.
    @ObservationIgnored var demoDrainDelay: Duration = .seconds(4)
    /// The process each stop-after-job request was made for, saved with it across launches.
    @ObservationIgnored private var drainProcesses: [String: Int32?] = [:]
    /// Restored requests not yet compared with their runner's current process. Nothing acts on them until then.
    @ObservationIgnored private var unconfirmedDrainRequests: Set<String> = []
    /// When each requested runner's state became unverifiable, so the request cannot wait on it forever.
    @ObservationIgnored private var drainUnknownSince: [String: Date] = [:]
    /// How long a stop-after-job request waits for an unverifiable state to clear before it ends.
    static let drainUnknownLimit: TimeInterval = 10 * 60

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunningMan", isDirectory: true)
    }

    init(demoMode: Bool = CommandLine.arguments.contains("--demo")) {
        self.demoMode = demoMode
        history = RunnerHistoryStore(fileURL: Self.supportDirectory.appendingPathComponent("jobs.json"))
        eventStore = ActivityStore(url: Self.supportDirectory.appendingPathComponent("activity.json"))
        activitySamples = RunnerActivityStore(fileURL: Self.supportDirectory.appendingPathComponent("observed-activity.json"))
        drainRequestStore = demoMode ? nil : DrainRequestStore(defaults: .standard)
        if demoMode {
            remoteMonitoringEnabled = true
            loadDemo()
        } else {
            let preferences = UserDefaults.standard
            refreshAutomatically = preferences.object(forKey: "refreshAutomatically") as? Bool ?? true
            keepAwakeWhileBusy = preferences.bool(forKey: "keepAwakeWhileBusy")
            remoteMonitoringEnabled = preferences.object(forKey: "remoteMonitoringEnabled") as? Bool ?? false
            forgejoServers = (preferences.stringArray(forKey: "forgejoServers") ?? []).compactMap(URL.init(string:))
            defaultForgejoServer = preferences.string(forKey: "defaultForgejoServer") ?? forgejoServers.first?.absoluteString ?? ""
            importedDirectories = (preferences.stringArray(forKey: "importedRunnerDirectories") ?? [])
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            restoreDrainRequests(drainRequestStore?.load() ?? [:])
        }
    }

    /// What quitting now would leave undone, or nil when RunningMan can quit without asking.
    var quitWarning: (title: String, message: String)? {
        demoMode ? nil : Self.quitWarning(isCreating: isCreating, actionsInProgress: busyRunnerIDs.count, drainRequests: drainingRunnerIDs.count)
    }

    nonisolated static func quitWarning(isCreating: Bool, actionsInProgress: Int, drainRequests: Int) -> (title: String, message: String)? {
        var notes: [String] = []
        if isCreating {
            notes.append("A runner is being created. Quitting interrupts the setup and can leave an incomplete installation folder.")
        }
        if actionsInProgress > 0 {
            notes.append(actionsInProgress == 1 ? "A runner action is still in progress and may not finish." : "\(actionsInProgress) runner actions are still in progress and may not finish.")
        }
        if drainRequests > 0 {
            notes.append((drainRequests == 1 ? "1 runner is waiting to stop after its job." : "\(drainRequests) runners are waiting to stop after their jobs.")
                + " RunningMan resumes these requests when you open it again unless a runner restarted in the meantime, but it must be running to stop the runners.")
        }
        guard !notes.isEmpty else { return nil }
        let title = isCreating ? "Quit while a runner is being created?"
            : drainRequests > 0 ? (drainRequests == 1 ? "Quit while a runner waits to stop?" : "Quit while runners wait to stop?")
            : "Quit while a runner action is in progress?"
        return (title, notes.joined(separator: "\n\n"))
    }

    var selectedRunner: RunnerSnapshot? { runners.first { $0.id == selectedRunnerID } }
    var filteredRunners: [RunnerSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? runners : runners.filter {
            [$0.runner.name, $0.runner.repository, $0.runner.provider.title, $0.status.title, $0.runner.directory.path]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    var filteredJobs: [RunnerJob] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return jobs.filter {
            query.isEmpty || [$0.name, $0.repository ?? "", $0.workflow ?? "", $0.outcome.title]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { $0.startedAt > $1.startedAt }
    }
    var runningCount: Int { runners.filter { $0.status.isRunning || $0.processID != nil }.count }
    var busyCount: Int { runners.filter { $0.status == .busy }.count }
    var startsAtLoginCount: Int { runners.filter { $0.startsAtLogin && $0.isEnabled }.count }
    var successfulJobs: Int { jobs.filter { $0.outcome == .success }.count }
    var successRate: Double? {
        let completed = jobs.filter { [.success, .failure, .cancelled].contains($0.outcome) }
        return completed.isEmpty ? nil : Double(successfulJobs) / Double(completed.count)
    }
    func jobs(for runnerID: String) -> [RunnerJob] {
        jobs.filter { $0.runnerID == runnerID }.sorted { $0.startedAt > $1.startedAt }
    }

    func startMonitoring() {
        guard pollingTask == nil, !demoMode else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            do { jobs = try await history.load() } catch { warnings = [Self.message(error)] }
            events = await eventStore.load()
            observedEventKeys = Set(events.map(ActivityIdentity.init))
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                if refreshAutomatically || !drainingRunnerIDs.isEmpty || keepAwakeWhileBusy { await refresh() }
            }
        }
    }

    func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
        workloadTask?.cancel()
        workloadTask = nil
        if let process = sleepPrevention, process.isRunning { process.terminate() }
        sleepPrevention = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        if demoMode { lastUpdated = Date(); return }
        isRefreshing = true
        defer { isRefreshing = false }
        let result = await discovery.discover(additionalDirectories: importedDirectories)
        let states = await controller.snapshots(for: result.runners, allowRemoteActivity: remoteMonitoringEnabled)
        async let githubScan = logs.scan(runners: result.runners.filter { $0.provider == .github })
        async let forgejoScan = forgejoLogs.scan(runners: result.runners.filter { $0.provider == .forgejo })
        async let cleanupScan = cleanupMonitor.scan(runners: result.runners)
        let (github, forgejo) = await (githubScan, forgejoScan)
        let cleanup = await cleanupScan
        cleanupRecords = cleanup.records
        cleanupWarnings = cleanup.warnings
        let scan = LogScanResult(jobs: github.jobs + forgejo.jobs, events: github.events + forgejo.events,
                                warnings: github.warnings + forgejo.warnings,
                                tails: github.tails.merging(forgejo.tails) { _, latest in latest })
        var candidates = Dictionary(jobs.filter { $0.outcome == .running }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for job in scan.jobs { candidates[job.id] = job }
        let reconciled = JobReconciler.reconcile(jobs: Array(candidates.values), snapshots: states)
        var next = states
        for index in next.indices where next[index].status == .busy {
            next[index].currentJob = reconciled.filter { $0.runnerID == next[index].id && $0.outcome == .running }
                .max { $0.startedAt < $1.startedAt }
        }
        let oldStates = Dictionary(uniqueKeysWithValues: runners.map { ($0.id, $0.status) })
        runners = next.sorted { $0.runner.name.localizedStandardCompare($1.runner.name) == .orderedAscending }
        warnings = Array((result.warnings + scan.warnings + cleanup.warnings).map(SecretRedactor.redact).prefix(20))
        do {
            try await activitySamples.record(snapshots: runners)
            var metrics: [String: ObservedRunnerUsage] = [:]
            for runner in runners { metrics[runner.id] = try await activitySamples.metrics(for: runner.id) }
            observedUsage = metrics
        } catch { warnings.append("Activity sampling: " + Self.message(error)) }
        do { jobs = try await history.merge(reconciled) }
        catch { warnings.append(Self.message(error)) }
        logTails = scan.tails
        updateSelectedLog()
        for event in scan.events { record(event) }
        for runner in runners {
            if let previous = oldStates[runner.id], previous != runner.status {
                record(title: "\(runner.runner.name) · \(runner.status.title)",
                       runnerID: runner.id, detail: runner.detail,
                       kind: runner.status == .attention ? .warning : .info)
            }
        }
        processDrainRequests()
        if selectedRunnerID == nil { selectedRunnerID = runners.first?.id }
        if let id = selectedRunnerID, !runners.contains(where: { $0.id == id }) { selectedRunnerID = runners.first?.id }
        updateSelectedLog()
        lastUpdated = Date()
        updateSleepPrevention()
        if remoteMonitoringEnabled && !isRefreshingWorkload {
            Task { [weak self] in await self?.refreshWorkload() }
        }
    }

    /// Requests saved by an earlier launch. Each waits until a refresh shows its runner's process.
    func restoreDrainRequests(_ requests: [String: Int32?]) {
        drainProcesses = requests
        unconfirmedDrainRequests = Set(requests.keys)
        drainingRunnerIDs = Set(requests.keys)
    }

    /// Ties every request to the process it is for and saves them. A new or confirmed request follows
    /// its runner's current process; an unconfirmed restored one keeps the process it was saved with.
    private func bindDrainRequests() {
        unconfirmedDrainRequests.formIntersection(drainingRunnerIDs)
        var bound = drainProcesses.filter { drainingRunnerIDs.contains($0.key) }
        for id in drainingRunnerIDs where !unconfirmedDrainRequests.contains(id) {
            if let processID = runners.first(where: { $0.id == id })?.processID { bound.updateValue(processID, forKey: id) }
            else if bound[id] == nil { bound.updateValue(nil, forKey: id) }
        }
        guard bound != drainProcesses else { return }
        drainProcesses = bound
        drainRequestStore?.save(bound)
    }

    /// A restored request applies only to the run it was made for. After a logout, a restart of the Mac
    /// or a runner restarted while RunningMan was closed, that run is over, so the request ends instead of
    /// stopping the new one. A runner without a visible process keeps its request waiting.
    private func confirmRestoredDrainRequests() {
        for id in unconfirmedDrainRequests.sorted() {
            guard let processID = runners.first(where: { $0.id == id })?.processID else { continue }
            unconfirmedDrainRequests.remove(id)
            let saved = drainProcesses[id] ?? nil
            guard saved != processID else { continue }
            drainingRunnerIDs.remove(id)
            record(title: "Stop after job ended: \(runnerDisplayName(id)) restarted while RunningMan was closed", runnerID: id)
        }
    }

    /// Stop-after-job requests that no longer apply: the runner is gone, or it is definitely stopped
    /// (it crashed or was stopped outside RunningMan). An unverifiable state is not evidence of a stop,
    /// and a runner with an action in progress is left to that action.
    nonisolated static func endedDrainRequests(_ requests: Set<String>, runners: [RunnerSnapshot], inProgress: Set<String>) -> Set<String> {
        let snapshots = Dictionary(runners.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return requests.subtracting(inProgress).filter { id in
            guard let runner = snapshots[id] else { return true }
            return (runner.status == .stopped || runner.status == .disabled) && runner.processID == nil
        }
    }

    /// Runs after each refresh: ends requests that no longer apply, then stops drained runners that have
    /// gone idle, waiting out the backoff after a failed attempt.
    func processDrainRequests(now: Date = Date()) {
        let ended = Self.endedDrainRequests(drainingRunnerIDs, runners: runners, inProgress: busyRunnerIDs)
        if !ended.isEmpty { drainingRunnerIDs.subtract(ended) }
        for id in ended.sorted() {
            record(title: "Stop after job ended: \(runnerDisplayName(id)) is no longer running", runnerID: id)
        }
        confirmRestoredDrainRequests()
        // Requests restored from an earlier launch can predate turning server monitoring off.
        if !remoteMonitoringEnabled { cancelForgejoDrainRequests() }
        endUnverifiableDrainRequests(now: now)
        for runner in runners where drainingRunnerIDs.contains(runner.id) && !unconfirmedDrainRequests.contains(runner.id)
            && runner.status == .idle && !busyRunnerIDs.contains(runner.id) {
            if let failure = drainFailures[runner.id], failure.retryDate > now { continue }
            runAction(.stop, on: runner, origin: .automatic)
        }
        // A runner's process can change while RunningMan watches it, for example when it updates itself.
        bindDrainRequests()
    }

    /// An unknown state is not evidence of a stop, but a request must not wait on it silently,
    /// possibly across relaunches: it ends with an explanation once the state stays unknown too long.
    private func endUnverifiableDrainRequests(now: Date) {
        for runner in runners where drainingRunnerIDs.contains(runner.id) && !busyRunnerIDs.contains(runner.id) {
            guard runner.status == .unknown else { drainUnknownSince[runner.id] = nil; continue }
            let since = drainUnknownSince[runner.id] ?? now
            drainUnknownSince[runner.id] = since
            guard now.timeIntervalSince(since) >= Self.drainUnknownLimit else { continue }
            drainingRunnerIDs.remove(runner.id)
            record(title: "Stop after job cancelled: \(runner.runner.name)’s activity could not be verified", runnerID: runner.id,
                   detail: "Its state stayed unknown for \(Int(Self.drainUnknownLimit / 60)) minutes. Check its logs or server connection in Workload, then request the stop again.",
                   kind: .warning)
        }
    }

    /// Automatic stops fail quietly: each distinct reason is logged once per runner, retries back off,
    /// and the request ends with a warning after `DrainFailure.attemptLimit` attempts.
    func noteAutomaticStopFailure(runnerID: String, message: String, at date: Date = Date()) {
        let name = runnerDisplayName(runnerID)
        // The request ended while this stop ran (cancelled, or the runner stopped otherwise),
        // so the failure no longer concerns anything the user asked for.
        guard drainingRunnerIDs.contains(runnerID) else {
            record(title: "Automatic stop did not finish", runnerID: runnerID, detail: "\(name): \(message)")
            return
        }
        let previous = drainFailures[runnerID]
        let failure = DrainFailure.after(previous, message: message, at: date)
        if failure.exhaustsAttempts {
            drainingRunnerIDs.remove(runnerID)
            record(title: "Stop after job cancelled: \(name) could not be stopped", runnerID: runnerID,
                   detail: "\(failure.attempts) automatic attempts failed. Last error: \(message)", kind: .warning)
            return
        }
        drainFailures[runnerID] = failure
        if previous?.message != message {
            record(title: "Automatic stop failed", runnerID: runnerID, detail: "\(name): \(message)", kind: .failure)
        }
    }

    /// Falls back to the folder name for a runner that is no longer discovered.
    private func runnerDisplayName(_ id: String) -> String {
        runners.first { $0.id == id }?.runner.name ?? URL(fileURLWithPath: id).lastPathComponent
    }

    func refreshWorkload(force: Bool = false) async {
        guard remoteMonitoringEnabled, !isRefreshingWorkload, !demoMode else { return }
        guard force || lastWorkloadAttempt.map({ Date().timeIntervalSince($0) >= 60 }) != false else { return }
        lastWorkloadAttempt = Date()
        isRefreshingWorkload = true
        defer { isRefreshingWorkload = false; workloadTask = nil }
        let monitor = workloadMonitor
        let installations = runners.map(\.runner)
        let request = Task { await monitor.refresh(runners: installations, force: force) }
        workloadTask = request
        let report = await request.value
        guard !Task.isCancelled, !request.isCancelled, remoteMonitoringEnabled else { return }
        workload = report
    }

    var visibleWorkloadScopes: [WorkloadScopeSnapshot] {
        let scopes = workload?.scopes ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, section == .workload else { return scopes }
        return scopes.filter { $0.scopeURL.absoluteString.localizedCaseInsensitiveContains(query)
            || $0.provider.title.localizedCaseInsensitiveContains(query)
            || $0.jobs.contains { $0.name.localizedCaseInsensitiveContains(query) || $0.repository.localizedCaseInsensitiveContains(query) } }
    }
    func workloadScope(for runnerID: String) -> WorkloadScopeSnapshot? {
        workload?.scopes.first { $0.runnerIDs.contains(runnerID) }
    }
    func usage(for runner: InstalledRunner) -> RunnerUsageMetrics {
        RunnerUsage.calculate(runner: runner, jobs: jobs)
    }

    var filteredCleanupRecords: [RunnerCleanupRecord] {
        let query = section == .cleanup ? searchText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return cleanupRecords.filter { record in
            query.isEmpty || [record.repository, record.job, record.status.title, runnerName(for: record.runnerID)]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
    }

    func runnerName(for id: String) -> String { runners.first { $0.id == id }?.runner.name ?? "Runner no longer installed" }

    func latestCleanup(for runnerID: String) -> RunnerCleanupRecord? {
        cleanupRecords.filter { $0.runnerID == runnerID }.max { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }
    }

    func selectionChanged() { updateSelectedLog() }

    func perform(_ action: RunnerAction, on runner: RunnerSnapshot) {
        // Cancelling is always allowed, even when a new request would be refused or an action is
        // in progress. An automatic stop already running still finishes; it is just not retried.
        if action == .drain, drainingRunnerIDs.contains(runner.id) {
            drainingRunnerIDs.remove(runner.id)
            record(title: "Stop after job cancelled", runnerID: runner.id, detail: runner.runner.name)
            return
        }
        guard !busyRunnerIDs.contains(runner.id) else { return }
        guard requireUserService(runner) else { return }
        if action == .drain {
            if let refusal = drainRefusal(for: runner) {
                errorMessage = refusal
                return
            }
            drainingRunnerIDs.insert(runner.id)
            record(title: "Will stop after the current job", runnerID: runner.id, detail: runner.runner.name)
            if runner.status == .idle { runAction(.stop, on: runner) }
            else if demoMode && runner.status == .busy { simulateJobFinish(for: runner.id) }
            return
        }
        if action == .delete {
            confirmation = RunnerConfirmation(title: "Remove \(runner.runner.name)?",
                message: "Unregisters this runner from \(runner.runner.provider.title) and removes its login service. Installation files and job history are kept. An active job will be interrupted.",
                buttonTitle: "Remove runner")
            pendingConfirmation = .runner(PendingRunnerAction(action: action, runnerID: runner.id, force: true))
        } else if (runner.status == .busy || runner.status == .unknown) && (action == .stop || action == .disable) {
            confirmation = RunnerConfirmation(title: runner.status == .busy ? "Interrupt the active job?" : "Stop with activity unverified?",
                message: runner.status == .busy ? "\(runner.runner.name) is building right now. This will stop the runner and interrupt its job. Choose “Stop when idle” to let it finish." : "RunningMan cannot verify whether \(runner.runner.name) has active jobs. Stopping may interrupt work.",
                buttonTitle: action == .disable ? "Disable and interrupt" : "Stop and interrupt")
            pendingConfirmation = .runner(PendingRunnerAction(action: action, runnerID: runner.id, force: true))
        } else { runAction(action, on: runner) }
    }

    /// Why a new stop-after-job request cannot be honoured, or nil when it can. A Forgejo runner's
    /// idle state comes from the server, so its request needs that state to be known.
    private func drainRefusal(for runner: RunnerSnapshot) -> String? {
        let name = runner.runner.name
        if runner.status == .stopped || runner.status == .disabled { return "\(name) is not running." }
        guard runner.runner.provider == .forgejo else { return nil }
        guard remoteMonitoringEnabled else {
            return "Turn on server monitoring in Workload so RunningMan can tell when \(name) finishes its job. You can still stop it now after confirming the interruption."
        }
        guard runner.status != .busy, runner.status != .idle else { return nil }
        return "RunningMan cannot verify whether \(name) is running a job, so it cannot tell when to stop it. Check this server’s connection in Workload, or stop the runner now after confirming the interruption."
    }

    /// Without server monitoring a Forgejo request could never complete, so it ends with an explanation.
    private func cancelForgejoDrainRequests() {
        let ids = drainingRunnerIDs.intersection(runners.filter { $0.runner.provider == .forgejo }.map(\.id))
        guard !ids.isEmpty else { return }
        drainingRunnerIDs.subtract(ids)
        for id in ids.sorted() {
            record(title: "Stop after job cancelled: Forgejo activity can no longer be verified", runnerID: id, detail: runnerDisplayName(id))
        }
    }

    func confirmPendingAction() {
        let pending = pendingConfirmation
        confirmation = nil
        pendingConfirmation = nil
        switch pending {
        case .runner(let request): runConfirmed(request)
        case .clearHistory: clearHistoryConfirmed()
        case nil: break
        }
    }
    func cancelPendingAction() { confirmation = nil; pendingConfirmation = nil }

    /// The dialog may have stayed open across refreshes and other actions, so the runner's current
    /// snapshot decides, not the one shown when it opened.
    private func runConfirmed(_ request: PendingRunnerAction) {
        guard let runner = runners.first(where: { $0.id == request.runnerID }) else {
            errorMessage = "\(runnerDisplayName(request.runnerID)) is no longer installed. Nothing was changed."
            return
        }
        guard !busyRunnerIDs.contains(runner.id) else {
            errorMessage = "\(runner.runner.name) is still busy with another action. Nothing was changed; try again when it finishes."
            return
        }
        runAction(request.action, on: runner, force: request.force)
    }

    private func runAction(_ action: RunnerAction, on runner: RunnerSnapshot, force: Bool = false, origin: ActionOrigin = .user) {
        // Two operations must never run on one runner at once; the first one's completion would
        // re-enable controls while the other is still running.
        guard busyRunnerIDs.insert(runner.id).inserted else { return }
        if demoMode { simulate(action, runner: runner); busyRunnerIDs.remove(runner.id); return }
        Task {
            defer { busyRunnerIDs.remove(runner.id) }
            do {
                switch action {
                case .start: try await controller.start(runner.runner)
                case .stop: try await controller.stop(runner.runner, force: force)
                case .enable: try await controller.setEnabled(true, for: runner.runner)
                case .disable: try await controller.setEnabled(false, for: runner.runner, force: force)
                case .delete: try await controller.delete(runner.runner, trashFiles: false, force: force)
                case .drain: return
                }
                // A successful start also ends a leftover request, so the runner is not stopped right after.
                if [.start, .stop, .disable, .delete].contains(action) { drainingRunnerIDs.remove(runner.id) }
                let title: String
                switch action {
                case .start: title = "Runner started"
                case .stop: title = "Runner stopped"
                case .enable: title = "Runner enabled"
                case .disable: title = "Runner disabled"
                case .delete: title = "Runner unregistered"
                case .drain: title = "Stop after job"
                }
                record(title: title, runnerID: runner.id, detail: runner.runner.name, kind: .success)
                await refresh()
            } catch {
                let message = Self.message(error)
                switch origin {
                case .user:
                    errorMessage = message
                    record(title: "Runner action failed", runnerID: runner.id, detail: message, kind: .failure)
                case .automatic:
                    noteAutomaticStopFailure(runnerID: runner.id, message: message)
                }
            }
        }
    }

    func setStartup(_ enabled: Bool, for runner: RunnerSnapshot) {
        guard requireUserService(runner) else { return }
        if demoMode {
            if let index = runners.firstIndex(where: { $0.id == runner.id }) { runners[index].startsAtLogin = enabled }
            return
        }
        guard !busyRunnerIDs.contains(runner.id) else { return }
        busyRunnerIDs.insert(runner.id)
        Task {
            defer { busyRunnerIDs.remove(runner.id) }
            do {
                try await controller.setStartsAtLogin(enabled, for: runner.runner)
                record(title: enabled ? "Start at login enabled" : "Start at login disabled",
                       runnerID: runner.id, detail: runner.runner.name, kind: .success)
                await refresh()
            } catch { errorMessage = Self.message(error) }
        }
    }

    func startAll() {
        for runner in runners where runner.runner.serviceDomain == .user && runner.isEnabled && !runner.status.isRunning && runner.processID == nil { perform(.start, on: runner) }
    }
    func stopAllWhenIdle() {
        for runner in runners where runner.runner.serviceDomain == .user && (runner.status.isRunning || runner.processID != nil) && !drainingRunnerIDs.contains(runner.id) { perform(.drain, on: runner) }
    }
    /// System LaunchDaemons are monitored only; the service controller refuses them too.
    private func requireUserService(_ runner: RunnerSnapshot) -> Bool {
        guard runner.runner.serviceDomain == .system else { return true }
        errorMessage = "\(runner.runner.name) is managed by a system LaunchDaemon. RunningMan monitors it but does not start, stop or change system services."
        return false
    }

    func checkGitHub() async {
        if demoMode { githubAccount = "octocat"; return }
        do { githubAccount = try await installer.account() }
        catch { errorMessage = Self.message(error) }
    }

    func connectForgejo(server: String, token: String) async -> Bool {
        guard let rawURL = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Enter an HTTPS Forgejo server URL."
            return false
        }
        do {
            let origin = try ForgejoConnectionStore.origin(for: rawURL)
            if demoMode { forgejoAccount = "octocat"; return true }
            if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await forgejoConnections.setToken(token, for: origin)
            }
            let account = try await forgejoInstaller.account(serverURL: origin)
            forgejoAccount = account
            defaultForgejoServer = origin.absoluteString
            if !forgejoServers.contains(origin) { forgejoServers.append(origin) }
            UserDefaults.standard.set(forgejoServers.map(\.absoluteString), forKey: "forgejoServers")
            UserDefaults.standard.set(defaultForgejoServer, forKey: "defaultForgejoServer")
            lastWorkloadAttempt = nil
            await workloadMonitor.invalidate()
            record(title: "Forgejo connected", detail: origin.host, kind: .success)
            await refreshWorkload(force: true)
            return true
        } catch { errorMessage = Self.message(error); return false }
    }

    func forgetForgejo(_ server: URL) async {
        if demoMode { forgejoServers.removeAll { $0 == server }; return }
        do {
            try await forgejoConnections.removeToken(for: server)
            forgejoServers.removeAll { $0 == server }
            UserDefaults.standard.set(forgejoServers.map(\.absoluteString), forKey: "forgejoServers")
            forgejoAccount = nil
            workload = nil
            await workloadMonitor.invalidate()
        } catch { errorMessage = Self.message(error) }
    }

    func createForgejoRunner(server: String, scope: ForgejoRunnerScope, scopeName: String,
                             name: String, labels: String, capacity: Int, startsAtLogin: Bool) async -> Bool {
        guard !isCreating else { return false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanName.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else {
            errorMessage = "Use a runner name of up to 64 letters, numbers, dots, underscores or dashes, beginning with a letter or number."
            return false
        }
        guard let rawURL = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              let origin = try? ForgejoConnectionStore.origin(for: rawURL) else {
            errorMessage = "Enter an HTTPS Forgejo server URL."
            return false
        }
        isCreating = true
        creationProgress = "Preparing your Forgejo runner…"
        defer { isCreating = false }
        let root = demoMode ? URL(fileURLWithPath: "/Users/demo/Runners", isDirectory: true)
            : Self.supportDirectory.appendingPathComponent("Runners", isDirectory: true)
        let directory = root.appendingPathComponent(cleanName, isDirectory: true)
        let customLabels = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if demoMode {
            let remote = scopeName.isEmpty ? origin : origin.appendingPathComponent(scopeName)
            let runner = InstalledRunner(name: cleanName, directory: directory, githubURL: remote,
                                         labels: customLabels, provider: .forgejo, capacity: capacity)
            runners.append(RunnerSnapshot(runner: runner, status: .idle, processID: 9100, startsAtLogin: startsAtLogin))
            selectedRunnerID = runner.id; section = .runners
            creationProgress = "Demo Forgejo runner created"
            return true
        }
        do {
            let request = CreateForgejoRunnerRequest(serverURL: origin, scope: scope, scopeName: scopeName,
                name: cleanName, labels: customLabels, directory: directory,
                capacity: capacity, startsAtLogin: startsAtLogin, startImmediately: true)
            let runner = try await forgejoInstaller.create(request) { [weak self] message in
                Task { @MainActor in self?.creationProgress = SecretRedactor.redact(message) }
            }
            record(title: "Forgejo runner created", runnerID: runner.id, detail: runner.name, kind: .success)
            selectedRunnerID = runner.id; section = .runners
            lastWorkloadAttempt = nil
            await refresh()
            return true
        } catch {
            creationProgress = Self.message(error); errorMessage = Self.message(error)
            record(title: "Forgejo setup failed", detail: Self.message(error), kind: .failure)
            return false
        }
    }

    func createRunner(githubURL: String, name: String, labels: String, startsAtLogin: Bool) async -> Bool {
        guard !isCreating else { return false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanName.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else {
            errorMessage = "Use a runner name of up to 64 letters, numbers, dots, underscores or dashes, beginning with a letter or number."
            return false
        }
        guard let url = URL(string: githubURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "Enter a GitHub repository or organization URL."
            return false
        }
        isCreating = true
        creationProgress = "Preparing your runner…"
        defer { isCreating = false }
        let root = demoMode ? URL(fileURLWithPath: "/Users/demo/Runners", isDirectory: true)
            : Self.supportDirectory.appendingPathComponent("Runners", isDirectory: true)
        let directory = root.appendingPathComponent(cleanName, isDirectory: true)
        let customLabels = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if demoMode {
            let runner = InstalledRunner(name: cleanName, directory: directory, githubURL: url, labels: customLabels)
            runners.append(RunnerSnapshot(runner: runner, status: .idle, startsAtLogin: startsAtLogin))
            selectedRunnerID = runner.id
            section = .runners
            creationProgress = "Demo runner created"
            return true
        }
        do {
            let request = CreateRunnerRequest(githubURL: url, name: cleanName, labels: customLabels,
                                             directory: directory, startsAtLogin: startsAtLogin, startImmediately: true)
            let runner = try await installer.create(request) { [weak self] message in
                Task { @MainActor in self?.creationProgress = SecretRedactor.redact(message) }
            }
            record(title: "Runner created", runnerID: runner.id, detail: runner.name, kind: .success)
            selectedRunnerID = runner.id
            section = .runners
            await refresh()
            return true
        } catch {
            creationProgress = Self.message(error)
            errorMessage = Self.message(error)
            record(title: "Runner creation failed", detail: Self.message(error), kind: .failure)
            return false
        }
    }

    func importRunner() {
        guard !demoMode else {
            errorMessage = "This is a preview workspace. Open RunningMan normally to import a real runner."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Add an existing runner"
        panel.message = "Choose a configured GitHub runner folder, a RunningMan Forgejo installation, or a Forgejo folder referenced by a user login service."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add runners"
        guard panel.runModal() == .OK else { return }
        Task {
            for url in panel.urls {
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                let result = await discovery.discover(additionalDirectories: [canonical])
                guard result.runners.contains(where: { $0.directory.standardizedFileURL == canonical }) else {
                    errorMessage = "No configured runner was found in \(canonical.lastPathComponent). Choose a GitHub runner folder, a RunningMan Forgejo installation, or a Forgejo folder used by a login service."
                    continue
                }
                if !importedDirectories.contains(canonical) { importedDirectories.append(canonical) }
                record(title: "Existing runner added", detail: canonical.lastPathComponent)
                selectedRunnerID = canonical.path
            }
            UserDefaults.standard.set(importedDirectories.map(\.path), forKey: "importedRunnerDirectories")
            section = .runners
            await refresh()
        }
    }

    func revealRunner(_ runner: InstalledRunner) { NSWorkspace.shared.open(runner.directory) }
    func openGitHub(_ runner: InstalledRunner) { if let url = runner.remoteURL { openServerLink(url) } }
    func openJob(_ job: RunnerJob) {
        if let url = job.runURL { openServerLink(url) }
    }
    func openServerLink(_ url: URL) {
        let knownHosts = Set(["github.com"] + runners.compactMap { $0.runner.remoteURL?.host?.lowercased() }
            + forgejoServers.compactMap { $0.host?.lowercased() })
        guard url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), knownHosts.contains(host) else { return }
        NSWorkspace.shared.open(url)
    }
    func clearHistory() {
        confirmation = RunnerConfirmation(title: "Clear saved job history?",
            message: "Clears RunningMan’s saved history. Runner diagnostic files are kept; jobs still present in those files may appear again after refreshing.",
            buttonTitle: "Clear history")
        pendingConfirmation = .clearHistory
    }
    private func clearHistoryConfirmed() {
        Task {
            do { if !demoMode { try await history.clear() }; jobs = []; record(title: "Saved job history cleared") }
            catch { errorMessage = Self.message(error) }
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export runner diagnostics"
        panel.message = "Includes runner names, installation paths, job and cleanup history, and redacted log excerpts. Registration credentials are never included."
        panel.nameFieldStringValue = "RunningMan-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        struct Report: Encodable {
            struct State: Encodable {
                var runner: InstalledRunner
                var status: RunnerStatus
                var processID: Int32?
                var startsAtLogin: Bool
                var enabled: Bool
            }
            var generatedAt: Date
            var runners: [State]
            var jobs: [RunnerJob]
            var events: [ActivityEvent]
            var cleanup: [RunnerCleanupRecord]
            var logs: [String: String]
            var warnings: [String]
        }
        let report = Report(generatedAt: Date(), runners: runners.map {
            .init(runner: $0.runner, status: $0.status, processID: $0.processID,
                  startsAtLogin: $0.startsAtLogin, enabled: $0.isEnabled)
        }, jobs: jobs, events: events, cleanup: cleanupRecords, logs: logTails.mapValues(SecretRedactor.redact), warnings: warnings)
        Task {
            do {
                try await Task.detached {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(report)
                    let scrubbed = SecretRedactor.redact(String(decoding: data, as: UTF8.self))
                    try Data(scrubbed.utf8).write(to: destination, options: .atomic)
                }.value
                record(title: "Diagnostics exported", detail: destination.lastPathComponent, kind: .success)
            } catch { errorMessage = Self.message(error) }
        }
    }

    private func updateSelectedLog() {
        let next = selectedRunnerID.flatMap { logTails[$0] } ?? ""
        if next != logText { logText = next }
    }
    private static func message(_ error: Error) -> String { SecretRedactor.redact(error.localizedDescription) }
    private func record(title: String, runnerID: String? = nil, detail: String? = nil, kind: ActivityKind = .info) {
        record(ActivityEvent(runnerID: runnerID, title: title, detail: detail.map(SecretRedactor.redact), kind: kind))
    }
    private func record(_ event: ActivityEvent) {
        guard observedEventKeys.insert(ActivityIdentity(event)).inserted else { return }
        events.append(event)
        events.sort { $0.date > $1.date }
        if events.count > 500 { events = Array(events.prefix(500)) }
        if observedEventKeys.count > 2_000 { observedEventKeys = Set(events.map(ActivityIdentity.init)) }
        if !demoMode { Task { await eventStore.append(event) } }
    }

    private func updateSleepPrevention() {
        guard !demoMode else { return }
        if keepAwakeWhileBusy && busyCount > 0 {
            guard sleepPrevention?.isRunning != true else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run(); sleepPrevention = process }
            catch { warnings.append("Could not prevent idle sleep: \(Self.message(error))") }
        } else {
            if let process = sleepPrevention, process.isRunning { process.terminate() }
            sleepPrevention = nil
        }
    }

    private func simulate(_ action: RunnerAction, runner: RunnerSnapshot) {
        guard let index = runners.firstIndex(where: { $0.id == runner.id }) else { return }
        switch action {
        case .start: runners[index].status = .idle
        case .stop: runners[index].status = .stopped; runners[index].processID = nil; runners[index].currentJob = nil
        case .enable: runners[index].isEnabled = true; runners[index].status = .stopped
        case .disable: runners[index].isEnabled = false; runners[index].status = .disabled
        case .delete: runners.remove(at: index)
        case .drain: break
        }
        if [.start, .stop, .disable, .delete].contains(action) { drainingRunnerIDs.remove(runner.id) }
        record(title: "Demo runner updated", runnerID: runner.id)
    }

    /// Demo jobs never end on their own, so a busy demo runner with a stop-after-job request finishes
    /// its job successfully after a short pause and then takes the normal idle-stop path.
    private func simulateJobFinish(for runnerID: String) {
        let delay = demoDrainDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, drainingRunnerIDs.contains(runnerID),
                  let index = runners.firstIndex(where: { $0.id == runnerID }), runners[index].status == .busy else { return }
            if let jobID = runners[index].currentJob?.id, let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[jobIndex].outcome = .success
                jobs[jobIndex].finishedAt = Date()
            }
            runners[index].currentJob = nil
            runners[index].status = .idle
            processDrainRequests()
        }
    }

    private func loadDemo() {
        let names = ["studio-release", "swift-builder", "web-preview", "nightly-checks", "archive-runner"]
        let repos = ["octocat/WeatherKit", "octocat/TrailNotes", "octocat/Portfolio", "octocat/Orbit", "octocat/Archive"]
        let statuses: [RunnerStatus] = [.busy, .idle, .idle, .stopped, .disabled]
        for index in names.indices {
            let runner = InstalledRunner(name: names[index], directory: URL(fileURLWithPath: "/Users/demo/Runners/\(names[index])"),
                githubURL: URL(string: "https://github.com/\(repos[index])"), agentID: 100 + index,
                serviceLabel: "runningman.demo.\(index)", version: "2.337.0", labels: ["self-hosted", "macOS", "ARM64"])
            runners.append(RunnerSnapshot(runner: runner, status: statuses[index], processID: statuses[index].isRunning ? Int32(8040 + index) : nil,
                startsAtLogin: index < 4, isEnabled: index != 4))
        }
        let titles = ["Build & publish macOS app", "Unit tests", "Release universal app", "Preview deployment", "Swift package checks", "Archive & sign"]
        for index in 0..<24 {
            let runner = runners[index % 4].runner
            let started = Date().addingTimeInterval(-Double(index * 1500 + 180))
            let outcome: JobOutcome = index == 0 ? .running : (index == 7 || index == 18 ? .failure : .success)
            jobs.append(RunnerJob(id: "demo-job-\(index)", runnerID: runner.id, name: titles[index % titles.count],
                repository: runner.repository, workflow: index % 2 == 0 ? "Release" : "Continuous integration",
                runURL: URL(string: "https://github.com/\(runner.repository)/actions"),
                startedAt: started, finishedAt: outcome == .running ? nil : started.addingTimeInterval(Double(95 + index * 17)), outcome: outcome))
        }
        runners[0].currentJob = jobs.first
        let forgeURL = URL(string: "https://forge.example.com/octocat/NativeBuild")!
        let forgeRunner = InstalledRunner(name: "forge-macos", directory: URL(fileURLWithPath: "/Users/demo/Runners/forge-macos"),
            githubURL: forgeURL, agentID: 901, serviceLabel: "runningman.demo.forge.0", version: "13.2.0",
            labels: ["macos-arm64", "release"], provider: .forgejo, capacity: 2)
        let docsRunner = InstalledRunner(name: "forge-docs", directory: URL(fileURLWithPath: "/Users/demo/Runners/forge-docs"),
            githubURL: forgeURL, agentID: 902, serviceLabel: "runningman.demo.forge.1", version: "13.2.0",
            labels: ["docs"], provider: .forgejo)
        runners += [RunnerSnapshot(runner: forgeRunner, status: .busy, processID: 9051, startsAtLogin: true),
                    RunnerSnapshot(runner: docsRunner, status: .idle, processID: 9052, startsAtLogin: true)]
        forgejoServers = [URL(string: "https://forge.example.com")!]
        forgejoAccount = "octocat"
        let now = Date()
        let ratios = [0.74, 0.42, 0.09, 0.28, 0.02, 0.91, 0.18]
        for (index, runner) in runners.enumerated() {
            observedUsage[runner.id] = ObservedRunnerUsage(observedSeconds: 21_600,
                busySeconds: 21_600 * ratios[index], busyFraction: ratios[index],
                windowStart: now.addingTimeInterval(-86_400), windowEnd: now)
        }
        let githubRunner = runners[0].runner
        let githubQueue = (0..<3).map { index in
            WorkloadJob(id: "demo-github-queued-\(index)", name: ["Release app", "Integration tests", "Build preview"][index],
                repository: githubRunner.repository, workflow: "Release", url: URL(string: "https://github.com/\(githubRunner.repository)/actions"),
                state: .queued, labels: ["self-hosted", "macOS", "ARM64"],
                createdAt: now.addingTimeInterval(-Double(720 - index * 180)))
        }
        let forgeQueue = (0..<6).map { index in
            WorkloadJob(id: "demo-forgejo-queued-\(index)", name: index.isMultiple(of: 2) ? "Build macOS app" : "Run native tests",
                repository: "octocat/NativeBuild", workflow: "Native build", url: forgeURL.appendingPathComponent("actions"),
                state: .queued, labels: ["macos-arm64"])
        }
        workload = WorkloadReport(scopes: [
            WorkloadScopeSnapshot(scopeURL: githubRunner.remoteURL!, provider: .github, state: .available,
                message: "Queued jobs can be claimed by any runner with the required labels.", jobs: githubQueue,
                runnerIDs: [githubRunner.id], runnerLabels: [githubRunner.id: githubRunner.labels], capacity: 1),
            WorkloadScopeSnapshot(scopeURL: forgeURL, provider: .forgejo, state: .partial,
                message: "This Forgejo version omits queue timestamps and per-job runner assignment. Running jobs describe the compatible pool; active runner state confirms at least one job.",
                jobs: forgeQueue + [WorkloadJob(id: "demo-forgejo-running", name: "Publish universal app", repository: "octocat/NativeBuild",
                    url: forgeURL.appendingPathComponent("actions"), state: .running, labels: ["macos-arm64"])],
                runnerIDs: [forgeRunner.id, docsRunner.id], runnerLabels: [forgeRunner.id: forgeRunner.labels, docsRunner.id: docsRunner.labels],
                capacity: 3, remoteBusyRunnerIDs: [forgeRunner.id])
        ])
        cleanupRecords = [
            RunnerCleanupRecord(id: "B314EC3B-B92B-4BE6-A1B1-F846511BB090", runnerID: runners[1].id,
                repository: runners[1].runner.repository, runID: "1048", runAttempt: "1", job: "Release app",
                runURL: URL(string: "https://github.com/octocat/TrailNotes/actions/runs/1048"),
                startedAt: now.addingTimeInterval(-2100), finishedAt: now.addingTimeInterval(-1500), status: .success,
                bytesRemoved: 3_250_000_000, filesRemoved: 18_420,
                paths: [RunnerCleanupPath(path: "/Users/demo/Runners/swift-builder/_work/_temp/runningman-release-example", status: .success,
                    bytesRemoved: 3_250_000_000, filesRemoved: 18_420)]),
            RunnerCleanupRecord(id: "DD2ADAD6-3F4B-4FB0-8886-843DD8FAEDDB", runnerID: runners[2].id,
                repository: runners[2].runner.repository, runID: "1047", runAttempt: "1", job: "Release app",
                runURL: URL(string: "https://github.com/octocat/Portfolio/actions/runs/1047"),
                startedAt: now.addingTimeInterval(-5700), finishedAt: now.addingTimeInterval(-5100), status: .success,
                bytesRemoved: 890_000_000, filesRemoved: 4_080, paths: []),
            RunnerCleanupRecord(id: "24E01585-E5B9-4B7A-A9FE-545A63FB94EA", runnerID: runners[3].id,
                repository: runners[3].runner.repository, runID: "1046", runAttempt: "1", job: "Release app",
                runURL: nil, startedAt: now.addingTimeInterval(-7500), finishedAt: now.addingTimeInterval(-6900), status: .failed,
                bytesRemoved: 0, filesRemoved: 0, paths: [], message: "Workspace ownership could not be verified. No files were deleted."),
            RunnerCleanupRecord(id: "9EC3EE52-1D86-4269-924F-B031D144B4AB", runnerID: runners[0].id,
                repository: runners[0].runner.repository, runID: "1049", runAttempt: "1", job: "Release app",
                runURL: nil, startedAt: now.addingTimeInterval(-180), finishedAt: nil, status: .pending,
                bytesRemoved: 0, filesRemoved: 0, paths: [])
        ]
        selectedRunnerID = runners.first?.id
        githubAccount = "octocat"
        events = [
            ActivityEvent(date: Date().addingTimeInterval(-180), runnerID: runners[0].id,
                title: "Release build started", detail: "studio-release · WeatherKit", kind: .info),
            ActivityEvent(date: Date().addingTimeInterval(-920), runnerID: runners[1].id,
                title: "Unit tests passed", detail: "swift-builder · 128 tests", kind: .success),
            ActivityEvent(date: Date().addingTimeInterval(-1800), runnerID: runners[2].id,
                title: "Preview deployed", detail: "web-preview · Portfolio", kind: .success)
        ]
        for runner in runners {
            logTails[runner.id] = """
            [13:42:01 INFO] Runner connected to GitHub.
            [13:42:02 INFO] Listening for jobs.
            [13:43:15 INFO] Running job: Build & publish macOS app
            [13:43:15 INFO] Repository: \(runner.runner.repository)
            [13:43:16 INFO] Checking out main…
            [13:43:18 INFO] Restoring build cache…
            [13:43:21 INFO] Building arm64 and x86_64…
            [13:44:02 INFO] Build completed. Running tests…
            """
        }
        lastUpdated = Date()
        updateSelectedLog()
    }
}

struct ActivityIdentity: Hashable {
    let runnerID: String?
    let timestamp: Int64
    let title: String
    let detail: String?
    init(_ event: ActivityEvent) {
        runnerID = event.runnerID
        timestamp = Int64(event.date.timeIntervalSince1970.rounded(.down))
        title = event.title
        detail = event.detail
    }
}

actor ActivityStore {
    let url: URL
    private var items: [ActivityEvent]?
    init(url: URL) { self.url = url }
    func load() -> [ActivityEvent] {
        if let items { return items }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([ActivityEvent].self, from: $0) } ?? []
        var seen: Set<ActivityIdentity> = []
        let loaded = Array(decoded.filter { seen.insert(ActivityIdentity($0)).inserted }
            .sorted { $0.date > $1.date }.prefix(500))
        items = loaded
        return loaded
    }
    func append(_ event: ActivityEvent) {
        var next = load()
        guard !next.contains(where: { ActivityIdentity($0) == ActivityIdentity(event) }) else { return }
        next.append(event)
        next.sort { $0.date > $1.date }
        next = Array(next.prefix(500))
        items = next
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(next).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* The live activity view remains available if storage is unavailable. */ }
    }
}
