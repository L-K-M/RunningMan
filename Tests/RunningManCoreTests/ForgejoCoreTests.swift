import XCTest
@testable import RunningManCore

final class ForgejoCoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("forgejo-core-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ text: String, _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    func testOldInstalledRunnerDecodesWithGitHubDefaults() throws {
        let json = #"{"name":"mac-example","directory":"file:///synthetic/runner","labels":["ARM64"]}"#
        let runner = try JSONDecoder().decode(InstalledRunner.self, from: Data(json.utf8))
        XCTAssertEqual(runner.provider, .github); XCTAssertEqual(runner.capacity, 1)
        XCTAssertNil(runner.configurationURL); XCTAssertTrue(runner.diagnosticURLs.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(InstalledRunner.self, from: JSONEncoder().encode(runner)), runner)
    }
    func testUnknownRunnerCredentialsAreNotParsedAsGitHubMetadata() async throws {
        try write("{not-public-persistent-token-data}", root.appendingPathComponent("unknown/.runner"))
        let result = await RunnerDiscovery(homeDirectory: root).discover()
        XCTAssertTrue(result.runners.isEmpty); XCTAssertTrue(result.warnings.isEmpty)
    }
    func testManagedForgejoDescriptorNeverReadsCredentialsOrYAML() async throws {
        let directory = root.appendingPathComponent("native-forgejo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = RunnerInstallationDescriptor(provider: .forgejo, name: "native-example", remoteURL: URL(string: "https://forge.example.test/team/project"),
            agentID: 42, labels: ["macos:host"], capacity: 2, executablePath: "forgejo-runner", configurationPath: "config.yaml", diagnosticPaths: ["_diag/runner.log"])
        try descriptor.write(to: directory)
        try write("this is not JSON and must not be opened", directory.appendingPathComponent(".runner"))
        try write("token: persistent-private-token", directory.appendingPathComponent("config.yaml"))
        let result = await RunnerDiscovery(homeDirectory: root).discover()
        XCTAssertEqual(result.runners.count, 1); XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.runners[0].provider, .forgejo); XCTAssertEqual(result.runners[0].capacity, 2)
        XCTAssertEqual(result.runners[0].configurationURL?.path, directory.appendingPathComponent("config.yaml").path)
        let saved = try String(contentsOf: directory.appendingPathComponent(RunnerInstallationDescriptor.fileName), encoding: .utf8)
        XCTAssertFalse(saved.contains("persistent-private-token"))
        XCTAssertEqual(try RunnerInstallationDescriptor.load(from: directory).agentID, 42)
    }
    func testImportedForgejoServiceDiscoversPublicPathsWithoutCredentials() async throws {
        let directory = root.appendingPathComponent("outside/forgejo-instance")
        try write("{persistent token: do not parse}", directory.appendingPathComponent(".runner"))
        try write("runner:\n  token: do-not-read-yaml", directory.appendingPathComponent("config.yaml"))
        let plist = root.appendingPathComponent("Library/LaunchAgents/homebrew.mxcl.forgejo-runner.plist")
        let object: [String: Any] = ["Label": "homebrew.mxcl.forgejo-runner", "WorkingDirectory": directory.path,
            "ProgramArguments": ["/opt/example/bin/forgejo-runner", "daemon", "--config", "config.yaml"],
            "StandardErrorPath": directory.appendingPathComponent("daemon.log").path]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: plist)
        let result = await RunnerDiscovery(homeDirectory: root).discover()
        XCTAssertEqual(result.runners.count, 1); XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.runners[0].provider, .forgejo); XCTAssertNil(result.runners[0].remoteURL)
        XCTAssertEqual(result.runners[0].serviceLabel, "homebrew.mxcl.forgejo-runner")
        XCTAssertEqual(result.runners[0].configurationURL?.path, directory.appendingPathComponent("config.yaml").path)
    }
    func testDescriptorRefusesDiagnosticCredentialPaths() throws {
        let descriptor = RunnerInstallationDescriptor(provider: .forgejo, name: "example", executablePath: "forgejo-runner", diagnosticPaths: [".runner"])
        XCTAssertThrowsError(try descriptor.write(to: root))
    }
    func testForgejoLogsOnlyClaimExplicitResultsAndRemainIncremental() async throws {
        let log = root.appendingPathComponent("_diag/runner.log")
        try write("""
        {"time":"2026-10-16T10:00:00Z","level":"info","msg":"[poller] launched"}
        {"time":"2026-10-16T10:01:00Z","level":"info","msg":"task 42 repo is example/project https://code.example.test https://forge.example.test"}
        {"time":"2026-10-16T10:02:00Z","level":"trace","msg":"step complete","task_id":42,"stage":"Main","jobResult":"success"}
        {"time":"2026-10-16T10:02:01Z","level":"info","msg":"authentication failed token=PRIVATE_TOKEN"}

        """, log)
        let runner = InstalledRunner(name: "native-example", directory: root, provider: .forgejo, diagnosticURLs: [log])
        let monitor = ForgejoLogMonitor()
        let initial = await monitor.scan(runners: [runner])
        XCTAssertEqual(initial.jobs.count, 1); XCTAssertEqual(initial.jobs[0].outcome, .unknown)
        XCTAssertNil(initial.jobs[0].finishedAt); XCTAssertNil(initial.jobs[0].runURL)
        XCTAssertFalse(initial.tails[runner.id]!.contains("PRIVATE_TOKEN"))
        let second = await monitor.scan(runners: [runner]); XCTAssertTrue(second.events.isEmpty)
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"time\":\"2026-10-16T10:03:00Z\",\"level\":\"trace\",\"task_id\":42,\"jobResult\":\"success\",\"stage\":\"Complete\"}\n".utf8)); try handle.close()
        let completed = await monitor.scan(runners: [runner])
        XCTAssertEqual(completed.jobs[0].outcome, .success); XCTAssertEqual(completed.jobs[0].duration, 120)
    }
    func testRecordedUsageClipsIntervalsAndAccountsForCapacity() {
        let runner = InstalledRunner(name: "two-slots", directory: root, capacity: 2)
        let now = Date(timeIntervalSince1970: 3600)
        let jobs = [
            RunnerJob(id: "before", runnerID: runner.id, name: "Build", startedAt: Date(timeIntervalSince1970: -3600), finishedAt: Date(timeIntervalSince1970: 1800), outcome: .success),
            RunnerJob(id: "overlap", runnerID: runner.id, name: "Test", startedAt: Date(timeIntervalSince1970: 900), finishedAt: Date(timeIntervalSince1970: 2700), outcome: .failure),
            RunnerJob(id: "excess", runnerID: runner.id, name: "Third", startedAt: Date(timeIntervalSince1970: 1200), finishedAt: Date(timeIntervalSince1970: 1500), outcome: .success),
            RunnerJob(id: "unknown", runnerID: runner.id, name: "No completion", startedAt: Date(timeIntervalSince1970: 0), outcome: .unknown)]
        let metrics = RunnerUsage.calculate(runner: runner, jobs: jobs, now: now, window: 3600)
        XCTAssertEqual(metrics.recordedSlotSeconds, 3600)
        XCTAssertEqual(metrics.recordedBusySeconds, 2700)
        XCTAssertEqual(metrics.recordedUtilization, 0.5)
        XCTAssertEqual(metrics.completedJobs, 3); XCTAssertEqual(metrics.jobsPerHour, 3)
        XCTAssertEqual(metrics.medianDuration, 1800)
    }
    func testObservedActivityExcludesGapsAndUncertainStateAndPersists() async throws {
        let runner = InstalledRunner(name: "observed", directory: root)
        let store = RunnerActivityStore(fileURL: root.appendingPathComponent("activity.json"))
        func snapshot(_ status: RunnerStatus) -> [RunnerSnapshot] { [RunnerSnapshot(runner: runner, status: status)] }
        for second in [0.0, 5, 10] { try await store.record(snapshots: snapshot(.busy), at: Date(timeIntervalSince1970: second)) }
        try await store.record(snapshots: snapshot(.idle), at: Date(timeIntervalSince1970: 15))
        try await store.record(snapshots: snapshot(.unknown), at: Date(timeIntervalSince1970: 20))
        try await store.record(snapshots: snapshot(.busy), at: Date(timeIntervalSince1970: 25))
        try await store.record(snapshots: snapshot(.busy), at: Date(timeIntervalSince1970: 60))
        try await store.record(snapshots: snapshot(.busy), at: Date(timeIntervalSince1970: 65))
        try await store.record(snapshots: snapshot(.busy), at: Date(timeIntervalSince1970: 90))
        let usage = try await store.metrics(for: runner.id, now: Date(timeIntervalSince1970: 90), window: 100)
        XCTAssertEqual(usage.observedSeconds, 20); XCTAssertEqual(usage.busySeconds, 15)
        XCTAssertEqual(usage.busyFraction, 0.75)
        let reloaded = try await RunnerActivityStore(fileURL: root.appendingPathComponent("activity.json")).metrics(for: runner.id, now: Date(timeIntervalSince1970: 90), window: 100)
        XCTAssertEqual(reloaded, usage)
    }
    func testObservedActivityRetainsSubsecondBoundariesAndBatchesWrites() async throws {
        let file = root.appendingPathComponent("subsecond-activity.json")
        let runner = InstalledRunner(name: "observed", directory: root)
        let snapshot = [RunnerSnapshot(runner: runner, status: .busy)]
        let store = RunnerActivityStore(fileURL: file)
        try await store.record(snapshots: snapshot, at: Date(timeIntervalSince1970: 0.125))
        let firstWrite = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try await store.record(snapshots: snapshot, at: Date(timeIntervalSince1970: 0.250))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, firstWrite)
        for second in [10.25, 20.25, 30.25] { try await store.record(snapshots: snapshot, at: Date(timeIntervalSince1970: second)) }
        let usage = try await RunnerActivityStore(fileURL: file).metrics(for: runner.id, now: Date(timeIntervalSince1970: 31), window: 60)
        XCTAssertEqual(usage.observedSeconds, 30.125, accuracy: 0.0001)
        XCTAssertEqual(usage.busySeconds, 30.125, accuracy: 0.0001)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testObservedActivityDropsOldIntervalsAndDoesNotBridgeOffline() async throws {
        let runner = InstalledRunner(name: "observed", directory: root)
        let store = RunnerActivityStore(fileURL: root.appendingPathComponent("retained-activity.json"))
        func snapshot(_ status: RunnerStatus) -> [RunnerSnapshot] { [RunnerSnapshot(runner: runner, status: status)] }
        for second in [0.0, 10] { try await store.record(snapshots: snapshot(.busy), at: Date(timeIntervalSince1970: second)) }
        try await store.record(snapshots: snapshot(.stopped), at: Date(timeIntervalSince1970: 20))
        for second in [172790.0, 172800, 172810, 172820] { try await store.record(snapshots: snapshot(.busy), at: Date(timeIntervalSince1970: second)) }
        let usage = try await store.metrics(for: runner.id, now: Date(timeIntervalSince1970: 172820), window: 48 * 3600)
        XCTAssertEqual(usage.observedSeconds, 30); XCTAssertEqual(usage.busySeconds, 30)
        let absent = try await store.metrics(for: "no-such-runner", now: Date(timeIntervalSince1970: 172820))
        XCTAssertEqual(absent.observedSeconds, 0); XCTAssertNil(absent.busyFraction)
    }

    func testOfficialTextDaemonLogsCorrelateTaskResultWithoutGuessingRunURL() async throws {
        let log = root.appendingPathComponent("daemon.log")
        try write("""
        time="2026-10-16T10:00:00Z" level=info msg="task 7 repo is example/project https://code.example.test https://forge.example.test"
        time="2026-10-16T10:01:00Z" level=trace msg="Job succeeded" jobResult=success task_id=7 stage=Complete

        """, log)
        let runner = InstalledRunner(name: "text-logger", directory: root, provider: .forgejo, diagnosticURLs: [log])
        let result = await ForgejoLogMonitor().scan(runners: [runner])
        XCTAssertEqual(result.jobs.count, 1); XCTAssertEqual(result.jobs[0].outcome, .success)
        XCTAssertEqual(result.jobs[0].duration, 60); XCTAssertNil(result.jobs[0].runURL)
    }
    func testReconcilerRetainsConcurrentRunningJobsOnlyWithinRunnerCapacity() {
        let runner = InstalledRunner(name: "multi-slot", directory: root, provider: .forgejo, capacity: 2)
        let jobs = (0..<3).map { RunnerJob(id: "job-\($0)", runnerID: runner.id, name: "Build", startedAt: Date(timeIntervalSince1970: Double($0))) }
        let result = JobReconciler.reconcile(jobs: jobs, snapshots: [RunnerSnapshot(runner: runner, status: .busy)])
        XCTAssertEqual(result.filter { $0.outcome == .running }.map(\.id), ["job-1", "job-2"])
        XCTAssertEqual(result[0].outcome, .unknown); XCTAssertNil(result[0].finishedAt)
    }

    func testRemovedForgejoInstallationIsNotRediscoveredFromPreservedCredentials() async throws {
        let directory = root.appendingPathComponent("retired-native")
        try write("binary placeholder", directory.appendingPathComponent("forgejo-runner"))
        try write("private registration data", directory.appendingPathComponent(".runner"))
        try write("private connection configuration", directory.appendingPathComponent("config.yaml"))
        let descriptor = RunnerInstallationDescriptor(provider: .forgejo, name: "retired-example", executablePath: "forgejo-runner")
        try descriptor.write(to: directory)
        let before = await RunnerDiscovery(homeDirectory: root).discover()
        XCTAssertEqual(before.runners.count, 1)
        try FileManager.default.moveItem(at: directory.appendingPathComponent(RunnerInstallationDescriptor.fileName), to: directory.appendingPathComponent("runningman-runner.removed-example.json"))
        let after = await RunnerDiscovery(homeDirectory: root).discover()
        XCTAssertTrue(after.runners.isEmpty); XCTAssertTrue(after.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.yaml").path))
    }

    func testRegistrationServiceNamedDaemonIsNotDiscoveredAsLiveRunner() async throws {
        let directory = root.appendingPathComponent("register-only")
        try write("credential file must remain unread", directory.appendingPathComponent("config.yaml"))
        let plist = root.appendingPathComponent("Library/LaunchAgents/example.registration.plist")
        let object: [String: Any] = ["Label": "example.registration", "WorkingDirectory": directory.path,
            "ProgramArguments": ["/opt/example/bin/forgejo-runner", "register", "--name", "daemon", "--config", "config.yaml"]]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: plist)
        let result = await RunnerDiscovery(homeDirectory: root).discover()
        XCTAssertTrue(result.runners.isEmpty, "A runner name or other flag value must never be mistaken for the daemon subcommand")
    }

    func testDaemonCommandConsumesFlagValuesAndAcceptsBothConfigurationOrders() {
        let executable = "/opt/example/bin/forgejo-runner"
        XCTAssertEqual(ForgejoDaemonCommand.parse(arguments: [executable, "daemon", "--config", "config.yaml"]), "config.yaml")
        XCTAssertEqual(ForgejoDaemonCommand.parse(arguments: [executable, "--config=config.yaml", "daemon"]), "config.yaml")
        XCTAssertEqual(ForgejoDaemonCommand.parse(arguments: [executable, "-c", "/private/config.yaml", "daemon", "--label", "daemon", "--fetch-interval=5s"]), "/private/config.yaml")
        XCTAssertNil(ForgejoDaemonCommand.parse(arguments: [executable, "register", "--name", "daemon", "--config", "config.yaml"]))
        XCTAssertNil(ForgejoDaemonCommand.parse(arguments: [executable, "--config", "daemon"]))
        XCTAssertNil(ForgejoDaemonCommand.parse(arguments: [executable, "daemon", "daemon", "--config", "config.yaml"]))
        XCTAssertNil(ForgejoDaemonCommand.parse(arguments: [executable, "daemon", "--config", "config.yaml", "--help"]))
        XCTAssertNil(ForgejoDaemonCommand.parse(arguments: [executable, "daemon", "--config", "one.yaml", "-c", "two.yaml"]))
    }

}
