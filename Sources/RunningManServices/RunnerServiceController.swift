import Foundation
import CryptoKit
import RunningManCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ServiceDescriptor {
    var url: URL
    var label: String
    var dictionary: [String: Any]
    var startsAtLogin: Bool {
        if dictionary["RunAtLoad"] as? Bool == true { return true }
        if let keepAlive = dictionary["KeepAlive"] as? Bool { return keepAlive }
        if let keepAlive = dictionary["KeepAlive"] as? [String: Any], keepAlive["SuccessfulExit"] is Bool { return true }
        return false
    }
    var hasUncertainStartupPolicy: Bool {
        guard let keepAlive = dictionary["KeepAlive"], !(keepAlive is Bool) else { return false }
        guard let conditions = keepAlive as? [String: Any] else { return true }
        return !conditions.isEmpty && !(conditions.count == 1 && conditions["SuccessfulExit"] is Bool)
    }
}
struct RunnerProcesses {
    struct Entry { var pid: Int32; var parent: Int32; var command: String }
    var entries: [Entry]
    init(_ output: String) {
        entries = output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return Entry(pid: pid, parent: parent, command: String(fields[2]))
        }
    }
    func pid(for runner: InstalledRunner) -> Int32? {
        if runner.provider == .forgejo {
            guard let executable = runner.executableURL, let configuration = runner.configurationURL else { return nil }
            // ps output cannot be split unambiguously, so exact forms keep paths
            // containing spaces recognisable.
            let daemon = executable.path + " daemon "
            let expected = [daemon + "--config " + configuration.path, daemon + "-c " + configuration.path]
            return entries.first { expected.contains($0.command) || Self.isDaemon($0.command, of: runner, executable: executable, configuration: configuration) }?.pid
        }
        return entries.first { $0.command.hasPrefix(runner.directory.path + "/bin/Runner.Listener ") || $0.command == runner.directory.path + "/bin/Runner.Listener" }?.pid
    }
    func isBusy(_ runner: InstalledRunner, servicePID: Int32?) -> Bool {
        guard runner.provider == .github else { return false }
        var descendants: Set<Int32> = Set([servicePID, pid(for: runner)].compactMap { $0 })
        for _ in 0..<32 {
            let next = Set(entries.filter { descendants.contains($0.parent) }.map(\.pid))
            let old = descendants.count; descendants.formUnion(next)
            if descendants.count == old { break }
        }
        return entries.contains {
            $0.command.hasPrefix(runner.directory.path + "/bin/Runner.Worker ") ||
            $0.command == runner.directory.path + "/bin/Runner.Worker" ||
            (descendants.contains($0.pid) && ($0.command.contains("/Runner.Worker ") || $0.command.hasSuffix("/Runner.Worker")))
        }
    }
    /// Accepts every flag order and form ForgejoDaemonCommand accepts. ps does not
    /// show a process's working directory, so a relative configuration path is
    /// resolved against the runner directory only when the executable lives there.
    /// With a shared executable, such as Homebrew's, another runner's daemon
    /// could otherwise pass as this one and be stopped.
    private static func isDaemon(_ command: String, of runner: InstalledRunner, executable: URL, configuration: URL) -> Bool {
        guard command.hasPrefix(executable.path + " ") else { return false }
        let arguments = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard arguments.first == executable.path, let value = ForgejoDaemonCommand.parse(arguments: arguments) else { return false }
        let candidate: URL
        if value.hasPrefix("/") { candidate = URL(fileURLWithPath: value) }
        else if executable.standardizedFileURL.path.hasPrefix(runner.directory.standardizedFileURL.path + "/") { candidate = runner.directory.appendingPathComponent(value) }
        else { return false }
        return candidate.standardizedFileURL.path == configuration.standardizedFileURL.path
    }
}

