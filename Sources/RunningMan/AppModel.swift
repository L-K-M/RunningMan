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

struct RunnerConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let buttonTitle: String
}

@MainActor @Observable
final class AppModel {
    var runners: [RunnerSnapshot] = [] { didSet { runnersChanged() } }
    var jobs: [RunnerJob] = [] { didSet { jobsChanged() } }
    var events: [ActivityEvent] = []
    var warnings: [String] = []
    var workload: WorkloadReport? { didSet { rebuildQueueCaches() } }
    /// Republished only when a displayed figure changes; see `observedUsageDisplayChanged`.
    var observedUsage: [String: ObservedRunnerUsage] = [:]
    // Derived from jobs, runners and workload once per change, so view bodies only
    // look values up instead of filtering, sorting or recalculating on every render.
    private(set) var sortedJobs: [RunnerJob] = []
    private(set) var jobsByRunner: [String: [RunnerJob]] = [:]
    private(set) var recentJobs: [RunnerJob] = []
    private(set) var successfulJobs = 0
    private(set) var completedJobCount = 0
    private(set) var usageByRunner: [String: RunnerUsageMetrics] = [:]
    private(set) var runnerNames: [String: String] = [:]
    /// Compatible queued jobs per runner. A missing entry means unknown, not zero.
    private(set) var compatibleQueueByRunner: [String: Int] = [:]
    private(set) var fleetQueue = FleetQueueSummary()
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
            }
        }
    }
    var selectedRunnerID: String?
    var section: AppSection = .overview
    var searchText = ""
    /// Set only by `refreshNow()`, so background polls never animate the toolbar.
    private(set) var isManualRefreshing = false
    var busyRunnerIDs: Set<String> = []
    var drainingRunnerIDs: Set<String> = []
    var lastUpdated: Date?
    var logText = ""
    /// Steps and output of each GitHub runner's most recent job, by runner ID.
    var stepLogs: [String: JobStepLog] = [:]
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
    @ObservationIgnored private let controller: RunnerServiceController
    @ObservationIgnored private let installer = GitHubRunnerInstaller()
    @ObservationIgnored private let forgejoInstaller: ForgejoRunnerInstaller
    @ObservationIgnored private let forgejoConnections: ForgejoConnectionStore
    @ObservationIgnored private let forgejoLogs = ForgejoLogMonitor()
    @ObservationIgnored private let workloadMonitor: WorkloadMonitor
    @ObservationIgnored private let cleanupMonitor = RunnerCleanupMonitor()
    @ObservationIgnored private let history: RunnerHistoryStore
    @ObservationIgnored private let eventStore: ActivityStore
    @ObservationIgnored private let activitySamples: RunnerActivityStore
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var workloadTask: Task<WorkloadReport, Never>?
    @ObservationIgnored private var lastWorkloadAttempt: Date?
    @ObservationIgnored private var pendingAction: (() -> Void)?
    @ObservationIgnored private var sleepPrevention: Process?
    @ObservationIgnored private var logTails: [String: String] = [:]
    @ObservationIgnored private var importedDirectories: [URL] = []
    @ObservationIgnored private var observedEventKeys: Set<ActivityIdentity> = []
    @ObservationIgnored private let refreshes = RefreshCoalescer()
    @ObservationIgnored private var usageComputedAt: Date?
    @ObservationIgnored private var usageCapacities: [String: Int] = [:]
    @ObservationIgnored var showMainWindow: (() -> Void)?

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RunningMan", isDirectory: true)
    }

    init(demoMode: Bool = CommandLine.arguments.contains("--demo")) {
        self.demoMode = demoMode
        // One credential store and API client, so a token read from Keychain or saved
        // by Connect is shared by status checks, queue monitoring and runner setup.
        let connections = ForgejoConnectionStore()
        let forgejoAPI = ForgejoAPIClient(tokens: connections)
        forgejoConnections = connections
        controller = RunnerServiceController(forgejoAPI: forgejoAPI)
        forgejoInstaller = ForgejoRunnerInstaller(api: forgejoAPI)
        workloadMonitor = WorkloadMonitor(forgejo: forgejoAPI)
        history = RunnerHistoryStore(fileURL: Self.supportDirectory.appendingPathComponent("jobs.json"))
        eventStore = ActivityStore(url: Self.supportDirectory.appendingPathComponent("activity.json"))
        activitySamples = RunnerActivityStore(fileURL: Self.supportDirectory.appendingPathComponent("observed-activity.json"))
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
        }
    }

    var selectedRunner: RunnerSnapshot? { runners.first { $0.id == selectedRunnerID } }
    var filteredRunners: [RunnerSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? runners : runners.filter {
            [$0.runner.name, $0.runner.repository, $0.runner.provider.title, $0.status.title, $0.runner.directory.path]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    /// Newest first; filtering keeps the order of `sortedJobs`.
    var filteredJobs: [RunnerJob] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sortedJobs }
        return sortedJobs.filter {
            [$0.name, $0.repository ?? "", $0.workflow ?? "", $0.outcome.title]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    var runningCount: Int { runners.filter { $0.status.isRunning || $0.processID != nil }.count }
    var busyCount: Int { runners.filter { $0.status == .busy }.count }
    var startsAtLoginCount: Int { runners.filter { $0.startsAtLogin && $0.isEnabled }.count }
    var successRate: Double? {
        completedJobCount == 0 ? nil : Double(successfulJobs) / Double(completedJobCount)
    }
    /// Newest first.
    func jobs(for runnerID: String) -> [RunnerJob] { jobsByRunner[runnerID] ?? [] }
    func jobCount(for runnerID: String) -> Int { jobsByRunner[runnerID]?.count ?? 0 }
    /// Passes started by the refresh coalescer; a test seam.
    var refreshPassCount: Int { refreshes.passCount }

    func startMonitoring() {
        guard pollingTask == nil, !demoMode else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            do { jobs = try await history.load() } catch { warnings = [Self.message(error)] }
            events = await eventStore.load()
            observedEventKeys = Set(events.map(ActivityIdentity.init))
            if let notice = await history.takeRecoveryNotice() { record(title: "Could not read all saved job history", detail: notice, kind: .warning) }
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

    /// Refreshes runner state. A call made while a pass is running waits for one
    /// coalesced follow-up pass, so a caller always observes state read after its request.
    func refresh() async {
        await refreshes.run { await refreshPass() }
    }

    /// The toolbar button, the Refresh command and the menu bar use this; it is the
    /// only refresh that shows progress, so background polls never animate the UI.
    func refreshNow() async {
        guard !isManualRefreshing else { return }
        isManualRefreshing = true
        defer { isManualRefreshing = false }
        await refresh()
    }

    /// Never call `refresh()` from inside a pass: it would wait for its own follow-up.
    private func refreshPass() async {
        if demoMode { markUpdated(); refreshUsageIfStale(); return }
        let result = await discovery.discover(additionalDirectories: importedDirectories)
        let states = await controller.snapshots(for: result.runners, allowRemoteActivity: remoteMonitoringEnabled)
        // Process reads in a cancelled task fail, which reads as every runner being unknown.
        // Monitoring stops when the app quits; never record that as status changes.
        guard !Task.isCancelled else { return }
        async let githubScan = logs.scan(runners: result.runners.filter { $0.provider == .github })
        async let forgejoScan = forgejoLogs.scan(runners: result.runners.filter { $0.provider == .forgejo })
        async let cleanupScan = cleanupMonitor.scan(runners: result.runners)
        let (github, forgejo) = await (githubScan, forgejoScan)
        let cleanup = await cleanupScan
        assign(\.cleanupRecords, cleanup.records)
        assign(\.cleanupWarnings, cleanup.warnings)
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
        assign(\.runners, next.sorted { $0.runner.name.localizedStandardCompare($1.runner.name) == .orderedAscending })
        var nextWarnings = Array((result.warnings + scan.warnings + cleanup.warnings).map(SecretRedactor.redact).prefix(20))
        do {
            try await activitySamples.record(snapshots: runners)
            var metrics: [String: ObservedRunnerUsage] = [:]
            for runner in runners { metrics[runner.id] = try await activitySamples.metrics(for: runner.id) }
            // The window end moves every poll, so exact values always differ.
            if Self.observedUsageDisplayChanged(from: observedUsage, to: metrics) { observedUsage = metrics }
        } catch { nextWarnings.append("Activity sampling: " + Self.message(error)) }
        do { assign(\.jobs, try await history.merge(reconciled)) }
        catch { nextWarnings.append(Self.message(error)) }
        assign(\.warnings, nextWarnings)
        logTails = scan.tails
        updateStepLogs(github.stepLogs)
        updateSelectedLog()
        for event in scan.events { record(event) }
        for runner in runners {
            if let previous = oldStates[runner.id], previous != runner.status {
                record(title: "\(runner.runner.name) · \(runner.status.title)",
                       runnerID: runner.id, detail: runner.detail,
                       kind: runner.status == .attention ? .warning : .info)
            }
            if drainingRunnerIDs.contains(runner.id), runner.status == .idle, !busyRunnerIDs.contains(runner.id) {
                runAction(.stop, on: runner)
            }
        }
        if selectedRunnerID == nil { assign(\.selectedRunnerID, runners.first?.id) }
        // A pending follow-up was requested after this pass started reading, for example
        // by an import that selected its new runner; let that pass resolve the selection.
        if let id = selectedRunnerID, !runners.contains(where: { $0.id == id }), !refreshes.hasPendingFollowUp {
            assign(\.selectedRunnerID, runners.first?.id)
        }
        updateSelectedLog()
        markUpdated()
        refreshUsageIfStale()
        updateSleepPrevention()
        if remoteMonitoringEnabled && !isRefreshingWorkload {
            Task { [weak self] in await self?.refreshWorkload() }
        }
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
        usageByRunner[runner.id] ?? RunnerUsage.calculate(runner: runner, jobs: jobs(for: runner.id))
    }
    func compatibleQueueCount(for runnerID: String) -> Int? { compatibleQueueByRunner[runnerID] }

    var filteredCleanupRecords: [RunnerCleanupRecord] {
        let query = section == .cleanup ? searchText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return cleanupRecords.filter { record in
            query.isEmpty || [record.repository, record.job, record.status.title, runnerName(for: record.runnerID)]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
    }

    func runnerName(for id: String) -> String { runnerNames[id] ?? "Runner no longer installed" }

    func latestCleanup(for runnerID: String) -> RunnerCleanupRecord? {
        cleanupRecords.filter { $0.runnerID == runnerID }.max { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }
    }

    func selectionChanged() { updateSelectedLog() }

    func perform(_ action: RunnerAction, on runner: RunnerSnapshot) {
        guard !busyRunnerIDs.contains(runner.id) else { return }
        guard requireUserService(runner) else { return }
        if action == .drain {
            if runner.runner.provider == .forgejo && !remoteMonitoringEnabled && !demoMode {
                errorMessage = "Enable server monitoring in Workload to verify when this Forgejo runner becomes idle. Stop now is available with an interruption confirmation."
                return
            }
            if drainingRunnerIDs.contains(runner.id) {
                drainingRunnerIDs.remove(runner.id)
                record(title: "Stop-after-job cancelled", runnerID: runner.id)
            } else {
                drainingRunnerIDs.insert(runner.id)
                record(title: "Will stop after the current job", runnerID: runner.id)
                if runner.status == .idle { runAction(.stop, on: runner) }
            }
            return
        }
        if action == .delete {
            confirmation = RunnerConfirmation(title: "Remove \(runner.runner.name)?",
                message: "Unregisters this runner from \(runner.runner.provider.title) and removes its login service. Installation files and job history are kept. An active job will be interrupted.",
                buttonTitle: "Remove runner")
            pendingAction = { [weak self] in self?.runAction(action, on: runner, force: true) }
        } else if (runner.status == .busy || runner.status == .unknown) && (action == .stop || action == .disable) {
            confirmation = RunnerConfirmation(title: runner.status == .busy ? "Interrupt the active job?" : "Stop with activity unverified?",
                message: runner.status == .busy ? "\(runner.runner.name) is building right now. This will stop the runner and interrupt its job. Choose “Stop when idle” to let it finish." : "RunningMan cannot verify whether \(runner.runner.name) has active jobs. Stopping may interrupt work.",
                buttonTitle: action == .disable ? "Disable and interrupt" : "Stop and interrupt")
            pendingAction = { [weak self] in self?.runAction(action, on: runner, force: true) }
        } else { runAction(action, on: runner) }
    }

    func confirmPendingAction() {
        let action = pendingAction
        confirmation = nil
        pendingAction = nil
        action?()
    }
    func cancelPendingAction() { confirmation = nil; pendingAction = nil }

    private func runAction(_ action: RunnerAction, on runner: RunnerSnapshot, force: Bool = false) {
        if demoMode { simulate(action, runner: runner); return }
        busyRunnerIDs.insert(runner.id)
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
                if action == .stop || action == .disable || action == .delete { drainingRunnerIDs.remove(runner.id) }
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
                errorMessage = Self.message(error)
                record(title: "Runner action failed", runnerID: runner.id, detail: Self.message(error), kind: .failure)
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
            let account = try await forgejoInstaller.connect(serverURL: origin, candidateToken: token, savingTo: forgejoConnections)
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

    func revealRunner(_ runner: InstalledRunner) {
        // Opening a directory that LaunchServices treats as a package launches it, so
        // only a folder known not to be a package is opened; anything else is revealed.
        if (try? runner.directory.resourceValues(forKeys: [.isPackageKey]).isPackage) == false {
            NSWorkspace.shared.open(runner.directory)
        } else { NSWorkspace.shared.activateFileViewerSelecting([runner.directory]) }
    }
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
        pendingAction = { [weak self] in
            guard let self else { return }
            Task {
                do { if !self.demoMode { try await self.history.clear() }; self.jobs = []; self.record(title: "Saved job history cleared") }
                catch { self.errorMessage = Self.message(error) }
            }
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export runner diagnostics"
        panel.message = "Includes runner names, installation paths, job and cleanup history, and redacted log excerpts. Registration credentials are never included."
        panel.nameFieldStringValue = "RunningMan-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let generatedAt = Date(), runners = self.runners, jobs = self.jobs, events = self.events
        let cleanup = cleanupRecords, logs = logTails, warnings = self.warnings
        Task {
            do {
                try await Task.detached {
                    let data = try AppModel.diagnosticsReportData(generatedAt: generatedAt, runners: runners, jobs: jobs,
                        events: events, cleanup: cleanup, logs: logs, warnings: warnings)
                    try data.write(to: destination, options: .atomic)
                }.value
                record(title: "Diagnostics exported", detail: destination.lastPathComponent, kind: .success)
            } catch { errorMessage = Self.message(error) }
        }
    }

    /// Assigns only changed logs, so views of other runners are not invalidated on every poll.
    private func updateStepLogs(_ next: [String: JobStepLog]) {
        for (runnerID, log) in next where stepLogs[runnerID]?.revision != log.revision {
            stepLogs[runnerID] = log
        }
        for runnerID in stepLogs.keys where next[runnerID] == nil {
            stepLogs[runnerID] = nil
        }
    }

    private struct DiagnosticsReport: Encodable {
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

    /// Redacts each free-text field once, then encodes. Redacting the encoded JSON instead can
    /// consume the backslash that escapes a quote, and never sees URLs because the encoder
    /// escapes their slashes.
    nonisolated static func diagnosticsReportData(generatedAt: Date, runners: [RunnerSnapshot], jobs: [RunnerJob],
                                                  events: [ActivityEvent], cleanup: [RunnerCleanupRecord],
                                                  logs: [String: String], warnings: [String]) throws -> Data {
        let redact: (String) -> String = SecretRedactor.redact
        let report = DiagnosticsReport(generatedAt: generatedAt, runners: runners.map {
            var runner = $0.runner
            runner.name = redact(runner.name); runner.labels = runner.labels.map(redact); runner.githubURL = exportable(runner.githubURL)
            return .init(runner: runner, status: $0.status, processID: $0.processID,
                         startsAtLogin: $0.startsAtLogin, enabled: $0.isEnabled)
        }, jobs: jobs.map {
            var job = $0
            // A job seen without its dispatch line has an id built from its raw name.
            job.id = redact(job.id)
            job.name = redact(job.name); job.repository = job.repository.map(redact); job.workflow = job.workflow.map(redact)
            job.runURL = exportable(job.runURL)
            return job
        }, events: events.map {
            var event = $0
            event.title = redact(event.title); event.detail = event.detail.map(redact)
            return event
        }, cleanup: cleanup.map {
            var record = $0
            record.repository = redact(record.repository); record.job = redact(record.job); record.message = record.message.map(redact)
            record.runURL = exportable(record.runURL)
            record.paths = record.paths.map { var path = $0; path.path = redact(path.path); path.message = path.message.map(redact); return path }
            return record
        }, logs: logs.mapValues(redact), warnings: warnings.map(redact))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Paths, runner ids and log keys are not redacted field by field; a token pasted into a folder
        // name is still caught by the token-only pass, which cannot break the JSON.
        return Data(SecretRedactor.redactTokenLiterals(String(decoding: try encoder.encode(report), as: UTF8.self)).utf8)
    }

    /// Remote links are exported only when they carry nothing redaction would hide.
    private nonisolated static func exportable(_ url: URL?) -> URL? {
        guard let url, url.user == nil, url.password == nil,
              SecretRedactor.redact(url.absoluteString) == url.absoluteString else { return nil }
        return url
    }

    private func updateSelectedLog() {
        let next = selectedRunnerID.flatMap { logTails[$0] } ?? ""
        if next != logText { logText = next }
    }

    /// Writes only real changes. The Observation macro in the Swift 6.1 toolchain used
    /// for CI and releases notifies observers on every assignment, even of an equal
    /// value, which would re-render most views on every poll.
    @discardableResult
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>, _ value: Value) -> Bool {
        guard self[keyPath: keyPath] != value else { return false }
        self[keyPath: keyPath] = value
        return true
    }

    /// Views show the refresh time to the minute, so a poll within the same minute
    /// leaves it unchanged.
    private func markUpdated(at date: Date = Date()) {
        guard !Self.isSameDisplayedMinute(lastUpdated, date) else { return }
        lastUpdated = date
    }

    private func jobsChanged() {
        let sorted = jobs.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }
        assign(\.sortedJobs, sorted)
        assign(\.recentJobs, Array(sorted.prefix(4)))
        assign(\.successfulJobs, sorted.filter { $0.outcome == .success }.count)
        assign(\.completedJobCount, sorted.filter { [.success, .failure, .cancelled].contains($0.outcome) }.count)
        if assign(\.jobsByRunner, Dictionary(grouping: sorted, by: \.runnerID)) { rebuildUsage() }
    }

    private func runnersChanged() {
        assign(\.runnerNames, Dictionary(runners.map { ($0.id, $0.runner.name) }, uniquingKeysWith: { first, _ in first }))
        // Status changes every few polls; recorded usage only depends on identity and capacity.
        if Self.capacities(of: runners) != usageCapacities { rebuildUsage() }
        rebuildQueueCaches()
    }

    /// Recalculates recorded usage from each runner's own jobs. The sliding 24-hour
    /// window otherwise advances at most once a minute through `refreshUsageIfStale`.
    private func rebuildUsage(now: Date = Date()) {
        usageCapacities = Self.capacities(of: runners)
        usageComputedAt = now
        var usage: [String: RunnerUsageMetrics] = [:]
        for snapshot in runners where usage[snapshot.id] == nil {
            usage[snapshot.id] = RunnerUsage.calculate(runner: snapshot.runner, jobs: jobs(for: snapshot.id), now: now)
        }
        assign(\.usageByRunner, usage)
    }

    private func refreshUsageIfStale(now: Date = Date()) {
        guard usageComputedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        rebuildUsage(now: now)
    }

    /// Fleet figures use every scope, not the search-filtered `visibleWorkloadScopes`.
    private func rebuildQueueCaches() {
        let scopes = workload?.scopes ?? []
        assign(\.compatibleQueueByRunner, FleetQueueSummary.compatibleQueueCounts(scopes: scopes, runnerIDs: runners.map(\.id)))
        assign(\.fleetQueue, FleetQueueSummary(scopes: scopes))
    }

    private static func capacities(of runners: [RunnerSnapshot]) -> [String: Int] {
        Dictionary(runners.map { ($0.id, $0.runner.capacity) }, uniquingKeysWith: { first, _ in first })
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
        case .stop: runners[index].status = .stopped; drainingRunnerIDs.remove(runner.id)
        case .enable: runners[index].isEnabled = true; runners[index].status = .stopped
        case .disable: runners[index].isEnabled = false; runners[index].status = .disabled
        case .delete: runners.remove(at: index)
        case .drain: break
        }
        record(title: "Demo runner updated", runnerID: runner.id)
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
        stepLogs[runners[0].id] = Self.demoStepLog(runnerID: runners[0].id, jobID: "demo-job-0",
            startedAt: jobs[0].startedAt, isFinished: false, steps: [
                ("Set up job", 3, .success, [
                    "Current runner version: '2.337.0'", "> Runner Image Provisioner", "  Hosted Compute Agent",
                    "> Operating System", "  macOS", "  15.5", "Prepare workflow directory",
                    "Prepare all required actions", "Download action repository 'actions/checkout@v4'",
                    "Complete job name: Build & publish macOS app"]),
                ("Run actions/checkout@v4", 4, .success, [
                    "> Run actions/checkout@v4", "  with:", "    repository: octocat/WeatherKit", "    fetch-depth: 1",
                    "Syncing repository: octocat/WeatherKit", "$ /usr/bin/git version", "git version 2.50.1",
                    "> Fetching the repository", "  $ /usr/bin/git -c protocol.version=2 fetch --no-tags --depth=1 origin",
                    "Checking out the ref", "$ /usr/bin/git log -1 --format=%H", "5e1c0a2d9b7f4c3e8a6b1d0f2e4c6a8b0d2f4e6a"]),
                ("Restore build cache", 6, .success, [
                    "> Run actions/cache@v4", "  with:", "    path: .build", "    key: macos-spm-example",
                    "Cache restored from key: macos-spm-example"]),
                ("Build app bundle", nil, .running, [
                    "> Run scripts/build-app.sh release", "  scripts/build-app.sh release", "  shell: /bin/bash -e {0}",
                    "Building for production...", "compile WeatherCore (24 files)", "compile WeatherKit (61 files)",
                    "! Sources/WeatherKit/ForecastView.swift:88:13: 'foregroundColor' is deprecated: use foregroundStyle",
                    "link WeatherKit", "compile app-icon", "codesign: build/WeatherKit.app: valid on disk"])
            ])
        stepLogs[runners[1].id] = Self.demoStepLog(runnerID: runners[1].id, jobID: "demo-job-1",
            startedAt: jobs[1].startedAt, isFinished: true, steps: [
                ("Set up job", 2, .success, ["Current runner version: '2.337.0'", "Prepare workflow directory"]),
                ("Run actions/checkout@v4", 3, .success, ["> Run actions/checkout@v4", "Syncing repository: octocat/TrailNotes"]),
                ("Run swift test", 41, .success, [
                    "> Run swift test --parallel", "  swift test --parallel", "Building for debugging...",
                    "Test Suite 'All tests' started", "Executed 128 tests, with 0 failures (0 unexpected) in 12.4 seconds"]),
                ("Upload test results", 0, .skipped, []),
                ("Post Run actions/checkout@v4", 1, .success, ["Post job cleanup.", "$ /usr/bin/git version", "git version 2.50.1"]),
                ("Complete job", 1, .success, ["Cleaning up orphan processes"])
            ])
        lastUpdated = Date()
        updateSelectedLog()
    }

    /// Fictional step output for demo mode. Line prefixes: "> " group header, "  " grouped line,
    /// "$ " command, "! " warning.
    private static func demoStepLog(runnerID: String, jobID: String, startedAt: Date, isFinished: Bool,
                                    steps: [(name: String, seconds: Double?, outcome: JobStepOutcome, lines: [String])]) -> JobStepLog {
        var lineID = 0
        var start = startedAt
        let built = steps.enumerated().map { index, step in
            let finished = step.seconds.map { start.addingTimeInterval($0) }
            let lines = step.lines.map { raw -> JobStepLine in
                defer { lineID += 1 }
                let date = start
                if raw.hasPrefix("> ") { return JobStepLine(id: lineID, date: date, text: String(raw.dropFirst(2)), kind: .groupHeader) }
                if raw.hasPrefix("  ") { return JobStepLine(id: lineID, date: date, text: String(raw.dropFirst(2)), isGrouped: true) }
                if raw.hasPrefix("$ ") { return JobStepLine(id: lineID, date: date, text: String(raw.dropFirst(2)), kind: .command) }
                if raw.hasPrefix("! ") { return JobStepLine(id: lineID, date: date, text: String(raw.dropFirst(2)), kind: .warning) }
                return JobStepLine(id: lineID, date: date, text: raw)
            }
            defer { start = finished ?? start }
            return JobStep(id: index, name: step.name, startedAt: start, finishedAt: finished, outcome: step.outcome, lines: lines)
        }
        return JobStepLog(jobID: jobID, runnerID: runnerID, isFinished: isFinished, hasOutput: true,
                          isTruncated: false, revision: 1, steps: built)
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
