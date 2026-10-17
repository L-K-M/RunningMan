import XCTest
import RunningManCore
@testable import RunningManServices

actor ForgejoTestAPI: ForgejoAPIRequesting {
    struct Call: Sendable { var path: String; var server: URL; var method: String; var body: Data? }
    var calls: [Call] = []
    var status = "idle"
    var failure: ForgejoAPIError?
    var failDelete = false
    func configure(status: String = "idle", failure: ForgejoAPIError? = nil, failDelete: Bool = false) { self.status = status; self.failure = failure; self.failDelete = failDelete }
    func recorded() -> [Call] { calls }
    func request(path: String, serverURL: URL, method: String, body: Data?) async throws -> Data {
        calls.append(Call(path: path, server: serverURL, method: method, body: body))
        if let failure { throw failure }
        if method == "POST" { return Data(#"{"id":42,"uuid":"00000000-0000-4000-8000-000000000042","token":"0123456789abcdef0123456789abcdef01234567"}"#.utf8) }
        if method == "DELETE" {
            if failDelete { throw ForgejoAPIError("Delete denied", statusCode: 403) }
            return Data()
        }
        if path == "/user" { return Data(#"{"login":"example"}"#.utf8) }
        return try JSONSerialization.data(withJSONObject: ["id":42, "status":status, "uuid":"00000000-0000-4000-8000-000000000042"])
    }
}

private actor ForgejoCommandExecutor: ProcessExecuting {
    let package: URL
    var commands: [ProcessRequest] = []
    var processOutput = ""
    var serviceOutput = ""
    var disabledOutput = ""
    var systemService = ProcessResult(status: 113, output: "", error: "Could not find service")
    init(package: URL) { self.package = package }
    func configure(processes: String = "", services: String = "", disabled: String = "") { processOutput = processes; serviceOutput = services; disabledOutput = disabled }
    func configureSystemService(_ result: ProcessResult) { systemService = result }
    func recorded() -> [ProcessRequest] { commands }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        commands.append(request)
        if request.arguments.first == "--prefix" { return ProcessResult(status: 0, output: package.path + "\n", error: "") }
        if request.arguments == ["--version"] { return ProcessResult(status: 0, output: "forgejo-runner version v13.2.0\n", error: "") }
        if request.executable == "/bin/ps" { return ProcessResult(status: 0, output: processOutput, error: "") }
        if request.arguments.first == "list" { return ProcessResult(status: 0, output: serviceOutput, error: "") }
        if request.arguments.first == "print-disabled" { return ProcessResult(status: 0, output: disabledOutput, error: "") }
        if request.arguments.first == "print", request.arguments.last?.hasPrefix("system/") == true { return systemService }
        return ProcessResult(status: 0, output: "", error: "")
    }
}

final class ForgejoServiceTests: XCTestCase {
    var home: URL!
    var package: URL!
    var root: URL!
    var api: ForgejoTestAPI!
    private var executor: ForgejoCommandExecutor!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("runningman-forgejo-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        package = home.appendingPathComponent("package")
        root = home.appendingPathComponent("runner with spaces")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let binary = package.appendingPathComponent("bin/forgejo-runner")
        try Data("synthetic binary, never executed".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: binary.path)
        api = ForgejoTestAPI(); executor = ForgejoCommandExecutor(package: package)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    func create(start: Bool = false, manual: Bool = false) async throws -> InstalledRunner {
        let installer = ForgejoRunnerInstaller(homeDirectory: home, executor: executor, api: api)
        let request = CreateForgejoRunnerRequest(serverURL: URL(string: "https://forge.example.test")!, scope: .repository,
            scopeName: "example/project", name: "test-mac", labels: ["macos", "local-release:host"], directory: root,
            capacity: 2, startsAtLogin: false, startImmediately: start,
            registrationUUID: manual ? "00000000-0000-4000-8000-000000000042" : nil,
            registrationToken: manual ? "0123456789abcdef0123456789abcdef01234567" : nil)
        return try await installer.create(request) { _ in }
    }
    func makeLive(_ runner: InstalledRunner) async {
        let command = runner.executableURL!.path + " daemon --config " + runner.configurationURL!.path
        await executor.configure(processes: "321 1 " + command, services: "321 0 " + runner.serviceLabel!)
    }
    func testCreateUsesHomebrewCoreWithoutGlobalServiceAndKeepsSecretsPrivate() async throws {
        let runner = try await create(start: true)
        XCTAssertEqual(runner.provider, .forgejo)
        XCTAssertEqual(runner.capacity, 2)
        XCTAssertEqual(runner.agentID, 42)
        XCTAssertEqual(runner.labels, ["macos", "local-release"])
        XCTAssertEqual(try Data(contentsOf: runner.executableURL!), Data("synthetic binary, never executed".utf8))
        let metadata = try String(contentsOf: root.appendingPathComponent(RunnerInstallationDescriptor.fileName), encoding: .utf8)
        let configuration = try String(contentsOf: runner.configurationURL!, encoding: .utf8)
        let token = "0123456789abcdef0123456789abcdef01234567"
        XCTAssertFalse(metadata.contains(token))
        XCTAssertFalse(configuration.contains(token))
        XCTAssertTrue(configuration.contains("token_url:"))
        XCTAssertTrue(configuration.contains("macos:host"))
        XCTAssertTrue(configuration.contains("capacity: 2"))
        for file in ["connection-token", "config.yaml"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let commands = await executor.recorded()
        XCTAssertTrue(commands.contains { $0.arguments == ["install", "homebrew/core/forgejo-runner"] && $0.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1" })
        XCTAssertFalse(commands.contains { $0.arguments.contains("services") || $0.arguments.joined().contains(token) })
        XCTAssertTrue(commands.contains { $0.arguments.first == "kickstart" })
    }
    func testManualUUIDConnectionRequiresNoAPIRegistration() async throws {
        let runner = try await create(manual: true)
        XCTAssertNil(runner.agentID)
        let calls = await api.recorded()
        XCTAssertTrue(calls.isEmpty)
    }
    func testDiscoveryControlNeverReadsLegacyRegistrationOrConfigurationContents() async throws {
        let runner = try await create()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".runner"), withIntermediateDirectories: false)
        try Data("token: NEVER_READ_THIS_CONFIGURATION_SECRET".utf8).write(to: runner.configurationURL!)
        try FileManager.default.setAttributes([.posixPermissions:0], ofItemAtPath: runner.configurationURL!.path)
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        try await controller.setStartsAtLogin(true, for: runner)
        let snapshots = await controller.snapshots(for: [runner])
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertTrue(snapshot.startsAtLogin)
        XCTAssertEqual(snapshot.status, .stopped)
    }
    func testLiveDaemonWithoutAPIEvidenceIsUnknownAndRefusesInterruption() async throws {
        let runner = try await create()
        await makeLive(runner)
        await api.configure(failure: ForgejoAPIError("Access denied", statusCode: 403))
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        let snapshots = await controller.snapshots(for: [runner])
        XCTAssertEqual(snapshots.first?.status, .unknown)
        XCTAssertEqual(snapshots.first?.processID, 321)
        let before = await executor.recorded().count
        do { try await controller.stop(runner); XCTFail("Expected unknown-state refusal") } catch {}
        let commands = Array(await executor.recorded().dropFirst(before))
        XCTAssertFalse(commands.contains { $0.arguments.first == "bootout" || $0.executable == "/bin/kill" })
    }
    func testLocalOnlySnapshotDoesNotContactForgejo() async throws {
        let runner = try await create()
        await makeLive(runner)
        let before = await api.recorded().count
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        let snapshots = await controller.snapshots(for: [runner], allowRemoteActivity: false)
        XCTAssertEqual(snapshots.first?.processID, 321)
        XCTAssertEqual(snapshots.first?.status, .unknown)
        let after = await api.recorded().count
        XCTAssertEqual(before, after)
    }
    func testRoutineSnapshotCachesStatusButStopRechecksFreshActivity() async throws {
        let runner = try await create()
        await makeLive(runner)
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        let first = await controller.snapshots(for: [runner])
        XCTAssertEqual(first.first?.status, .idle)
        let beforeCalls = await api.recorded().count
        await api.configure(status: "active")
        let cached = await controller.snapshots(for: [runner])
        XCTAssertEqual(cached.first?.status, .idle)
        let afterCachedCalls = await api.recorded().count
        XCTAssertEqual(beforeCalls, afterCachedCalls)
        let commandCount = await executor.recorded().count
        do { try await controller.stop(runner); XCTFail("Fresh API must block stopping an active job") } catch {}
        let commands = Array(await executor.recorded().dropFirst(commandCount))
        XCTAssertFalse(commands.contains { $0.arguments.first == "bootout" })
        let calls = await api.recorded()
        XCTAssertEqual(calls.count, beforeCalls + 1)
    }
    func testStartupPolicyEditNeverRestartsBusyDaemon() async throws {
        let runner = try await create()
        await makeLive(runner)
        await api.configure(status: "active")
        let before = await executor.recorded().count
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        try await controller.setStartsAtLogin(true, for: runner)
        let commands = Array(await executor.recorded().dropFirst(before))
        XCTAssertTrue(commands.isEmpty)
    }
    func testForgejoDeleteRetiresPublicDescriptorAndPreservesFiles() async throws {
        let runner = try await create()
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        try await controller.delete(runner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("_work").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("connection-token").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(RunnerInstallationDescriptor.fileName).path))
        let calls = await api.recorded()
        XCTAssertTrue(calls.contains { $0.method == "DELETE" && $0.path == "/repos/example/project/actions/runners/42" })
    }
    func testForgejoFailedDeleteRestoresServiceAndPublicDescriptor() async throws {
        let runner = try await create()
        await api.configure(failDelete: true)
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        do { try await controller.delete(runner); XCTFail("Expected remote delete refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("The runner was stopped and remains stopped."), error.localizedDescription) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(RunnerInstallationDescriptor.fileName).path))
        let marker = try String(contentsOf: root.appendingPathComponent(".service"), encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
    }
    func testManualConnectionWithoutNumericIDCannotDeleteAnotherRegistration() async throws {
        let runner = try await create(manual: true)
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        do { try await controller.delete(runner); XCTFail("Expected missing-ID refusal") } catch {}
        let calls = await api.recorded()
        XCTAssertFalse(calls.contains { $0.method == "DELETE" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(RunnerInstallationDescriptor.fileName).path))
    }
    private func systemRunner() throws -> InstalledRunner {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return InstalledRunner(name: "forgejo-runner", directory: root, serviceLabel: "org.example.forgejo-runner", provider: .forgejo,
            executableURL: package.appendingPathComponent("bin/forgejo-runner"), configurationURL: root.appendingPathComponent("config.yml"),
            serviceDomain: .system)
    }
    func testSystemDaemonIsObservedButNeverControlled() async throws {
        let runner = try systemRunner()
        await executor.configureSystemService(ProcessResult(status: 0, output: "system/org.example.forgejo-runner = {\n\tstate = running\n\tresource coalition = {\n\t\tpid = 5\n\t}\n\tpid = 77\n}\n", error: ""))
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        let snapshotSnapshots = await controller.snapshots(for: [runner])
        let snapshot = try XCTUnwrap(snapshotSnapshots.first)
        XCTAssertEqual(snapshot.processID, 77)
        XCTAssertEqual(snapshot.status, .unknown, "A daemon without server evidence must not be called idle")
        XCTAssertFalse(snapshot.startsAtLogin); XCTAssertTrue(snapshot.isEnabled)
        XCTAssertTrue(snapshot.detail?.contains("system service org.example.forgejo-runner") == true)
        let before = await executor.recorded().count
        let operations: [(String, () async throws -> Void)] = [
            ("start", { try await controller.start(runner) }),
            ("stop", { try await controller.stop(runner, force: true) }),
            ("enable", { try await controller.setEnabled(true, for: runner) }),
            ("disable", { try await controller.setEnabled(false, for: runner, force: true) }),
            ("login", { try await controller.setStartsAtLogin(false, for: runner) }),
            ("delete", { try await controller.delete(runner, trashFiles: true, force: true) })]
        for (name, operation) in operations {
            do { try await operation(); XCTFail("\(name) must refuse a system LaunchDaemon") }
            catch { XCTAssertTrue(error.localizedDescription.contains("system LaunchDaemon"), name) }
        }
        let commands = Array(await executor.recorded().dropFirst(before))
        XCTAssertTrue(commands.isEmpty, "Refusal must happen before any launchctl, kill or API call")
        let calls = await api.recorded()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }
    func testUnloadedOrDisabledSystemDaemonIsNotRunning() async throws {
        let runner = try systemRunner()
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        let stoppedSnapshots = await controller.snapshots(for: [runner])
        let stopped = try XCTUnwrap(stoppedSnapshots.first)
        XCTAssertEqual(stopped.status, .stopped); XCTAssertNil(stopped.processID)
        await executor.configure(disabled: "\tdisabled services = {\n\t\t\"org.example.forgejo-runner\" => disabled\n\t}\n")
        let disabledSnapshots = await controller.snapshots(for: [runner])
        let disabled = try XCTUnwrap(disabledSnapshots.first)
        XCTAssertEqual(disabled.status, .disabled); XCTAssertFalse(disabled.isEnabled)
    }
    func testUnreadableSystemDaemonStateIsUnknown() async throws {
        let runner = try systemRunner()
        await executor.configureSystemService(ProcessResult(status: 5, output: "", error: "Input/output error"))
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        let snapshotSnapshots = await controller.snapshots(for: [runner])
        let snapshot = try XCTUnwrap(snapshotSnapshots.first)
        XCTAssertEqual(snapshot.status, .unknown); XCTAssertNil(snapshot.processID)
        XCTAssertEqual(snapshot.detail, "Some local process or launch service information could not be read.")
    }
    func testDaemonStartedWithShortConfigurationFlagIsRecognised() {
        let runner = InstalledRunner(name: "example", directory: root, provider: .forgejo,
            executableURL: URL(fileURLWithPath: "/opt/example/bin/forgejo-runner"), configurationURL: URL(fileURLWithPath: "/opt/example/config.yml"))
        XCTAssertEqual(RunnerProcesses("1551 1 /opt/example/bin/forgejo-runner daemon -c /opt/example/config.yml\n").pid(for: runner), 1551)
        XCTAssertEqual(RunnerProcesses("1552 1 /opt/example/bin/forgejo-runner daemon --config /opt/example/config.yml\n").pid(for: runner), 1552)
        XCTAssertNil(RunnerProcesses("1553 1 /opt/example/bin/forgejo-runner daemon -c /opt/example/other.yml\n").pid(for: runner))
    }
    func testDaemonWithEquivalentArgumentFormsIsRecognised() {
        let runner = InstalledRunner(name: "example", directory: URL(fileURLWithPath: "/opt/example"), provider: .forgejo,
            executableURL: URL(fileURLWithPath: "/opt/shared/bin/forgejo-runner"), configurationURL: URL(fileURLWithPath: "/opt/example/config.yml"))
        XCTAssertEqual(RunnerProcesses("1561 1 /opt/shared/bin/forgejo-runner daemon --config=/opt/example/config.yml\n").pid(for: runner), 1561)
        XCTAssertEqual(RunnerProcesses("1562 1 /opt/shared/bin/forgejo-runner --config /opt/example/config.yml daemon\n").pid(for: runner), 1562)
        XCTAssertEqual(RunnerProcesses("1563 1 /opt/shared/bin/forgejo-runner daemon --config /opt/example/config.yml --label x\n").pid(for: runner), 1563)
        XCTAssertEqual(RunnerProcesses("1564 1 /opt/shared/bin/forgejo-runner  daemon\t-c /opt/example/./config.yml\n").pid(for: runner), 1564)
        XCTAssertNil(RunnerProcesses("1565 1 /opt/shared/bin/forgejo-runner register --config /opt/example/config.yml\n").pid(for: runner))
        XCTAssertNil(RunnerProcesses("1566 1 /opt/other/bin/forgejo-runner daemon --config=/opt/example/config.yml\n").pid(for: runner))
        XCTAssertNil(RunnerProcesses("1567 1 /opt/shared/bin/forgejo-runner daemon --config=/opt/example/config.yml --unknown\n").pid(for: runner))
        // A shared executable gives no evidence of the daemon's working directory.
        XCTAssertNil(RunnerProcesses("1568 1 /opt/shared/bin/forgejo-runner daemon -c config.yml\n").pid(for: runner))
    }
    func testDaemonWithRelativeConfigurationResolvesOnlyForOwnedExecutable() {
        let runner = InstalledRunner(name: "example", directory: URL(fileURLWithPath: "/opt/example"), provider: .forgejo,
            executableURL: URL(fileURLWithPath: "/opt/example/forgejo-runner"), configurationURL: URL(fileURLWithPath: "/opt/example/config.yml"))
        XCTAssertEqual(RunnerProcesses("1571 1 /opt/example/forgejo-runner --config=config.yml daemon\n").pid(for: runner), 1571)
        XCTAssertNil(RunnerProcesses("1572 1 /opt/example/forgejo-runner daemon -c other.yml\n").pid(for: runner))
    }
    private func importedFixture(arguments: [String]? = nil, workingDirectory: Bool = true, keepAlive: Any? = nil) throws -> (InstalledRunner, URL) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = root.appendingPathComponent("config.yaml")
        try Data("PRIVATE_EXISTING_CONFIG_NOT_READ".utf8).write(to: configuration)
        try FileManager.default.setAttributes([.posixPermissions:0], ofItemAtPath: configuration.path)
        let executable = package.appendingPathComponent("bin/forgejo-runner")
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let label = "homebrew.mxcl.forgejo-runner"
        let plist = launchAgents.appendingPathComponent(label + ".plist")
        var object: [String: Any] = ["Label": label, "ProgramArguments": arguments ?? [executable.path, "--config=config.yaml", "daemon"], "RunAtLoad": true,
            "EnvironmentVariables": ["PATH":"/usr/bin:/bin", "EXISTING_SETTING":"kept"]]
        if workingDirectory { object["WorkingDirectory"] = root.path }
        if let keepAlive { object["KeepAlive"] = keepAlive }
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: plist)
        return (InstalledRunner(name: "Imported Forgejo", directory: root, serviceLabel: label, provider: .forgejo,
            executableURL: executable, configurationURL: configuration), plist)
    }
    func testImportedHomebrewServiceCanChangeStartupAndEnableWithoutMigration() async throws {
        let (runner, plist) = try importedFixture()
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        try await controller.setStartsAtLogin(false, for: runner)
        try await controller.setEnabled(true, for: runner)
        let dictionary = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        XCTAssertEqual(dictionary["RunAtLoad"] as? Bool, false)
        XCTAssertEqual(dictionary["ProgramArguments"] as? [String], [runner.executableURL!.path, "--config=config.yaml", "daemon"])
        XCTAssertEqual((dictionary["EnvironmentVariables"] as? [String: String])?["EXISTING_SETTING"], "kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".service").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(RunnerInstallationDescriptor.fileName).path))
        let commands = await executor.recorded()
        XCTAssertEqual(commands.map(\.arguments), [["enable", "gui/\(getuid())/homebrew.mxcl.forgejo-runner"]])
    }
    func testImportedHomebrewServiceStartsInPlaceAndRequiresForceBeforeStop() async throws {
        let (runner, _) = try importedFixture()
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        try await controller.start(runner)
        let started = await executor.recorded()
        XCTAssertTrue(started.contains { $0.arguments.first == "kickstart" && $0.arguments.last == "gui/\(getuid())/homebrew.mxcl.forgejo-runner" })
        await executor.configure(services: "789 0 homebrew.mxcl.forgejo-runner")
        let before = await executor.recorded().count
        do { try await controller.stop(runner); XCTFail("Unverified imported job state must refuse interruption") } catch {}
        let refused = Array(await executor.recorded().dropFirst(before))
        XCTAssertFalse(refused.contains { $0.arguments.first == "bootout" })
        try await controller.stop(runner, force: true)
        let commands = await executor.recorded()
        XCTAssertTrue(commands.contains { $0.arguments == ["bootout", "gui/\(getuid())/homebrew.mxcl.forgejo-runner"] })
        let calls = await api.recorded()
        XCTAssertTrue(calls.isEmpty)
    }
    func testImportedRegistrationCommandWithDaemonNameCannotBeControlled() async throws {
        let arguments = [package.appendingPathComponent("bin/forgejo-runner").path, "register", "--name", "daemon", "--config", root.appendingPathComponent("config.yaml").path]
        let (runner, plist) = try importedFixture(arguments: arguments)
        let before = try Data(contentsOf: plist)
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        do { try await controller.setStartsAtLogin(false, for: runner); XCTFail("A registration command must never be treated as a daemon") } catch {}
        XCTAssertEqual(before, try Data(contentsOf: plist))
        let commands = await executor.recorded()
        XCTAssertTrue(commands.isEmpty)
    }
    func testImportedServiceMismatchRefusesAnyLocalMutation() async throws {
        let (runner, plist) = try importedFixture(arguments: [package.appendingPathComponent("bin/forgejo-runner").path, "daemon", "--config", "another.yaml"])
        let before = try Data(contentsOf: plist)
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        do { try await controller.setStartsAtLogin(false, for: runner); XCTFail("Expected public config-path mismatch refusal") } catch {}
        XCTAssertEqual(before, try Data(contentsOf: plist))
        let commands = await executor.recorded()
        XCTAssertTrue(commands.isEmpty)
    }
    func testImportedServiceWithoutRegistrationMetadataCannotUnregister() async throws {
        let (runner, plist) = try importedFixture()
        let before = try Data(contentsOf: plist)
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        do { try await controller.delete(runner, force: true); XCTFail("Expected missing API metadata refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("registration ID")) }
        XCTAssertEqual(before, try Data(contentsOf: plist))
        let commands = await executor.recorded()
        XCTAssertTrue(commands.isEmpty)
    }
    func testImportedServiceWithMissingPlistReportsMissingFile() async throws {
        let (runner, plist) = try importedFixture()
        try FileManager.default.removeItem(at: plist)
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        do { try await controller.setStartsAtLogin(false, for: runner); XCTFail("Expected missing service refusal") }
        catch { XCTAssertEqual(error.localizedDescription, "The login service file referenced by this runner is missing.") }
        let commands = await executor.recorded()
        XCTAssertTrue(commands.isEmpty)
    }
    func testHomebrewKeepAliveStartupIsBackedUpPrivatelyAndRestoredWithoutRestart() async throws {
        let (runner, plist) = try importedFixture(keepAlive: ["SuccessfulExit":true])
        var initial = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        initial["RunAtLoad"] = false
        initial["EnvironmentVariables"] = ["SECRET_EXISTING_ENV":"never-copy-this-secret"]
        try PropertyListSerialization.data(fromPropertyList: initial, format: .xml, options: 0).write(to: plist)
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        let before = await controller.snapshots(for: [runner], allowRemoteActivity: false)
        XCTAssertTrue(before[0].startsAtLogin, "SuccessfulExit KeepAlive implies an initial launch")
        let commandCount = await executor.recorded().count
        try await controller.setStartsAtLogin(false, for: runner)
        let disabled = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        XCTAssertEqual(disabled["RunAtLoad"] as? Bool, false)
        XCTAssertEqual(disabled["KeepAlive"] as? Bool, false)
        let backup = home.appendingPathComponent("Library/Application Support/RunningMan/ServicePolicies/homebrew.mxcl.forgejo-runner.plist")
        let bytes = try Data(contentsOf: backup)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("never-copy-this-secret"))
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let off = await controller.snapshots(for: [runner], allowRemoteActivity: false)
        XCTAssertFalse(off[0].startsAtLogin)
        try await controller.setStartsAtLogin(true, for: runner)
        let restored = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        XCTAssertEqual(restored["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((restored["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let commands = Array(await executor.recorded().dropFirst(commandCount))
        XCTAssertFalse(commands.contains { ["kickstart", "bootout", "bootstrap", "enable", "disable"].contains($0.arguments.first ?? "") })
    }
    func testExternalServiceEditsPreventStaleKeepAliveRestoration() async throws {
        let (runner, plist) = try importedFixture(keepAlive: true)
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        try await controller.setStartsAtLogin(false, for: runner)
        var changed = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        changed["EnvironmentVariables"] = ["EXTERNALLY_CHANGED":"yes"]
        try PropertyListSerialization.data(fromPropertyList: changed, format: .xml, options: 0).write(to: plist)
        try await controller.setStartsAtLogin(true, for: runner)
        let after = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        XCTAssertEqual(after["KeepAlive"] as? Bool, false, "An external edit prevents applying the saved old policy")
        XCTAssertEqual(after["EnvironmentVariables"] as? [String: String], ["EXTERNALLY_CHANGED":"yes"])
        XCTAssertEqual(after["RunAtLoad"] as? Bool, true)
    }
    func testComplexKeepAlivePolicyRefusesStartupRewrite() async throws {
        let (runner, plist) = try importedFixture(keepAlive: ["PathState":["/tmp/fictional-condition":true]])
        let before = try Data(contentsOf: plist)
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        do { try await controller.setStartsAtLogin(false, for: runner); XCTFail("Expected unsupported automatic-condition refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("complex KeepAlive")) }
        XCTAssertEqual(before, try Data(contentsOf: plist))
        let snapshots = await controller.snapshots(for: [runner], allowRemoteActivity: false)
        XCTAssertTrue(snapshots[0].detail?.contains("additional automatic launch conditions") == true)
    }
    func testImportedHomebrewServiceRemainsVisibleWithoutReadingItsCredentials() async throws {
        let imported = InstalledRunner(name: "Imported Forgejo", directory: root, serviceLabel: "homebrew.mxcl.forgejo-runner", provider: .forgejo,
            executableURL: package.appendingPathComponent("bin/forgejo-runner"), configurationURL: home.appendingPathComponent("private/config.yaml"))
        await executor.configure(services: "789 0 homebrew.mxcl.forgejo-runner")
        let controller = RunnerServiceController(homeDirectory: home, executor: executor, forgejoAPI: api)
        let snapshots = await controller.snapshots(for: [imported])
        XCTAssertEqual(snapshots.first?.processID, 789)
        XCTAssertEqual(snapshots.first?.status, .unknown)
        let calls = await api.recorded()
        XCTAssertTrue(calls.isEmpty)
    }
    func testScopeValidationAndHostLabels() throws {
        let server = URL(string: "https://forge.example.test")!
        XCTAssertEqual(try ForgejoRegistrationLocation(serverURL: server, scope: .organization, scopeName: "example").path, "/orgs/example/actions/runners")
        XCTAssertEqual(try ForgejoRegistrationLocation(serverURL: server, scope: .user, scopeName: "").path, "/user/actions/runners")
        XCTAssertEqual(try ForgejoRegistrationLocation(serverURL: server, scope: .instance, scopeName: "").path, "/admin/actions/runners")
        XCTAssertThrowsError(try ForgejoRegistrationLocation(serverURL: server, scope: .repository, scopeName: "../repo"))
        XCTAssertThrowsError(try ForgejoRegistrationLocation(serverURL: URL(string: "http://forge.example.test")!, scope: .user, scopeName: ""))
        XCTAssertThrowsError(try ForgejoRegistrationLocation.validatedPath("/repos/owner/../actions/runners"))
        XCTAssertEqual(try ForgejoRunnerInstaller.hostLabels(["macos", "self-hosted:host"]), ["macos:host", "self-hosted:host"])
        XCTAssertThrowsError(try ForgejoRunnerInstaller.hostLabels(["ubuntu:docker://node:20"]))
        XCTAssertEqual(try ForgejoRunnerInstaller.supportedVersion("forgejo-runner version v13.2.0"), "v13.2.0")
        XCTAssertThrowsError(try ForgejoRunnerInstaller.supportedVersion("forgejo-runner version v13.1.0"))
    }
}