public actor RunnerServiceController {
    private let homeDirectory: URL
    private let executor: any ProcessExecuting
    private let githubCLIOverride: String?
    private let userID: UInt32
    private let forgejoAPI: any ForgejoAPIRequesting
    private struct ForgejoStateCache { var status: RunnerStatus; var expires: Date }
    private var forgejoStateCache: [String: ForgejoStateCache] = [:]
    private var domain: String { "gui/\(userID)" }
    private var launchAgents: URL { homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, forgejoAPI: any ForgejoAPIRequesting = ForgejoAPIClient()) {
        self.homeDirectory = homeDirectory.standardizedFileURL; self.executor = SystemProcessExecutor(); self.userID = getuid(); self.githubCLIOverride = nil; self.forgejoAPI = forgejoAPI
    }
    init(homeDirectory: URL, executor: any ProcessExecuting, userID: UInt32 = getuid(), githubCLIPath: String = "/usr/bin/gh", forgejoAPI: any ForgejoAPIRequesting = ForgejoAPIClient()) {
        self.homeDirectory = homeDirectory.standardizedFileURL; self.executor = executor; self.userID = userID; self.githubCLIOverride = githubCLIPath; self.forgejoAPI = forgejoAPI
    }

    public func snapshots(for runners: [InstalledRunner], allowRemoteActivity: Bool = true) async -> [RunnerSnapshot] {
        await snapshots(for: runners, freshForgejoState: false, allowRemoteActivity: allowRemoteActivity)
    }
    private func snapshots(for runners: [InstalledRunner], freshForgejoState: Bool, allowRemoteActivity: Bool = true) async -> [RunnerSnapshot] {
        guard !runners.isEmpty else { return [] }
        async let processes = try? executor.run(Self.processListRequest)
        async let services = try? executor.run(ProcessRequest(executable: "/bin/launchctl", arguments: ["list"]))
        async let disabled = try? executor.run(ProcessRequest(executable: "/bin/launchctl", arguments: ["print-disabled", domain]))
        let (processResult, serviceResult, disabledResult) = await (processes, services, disabled)
        let processList = RunnerProcesses(processResult?.status == 0 ? processResult!.output : "")
        let loaded = Self.parseServices(serviceResult?.status == 0 ? serviceResult!.output : "", including: Set(runners.compactMap(\.serviceLabel)))
        let disabledLabels = Self.parseDisabled(disabledResult?.status == 0 ? disabledResult!.output : "")
        let system = await systemServiceStates(for: runners.filter { $0.serviceDomain == .system })
        let forgejoStates = allowRemoteActivity ? await forgejoStatuses(runners: runners, processes: processList, loaded: loaded, fresh: freshForgejoState) : [:]
        return runners.map { runner in
            let isSystem = runner.serviceDomain == .system
            // A user LaunchAgent that happens to share a system service's label is not that service.
            let descriptor = isSystem ? nil : try? service(for: runner)
            let label = descriptor?.label ?? runner.serviceLabel
            let servicePID = isSystem ? system.pids[runner.id] : label.flatMap { loaded[$0] }.flatMap { $0 > 0 ? $0 : nil }
            let pid = processList.pid(for: runner) ?? servicePID
            let enabled = !(isSystem ? system.disabledLabels : disabledLabels).contains(label ?? "")
            let remoteState = forgejoStates[runner.id] ?? .unknown
            let busy = runner.provider == .forgejo ? pid != nil && remoteState == .busy : processList.isBusy(runner, servicePID: servicePID)
            let unavailable = processResult?.status != 0 || serviceResult?.status != 0 || disabledResult?.status != 0 || processResult?.truncated == true || serviceResult?.truncated == true || disabledResult?.truncated == true || processResult?.timedOut == true || serviceResult?.timedOut == true || disabledResult?.timedOut == true
                || (isSystem && system.unavailable.contains(runner.id))
            let status: RunnerStatus = busy ? .busy : unavailable ? .unknown : pid != nil ? (runner.provider == .forgejo ? remoteState : .idle) : !enabled ? .disabled : .stopped
            let activityUnverified = runner.provider == .forgejo && pid != nil && remoteState == .unknown
            let readOnlyForgejo = runner.provider == .forgejo && descriptor == nil && !FileManager.default.fileExists(atPath: runner.directory.appendingPathComponent(RunnerInstallationDescriptor.fileName).path)
            return RunnerSnapshot(runner: runner, status: status, processID: pid,
                                  startsAtLogin: descriptor?.startsAtLogin ?? false, isEnabled: enabled,
                                  detail: unavailable ? "Some local process or launch service information could not be read." : isSystem ? Self.systemServiceDetail(label: label) : descriptor?.hasUncertainStartupPolicy == true ? "This service has additional automatic launch conditions. Login behavior cannot be fully inferred; changing its startup policy is unavailable." : readOnlyForgejo ? "This imported Forgejo service could not be validated for local controls. Its process is visible, but configuration and credentials will not be read or changed." : activityUnverified ? "The Forgejo daemon is running, but job activity could not be verified. Connect API access for this server to verify idle state." : descriptor == nil ? "No validated login service is installed. Start installs one for your account." : nil)
        }
    }

    public func start(_ runner: InstalledRunner) async throws {
        try validateRunner(runner)
        let current = await snapshots(for: [runner]).first
        if current?.processID != nil { return }
        guard current?.status != .unknown else { throw RunnerServiceError("Cannot verify this runner’s current state. Refresh before starting it.") }
        let descriptor = try await ensureService(for: runner)
        let disabled = try await checked(executor, ProcessRequest(executable: "/bin/launchctl", arguments: ["print-disabled", domain]), operation: "Read service enablement")
        guard !Self.parseDisabled(disabled.output).contains(descriptor.label) else { throw RunnerServiceError("Enable this runner before starting it.") }
        let target = domain + "/" + descriptor.label
        let state = try await executor.run(ProcessRequest(executable: "/bin/launchctl", arguments: ["print", target]))
        if state.status != 0 {
            _ = try await checked(executor, ProcessRequest(executable: "/bin/launchctl", arguments: ["bootstrap", domain, descriptor.url.path]), operation: "Load runner service")
        }
        // No -k: starting an already-running runner must never terminate its job.
        _ = try await checked(executor, ProcessRequest(executable: "/bin/launchctl", arguments: ["kickstart", target]), operation: "Start runner")
    }

    public func stop(_ runner: InstalledRunner, force: Bool = false) async throws {
        try validateRunner(runner)
        try await requireIdle(runner, force: force)
        try await performStop(runner)
    }
    /// Stops a validated runner whose busy state the caller has already checked.
    private func performStop(_ runner: InstalledRunner) async throws {
        if let descriptor = try optionalService(for: runner) {
            let target = domain + "/" + descriptor.label
            let state = try await executor.run(ProcessRequest(executable: "/bin/launchctl", arguments: ["print", target]))
            // Only "not found" proves the service is unloaded. Killing the process of
            // a service launchd still supervises would let KeepAlive restart it.
            guard !state.timedOut, !state.truncated, state.status == 0 || state.status == Self.launchctlServiceNotFound else {
                throw RunnerServiceError("Cannot verify whether the runner service is loaded. The runner was not stopped.")
            }
            if state.status == 0 {
                _ = try await checked(executor, ProcessRequest(executable: "/bin/launchctl", arguments: ["bootout", target]), operation: "Stop runner")
            }
        } else if let plist = try stalePlist(for: runner) {
            // The marker's plist was deleted, but launchd can still supervise the
            // service it loaded from that file. Unload it only when launchd reports
            // exactly that path, so another service with the same label is never touched.
            let target = domain + "/" + plist.deletingPathExtension().lastPathComponent
            let state = try await executor.run(ProcessRequest(executable: "/bin/launchctl", arguments: ["print", target]))
            if state.status == 0, !state.timedOut, !state.truncated, Self.parseLoadedServicePath(state.output) == plist.path {
                _ = try await checked(executor, ProcessRequest(executable: "/bin/launchctl", arguments: ["bootout", target]), operation: "Stop runner")
            }
        }
        // A runner started manually in Terminal is not owned by launchd. Target only
        // the validated listener PID; never pkill a name shared by other runners.
        let processes = try await checked(executor, Self.processListRequest, operation: "Inspect runner processes")
        guard let pid = RunnerProcesses(processes.output).pid(for: runner) else { return }
        let termination = ProcessRequest(executable: "/bin/kill", arguments: ["-TERM", String(pid)])
        let result = try await executor.run(termination)
        // The process can exit on its own between the snapshot and the signal.
        let alreadyExited = result.status != 0 && !result.timedOut && result.error.contains("No such process")
        if !alreadyExited { _ = try requireSuccess(result, of: termination, operation: "Stop manually started runner") }
        try await waitForExit(of: runner)
    }
    /// A signal does not prove the runner exited, and another supervisor may start
    /// it again. Poll briefly so a surviving process is never reported as stopped.
    private func waitForExit(of runner: InstalledRunner) async throws {
        for _ in 0..<Self.exitPollAttempts {
            try await Task.sleep(nanoseconds: Self.exitPollInterval)
            let processes = try await checked(executor, Self.processListRequest, operation: "Verify the runner stopped")
            if RunnerProcesses(processes.output).pid(for: runner) == nil { return }
        }
        throw RunnerServiceError("The runner process is still running after the stop request. It may still be shutting down, or another service restarted it. Refresh to check its state.")
    }
    private static let processListRequest = ProcessRequest(executable: "/bin/ps", arguments: ["-ww", "-axo", "pid=,ppid=,command="])
    private static let exitPollAttempts = 8
    private static let exitPollInterval: UInt64 = 250_000_000

    public func setEnabled(_ enabled: Bool, for runner: InstalledRunner, force: Bool = false) async throws {
        try validateRunner(runner)
        if !enabled { try await requireIdle(runner, force: force) }
        let descriptor = try await ensureService(for: runner)
        _ = try await checked(executor, ProcessRequest(executable: "/bin/launchctl", arguments: [enabled ? "enable" : "disable", domain + "/" + descriptor.label]), operation: enabled ? "Enable runner" : "Disable runner")
        guard !enabled else { return }
        // Disable first, so a failed stop cannot leave the runner enabled. A job can
        // start while the service is prepared and disabled, so check again right
        // before stopping; a busy runner then stays disabled but keeps its job.
        do {
            try await requireIdle(runner, force: force)
            try await performStop(runner)
        } catch { throw RunnerServiceError("Disabled, but stopping failed: " + error.localizedDescription) }
    }

    public func setStartsAtLogin(_ enabled: Bool, for runner: InstalledRunner) async throws {
        try validateRunner(runner)
        var descriptor = try await ensureService(for: runner)
        let policyBackup = try prepareStartupPolicy(enabled, service: &descriptor)
        descriptor.dictionary["RunAtLoad"] = enabled
        let data = try PropertyListSerialization.data(fromPropertyList: descriptor.dictionary, format: .xml, options: 0)
        try data.write(to: descriptor.url, options: .atomic)
        if enabled, let policyBackup { try? FileManager.default.removeItem(at: policyBackup) }
        // launchd reads this plist on the next bootstrap/login. Do not restart a
        // live service merely because its next-login policy changed.
    }

    public func delete(_ runner: InstalledRunner, trashFiles: Bool = false, force: Bool = false) async throws {
        try requireUserService(runner)
        if runner.provider == .forgejo { try await deleteForgejo(runner, trashFiles: trashFiles, force: force); return }
        try validateRunner(runner)
        try await requireIdle(runner, force: force)
        guard let githubURL = runner.githubURL else { throw RunnerServiceError("This runner has no GitHub URL. Its files were preserved.") }
        let scope = try GitHubRunnerScope(url: githubURL)
        let gh = try githubCLIOverride ?? githubCLI()
        let tokenResult = try await checked(executor, ProcessRequest(executable: gh, arguments: ["api", "--hostname", "github.com", "--method", "POST", scope.apiPrefix + "/remove-token"], timeout: 35), operation: "Request runner removal permission")
        let token = try GitHubRunnerInstaller.decodeToken(tokenResult.output)
        let descriptor = try optionalService(for: runner)
        try await stop(runner, force: force)
        // config.sh requires the service marker to be removed before unregister.
        // Restore the service metadata if GitHub unregister fails.
        let marker = runner.directory.appendingPathComponent(".service")
        let markerData = descriptor == nil ? nil : try Data(contentsOf: marker)
        do {
            if let descriptor { try FileManager.default.removeItem(at: descriptor.url) }
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            _ = try await checked(executor, ProcessRequest(executable: "/bin/bash", arguments: [runner.directory.appendingPathComponent("config.sh").path, "remove"], directory: runner.directory,
                environment: ["ACTIONS_RUNNER_INPUT_TOKEN": token], timeout: 120, secrets: [token]), operation: "Unregister runner")
        } catch {
            if let descriptor, let data = try? PropertyListSerialization.data(fromPropertyList: descriptor.dictionary, format: .xml, options: 0) { try? data.write(to: descriptor.url, options: .atomic) }
            if let markerData { try? markerData.write(to: marker, options: .atomic) }
            throw Self.stoppedAfterFailedRemoval(error)
        }
        if trashFiles {
            #if os(macOS)
            var destination: NSURL?
            try FileManager.default.trashItem(at: runner.directory, resultingItemURL: &destination)
            #else
            throw RunnerServiceError("Runner unregistered; moving files to Trash is available on macOS only. Files were preserved.")
            #endif
        }
    }

    /// Removal stops the runner before unregistering it and does not restart it
    /// when unregistering fails.
    private static func stoppedAfterFailedRemoval(_ error: Error) -> RunnerServiceError {
        RunnerServiceError(error.localizedDescription + " The runner was stopped and remains stopped. Start it again to resume taking jobs.")
    }
    private func requireIdle(_ runner: InstalledRunner, force: Bool) async throws {
        guard !force else { return }
        let state = await snapshots(for: [runner], freshForgejoState: true).first
        guard state?.status != .busy else { throw RunnerServiceError("This runner is executing a job. Wait for it to finish or explicitly force the action.") }
        guard state?.status != .unknown else { throw RunnerServiceError("Cannot verify whether this runner is busy. No action was taken.") }
    }
    private func requireUserService(_ runner: InstalledRunner) throws {
        guard runner.serviceDomain == .user else {
            throw RunnerServiceError("This runner is managed by a system LaunchDaemon. RunningMan does not start, stop or change system services; manage it with an administrator account.")
        }
    }
    private func validateRunner(_ runner: InstalledRunner) throws {
        try requireUserService(runner)
        let root = runner.directory.standardizedFileURL
        guard root.isFileURL, root.path != "/", root.path != homeDirectory.path,
              root.resolvingSymlinksInPath().path == root.path else { throw RunnerServiceError("Runner directory must be a real, dedicated directory, not a symbolic link or your home directory.") }
        if runner.provider == .forgejo {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(RunnerInstallationDescriptor.fileName).path) else {
                // Imported user services can be controlled in place using only
                // public LaunchAgent metadata. Never read their runner config.
                _ = try service(for: runner)
                guard let executable = runner.executableURL, FileManager.default.isExecutableFile(atPath: executable.path),
                      let configuration = runner.configurationURL, FileManager.default.fileExists(atPath: configuration.path) else {
                    throw RunnerServiceError("The imported Forgejo service’s executable or configuration path is missing. Local controls are unavailable; its files were preserved.")
                }
                return
            }
            let descriptor = try RunnerInstallationDescriptor.load(from: root)
            let installed = try descriptor.installedRunner(in: root)
            guard installed.provider == .forgejo, installed.name == runner.name, installed.agentID == runner.agentID,
                  installed.remoteURL == runner.remoteURL, installed.executableURL == runner.executableURL,
                  installed.configurationURL == runner.configurationURL,
                  let executable = installed.executableURL, let configuration = installed.configurationURL else {
                throw RunnerServiceError("Forgejo runner metadata changed. Refresh before trying again.")
            }
            for url in [executable, configuration] {
                guard url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path == url.path,
                      (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile) == true,
                      (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else {
                    throw RunnerServiceError("Forgejo control requires owned executable and configuration files inside this installation, without symbolic links.")
                }
            }
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw RunnerServiceError("The Forgejo runner executable is missing or not executable.") }
            return
        }
        let info = try runnerMetadata(at: root)
        guard info["agentName"] as? String == runner.name,
              runner.agentID == nil || info["agentId"] as? Int == runner.agentID,
              runner.githubURL == nil || (info["gitHubUrl"] as? String).flatMap(URL.init(string:))?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == runner.githubURL?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { throw RunnerServiceError("Runner metadata has changed. Refresh before trying again.") }
        let script = root.appendingPathComponent("config.sh")
        guard FileManager.default.fileExists(atPath: script.path), !((try? script.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true) else { throw RunnerServiceError("Runner config.sh is missing or is a symbolic link.") }
    }
    private func optionalService(for runner: InstalledRunner) throws -> ServiceDescriptor? {
        let marker = runner.directory.appendingPathComponent(".service")
        if FileManager.default.fileExists(atPath: marker.path) {
            // A marker left behind after its plist was deleted means there is no
            // service, so starting can install a fresh one.
            return try isStaleServiceMarker(marker) ? nil : service(for: runner)
        }
        if runner.provider == .forgejo, let label = runner.serviceLabel,
           Self.isSafeServiceLabel(label), FileManager.default.fileExists(atPath: launchAgents.appendingPathComponent(label + ".plist").path) {
            return try service(for: runner)
        }
        return nil
    }
    /// True when the marker names a missing plist with a safe label directly in
    /// the user's LaunchAgents folder. Anything else is still validated in full.
    /// The missing plist a stale marker names, if the marker is stale.
    private func stalePlist(for runner: InstalledRunner) throws -> URL? {
        let marker = runner.directory.appendingPathComponent(".service")
        guard !Self.isMissing(marker), try isStaleServiceMarker(marker) else { return nil }
        return URL(fileURLWithPath: try runnerText(marker)).standardizedFileURL
    }
    private func isStaleServiceMarker(_ marker: URL) throws -> Bool {
        let path = try runnerText(marker)
        guard path.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == launchAgents.path, url.pathExtension == "plist",
              Self.isSafeServiceLabel(url.deletingPathExtension().lastPathComponent) else { return false }
        return Self.isMissing(url)
    }
    private func service(for runner: InstalledRunner) throws -> ServiceDescriptor {
        let marker = runner.directory.appendingPathComponent(".service")
        let path: String
        if FileManager.default.fileExists(atPath: marker.path) { path = try runnerText(marker) }
        else if runner.provider == .forgejo, let label = runner.serviceLabel, Self.isSafeServiceLabel(label) {
            path = launchAgents.appendingPathComponent(label + ".plist").path
        } else { throw RunnerServiceError("This runner has no validated user LaunchAgent.") }
        guard path.hasPrefix("/") else { throw RunnerServiceError("Runner .service must point to an absolute LaunchAgent plist path.") }
        return try validatedService(at: URL(fileURLWithPath: path).standardizedFileURL, for: runner)
    }
    /// Validates that a plist directly in the user's LaunchAgents folder is this
    /// installation's service and belongs to this account.
    private func validatedService(at url: URL, for runner: InstalledRunner) throws -> ServiceDescriptor {
        let unsafeLocation = RunnerServiceError("This runner service is outside your LaunchAgents folder or uses a symbolic link. It will not be modified.")
        guard url.deletingLastPathComponent().path == launchAgents.path else { throw unsafeLocation }
        guard !Self.isMissing(url) else { throw RunnerServiceError("The login service file referenced by this runner is missing.") }
        guard url.resolvingSymlinksInPath().path == url.path,
              !((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true) else { throw unsafeLocation }
        let data = try Data(contentsOf: url)
        guard data.count < 1_000_000,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, Self.isSafeServiceLabel(label) else {
            throw RunnerServiceError("The runner LaunchAgent does not match this installation. It will not be modified.")
        }
        let arguments = plist["ProgramArguments"] as? [String]
        let matches: Bool
        if runner.provider == .forgejo, let executable = runner.executableURL, let configuration = runner.configurationURL {
            let hasManagedDescriptor = FileManager.default.fileExists(atPath: runner.directory.appendingPathComponent(RunnerInstallationDescriptor.fileName).path)
            let workingPath = plist["WorkingDirectory"] as? String
            let working = workingPath.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).standardizedFileURL : nil }
            let workingMatches = working == nil || working?.resolvingSymlinksInPath().path == runner.directory.path
            let managedMatches = !hasManagedDescriptor || (label.hasPrefix("io.github.l-k-m.RunningMan.forgejo.") && workingPath == runner.directory.path)
            matches = label == runner.serviceLabel && workingMatches && managedMatches &&
                Self.forgejoArgumentsMatch(arguments ?? [], executable: executable, configuration: configuration, workingDirectory: working)
        } else {
            matches = runner.provider == .github && label.hasPrefix("actions.runner.") &&
                plist["WorkingDirectory"] as? String == runner.directory.path && arguments?.first == runner.directory.appendingPathComponent("runsvc.sh").path
        }
        guard matches else { throw RunnerServiceError("The runner LaunchAgent does not match this installation. It will not be modified.") }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == userID else { throw RunnerServiceError("The runner LaunchAgent belongs to another account.") }
        return ServiceDescriptor(url: url, label: label, dictionary: plist)
    }
    private func ensureService(for runner: InstalledRunner) async throws -> ServiceDescriptor {
        if let service = try optionalService(for: runner) { return service }
        if runner.provider == .forgejo {
            try removeStaleServiceMarker(for: runner)
            return try installForgejoService(for: runner)
        }
        guard launchAgents.resolvingSymlinksInPath().path == launchAgents.path else { throw RunnerServiceError("The LaunchAgents directory uses a symbolic link. No service was installed.") }
        if let service = try adoptExistingService(for: runner) { return service }
        guard FileManager.default.fileExists(atPath: runner.directory.appendingPathComponent("svc.sh").path) else { throw RunnerServiceError("This runner installation has no svc.sh. Reinstall the official runner package.") }
        // svc.sh writes the marker through the shell, which would follow a link.
        try removeStaleServiceMarker(for: runner)
        _ = try await checked(executor, ProcessRequest(executable: "/bin/bash", arguments: [runner.directory.appendingPathComponent("env.sh").path], directory: runner.directory), operation: "Capture runner tool environment")
        _ = try await checked(executor, ProcessRequest(executable: "/bin/bash", arguments: [runner.directory.appendingPathComponent("svc.sh").path, "install"], directory: runner.directory), operation: "Install runner login service")
        var descriptor = try service(for: runner)
        // svc.sh supplies RunAtLoad=true. Installing the mechanism for a manual
        // runner must not silently opt it into login startup.
        descriptor.dictionary["RunAtLoad"] = false
        let data = try PropertyListSerialization.data(fromPropertyList: descriptor.dictionary, format: .xml, options: 0)
        try data.write(to: descriptor.url, options: .atomic)
        return descriptor
    }
    /// svc.sh refuses to overwrite an existing plist. When the marker is missing
    /// or stale but this installation's plist is still present, reconnect it and
    /// keep its startup policy instead of reinstalling.
    private func adoptExistingService(for runner: InstalledRunner) throws -> ServiceDescriptor? {
        guard runner.provider == .github, let label = runner.serviceLabel, Self.isSafeServiceLabel(label) else { return nil }
        let url = launchAgents.appendingPathComponent(label + ".plist").standardizedFileURL
        guard !Self.isMissing(url) else { return nil }
        let descriptor = try validatedService(at: url, for: runner)
        guard descriptor.label == label else { throw RunnerServiceError("The runner LaunchAgent does not match this installation. It will not be modified.") }
        try removeStaleServiceMarker(for: runner)
        try Data(descriptor.url.path.utf8).write(to: runner.directory.appendingPathComponent(".service"), options: .atomic)
        return descriptor
    }
    /// Removes a marker only after confirming it is a regular file in this runner
    /// directory that names a missing plist. A missing marker needs no work.
    private func removeStaleServiceMarker(for runner: InstalledRunner) throws {
        let marker = runner.directory.appendingPathComponent(".service")
        guard !Self.isMissing(marker) else { return }
        let values = try? marker.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard marker.deletingLastPathComponent().resolvingSymlinksInPath().path == runner.directory.standardizedFileURL.path,
              values?.isSymbolicLink == false, values?.isRegularFile == true, try isStaleServiceMarker(marker) else {
            throw RunnerServiceError("The runner’s .service marker could not be validated. It was not replaced.")
        }
        try FileManager.default.removeItem(at: marker)
    }
    private struct SystemServiceStates { var pids: [String: Int32] = [:]; var disabledLabels: Set<String> = []; var unavailable: Set<String> = [] }
    /// Reads system LaunchDaemon state without privileges. launchctl exits with
    /// 113 when a label is not loaded, which means not running rather than unknown.
    private func systemServiceStates(for runners: [InstalledRunner]) async -> SystemServiceStates {
        var states = SystemServiceStates()
        guard !runners.isEmpty else { return states }
        let disabled = try? await executor.run(ProcessRequest(executable: "/bin/launchctl", arguments: ["print-disabled", "system"]))
        let disabledReadable = disabled?.status == 0 && disabled?.truncated == false && disabled?.timedOut == false
        if disabledReadable, let disabled { states.disabledLabels = Self.parseDisabled(disabled.output) }
        for runner in runners {
            guard disabledReadable, let label = runner.serviceLabel, Self.isSafeServiceLabel(label),
                  let result = try? await executor.run(ProcessRequest(executable: "/bin/launchctl", arguments: ["print", "system/" + label])),
                  !result.truncated, !result.timedOut, result.status == 0 || result.status == Self.launchctlServiceNotFound else {
                states.unavailable.insert(runner.id); continue
            }
            if result.status == 0 { states.pids[runner.id] = Self.parseSystemServicePID(result.output) }
        }
        return states
    }
    private static let launchctlServiceNotFound: Int32 = 113
    /// The plist path launchd loaded a service from: the top-level `path` key only.
    static func parseLoadedServicePath(_ text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("\tpath = ") {
            return String(line.dropFirst("\tpath = ".count))
        }
        return nil
    }
    static func parseSystemServicePID(_ text: String) -> Int32? {
        // Only the service's own top-level key; nested blocks are indented further.
        for line in text.split(separator: "\n") where line.hasPrefix("\tpid = ") {
            if let pid = Int32(line.dropFirst("\tpid = ".count)), pid > 0 { return pid }
        }
        return nil
    }
    private static func systemServiceDetail(label: String?) -> String {
        let service = label.map { "the system service " + $0 } ?? "a system service"
        return "This runner is managed by \(service). RunningMan shows its process, logs and jobs, but does not start, stop or change system services, and cannot verify whether it is running a job."
    }

    private func forgejoStatuses(runners: [InstalledRunner], processes: RunnerProcesses, loaded: [String: Int32], fresh: Bool) async -> [String: RunnerStatus] {
        var result: [String: RunnerStatus] = [:]
        struct Lookup: Sendable { var runnerID: String; var server: URL; var path: String }
        var lookups: [Lookup] = []
        for runner in runners where runner.provider == .forgejo {
            let servicePID = runner.serviceLabel.flatMap { loaded[$0] }.flatMap { $0 > 0 ? $0 : nil }
            guard processes.pid(for: runner) != nil || servicePID != nil else { continue }
            if !fresh, let cached = forgejoStateCache[runner.id], cached.expires > Date() { result[runner.id] = cached.status; continue }
            guard let descriptor = try? RunnerInstallationDescriptor.load(from: runner.directory),
                  let id = descriptor.agentID, id > 0, let remote = descriptor.remoteURL,
                  let path = descriptor.registrationPath.flatMap({ try? ForgejoRegistrationLocation.validatedPath($0) }),
                  var components = URLComponents(url: remote, resolvingAgainstBaseURL: false) else { result[runner.id] = .unknown; continue }
            components.path = ""
            guard let server = components.url else { result[runner.id] = .unknown; continue }
            lookups.append(Lookup(runnerID: runner.id, server: server, path: path + "/" + String(id)))
        }
        let api = forgejoAPI
        await withTaskGroup(of: (String, RunnerStatus, Date).self) { group in
            for lookup in lookups {
                group.addTask {
                    do {
                        let data = try await api.request(path: lookup.path, serverURL: lookup.server, method: "GET", body: nil)
                        struct RemoteRunner: Decodable { var status: String }
                        let remote = try JSONDecoder().decode(RemoteRunner.self, from: data)
                        let status: RunnerStatus = remote.status == "active" ? .busy : remote.status == "idle" ? .idle : .unknown
                        return (lookup.runnerID, status, Date().addingTimeInterval(30))
                    } catch {
                        return (lookup.runnerID, .unknown, max(Date().addingTimeInterval(30), (error as? ForgejoAPIError)?.retryAfter ?? Date()))
                    }
                }
            }
            for await (id, status, expiry) in group { result[id] = status; forgejoStateCache[id] = ForgejoStateCache(status: status, expires: expiry) }
        }
        return result
    }

    private func installForgejoService(for runner: InstalledRunner) throws -> ServiceDescriptor {
        guard let executable = runner.executableURL, let configuration = runner.configurationURL,
              let label = runner.serviceLabel, label.hasPrefix("io.github.l-k-m.RunningMan.forgejo."), !label.contains("/"),
              !label.contains("\n"), !label.contains("\r") else { throw RunnerServiceError("This Forgejo installation has no valid managed service metadata.") }
        guard launchAgents.resolvingSymlinksInPath().path == launchAgents.path else { throw RunnerServiceError("The LaunchAgents directory uses a symbolic link. No service was installed.") }
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let url = launchAgents.appendingPathComponent(label + ".plist")
        guard !FileManager.default.fileExists(atPath: url.path), launchAgents.resolvingSymlinksInPath().path == launchAgents.path else {
            throw RunnerServiceError("The Forgejo service already exists or the LaunchAgents directory uses a symbolic link. No service was overwritten.")
        }
        let logs = runner.directory.appendingPathComponent("_diag", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var paths: [String] = []
        for name in ["runner.log", "error.log"] {
            let file = logs.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath().path == file.path else { throw RunnerServiceError("The Forgejo log path uses a symbolic link.") }
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600]) }
            paths.append(file.path)
        }
        let dictionary: [String: Any] = ["Label": label, "ProgramArguments": [executable.path, "daemon", "--config", configuration.path],
            "WorkingDirectory": runner.directory.path, "RunAtLoad": false, "ProcessType": "Interactive", "SessionCreate": true,
            "StandardOutPath": paths[0], "StandardErrorPath": paths[1],
            "EnvironmentVariables": ["PATH": SystemProcessExecutor.toolPath, "HOME": homeDirectory.path, "NO_COLOR": "1"]]
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        do { try Data(url.path.utf8).write(to: runner.directory.appendingPathComponent(".service"), options: .atomic) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        return try service(for: runner)
    }

    private func deleteForgejo(_ runner: InstalledRunner, trashFiles: Bool, force: Bool) async throws {
        guard FileManager.default.fileExists(atPath: runner.directory.appendingPathComponent(RunnerInstallationDescriptor.fileName).path) else {
            throw RunnerServiceError("Unregistering this imported Forgejo runner requires its non-secret numeric API registration ID and scope. Supply public registration metadata or remove the registration in Forgejo. The local service and files were preserved.")
        }
        try validateRunner(runner)
        try await requireIdle(runner, force: force)
        let installation = try RunnerInstallationDescriptor.load(from: runner.directory)
        guard let id = installation.agentID, id > 0, let remote = installation.remoteURL,
              let path = installation.registrationPath.flatMap({ try? ForgejoRegistrationLocation.validatedPath($0) }),
              var components = URLComponents(url: remote, resolvingAgainstBaseURL: false) else {
            throw RunnerServiceError("Automatic Forgejo removal needs the numeric runner ID and API scope from registration. Remove this registration on the server if it was connected manually; local files were preserved.")
        }
        components.path = ""
        guard let server = components.url else { throw RunnerServiceError("The Forgejo server URL is invalid.") }
        // Verify authorization before stopping a healthy service.
        _ = try await forgejoAPI.request(path: path + "/" + String(id), serverURL: server, method: "GET", body: nil)
        let descriptor = try optionalService(for: runner)
        let marker = runner.directory.appendingPathComponent(".service")
        let markerData = descriptor == nil ? nil : try Data(contentsOf: marker)
        try await stop(runner, force: force)
        do {
            if let descriptor { try FileManager.default.removeItem(at: descriptor.url) }
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            _ = try await forgejoAPI.request(path: path + "/" + String(id), serverURL: server, method: "DELETE", body: nil)
        } catch {
            if let descriptor, let data = try? PropertyListSerialization.data(fromPropertyList: descriptor.dictionary, format: .xml, options: 0) { try? data.write(to: descriptor.url, options: .atomic) }
            if let markerData { try? markerData.write(to: marker, options: .atomic) }
            throw Self.stoppedAfterFailedRemoval(error)
        }
        let metadata = runner.directory.appendingPathComponent(RunnerInstallationDescriptor.fileName)
        let retired = runner.directory.appendingPathComponent("runningman-runner.removed-" + UUID().uuidString + ".json")
        do { try FileManager.default.moveItem(at: metadata, to: retired) }
        catch { throw RunnerServiceError("The runner was removed from Forgejo, but its public local descriptor could not be retired. Files were preserved at \(runner.directory.path).") }
        forgejoStateCache.removeValue(forKey: runner.id)
        if trashFiles {
            #if os(macOS)
            var destination: NSURL?
            try FileManager.default.trashItem(at: runner.directory, resultingItemURL: &destination)
            #else
            throw RunnerServiceError("Runner unregistered; moving files to Trash is available on macOS only. Files were preserved.")
            #endif
        }
    }

    private func prepareStartupPolicy(_ enabled: Bool, service: inout ServiceDescriptor) throws -> URL? {
        guard !service.hasUncertainStartupPolicy else {
            throw RunnerServiceError("This service has complex KeepAlive conditions. RunningMan cannot safely infer or change its login startup policy; its existing policy was preserved.")
        }
        let previous = service.dictionary["KeepAlive"]
        let usesKeepAlive = (previous as? Bool == true) || ((previous as? [String: Any])?["SuccessfulExit"] is Bool)
        if !enabled && !usesKeepAlive { return nil }
        let policies = homeDirectory.appendingPathComponent("Library/Application Support/RunningMan/ServicePolicies", isDirectory: true)
        let backup = policies.appendingPathComponent(service.label + ".plist")
        if enabled && !FileManager.default.fileExists(atPath: backup.path) { return nil }
        guard policies.resolvingSymlinksInPath().path == policies.path else { throw RunnerServiceError("The startup-policy backup directory uses a symbolic link. The service was preserved.") }
        guard backup.resolvingSymlinksInPath().path == backup.path else { throw RunnerServiceError("The startup-policy backup uses a symbolic link. The service was preserved.") }
        if FileManager.default.fileExists(atPath: backup.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: backup.path)
            guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == userID,
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) < 128 * 1024 else { throw RunnerServiceError("The startup-policy backup cannot be verified. The service was preserved.") }
        }
        let identity = try Self.startupPolicyIdentity(service)
        if enabled {
            if FileManager.default.fileExists(atPath: backup.path) {
                let saved = try PropertyListSerialization.propertyList(from: Data(contentsOf: backup), format: nil) as? [String: Any]
                // Restore only our own unchanged off-state. An external edit wins.
                if saved?["Identity"] as? String == identity,
                   service.dictionary["RunAtLoad"] as? Bool == false,
                   service.dictionary["KeepAlive"] as? Bool == false,
                   let previous = saved?["KeepAlive"] {
                    service.dictionary["KeepAlive"] = previous
                }
                return backup
            }
            return nil
        }
        guard usesKeepAlive, let previous else { return nil }
        try FileManager.default.createDirectory(at: policies, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record: [String: Any] = ["Identity": identity, "ServiceLabel": service.label, "ServicePath": service.url.path, "KeepAlive": previous]
        let data = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
        try data.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        service.dictionary["KeepAlive"] = false
        return backup
    }
    private static func startupPolicyIdentity(_ service: ServiceDescriptor) throws -> String {
        var dictionary = service.dictionary
        dictionary.removeValue(forKey: "RunAtLoad"); dictionary.removeValue(forKey: "KeepAlive")
        guard JSONSerialization.isValidJSONObject(dictionary) else { throw RunnerServiceError("This service uses an extended plist format whose startup policy cannot be safely backed up.") }
        // Bind the non-secret backup to the selected service and every other plist
        // setting without copying environment values or other possible secrets.
        var data = Data((service.url.path + "\n" + service.label + "\n").utf8)
        data.append(try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True only when nothing exists at the path, not even a dangling symbolic link.
    private static func isMissing(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }
    private static func isSafeServiceLabel(_ label: String) -> Bool {
        label.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$"#, options: .regularExpression) != nil
    }
    private static func forgejoArgumentsMatch(_ arguments: [String], executable: URL, configuration: URL, workingDirectory: URL?) -> Bool {
        guard arguments.first == executable.path,
              let value = ForgejoDaemonCommand.parse(arguments: arguments) else { return false }
        let candidate: URL
        if value.hasPrefix("/") { candidate = URL(fileURLWithPath: value).standardizedFileURL }
        else if let workingDirectory { candidate = workingDirectory.appendingPathComponent(value).standardizedFileURL }
        else { return false }
        return candidate == configuration.standardizedFileURL
    }

    static func parseServices(_ text: String, including discoveredLabels: Set<String> = []) -> [String: Int32] {
        var result: [String: Int32] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, fields[2].hasPrefix("actions.runner.") || fields[2].hasPrefix("io.github.l-k-m.RunningMan.forgejo.") || discoveredLabels.contains(String(fields[2])) else { continue }
            result[String(fields[2])] = Int32(fields[0]) ?? 0
        }
        return result
    }
    static func parseDisabled(_ text: String) -> Set<String> {
        // Current macOS prints "disabled"/"enabled"; older releases print "true"/"false".
        let pattern = #"\"([^\"]+)\"\s*=>\s*(?:true|disabled)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return Set(expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }
}
