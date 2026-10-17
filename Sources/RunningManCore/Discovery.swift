import Foundation

/// Discovers only explicit installations, shallow home folders, user LaunchAgents and
/// Forgejo system LaunchDaemons that run as this user. It never executes a runner or
/// opens its credential files.
public actor RunnerDiscovery {
    public static let systemDaemonsDirectory = URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
    /// Standard home folders the shallow home scan never looks inside. Touching
    /// files in Desktop, Documents or Downloads makes macOS ask whether RunningMan
    /// may access that folder, and an ad-hoc signed build loses the grant with
    /// every update. The other folders do not hold runner installations. Imported
    /// folders and folders referenced by a service are still discovered.
    private static let skippedHomeFolders: Set<String> = ["Applications", "Desktop", "Documents", "Downloads",
        "Library", "Movies", "Music", "Pictures", "Public"]
    /// Bounds every folder listing so one crowded folder cannot stall a refresh.
    private static let listingLimit = 512
    private let homeDirectory: URL
    private let systemDaemonsDirectory: URL?
    private let userName: String
    private let fileManager = FileManager.default
    /// System services are opt-in, so a synthetic home directory never picks up
    /// the machine's real LaunchDaemons. The app passes `systemDaemonsDirectory`.
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                systemDaemonsDirectory: URL? = nil, userName: String = NSUserName()) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.systemDaemonsDirectory = systemDaemonsDirectory?.standardizedFileURL
        self.userName = userName
    }

    public func discover(additionalDirectories: [URL] = []) -> DiscoveryResult {
        var candidates = Set<URL>(additionalDirectories.map(\.standardizedFileURL))
        var warnings: [String] = []
        let rootFolders = [homeDirectory,
            homeDirectory.appendingPathComponent("actions-runners"),
            homeDirectory.appendingPathComponent("GitHubRunners"),
            homeDirectory.appendingPathComponent("Library/Application Support/RunningMan/Runners")]
        for root in rootFolders {
            candidates.insert(root)
            guard var children = try? fileManager.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            let isHome = root == homeDirectory
            if isHome { children.removeAll { Self.skippedHomeFolders.contains($0.lastPathComponent) } }
            for child in limitedListing(children, of: root, kind: .folders, warnings: &warnings) {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
                // isDirectory describes a link itself. Runner folders may link to
                // another volume; links directly in the home folder are not followed
                // because they often lead into cloud storage or protected folders.
                let isLinkedDirectory = !isHome && values.isSymbolicLink == true
                    && (try? child.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if values.isDirectory == true || isLinkedDirectory {
                    candidates.insert(child.standardizedFileURL)
                }
            }
        }
        let agents = homeDirectory.appendingPathComponent("Library/LaunchAgents")
        var labels: [URL: String] = [:]
        var forgejoServices: [URL: InstalledRunner] = [:]
        if let files = try? fileManager.contentsOfDirectory(at: agents,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for file in limitedListing(files.filter({ $0.pathExtension == "plist" }), of: agents, kind: .services, warnings: &warnings) {
                guard let plist = Self.plist(at: file), let label = plist["Label"] as? String else { continue }
                if let forgejo = Self.forgejoService(plist) {
                    candidates.insert(forgejo.directory)
                    forgejoServices[forgejo.directory] = forgejo
                    continue
                }
                guard label.hasPrefix("actions.runner.") else { continue }
                if let working = plist["WorkingDirectory"] as? String, working.hasPrefix("/") {
                    let directory = URL(fileURLWithPath: working).standardizedFileURL
                    candidates.insert(directory); labels[directory] = label
                }
                let arguments = (plist["ProgramArguments"] as? [String] ?? []) + [plist["Program"] as? String].compactMap { $0 }
                for argument in arguments where argument.hasPrefix("/") {
                    let executable = URL(fileURLWithPath: argument)
                    if ["runsvc.sh", "run.sh", "Runner.Listener"].contains(executable.lastPathComponent) {
                        var directory = executable.deletingLastPathComponent()
                        if directory.lastPathComponent == "bin" { directory.deleteLastPathComponent() }
                        directory = directory.standardizedFileURL
                        candidates.insert(directory); labels[directory] = label
                    }
                }
            }
        }
        // An administrator can install the Forgejo daemon as a system service that
        // runs as this user. RunningMan never changes system services, so a folder
        // a system service uses is monitored only, even with a user LaunchAgent or
        // a public descriptor: stopping either could interrupt the system daemon.
        var systemServices: [URL: InstalledRunner] = [:]
        if let systemDaemonsDirectory, let files = try? fileManager.contentsOfDirectory(at: systemDaemonsDirectory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for file in limitedListing(files.filter({ $0.pathExtension == "plist" }), of: systemDaemonsDirectory, kind: .services, warnings: &warnings) {
                guard let plist = Self.plist(at: file), plist["UserName"] as? String == userName,
                      var forgejo = Self.forgejoService(plist), systemServices[forgejo.directory] == nil else { continue }
                forgejo.serviceDomain = .system
                candidates.insert(forgejo.directory)
                systemServices[forgejo.directory] = forgejo
            }
        }
        var runners: [InstalledRunner] = []
        var resolved = Set<String>()
        for directory in candidates.sorted(by: { $0.path < $1.path }) {
            let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
            guard !resolved.contains(canonical.path) else { continue }
            let descriptorURL = canonical.appendingPathComponent(RunnerInstallationDescriptor.fileName)
            if fileManager.fileExists(atPath: descriptorURL.path) {
                do {
                    let descriptor = try RunnerInstallationDescriptor.load(from: canonical)
                    var runner = try descriptor.installedRunner(in: canonical)
                    if let system = systemServices[canonical] ?? systemServices[directory] {
                        // Keep public registration metadata, but follow the live daemon's logs too.
                        runner.serviceDomain = .system; runner.serviceLabel = system.serviceLabel
                        runner.diagnosticURLs = Array(Set(runner.diagnosticURLs + system.diagnosticURLs)).sorted { $0.path < $1.path }
                    }
                    runners.append(runner)
                    resolved.insert(canonical.path)
                } catch {
                    warnings.append("Could not read public runner metadata in \(directory.lastPathComponent): \(error.localizedDescription)")
                }
                continue
            }
            if let service = systemServices[canonical] ?? systemServices[directory] ?? forgejoServices[canonical] ?? forgejoServices[directory] {
                runners.append(service); resolved.insert(canonical.path); continue
            }
            // Forgejo's .runner contains persistent credentials. Classify native
            // installations before ever considering the GitHub metadata format.
            let forgejoExecutables = [canonical.appendingPathComponent("forgejo-runner"), canonical.appendingPathComponent("bin/forgejo-runner")]
            if forgejoExecutables.contains(where: { fileManager.fileExists(atPath: $0.path) }) {
                // A binary alone is not a registration. In particular, removal
                // preserves its files after retiring the public descriptor.
                continue
            }
            guard fileManager.fileExists(atPath: canonical.appendingPathComponent("bin/Runner.Listener").path)
                    || fileManager.fileExists(atPath: canonical.appendingPathComponent("bin/Runner.Listener.deps.json").path)
                    || fileManager.fileExists(atPath: canonical.appendingPathComponent("config.sh").path) else { continue }
            let metadataURL = canonical.appendingPathComponent(".runner")
            guard fileManager.fileExists(atPath: metadataURL.path) else { continue }
            resolved.insert(canonical.path)
            do {
                let data = try Self.smallData(at: metadataURL, limit: 128 * 1024)
                let json = try JSONSerialization.jsonObject(with: Self.removingBOM(data))
                guard let metadata = json as? [String: Any],
                      let name = metadata["agentName"] as? String, !name.isEmpty else {
                    throw DiscoveryError.invalidMetadata
                }
                var serviceLabel = labels[directory]
                let serviceURL = directory.appendingPathComponent(".service")
                if let serviceData = try? Self.smallData(at: serviceURL, limit: 16 * 1024),
                   let service = String(data: Self.removingBOM(serviceData), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !service.isEmpty {
                    if service.hasPrefix("/"), let plist = Self.plist(at: URL(fileURLWithPath: service)) {
                        serviceLabel = plist["Label"] as? String ?? serviceLabel
                    } else if service.hasPrefix("actions.runner."), !service.contains("/") {
                        serviceLabel = service
                    }
                }
                let labelValues = metadata["labels"] as? [Any] ?? []
                let runnerLabels = labelValues.compactMap { value -> String? in
                    (value as? String) ?? (value as? [String: Any])?["name"] as? String
                }
                let urlString = metadata["gitHubUrl"] as? String ?? metadata["githubUrl"] as? String
                let githubURL = urlString.flatMap(URL.init(string:)).flatMap { url -> URL? in
                    guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    components?.query = nil; components?.fragment = nil
                    return components?.url
                }
                runners.append(InstalledRunner(name: SecretRedactor.redact(name), directory: canonical,
                    githubURL: githubURL, agentID: metadata["agentId"] as? Int,
                    serviceLabel: serviceLabel, version: metadata["agentVersion"] as? String ?? Self.installedVersion(at: canonical),
                    labels: runnerLabels.map(SecretRedactor.redact),
                    workDirectoryURL: Self.workDirectory(metadata["workFolder"] as? String, in: canonical)))
            } catch {
                warnings.append("Could not read runner settings in \(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return DiscoveryResult(runners: runners.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, warnings: warnings)
    }

    /// Returns at most `listingLimit` entries in name order, so the inspected subset
    /// stays the same between refreshes, and warns when the folder holds more.
    private enum ListingKind { case folders, services }
    private func limitedListing(_ entries: [URL], of folder: URL, kind: ListingKind, warnings: inout [String]) -> ArraySlice<URL> {
        if entries.count > Self.listingLimit {
            let remedy = kind == .folders ? "Use Import existing runner for any runner that does not appear." : "Services listed after those were not checked."
            warnings.append("Discovery inspected only the first \(Self.listingLimit) entries in \(displayName(of: folder)). \(remedy)")
        }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(Self.listingLimit)
    }

    /// Names a folder in a warning without exposing the account's home path.
    private func displayName(of folder: URL) -> String {
        let home = homeDirectory.path, path = folder.standardizedFileURL.path
        if path == home { return "your home folder" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func workDirectory(_ value: String?, in directory: URL) -> URL {
        let folder = value.flatMap { !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") && $0.utf8.count < 4096 ? $0 : nil } ?? "_work"
        return (folder.hasPrefix("/") ? URL(fileURLWithPath: folder) : directory.appendingPathComponent(folder)).standardizedFileURL
    }

    private static func forgejoService(_ plist: [String: Any]) -> InstalledRunner? {
        guard let label = plist["Label"] as? String,
              let arguments = plist["ProgramArguments"] as? [String], let first = arguments.first,
              first.hasPrefix("/"), let configPath = ForgejoDaemonCommand.parse(arguments: arguments) else { return nil }
        let executable = URL(fileURLWithPath: first).standardizedFileURL
        let name = executable.lastPathComponent.lowercased()
        guard name == "forgejo-runner" || name.range(of: #"^forgejo-runner[-_.][a-z0-9.-]+$"#, options: .regularExpression) != nil else { return nil }
        let working = (plist["WorkingDirectory"] as? String).flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        let config: URL?
        if configPath.hasPrefix("/") { config = URL(fileURLWithPath: configPath).standardizedFileURL }
        else { config = working?.appendingPathComponent(configPath).standardizedFileURL }
        let directory = (working ?? config?.deletingLastPathComponent() ?? executable.deletingLastPathComponent()).resolvingSymlinksInPath().standardizedFileURL
        let diagnosticURLs = ["StandardOutPath", "StandardErrorPath"].compactMap { plist[$0] as? String }.compactMap { value -> URL? in
            guard value.hasPrefix("/"), URL(fileURLWithPath: value).pathExtension.lowercased() == "log" else { return nil }
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        return InstalledRunner(name: directory.lastPathComponent, directory: directory,
            serviceLabel: label, provider: .forgejo, executableURL: executable,
            configurationURL: config, diagnosticURLs: Array(Set(diagnosticURLs)))
    }

    private static func installedVersion(at directory: URL) -> String? {
        // The shipped dependency manifest records the package version without executing its binary.
        guard let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent("bin/Runner.Listener.deps.json")) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8 * 1024),
              let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #"Runner\.Listener/([0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?)"#, options: .regularExpression) else { return nil }
        return String(text[range]).components(separatedBy: "/").last
    }

    private enum DiscoveryError: LocalizedError {
        case invalidMetadata, oversized
        var errorDescription: String? {
            switch self {
            case .invalidMetadata: return "The .runner file is not valid runner metadata."
            case .oversized: return "The settings file exceeds the safe size limit."
            }
        }
    }
    static func removingBOM(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
    }
    static func smallData(at url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw DiscoveryError.oversized }
        return data
    }
    private static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? smallData(at: url, limit: 256 * 1024) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
