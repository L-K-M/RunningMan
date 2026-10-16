import Foundation

/// Discovers only explicit installations, shallow home folders, and user LaunchAgents.
/// It never executes a runner or opens its credential files.
public actor RunnerDiscovery {
    private let homeDirectory: URL
    private let fileManager = FileManager.default
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
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
            guard let children = try? fileManager.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for child in children.prefix(512) {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    candidates.insert(child.standardizedFileURL)
                }
            }
        }
        let agents = homeDirectory.appendingPathComponent("Library/LaunchAgents")
        var labels: [URL: String] = [:]
        if let files = try? fileManager.contentsOfDirectory(at: agents,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for file in files.filter({ $0.pathExtension == "plist" }).prefix(512) {
                guard let plist = Self.plist(at: file),
                      let label = plist["Label"] as? String,
                      label.hasPrefix("actions.runner.") else { continue }
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
        var runners: [InstalledRunner] = []
        var resolved = Set<String>()
        for directory in candidates.sorted(by: { $0.path < $1.path }) {
            let metadataURL = directory.appendingPathComponent(".runner")
            guard fileManager.fileExists(atPath: metadataURL.path) else { continue }
            let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.insert(canonical.path).inserted else { continue }
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
                    labels: runnerLabels.map(SecretRedactor.redact)))
            } catch {
                warnings.append("Could not read runner settings in \(directory.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return DiscoveryResult(runners: runners.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, warnings: warnings)
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
