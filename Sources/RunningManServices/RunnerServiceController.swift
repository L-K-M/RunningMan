import Foundation
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
    var startsAtLogin: Bool { dictionary["RunAtLoad"] as? Bool ?? false }
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
        entries.first { $0.command.hasPrefix(runner.directory.path + "/bin/Runner.Listener ") || $0.command == runner.directory.path + "/bin/Runner.Listener" }?.pid
    }
    func isBusy(_ runner: InstalledRunner, servicePID: Int32?) -> Bool {
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
}

public actor RunnerServiceController {
    private let homeDirectory: URL
    private let executor: any ProcessExecuting
    private let githubCLIOverride: String?
    private let userID: UInt32
    private var domain: String { "gui/\(userID)" }
    private var launchAgents: URL { homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true) }

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL; self.executor = SystemProcessExecutor(); self.userID = getuid(); self.githubCLIOverride = nil
    }
    init(homeDirectory: URL, executor: any ProcessExecuting, userID: UInt32 = getuid(), githubCLIPath: String = "/usr/bin/gh") {
        self.homeDirectory = homeDirectory.standardizedFileURL; self.executor = executor; self.userID = userID; self.githubCLIOverride = githubCLIPath
    }

    public func snapshots(for runners: [InstalledRunner]) async -> [RunnerSnapshot] {
        guard !runners.isEmpty else { return [] }
        async let processes = try? executor.run(ProcessRequest(executable: "/bin/ps", arguments: ["-ww", "-axo", "pid=,ppid=,command="]))
        async let services = try? executor.run(ProcessRequest(executable: "/bin/launchctl", arguments: ["list"]))
        async let disabled = try? executor.run(ProcessRequest(executable: "/bin/launchctl", arguments: ["print-disabled", domain]))
        let (processResult, serviceResult, disabledResult) = await (processes, services, disabled)
        let processList = RunnerProcesses(processResult?.status == 0 ? processResult!.output : "")
        let loaded = Self.parseServices(serviceResult?.status == 0 ? serviceResult!.output : "")
        let disabledLabels = Self.parseDisabled(disabledResult?.status == 0 ? disabledResult!.output : "")
        return runners.map { runner in
            let descriptor = try? service(for: runner)
            let label = descriptor?.label ?? runner.serviceLabel
            let servicePID = label.flatMap { loaded[$0] }.flatMap { $0 > 0 ? $0 : nil }
            let pid = processList.pid(for: runner) ?? servicePID
            let enabled = !disabledLabels.contains(label ?? "")
            let busy = processList.isBusy(runner, servicePID: servicePID)
            let unavailable = processResult?.status != 0 || serviceResult?.status != 0 || disabledResult?.status != 0 || processResult?.truncated == true || serviceResult?.truncated == true || disabledResult?.truncated == true || processResult?.timedOut == true || serviceResult?.timedOut == true || disabledResult?.timedOut == true
            let status: RunnerStatus = busy ? .busy : unavailable ? .unknown : pid != nil ? .idle : !enabled ? .disabled : .stopped
            return RunnerSnapshot(runner: runner, status: status, processID: pid,
                                  startsAtLogin: descriptor?.startsAtLogin ?? false, isEnabled: enabled,
                                  detail: unavailable ? "Some local process or launch service information could not be read." : descriptor == nil ? "No validated login service is installed. Start installs one for your account." : nil)
        }
    }

    public func start(_ runner: InstalledRunner) async throws {
        try validateRunner(runner)
        let current = await snapshots(for: [runner]).first
        if current?.status.isRunning == true { return }
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
        if let descriptor = try optionalService(for: runner) {
            let target = domain + "/" + descriptor.label
            let state = try await executor.run(ProcessRequest(executable: "/bin/launchctl", arguments: ["print", target]))
            if state.status == 0 {
                _ = try await checked(executor, ProcessRequest(executable: "/bin/launchctl", arguments: ["bootout", target]), operation: "Stop runner")
            }
        }
        // A runner started manually in Terminal is not owned by launchd. Target only
        // the validated listener PID; never pkill a name shared by other runners.
        let processes = try await checked(executor, ProcessRequest(executable: "/bin/ps", arguments: ["-ww", "-axo", "pid=,ppid=,command="]), operation: "Inspect runner processes")
        if let pid = RunnerProcesses(processes.output).pid(for: runner) {
            _ = try await checked(executor, ProcessRequest(executable: "/bin/kill", arguments: ["-TERM", String(pid)]), operation: "Stop manually started runner")
        }
    }

    public func setEnabled(_ enabled: Bool, for runner: InstalledRunner, force: Bool = false) async throws {
        try validateRunner(runner)
        if !enabled { try await requireIdle(runner, force: force) }
        let descriptor = try await ensureService(for: runner)
        if !enabled { try await stop(runner, force: force) }
        _ = try await checked(executor, ProcessRequest(executable: "/bin/launchctl", arguments: [enabled ? "enable" : "disable", domain + "/" + descriptor.label]), operation: enabled ? "Enable runner" : "Disable runner")
    }

    public func setStartsAtLogin(_ enabled: Bool, for runner: InstalledRunner) async throws {
        try validateRunner(runner)
        var descriptor = try await ensureService(for: runner)
        descriptor.dictionary["RunAtLoad"] = enabled
        let data = try PropertyListSerialization.data(fromPropertyList: descriptor.dictionary, format: .xml, options: 0)
        try data.write(to: descriptor.url, options: .atomic)
        // launchd reads this plist on the next bootstrap/login. Do not restart a
        // live service merely because its next-login policy changed.
    }

    public func delete(_ runner: InstalledRunner, trashFiles: Bool = false, force: Bool = false) async throws {
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
            throw error
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

    private func requireIdle(_ runner: InstalledRunner, force: Bool) async throws {
        guard !force else { return }
        let state = await snapshots(for: [runner]).first
        guard state?.status != .busy else { throw RunnerServiceError("This runner is executing a job. Wait for it to finish or explicitly force the action.") }
        guard state?.status != .unknown else { throw RunnerServiceError("Cannot verify whether this runner is busy. No action was taken.") }
    }
    private func validateRunner(_ runner: InstalledRunner) throws {
        let root = runner.directory.standardizedFileURL
        guard root.isFileURL, root.path != "/", root.path != homeDirectory.path,
              root.resolvingSymlinksInPath().path == root.path else { throw RunnerServiceError("Runner directory must be a real, dedicated directory, not a symbolic link or your home directory.") }
        let info = try runnerMetadata(at: root)
        guard info["agentName"] as? String == runner.name,
              runner.agentID == nil || info["agentId"] as? Int == runner.agentID,
              runner.githubURL == nil || (info["gitHubUrl"] as? String).flatMap(URL.init(string:))?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == runner.githubURL?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { throw RunnerServiceError("Runner metadata has changed. Refresh before trying again.") }
        let script = root.appendingPathComponent("config.sh")
        guard FileManager.default.fileExists(atPath: script.path), !((try? script.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true) else { throw RunnerServiceError("Runner config.sh is missing or is a symbolic link.") }
    }
    private func optionalService(for runner: InstalledRunner) throws -> ServiceDescriptor? {
        let marker = runner.directory.appendingPathComponent(".service")
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        return try service(for: runner)
    }
    private func service(for runner: InstalledRunner) throws -> ServiceDescriptor {
        let path = try runnerText(runner.directory.appendingPathComponent(".service"))
        guard path.hasPrefix("/") else { throw RunnerServiceError("Runner .service must point to an absolute LaunchAgent plist path.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == launchAgents.path,
              url.resolvingSymlinksInPath().path == url.path,
              !((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? true) else {
            throw RunnerServiceError("This runner service is outside your LaunchAgents folder or uses a symbolic link. It will not be modified.")
        }
        let data = try Data(contentsOf: url)
        guard data.count < 1_000_000,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, label.hasPrefix("actions.runner."), !label.contains("/"),
              (plist["ProgramArguments"] as? [String])?.first == runner.directory.appendingPathComponent("runsvc.sh").path,
              plist["WorkingDirectory"] as? String == runner.directory.path else {
            throw RunnerServiceError("The runner LaunchAgent does not match this installation. It will not be modified.")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == userID else { throw RunnerServiceError("The runner LaunchAgent belongs to another account.") }
        return ServiceDescriptor(url: url, label: label, dictionary: plist)
    }
    private func ensureService(for runner: InstalledRunner) async throws -> ServiceDescriptor {
        if let service = try optionalService(for: runner) { return service }
        guard FileManager.default.fileExists(atPath: runner.directory.appendingPathComponent("svc.sh").path) else { throw RunnerServiceError("This runner installation has no svc.sh. Reinstall the official runner package.") }
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
    static func parseServices(_ text: String) -> [String: Int32] {
        var result: [String: Int32] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, fields[2].hasPrefix("actions.runner.") else { continue }
            result[String(fields[2])] = Int32(fields[0]) ?? 0
        }
        return result
    }
    static func parseDisabled(_ text: String) -> Set<String> {
        let pattern = #"\"([^\"]+)\"\s*=>\s*true"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return Set(expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }
}
