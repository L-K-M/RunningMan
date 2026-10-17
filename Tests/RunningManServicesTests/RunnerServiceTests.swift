import XCTest
import RunningManCore
@testable import RunningManServices

actor FakeExecutor: ProcessExecuting {
    var requests: [ProcessRequest] = []
    var processes = ""
    var services = ""
    var disabled = ""
    var failures: [String: ProcessResult] = [:]
    var installWhenRequested = false
    var processesAfterKill: String?
    var processesAfterDisable: String?
    func configure(processes: String = "", services: String = "", disabled: String = "", failures: [String: ProcessResult] = [:], installWhenRequested: Bool = false, processesAfterKill: String? = nil, processesAfterDisable: String? = nil) {
        self.processes = processes; self.services = services; self.disabled = disabled; self.failures = failures; self.installWhenRequested = installWhenRequested
        self.processesAfterKill = processesAfterKill; self.processesAfterDisable = processesAfterDisable
    }
    func recorded() -> [ProcessRequest] { requests }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        if request.executable == "/bin/kill", let processesAfterKill { processes = processesAfterKill }
        if request.arguments.first == "disable", let processesAfterDisable { processes = processesAfterDisable }
        let key = request.arguments.joined(separator: " ")
        if let result = failures[key] { return result }
        if installWhenRequested, request.arguments.last == "install", let root = request.directory {
            let launch = root.deletingLastPathComponent().appendingPathComponent("Library/LaunchAgents")
            try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
            let label = "actions.runner.example-project.test-mac"
            let url = launch.appendingPathComponent(label + ".plist")
            let plist: [String: Any] = ["Label": label, "WorkingDirectory": root.path, "ProgramArguments": [root.appendingPathComponent("runsvc.sh").path], "RunAtLoad": true]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
            try Data(url.path.utf8).write(to: root.appendingPathComponent(".service"))
        }
        if request.executable == "/bin/ps" { return ProcessResult(status: 0, output: processes, error: "") }
        if request.arguments.first == "list" { return ProcessResult(status: 0, output: services, error: "") }
        if request.arguments.first == "print-disabled" { return ProcessResult(status: 0, output: disabled, error: "") }
        if key.contains("remove-token") { return ProcessResult(status: 0, output: #"{"token":"TEMPORARY_REMOVAL_TOKEN"}"#, error: "") }
        return ProcessResult(status: 0, output: "", error: "")
    }
}

final class RunnerServiceTests: XCTestCase {
    var home: URL!
    var runner: InstalledRunner!
    var plist: URL!
    let label = "actions.runner.example-project.test-mac"
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("runningman-services-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        let root = home.appendingPathComponent("actions-runner-test")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let launch = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        runner = InstalledRunner(name: "test-mac", directory: root, githubURL: URL(string: "https://github.com/example/project"), agentID: 12, serviceLabel: label)
        let metadata = #"{"agentName":"test-mac","agentId":12,"gitHubUrl":"https://github.com/example/project"}"#
        try Data(("\u{FEFF}" + metadata).utf8).write(to: root.appendingPathComponent(".runner"))
        for name in ["config.sh", "runsvc.sh", "svc.sh", "env.sh"] { try Data("#!/bin/bash\nexit 0\n".utf8).write(to: root.appendingPathComponent(name)) }
        plist = launch.appendingPathComponent(label + ".plist")
        try writePlist(startup: true)
        try Data(("\u{FEFF}" + plist.path + "\n").utf8).write(to: root.appendingPathComponent(".service"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    func writePlist(startup: Bool, root: String? = nil) throws {
        let object: [String: Any] = ["Label": label, "ProgramArguments": [(root ?? runner.directory.path) + "/runsvc.sh"], "WorkingDirectory": root ?? runner.directory.path, "RunAtLoad": startup]
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: plist)
    }
    func readStartup() throws -> Bool {
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        return object["RunAtLoad"] as! Bool
    }
    func testSnapshotsBatchCommandsAndReadBOMAbsoluteServicePath() async throws {
        let fake = FakeExecutor()
        await fake.configure(services: "PID\tStatus\tLabel\n321\t0\t\(label)\n")
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        let snapshots = await controller.snapshots(for: [runner, runner, runner])
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertTrue(snapshots.allSatisfy { $0.status == .idle && $0.startsAtLogin && $0.processID == 321 })
        let commands = await fake.recorded()
        XCTAssertEqual(commands.count, 3, "One batch, independent of runner count")
    }
    func testBusyWorkerDescendantRefusesStopWithoutAnyMutation() async throws {
        let fake = FakeExecutor()
        await fake.configure(processes: "100 1 /bin/bash \(runner.directory.path)/runsvc.sh\n101 100 /different/path/Runner.Worker spawnclient 1 2\n", services: "100 0 \(label)")
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        do { try await controller.stop(runner); XCTFail("Expected busy refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("executing a job")) }
        XCTAssertTrue(try readStartup())
        let commands = await fake.recorded()
        XCTAssertFalse(commands.contains { ["bootout", "disable", "enable", "kickstart"].contains($0.arguments.first ?? "") || $0.executable == "/bin/kill" })
    }
    func testBusyWorkerRefusesDisableBeforeMutation() async throws {
        let fake = FakeExecutor()
        await fake.configure(processes: "555 1 \(runner.directory.path)/bin/Runner.Worker spawnclient")
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        do { try await controller.setEnabled(false, for: runner); XCTFail("Expected refusal") } catch {}
        let commands = await fake.recorded()
        XCTAssertEqual(commands.count, 3)
    }
    func testDisableAppliesOverrideBeforeStoppingAndRechecksIdle() async throws {
        let fake = FakeExecutor()
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        try await controller.setEnabled(false, for: runner)
        let commands = await fake.recorded()
        let disable = try XCTUnwrap(commands.firstIndex { $0.arguments.first == "disable" })
        let bootout = try XCTUnwrap(commands.firstIndex { $0.arguments.first == "bootout" })
        XCTAssertLessThan(disable, bootout, "The disable override must be written even if stopping fails")
        let checks = commands.indices.filter { commands[$0].arguments.first == "list" }
        XCTAssertEqual(checks.count, 2, "Busy state is checked before disabling and again before stopping")
        XCTAssertTrue(checks.contains { $0 > disable && $0 < bootout })
        XCTAssertTrue(try readStartup())
    }
    func testDisableNeverStopsAJobThatStartedAfterTheFirstCheck() async throws {
        let fake = FakeExecutor()
        let busy = "100 1 \(runner.directory.path)/bin/Runner.Listener run\n101 100 \(runner.directory.path)/bin/Runner.Worker spawnclient 1 2\n"
        await fake.configure(processesAfterDisable: busy)
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        do { try await controller.setEnabled(false, for: runner); XCTFail("Expected the busy runner to stay running") }
        catch { XCTAssertTrue(error.localizedDescription.hasPrefix("Disabled, but stopping failed:"), error.localizedDescription) }
        let commands = await fake.recorded()
        XCTAssertTrue(commands.contains { $0.arguments.first == "disable" })
        XCTAssertFalse(commands.contains { $0.arguments.first == "bootout" || $0.executable == "/bin/kill" })
    }
    func testDisableReportsStopFailureAfterDisabling() async throws {
        let fake = FakeExecutor()
        await fake.configure(failures: ["bootout gui/\(getuid())/\(label)": ProcessResult(status: 5, output: "", error: "Input/output error")])
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        do { try await controller.setEnabled(false, for: runner); XCTFail("Expected partial failure") }
        catch { XCTAssertTrue(error.localizedDescription.hasPrefix("Disabled, but stopping failed:"), error.localizedDescription) }
        let commands = await fake.recorded()
        XCTAssertTrue(commands.contains { $0.arguments == ["disable", "gui/\(getuid())/\(label)"] })
    }
    func testStopRefusesWhenServiceLoadStateCannotBeRead() async throws {
        let listener = "777 1 \(runner.directory.path)/bin/Runner.Listener run --startuptype service\n"
        for failure in [ProcessResult(status: 1, output: "", error: "Input/output error"), ProcessResult(status: 113, output: "", error: "", timedOut: true),
                        ProcessResult(status: 0, output: "", error: "", truncated: true)] {
            let fake = FakeExecutor()
            await fake.configure(processes: listener, failures: ["print gui/\(getuid())/\(label)": failure])
            let controller = RunnerServiceController(homeDirectory: home, executor: fake)
            do { try await controller.stop(runner); XCTFail("Expected unverifiable load state to refuse") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Cannot verify whether the runner service is loaded"), error.localizedDescription) }
            let commands = await fake.recorded()
            XCTAssertFalse(commands.contains { $0.arguments.first == "bootout" || $0.executable == "/bin/kill" })
        }
    }
    func testStopTreatsServiceNotFoundAsUnloaded() async throws {
        let fake = FakeExecutor()
        await fake.configure(failures: ["print gui/\(getuid())/\(label)": ProcessResult(status: 113, output: "", error: "Could not find service")])
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        try await controller.stop(runner)
        let commands = await fake.recorded()
        XCTAssertFalse(commands.contains { $0.arguments.first == "bootout" })
    }
    func testStopToleratesListenerThatExitsBeforeKill() async throws {
        let fake = FakeExecutor()
        await fake.configure(processes: "777 1 \(runner.directory.path)/bin/Runner.Listener run\n",
                             failures: ["-TERM 777": ProcessResult(status: 1, output: "", error: "kill: 777: No such process")], processesAfterKill: "")
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        try await controller.stop(runner)
        let commands = await fake.recorded()
        XCTAssertTrue(commands.contains { $0.executable == "/bin/kill" })
    }
    func testStopReportsListenerThatKeepsRunning() async throws {
        let fake = FakeExecutor()
        await fake.configure(processes: "777 1 \(runner.directory.path)/bin/Runner.Listener run\n")
        let controller = RunnerServiceController(homeDirectory: home, executor: fake, stopExitTimeout: 0.5)
        do { try await controller.stop(runner); XCTFail("A listener that survives stopping must not be reported as stopped") }
        catch { XCTAssertTrue(error.localizedDescription.contains("still running"), error.localizedDescription) }
    }
    func testStaleServiceMarkerIsReplacedWhenStarting() async throws {
        try FileManager.default.removeItem(at: plist)
        let fake = FakeExecutor()
        await fake.configure(installWhenRequested: true)
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        let snapshots = await controller.snapshots(for: [runner])
        XCTAssertEqual(snapshots.first?.status, .stopped)
        try await controller.start(runner)
        let commands = await fake.recorded()
        XCTAssertTrue(commands.contains { $0.arguments.last == "install" })
        XCTAssertTrue(commands.contains { $0.arguments.first == "kickstart" })
        XCTAssertEqual(try runnerText(runner.directory.appendingPathComponent(".service")), plist.path)
        XCTAssertFalse(try readStartup(), "A reinstalled service must not opt into login startup")
    }
    func testStaleServiceMarkerDoesNotBlockStop() async throws {
        try FileManager.default.removeItem(at: plist)
        let fake = FakeExecutor()
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        try await controller.stop(runner)
        let commands = await fake.recorded()
        XCTAssertFalse(commands.contains { $0.arguments.first == "bootout" }, "launchd does not report the deleted plist, so nothing is unloaded")
    }
    func testStaleServiceMarkerRefusesWhenLoadStateCannotBeRead() async throws {
        try FileManager.default.removeItem(at: plist)
        let listener = "777 1 \(runner.directory.path)/bin/Runner.Listener run --startuptype service\n"
        let fake = FakeExecutor()
        await fake.configure(processes: listener, failures: ["print gui/\(getuid())/\(label)": ProcessResult(status: 5, output: "", error: "Input/output error")])
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        do { try await controller.stop(runner); XCTFail("Expected a refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Cannot verify whether the runner service is loaded"), error.localizedDescription) }
        let commands = await fake.recorded()
        XCTAssertFalse(commands.contains { $0.arguments.first == "bootout" || $0.executable == "/bin/kill" })
    }
    func testFailedSignalIsAnErrorOnlyWhileTheProcessRemains() async throws {
        let listener = "777 1 \(runner.directory.path)/bin/Runner.Listener run --startuptype service\n"
        let denied = ProcessResult(status: 1, output: "", error: "kill: 777: Operation not permitted")
        let gone = FakeExecutor()
        await gone.configure(processes: listener, failures: ["-TERM 777": denied], processesAfterKill: "")
        try await RunnerServiceController(homeDirectory: home, executor: gone).stop(runner)
        let stays = FakeExecutor()
        await stays.configure(processes: listener, failures: ["-TERM 777": denied])
        do { try await RunnerServiceController(homeDirectory: home, executor: stays).stop(runner); XCTFail("Expected the signal failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Stop manually started runner failed"), error.localizedDescription) }
    }
    func testStaleServiceMarkerStillUnloadsTheServiceLoadedFromIt() async throws {
        try FileManager.default.removeItem(at: plist)
        let target = "gui/\(getuid())/\(label)"
        for (path, unloads) in [(plist.path, true), ("/Users/someone/Library/LaunchAgents/\(label).plist", false)] {
            let fake = FakeExecutor()
            await fake.configure(failures: ["print \(target)": ProcessResult(status: 0, output: "\(target) = {\n\tpath = \(path)\n\tstate = running\n}\n", error: "")])
            let controller = RunnerServiceController(homeDirectory: home, executor: fake)
            try await controller.stop(runner)
            let commands = await fake.recorded()
            XCTAssertEqual(commands.contains { $0.arguments == ["bootout", target] }, unloads, path)
        }
    }
    func testExistingServicePlistWithoutMarkerIsAdoptedInsteadOfReinstalled() async throws {
        try FileManager.default.removeItem(at: runner.directory.appendingPathComponent(".service"))
        let fake = FakeExecutor()
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        try await controller.setEnabled(true, for: runner)
        let commands = await fake.recorded()
        XCTAssertFalse(commands.contains { $0.arguments.last == "install" || $0.arguments.first?.hasSuffix("/env.sh") == true })
        XCTAssertEqual(commands.map(\.arguments), [["enable", "gui/\(getuid())/\(label)"]])
        XCTAssertEqual(try runnerText(runner.directory.appendingPathComponent(".service")), plist.path)
        XCTAssertTrue(try readStartup(), "Adopting an existing service preserves its startup policy")
    }
    func testForeignServicePlistWithoutMarkerIsNotAdopted() async throws {
        try FileManager.default.removeItem(at: runner.directory.appendingPathComponent(".service"))
        try writePlist(startup: true, root: home.appendingPathComponent("unrelated").path)
        let before = try Data(contentsOf: plist)
        let fake = FakeExecutor()
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        do { try await controller.setEnabled(true, for: runner); XCTFail("Expected mismatch refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("does not match"), error.localizedDescription) }
        XCTAssertEqual(before, try Data(contentsOf: plist))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runner.directory.appendingPathComponent(".service").path))
        let commands = await fake.recorded()
        XCTAssertTrue(commands.isEmpty)
    }
    func testStopPreservesStartupAndEnablement() async throws {
        let fake = FakeExecutor()
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        try await controller.stop(runner)
        XCTAssertTrue(try readStartup())
        let commands = await fake.recorded()
        XCTAssertTrue(commands.contains { $0.arguments == ["bootout", "gui/\(getuid())/\(label)"] })
        XCTAssertFalse(commands.contains { ["disable", "enable"].contains($0.arguments.first ?? "") })
    }
    func testStartupEditDoesNotRestartOrEnableService() async throws {
        let fake = FakeExecutor()
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        try await controller.setStartsAtLogin(false, for: runner)
        XCTAssertFalse(try readStartup())
        let commands = await fake.recorded()
        XCTAssertTrue(commands.isEmpty)
    }
    func testInstallingServiceForManualRunnerDoesNotOptIntoLoginStartup() async throws {
        try FileManager.default.removeItem(at: runner.directory.appendingPathComponent(".service"))
        try FileManager.default.removeItem(at: plist)
        let fake = FakeExecutor()
        await fake.configure(installWhenRequested: true)
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        try await controller.setEnabled(true, for: runner)
        XCTAssertFalse(try readStartup())
        let commands = await fake.recorded()
        XCTAssertFalse(commands.contains { $0.arguments.first == "kickstart" || $0.arguments.first == "bootstrap" })
    }
    func testEnableDoesNotStart() async throws {
        let fake = FakeExecutor()
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        try await controller.setEnabled(true, for: runner)
        let commands = await fake.recorded()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.arguments.first, "enable")
    }
    func testStartDisabledRunnerRefusesAndNeverEnablesImplicitly() async throws {
        let fake = FakeExecutor()
        await fake.configure(disabled: "disabled services = {\n \"\(label)\" => true\n}")
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        do { try await controller.start(runner); XCTFail("Expected refusal") } catch { XCTAssertTrue(error.localizedDescription.contains("Enable")) }
        let commands = await fake.recorded()
        XCTAssertFalse(commands.contains { ["enable", "kickstart", "bootstrap"].contains($0.arguments.first ?? "") })
    }
    func testStartDoesNotUseKillFlag() async throws {
        let fake = FakeExecutor()
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        try await controller.start(runner)
        let commands = await fake.recorded()
        XCTAssertTrue(commands.contains { $0.arguments.first == "kickstart" })
        XCTAssertFalse(commands.contains { $0.arguments.contains("-k") })
    }
    func testForeignServicePlistIsNotModified() async throws {
        try writePlist(startup: true, root: home.appendingPathComponent("unrelated").path)
        let before = try Data(contentsOf: plist)
        let fake = FakeExecutor()
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        do { try await controller.setStartsAtLogin(false, for: runner); XCTFail("Expected validation error") } catch {}
        XCTAssertEqual(before, try Data(contentsOf: plist))
        let commands = await fake.recorded()
        XCTAssertTrue(commands.isEmpty)
    }
    func testOutsideLaunchAgentsServiceIsNotModified() async throws {
        let outside = home.appendingPathComponent("not-an-agent.plist")
        try Data(contentsOf: plist).write(to: outside)
        try Data(outside.path.utf8).write(to: runner.directory.appendingPathComponent(".service"))
        let fake = FakeExecutor()
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        do { try await controller.setStartsAtLogin(false, for: runner); XCTFail("Expected validation error") } catch {}
        XCTAssertTrue(try readStartup())
        let commands = await fake.recorded()
        XCTAssertTrue(commands.isEmpty)
    }
    func testFailedUnregisterRestoresPlistAndPreservesDirectory() async throws {
        let fake = FakeExecutor()
        let remove = runner.directory.appendingPathComponent("config.sh").path + " remove"
        await fake.configure(failures: [remove: ProcessResult(status: 1, output: "", error: "Authentication TEMPORARY_REMOVAL_TOKEN failed")])
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        do { try await controller.delete(runner, trashFiles: true); XCTFail("Expected unregister failure") }
        catch {
            XCTAssertFalse(error.localizedDescription.contains("TEMPORARY_REMOVAL_TOKEN"))
            XCTAssertTrue(error.localizedDescription.contains("The runner was stopped and remains stopped."), error.localizedDescription)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: runner.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runner.directory.appendingPathComponent(".service").path))
        let commands = await fake.recorded()
        let unregister = try XCTUnwrap(commands.first { $0.arguments.last == "remove" })
        XCTAssertFalse(unregister.arguments.joined().contains("TEMPORARY_REMOVAL_TOKEN"))
        XCTAssertEqual(unregister.environment["ACTIONS_RUNNER_INPUT_TOKEN"], "TEMPORARY_REMOVAL_TOKEN")
    }
    func testUnregisterPreservesImportedFilesByDefault() async throws {
        let fake = FakeExecutor()
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        try await controller.delete(runner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runner.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runner.directory.appendingPathComponent("config.sh").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }
    func testUnknownProcessStateRefusesStopEvenWhenLaunchServiceHasPID() async throws {
        let fake = FakeExecutor()
        await fake.configure(services: "321 0 \(label)", failures: ["-ww -axo pid=,ppid=,command=": ProcessResult(status: 1, output: "", error: "Permission denied")])
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        do { try await controller.stop(runner); XCTFail("Expected inability to verify busy state") } catch {}
        let commands = await fake.recorded()
        XCTAssertFalse(commands.contains { $0.arguments.first == "bootout" })
    }
    func testIncompleteProcessInspectionRefusesStopWithLiveServicePID() async throws {
        for failure in [ProcessResult(status: 0, output: "", error: "", timedOut: true), ProcessResult(status: 0, output: "", error: "", truncated: true)] {
            let fake = FakeExecutor()
            await fake.configure(services: "321 0 \(label)", failures: ["-ww -axo pid=,ppid=,command=": failure])
            let controller = RunnerServiceController(homeDirectory: home, executor: fake)
            do { try await controller.stop(runner); XCTFail("Expected fail-closed refusal") } catch {}
            let commands = await fake.recorded()
            XCTAssertFalse(commands.contains { $0.arguments.first == "bootout" })
        }
    }
    func testStartingRunningRunnerIsIdempotent() async throws {
        let fake = FakeExecutor()
        await fake.configure(services: "321 0 \(label)")
        let controller = RunnerServiceController(homeDirectory: home, executor: fake)
        try await controller.start(runner)
        let commands = await fake.recorded()
        XCTAssertEqual(commands.count, 3)
        XCTAssertFalse(commands.contains { $0.arguments.first == "kickstart" })
    }
    func testServiceParsers() {
        XCTAssertEqual(RunnerServiceController.parseServices("- 0 actions.runner.one\n12 0 actions.runner.two\n8 0 com.example.other"), ["actions.runner.one": 0, "actions.runner.two": 12])
        XCTAssertEqual(RunnerServiceController.parseDisabled(#"{ "actions.runner.one" => true, "actions.runner.two" => false }"#), ["actions.runner.one"])
        // Current macOS spells the override as disabled/enabled.
        XCTAssertEqual(RunnerServiceController.parseDisabled(#"{ "actions.runner.three" => disabled, "actions.runner.four" => enabled, "actions.runner.disabledness" => enabled }"#), ["actions.runner.three"])
    }
}

final class InstallerSafetyTests: XCTestCase {
    func testOnlyExactPublicGitHubScopeURLsAreAccepted() throws {
        XCTAssertEqual(try GitHubRunnerScope(url: URL(string: "https://github.com/example/project/")!).apiPrefix, "repos/example/project/actions/runners")
        XCTAssertEqual(try GitHubRunnerScope(url: URL(string: "https://github.com/example")!).apiPrefix, "orgs/example/actions/runners")
        for string in ["http://github.com/example/repo", "https://github.com.evil.test/example/repo", "https://user:pass@github.com/example/repo", "https://github.com/example/repo/settings", "https://github.com/example/repo?token=secret", "https://github.com/example/%2e%2e", "https://github.com/example//repo", "https://github.com:443/example/repo"] {
            XCTAssertThrowsError(try GitHubRunnerScope(url: URL(string: string)!))
        }
    }
    func testArchiveTraversalAndEscapingLinksAreRejected() throws {
        XCTAssertThrowsError(try GitHubRunnerInstaller.validateArchive(names: "../outside\n", verbose: "- outside"))
        XCTAssertThrowsError(try GitHubRunnerInstaller.validateArchive(names: "/outside\n", verbose: "- outside"))
        XCTAssertThrowsError(try GitHubRunnerInstaller.validateArchive(names: "./bin/link\n", verbose: "lrwxr-xr-x 0 user group 0 date ./bin/link -> ../../outside"))
        XCTAssertThrowsError(try GitHubRunnerInstaller.validateArchive(names: "./file\n", verbose: "hrwxr-xr-x 0 user group 0 date ./file link to ../../outside"))
        XCTAssertNoThrow(try GitHubRunnerInstaller.validateArchive(names: "./externals/node/bin/npm\n", verbose: "lrwxr-xr-x 0 user group 0 date ./externals/node/bin/npm -> ../lib/npm.js"))
    }
    func testOfficialAssetRequiresMatchingNameOriginAndDigest() throws {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let name = "actions-runner-osx-arm64-2.337.0.tar.gz"
        let asset = OfficialRunnerAsset(name: name, browser_download_url: "https://github.com/actions/runner/releases/download/v2.337.0/" + name, digest: digest)
        XCTAssertNoThrow(try GitHubRunnerInstaller.validatedAsset(OfficialRunnerRelease(tag_name: "v2.337.0", assets: [asset]), architecture: "arm64"))
        var changed = asset; changed.browser_download_url = "https://evil.test/runner.tar.gz"
        XCTAssertThrowsError(try GitHubRunnerInstaller.validatedAsset(OfficialRunnerRelease(tag_name: "v2.337.0", assets: [changed]), architecture: "arm64"))
        changed = asset; changed.digest = nil
        XCTAssertThrowsError(try GitHubRunnerInstaller.validatedAsset(OfficialRunnerRelease(tag_name: "v2.337.0", assets: [changed]), architecture: "arm64"))
    }
    func testSHA256ChecksActualArchiveBytes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("runningman-hash-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertNoThrow(try GitHubRunnerInstaller.verifySHA256(file: file, digest: "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        XCTAssertThrowsError(try GitHubRunnerInstaller.verifySHA256(file: file, digest: "sha256:" + String(repeating: "0", count: 64)))
    }
    func testTokenParserNeverEchoesInvalidResponse() {
        do { _ = try GitHubRunnerInstaller.decodeToken(#"{"token":"SECRET TOKEN WITH SPACES"}"#); XCTFail("Expected invalid token") }
        catch { XCTAssertFalse(error.localizedDescription.contains("SECRET TOKEN")) }
    }
    func testCheckedErrorsRedactExplicitEphemeralSecrets() async throws {
        let fake = FakeExecutor()
        await fake.configure(failures: ["test": ProcessResult(status: 1, output: "", error: "secret=UNIQUE_TEMP_TOKEN")])
        do { _ = try await checked(fake, ProcessRequest(executable: "/bin/false", arguments: ["test"], secrets: ["UNIQUE_TEMP_TOKEN"]), operation: "Test"); XCTFail("Expected failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("UNIQUE_TEMP_TOKEN")) }
    }
    func testTimeoutTerminatesOwnedChildProcessGroup() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("runningman-child-pid-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = #"/bin/sleep 30 & child=$!; printf '%s' "$child" > "$1"; wait "$child""#
        let executor = SystemProcessExecutor()
        let result = try await executor.run(ProcessRequest(executable: "/bin/bash", arguments: ["-c", script, "fixture", pidFile.path], timeout: 0.2))
        XCTAssertTrue(result.timedOut)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        let deadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "The timed-out shell’s child must not survive")
    }
    func testExecutorTimesOutAndBoundsOutput() async throws {
        let executor = SystemProcessExecutor()
        let start = Date()
        let result = try await executor.run(ProcessRequest(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1))
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let output = try await executor.run(ProcessRequest(executable: "/usr/bin/printf", arguments: [String(repeating: "a", count: 4096)], outputLimit: 100))
        XCTAssertEqual(output.output.count, 100)
    }
}

private actor InstallerExecutor: ProcessExecuting {
    let home: URL
    let failRegistration: Bool
    var requests: [ProcessRequest] = []
    init(home: URL, failRegistration: Bool = false) { self.home = home; self.failRegistration = failRegistration }
    func recorded() -> [ProcessRequest] { requests }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        let arguments = request.arguments
        if arguments.contains("repos/actions/runner/releases/latest") {
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x64"
            #endif
            let name = "actions-runner-osx-\(arch)-2.337.0.tar.gz"
            let object: [String: Any] = ["tag_name": "v2.337.0", "assets": [["name": name, "browser_download_url": "https://github.com/actions/runner/releases/download/v2.337.0/" + name, "digest": "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]]]
            return ProcessResult(status: 0, output: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), error: "")
        }
        if request.executable == "/usr/bin/curl", let index = arguments.firstIndex(of: "--output") {
            try Data("abc".utf8).write(to: URL(fileURLWithPath: arguments[index + 1]))
        }
        if arguments.first == "-tzf" { return ProcessResult(status: 0, output: "./config.sh\n./env.sh\n./svc.sh\n./bin/Runner.Listener\n", error: "") }
        if arguments.first == "-tvzf" { return ProcessResult(status: 0, output: "-rw-r--r-- 0 user group 1 date ./config.sh\n", error: "") }
        if let index = arguments.firstIndex(of: "-C") {
            let root = URL(fileURLWithPath: arguments[index + 1])
            try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
            for file in ["config.sh", "env.sh", "svc.sh", "bin/Runner.Listener", "runsvc.sh"] { try Data("synthetic fixture".utf8).write(to: root.appendingPathComponent(file)) }
        }
        if arguments.last?.hasSuffix("/registration-token") == true { return ProcessResult(status: 0, output: #"{"token":"EPHEMERAL_REG_TOKEN"}"#, error: "") }
        if arguments.contains("--unattended") {
            if failRegistration { return ProcessResult(status: 1, output: "", error: "registration EPHEMERAL_REG_TOKEN failed") }
            let name = arguments[arguments.firstIndex(of: "--name")! + 1]
            let object: [String: Any] = ["agentName": name, "agentId": 42, "gitHubUrl": "https://github.com/example/project"]
            try JSONSerialization.data(withJSONObject: object).write(to: request.directory!.appendingPathComponent(".runner"))
        }
        if arguments.last == "install", arguments.first?.hasSuffix("/svc.sh") == true {
            let root = request.directory!
            let launch = home.appendingPathComponent("Library/LaunchAgents")
            try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
            let label = "actions.runner.example-project.created"
            let url = launch.appendingPathComponent(label + ".plist")
            let plist: [String: Any] = ["Label": label, "WorkingDirectory": root.path, "ProgramArguments": [root.appendingPathComponent("runsvc.sh").path], "RunAtLoad": true]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
            try Data(url.path.utf8).write(to: root.appendingPathComponent(".service"))
        }
        return ProcessResult(status: 0, output: "", error: "")
    }
}

final class InstallerFlowTests: XCTestCase {
    func testSuccessfulCreateKeepsTokenOutOfArgumentsAndUsesRequestedStartupPolicy() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("runningman-installer-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let executor = InstallerExecutor(home: home)
        let installer = GitHubRunnerInstaller(homeDirectory: home, executor: executor)
        let root = home.appendingPathComponent("runners/created runner")
        let runner = try await installer.create(CreateRunnerRequest(githubURL: URL(string: "https://github.com/example/project")!, name: "created", labels: ["local-mac-release"], directory: root, startsAtLogin: false, startImmediately: true)) { _ in }
        XCTAssertEqual(runner.name, "created")
        XCTAssertEqual(runner.agentID, 42)
        let plistURL = home.appendingPathComponent("Library/LaunchAgents/actions.runner.example-project.created.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, false)
        let commands = await executor.recorded()
        XCTAssertTrue(commands.contains { $0.arguments.first == "enable" })
        XCTAssertTrue(commands.contains { $0.arguments.first == "kickstart" })
        XCTAssertFalse(commands.contains { $0.arguments.joined().contains("EPHEMERAL_REG_TOKEN") })
        XCTAssertEqual(commands.filter { $0.environment["ACTIONS_RUNNER_INPUT_TOKEN"] != nil }.count, 1)
    }
    func testRegistrationFailurePreservesPartialInstallationAndRedactsToken() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("runningman-installer-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let executor = InstallerExecutor(home: home, failRegistration: true)
        let installer = GitHubRunnerInstaller(homeDirectory: home, executor: executor)
        let root = home.appendingPathComponent("created")
        do {
            _ = try await installer.create(CreateRunnerRequest(githubURL: URL(string: "https://github.com/example/project")!, name: "created", labels: [], directory: root)) { _ in }
            XCTFail("Expected registration failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("EPHEMERAL_REG_TOKEN"))
            XCTAssertTrue(error.localizedDescription.contains("preserved"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.sh").path))
    }
}
