import XCTest
@testable import RunningManCore

final class RunningManCoreTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("RunningManCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func runner(_ folder: String = "actions-runner-example") throws -> InstalledRunner {
        let url = temporary.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("_diag"), withIntermediateDirectories: true)
        return InstalledRunner(name: "build-example", directory: url, githubURL: URL(string: "https://github.com/example/desktop"))
    }

    func testDiscoveryBOMAndAbsoluteServicePathAndImportDeduplicate() async throws {
        let installation = temporary.appendingPathComponent("actions-runner-example")
        let plist = temporary.appendingPathComponent("Library/LaunchAgents/actions.runner.example.desktop.plist")
        try write("\u{feff}{\"agentName\":\"example-mac\",\"agentId\":42,\"gitHubUrl\":\"https://github.com/example/desktop\",\"labels\":[\"ARM64\",{\"name\":\"local-release\"}]}", to: installation.appendingPathComponent(".runner"))
        let properties: [String: Any] = ["Label": "actions.runner.example.desktop", "WorkingDirectory": installation.path,
            "ProgramArguments": [installation.appendingPathComponent("runsvc.sh").path]]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: plist)
        try write("\u{feff}\(plist.path)\n", to: installation.appendingPathComponent(".service"))
        try write("{\"targets\":{\"Runner.Listener/2.400.1\":{}}}", to: installation.appendingPathComponent("bin/Runner.Listener.deps.json"))
        // A credential file that cannot be parsed must never affect discovery.
        try write("DO NOT READ THIS NOT JSON", to: installation.appendingPathComponent(".credentials"))
        let alias = temporary.appendingPathComponent("runner-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: installation)
        let result = await RunnerDiscovery(homeDirectory: temporary).discover(additionalDirectories: [installation, alias])
        XCTAssertEqual(result.runners.count, 1)
        XCTAssertEqual(result.runners.first?.serviceLabel, "actions.runner.example.desktop")
        XCTAssertEqual(result.runners.first?.id, installation.path)
        XCTAssertEqual(result.runners.first?.labels, ["ARM64", "local-release"])
        XCTAssertEqual(result.runners.first?.version, "2.400.1")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testDiscoveryFindsExternalServiceButDoesNotRecursivelyScanHome() async throws {
        let external = temporary.appendingPathComponent("Elsewhere/installation")
        let deep = temporary.appendingPathComponent("Documents/deep/hidden-runner")
        let metadata = "{\"agentName\":\"external\",\"gitHubUrl\":\"https://github.com/example/desktop\"}"
        try write(metadata, to: external.appendingPathComponent(".runner"))
        try write("", to: external.appendingPathComponent("bin/Runner.Listener"))
        try write(metadata, to: deep.appendingPathComponent(".runner"))
        try write("", to: deep.appendingPathComponent("bin/Runner.Listener"))
        let plist = temporary.appendingPathComponent("Library/LaunchAgents/actions.runner.example.external.plist")
        let properties: [String: Any] = ["Label": "actions.runner.example.external", "ProgramArguments": [external.appendingPathComponent("runsvc.sh").path]]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: plist)
        let result = await RunnerDiscovery(homeDirectory: temporary).discover()
        XCTAssertEqual(result.runners.map { $0.directory.path }, [external.path])
    }

    func testMalformedRunnerProducesWarningAndDoesNotAbortOthers() async throws {
        try write("not json", to: temporary.appendingPathComponent("bad/.runner"))
        try write("", to: temporary.appendingPathComponent("bad/bin/Runner.Listener"))
        try write("{\"agentName\":\"valid\"}", to: temporary.appendingPathComponent("valid/.runner"))
        try write("", to: temporary.appendingPathComponent("valid/bin/Runner.Listener"))
        let result = await RunnerDiscovery(homeDirectory: temporary).discover()
        XCTAssertEqual(result.runners.map(\.name), ["valid"])
        XCTAssertEqual(result.warnings.count, 1)
    }

    private func writeGitHubRunner(_ name: String, at directory: URL) throws {
        try write("{\"agentName\":\"\(name)\",\"gitHubUrl\":\"https://github.com/example/desktop\"}", to: directory.appendingPathComponent(".runner"))
        try write("", to: directory.appendingPathComponent("bin/Runner.Listener"))
    }

    func testDiscoveryNeverProbesStandardHomeFoldersUnlessImportedOrReferenced() async throws {
        // A runner placed directly in a standard folder is found only if discovery looks inside it.
        for folder in ["Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public"] {
            try writeGitHubRunner("in-\(folder.lowercased())", at: temporary.appendingPathComponent(folder))
        }
        try writeGitHubRunner("home-child", at: temporary.appendingPathComponent("actions-runner"))
        try writeGitHubRunner("github-runners-child", at: temporary.appendingPathComponent("GitHubRunners/mac2"))
        let documentsRunner = temporary.appendingPathComponent("Documents/actions-runner")
        try writeGitHubRunner("documents-runner", at: documentsRunner)
        let serviceRunner = temporary.appendingPathComponent("Downloads/service-runner")
        try writeGitHubRunner("service-runner", at: serviceRunner)
        let plist = temporary.appendingPathComponent("Library/LaunchAgents/actions.runner.example.service.plist")
        let properties: [String: Any] = ["Label": "actions.runner.example.service", "WorkingDirectory": serviceRunner.path,
            "ProgramArguments": [serviceRunner.appendingPathComponent("runsvc.sh").path]]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: plist)
        let scanned = await RunnerDiscovery(homeDirectory: temporary).discover()
        XCTAssertEqual(scanned.runners.map(\.name), ["github-runners-child", "home-child", "service-runner"])
        XCTAssertTrue(scanned.warnings.isEmpty)
        let imported = await RunnerDiscovery(homeDirectory: temporary).discover(additionalDirectories: [documentsRunner])
        XCTAssertEqual(imported.runners.map(\.name), ["documents-runner", "github-runners-child", "home-child", "service-runner"])
        XCTAssertEqual(imported.runners.first?.directory.path, documentsRunner.resolvingSymlinksInPath().path)
    }

    func testDiscoveryFollowsRunnerFolderLinksOnceButNotHomeLinks() async throws {
        let home = temporary.appendingPathComponent("home")
        let external = temporary.appendingPathComponent("Volumes/Fast/mac1")
        try writeGitHubRunner("linked-runner", at: external)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("actions-runners"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("GitHubRunners"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("actions-runners/mac1"), withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("GitHubRunners/mac1-alias"), withDestinationURL: external)
        // Links to files and dangling links are not runner folders.
        try write("", to: temporary.appendingPathComponent("Volumes/Fast/notes.txt"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("actions-runners/notes"),
            withDestinationURL: temporary.appendingPathComponent("Volumes/Fast/notes.txt"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("actions-runners/missing"),
            withDestinationURL: temporary.appendingPathComponent("Volumes/Fast/missing"))
        // Links directly in the home folder, including a linked standard folder, are never followed.
        let elsewhere = temporary.appendingPathComponent("Volumes/Fast/desktop-runner")
        try writeGitHubRunner("home-link", at: elsewhere)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Desktop"), withDestinationURL: elsewhere)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("runner-shortcut"), withDestinationURL: elsewhere)
        let result = await RunnerDiscovery(homeDirectory: home).discover()
        XCTAssertEqual(result.runners.map(\.name), ["linked-runner"])
        XCTAssertEqual(result.runners.first?.directory.path, external.resolvingSymlinksInPath().path)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testDiscoveryWarnsWhenAFolderExceedsTheListingLimit() async throws {
        let roots = temporary.appendingPathComponent("actions-runners")
        let agents = temporary.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        for index in 0..<513 {
            try FileManager.default.createDirectory(at: roots.appendingPathComponent(String(format: "runner-%03d", index)), withIntermediateDirectories: true)
            try write("", to: agents.appendingPathComponent(String(format: "org.example.agent-%03d.plist", index)))
        }
        let result = await RunnerDiscovery(homeDirectory: temporary).discover()
        XCTAssertEqual(result.warnings.filter { $0.contains("first 512 entries") }.count, 2)
        XCTAssertTrue(result.warnings.contains { $0.contains("~/actions-runners") })
        XCTAssertTrue(result.warnings.contains { $0.contains("~/Library/LaunchAgents") })
        XCTAssertFalse(result.warnings.contains { $0.contains(temporary.path) })
        try FileManager.default.removeItem(at: roots.appendingPathComponent("runner-000"))
        try FileManager.default.removeItem(at: agents.appendingPathComponent("org.example.agent-000.plist"))
        let atLimit = await RunnerDiscovery(homeDirectory: temporary).discover()
        XCTAssertTrue(atLimit.warnings.isEmpty)
    }

    func testListenerJobsIncrementalCompletionAndNoDuplicateEvents() async throws {
        let runner = try runner()
        let log = runner.directory.appendingPathComponent("_diag/Runner_20261016-100000-utc.log")
        try write("""
        [2026-10-16 10:00:00Z INFO JobDispatcher] Job request 0 for plan 22222222-1111-1111-1111-111111111111 job 11111111-1111-1111-1111-111111111111 received.
        [2026-10-16 10:00:01Z INFO Terminal] WRITE LINE: 2026-10-16 10:00:01Z: Running job: release macOS

        """, to: log)
        let monitor = RunnerLogMonitor()
        let initial = await monitor.scan(runners: [runner])
        XCTAssertEqual(initial.jobs.count, 1)
        XCTAssertEqual(initial.jobs[0].outcome, .running)
        XCTAssertEqual(initial.jobs[0].name, "release macOS")
        XCTAssertEqual(initial.events.count, 1)
        let unchanged = await monitor.scan(runners: [runner])
        XCTAssertTrue(unchanged.events.isEmpty)
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
        try handle.write(contentsOf: Data("[2026-10-16 10:01:00Z INFO JobDispatcher] finish job request for job 11111111-1111-1111-1111-111111111111 with result: Succeeded\n".utf8)); try handle.close()
        let complete = await monitor.scan(runners: [runner])
        XCTAssertEqual(complete.jobs.count, 1)
        XCTAssertEqual(complete.jobs[0].outcome, .success)
        XCTAssertEqual(complete.jobs[0].duration, 59)
        XCTAssertEqual(complete.events.count, 1)
    }

    func testWorkerContextEnrichesListenerJobAndRedactsSecretContext() async throws {
        let runner = try runner()
        try write("""
        [2026-10-16 10:00:00Z INFO JobDispatcher] Job request 0 for plan p job 11111111-1111-1111-1111-111111111111 received.
        [2026-10-16 10:00:01Z INFO Terminal] WRITE LINE: Running job: build
        [2026-10-16 10:02:00Z INFO JobDispatcher] finish job request for job 11111111-1111-1111-1111-111111111111 with result: Failed

        """, to: runner.directory.appendingPathComponent("_diag/Runner_20261016-100000-utc.log"))
        let json: [String: Any] = ["jobId": "11111111-1111-1111-1111-111111111111", "jobDisplayName": "build",
            "variables": ["private.setting": ["value": "this-must-not-escape", "isSecret": true]],
            "contextData": ["github": ["t": 2, "d": [["k": "repository", "v": "example/desktop"],
                ["k": "run_id", "v": "123456"], ["k": "workflow", "v": "Publish desktop"]]]]]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted), as: UTF8.self)
        try write("[2026-10-16 10:00:01Z INFO Worker] Job message:\n\(body)\n[2026-10-16 10:00:01Z INFO JobRunner] Job ID 11111111-1111-1111-1111-111111111111\n[2026-10-16 10:01:59Z INFO JobRunner] Job result after all job steps finish: Failed\n", to: runner.directory.appendingPathComponent("_diag/Worker_20261016-100001-utc.log"))
        let result = await RunnerLogMonitor().scan(runners: [runner])
        XCTAssertEqual(result.jobs.count, 1)
        XCTAssertEqual(result.jobs[0].workflow, "Publish desktop")
        XCTAssertEqual(result.jobs[0].runURL?.absoluteString, "https://github.com/example/desktop/actions/runs/123456")
        XCTAssertEqual(result.jobs[0].outcome, .failure)
        XCTAssertFalse(result.tails[runner.id]!.contains("this-must-not-escape"))
    }

    func testMalformedLinesPartialUTF8AndTruncationRecover() async throws {
        let runner = try runner()
        let log = runner.directory.appendingPathComponent("_diag/Runner_20261016-100000-utc.log")
        try write("malformed\n[no timestamp] Running job: invented\n", to: log)
        let monitor = RunnerLogMonitor()
        let malformed = await monitor.scan(runners: [runner])
        XCTAssertTrue(malformed.jobs.isEmpty)
        try write("[2026-10-16 10:02:00Z INFO Terminal] Running job: café\n", to: log)
        let start = await monitor.scan(runners: [runner])
        XCTAssertEqual(start.jobs.count, 1)
        XCTAssertEqual(start.jobs[0].name, "café")
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
        try handle.write(contentsOf: Data("[2026-10-16 10:03:00Z INFO Terminal] Job café completed with result: Cancel".utf8)); try handle.close()
        let partial = await monitor.scan(runners: [runner])
        XCTAssertEqual(partial.jobs.first?.outcome, .running)
        let append = try FileHandle(forWritingTo: log); try append.seekToEnd(); try append.write(contentsOf: Data("ed\n".utf8)); try append.close()
        let end = await monitor.scan(runners: [runner])
        XCTAssertEqual(end.jobs.first?.outcome, .cancelled)
    }

    func testRedactorHidesCommonCredentialsWithoutDestroyingUsefulLogs() {
        let input = """
        Authorization: Bearer secretbearer
        token=registration123
        command --token registration456
        {"password":"password123", "safe":"keep"}
        {"private.setting":{"value":"secret-value","isSecret":true}}
        https://example.com/resource?sig=secret-signed&name=keep
        ghp_abcdefghijk github_pat_abcdefghijkl
        eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.signature
        Job result after all job steps finish: Succeeded
        """
        let safe = SecretRedactor.redact(input)
        for value in ["secretbearer", "registration123", "registration456", "password123", "secret-value", "secret-signed", "ghp_abcdefghijk", "github_pat_abcdefghijkl", "eyJhbGciOiJIUzI1NiJ9"] { XCTAssertFalse(safe.contains(value), value) }
        XCTAssertTrue(safe.contains("Succeeded")); XCTAssertTrue(safe.contains("keep"))
    }

    func testMalformedJobContextAndMultilinePrivateKeyRemainHidden() async throws {
        let runner = try runner()
        let log = runner.directory.appendingPathComponent("_diag/Worker_20261016-100000-utc.log")
        try write("""
        [2026-10-16 10:00:00Z INFO Worker] Job message:
        { malformed, "value":"private-setting-that-must-stay-hidden"
        [2026-10-16 10:00:01Z INFO Worker] Continuing diagnostics
        -----BEGIN RSA PRIVATE KEY-----
        private-key-body-that-must-stay-hidden
        -----END RSA PRIVATE KEY-----
        [2026-10-16 10:00:02Z INFO Worker] Listener is available

        """, to: log)
        let result = await RunnerLogMonitor().scan(runners: [runner])
        XCTAssertTrue(result.jobs.isEmpty)
        let tail = result.tails[runner.id] ?? ""
        XCTAssertFalse(tail.contains("private-setting-that-must-stay-hidden"))
        XCTAssertFalse(tail.contains("private-key-body-that-must-stay-hidden"))
        XCTAssertTrue(tail.contains("Listener is available"))
    }

    func testHistoryMergeDoesNotRegressCompletionAndPersistsEnrichmentPrivately() async throws {
        let file = temporary.appendingPathComponent("history/jobs.json")
        let store = RunnerHistoryStore(fileURL: file)
        let start = Date(timeIntervalSince1970: 1_000)
        let completed = RunnerJob(id: "one", runnerID: "runner", name: "Build", startedAt: start,
            finishedAt: start.addingTimeInterval(10), outcome: .success)
        _ = try await store.merge([completed])
        var stale = completed; stale.finishedAt = nil; stale.outcome = .running; stale.workflow = "Release"
        let merged = try await store.merge([stale])
        XCTAssertEqual(merged.first?.outcome, .success)
        XCTAssertEqual(merged.first?.workflow, "Release")
        let reload = try await RunnerHistoryStore(fileURL: file).load()
        XCTAssertEqual(reload, merged)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let modified = attributes[.modificationDate] as? Date
        _ = try await store.merge([stale])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, modified)
        try await store.clear(); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let cleared = try await store.load()
        XCTAssertTrue(cleared.isEmpty)
    }
}

extension RunningManCoreTests {
    func testHistoryBoundsUnicodeMetadataAndEncodedBytesWithoutTruncatingIDs() async throws {
        let file = temporary.appendingPathComponent("unicode-history.json")
        let store = RunnerHistoryStore(fileURL: file)
        let unicode = String(repeating: "🧑🏽‍💻", count: 100)
        let escapedID = String(repeating: "\u{0001}", count: 1500)
        let rows = (0..<2_010).map { index in
            RunnerJob(id: "\(escapedID)-\(index)", runnerID: "real-runner", name: unicode,
                repository: unicode, workflow: unicode, startedAt: Date(timeIntervalSince1970: Double(index)), outcome: .success)
        }
        let oversized = RunnerJob(id: "too-large", runnerID: String(repeating: "x", count: 4097), name: "Rejected oversized identifier", startedAt: Date())
        let result = try await store.merge(rows + [oversized])
        XCTAssertLessThanOrEqual(result.count, 2_000)
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy { $0.runnerID == "real-runner" && $0.id.hasPrefix(escapedID) })
        XCTAssertTrue(result.allSatisfy { $0.name.utf8.count <= 1024 && ($0.repository?.utf8.count ?? 0) <= 512 && ($0.workflow?.utf8.count ?? 0) <= 1024 })
        XCTAssertTrue(result.allSatisfy { !$0.name.contains("\u{fffd}") })
        let bytes = try Data(contentsOf: file)
        XCTAssertLessThanOrEqual(bytes.count, 6 * 1024 * 1024)
        let loaded = try await RunnerHistoryStore(fileURL: file).load()
        XCTAssertEqual(loaded, result)
    }

    func testReconcilerKeepsOnlyNewestUnfinishedJobForPositivelyBusyRunner() {
        let states: [RunnerStatus] = [.busy, .idle, .stopped, .disabled, .attention, .unknown]
        let snapshots = states.enumerated().map { index, status in
            RunnerSnapshot(runner: InstalledRunner(name: "runner-\(index)", directory: URL(fileURLWithPath: "/synthetic/runner-\(index)")), status: status)
        }
        var jobs = snapshots.enumerated().map { index, snapshot in
            RunnerJob(id: "job-\(index)", runnerID: snapshot.id, name: "Build", startedAt: Date(timeIntervalSince1970: 100))
        }
        jobs += [RunnerJob(id: "older", runnerID: snapshots[0].id, name: "Old interrupted build", startedAt: Date(timeIntervalSince1970: 50)),
                 RunnerJob(id: "removed", runnerID: "/synthetic/removed", name: "Missing runner", startedAt: Date(timeIntervalSince1970: 100)),
                 RunnerJob(id: "completed", runnerID: snapshots[0].id, name: "Completed", startedAt: Date(timeIntervalSince1970: 200), finishedAt: Date(timeIntervalSince1970: 210), outcome: .success)]
        let result = JobReconciler.reconcile(jobs: jobs, snapshots: snapshots)
        XCTAssertEqual(result.filter { $0.outcome == .running }.map(\.id), ["job-0"])
        XCTAssertTrue(result.filter { $0.id != "job-0" && $0.id != "completed" }.allSatisfy { $0.outcome == .unknown && $0.finishedAt == nil })
        XCTAssertEqual(result.last, jobs.last)
    }
}
