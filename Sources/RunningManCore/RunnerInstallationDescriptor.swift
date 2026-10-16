import Foundation

/// Public installation metadata only. Forgejo registration files and YAML configuration
/// contain persistent credentials, so discovery never opens either of those files.
public struct RunnerInstallationDescriptor: Codable, Sendable {
    public static let fileName = "runningman-runner.json"
    public var schemaVersion: Int
    public var provider: RunnerProvider
    public var name: String
    public var remoteURL: URL?
    public var agentID: Int?
    public var serviceLabel: String?
    public var version: String?
    public var labels: [String]
    public var capacity: Int
    public var executablePath: String
    public var configurationPath: String?
    public var diagnosticPaths: [String]
    public var registrationPath: String?

    public init(schemaVersion: Int = 1, provider: RunnerProvider, name: String, remoteURL: URL? = nil,
                agentID: Int? = nil, serviceLabel: String? = nil, version: String? = nil,
                labels: [String] = [], capacity: Int = 1, executablePath: String,
                configurationPath: String? = nil, diagnosticPaths: [String] = [], registrationPath: String? = nil) {
        self.schemaVersion = schemaVersion; self.provider = provider; self.name = name; self.remoteURL = remoteURL
        self.agentID = agentID; self.serviceLabel = serviceLabel; self.version = version
        self.labels = labels; self.capacity = capacity; self.executablePath = executablePath
        self.configurationPath = configurationPath; self.diagnosticPaths = diagnosticPaths; self.registrationPath = registrationPath
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, provider, name, remoteURL, agentID, serviceLabel, version, labels
        case capacity, executablePath, configurationPath, diagnosticPaths, registrationPath
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            provider: try values.decode(RunnerProvider.self, forKey: .provider),
            name: try values.decode(String.self, forKey: .name), remoteURL: try values.decodeIfPresent(URL.self, forKey: .remoteURL),
            agentID: try values.decodeIfPresent(Int.self, forKey: .agentID), serviceLabel: try values.decodeIfPresent(String.self, forKey: .serviceLabel),
            version: try values.decodeIfPresent(String.self, forKey: .version), labels: try values.decodeIfPresent([String].self, forKey: .labels) ?? [],
            capacity: try values.decodeIfPresent(Int.self, forKey: .capacity) ?? 1,
            executablePath: try values.decode(String.self, forKey: .executablePath),
            configurationPath: try values.decodeIfPresent(String.self, forKey: .configurationPath),
            diagnosticPaths: try values.decodeIfPresent([String].self, forKey: .diagnosticPaths) ?? [],
            registrationPath: try values.decodeIfPresent(String.self, forKey: .registrationPath))
    }

    public static func load(from directory: URL) throws -> Self {
        let file = directory.appendingPathComponent(fileName)
        guard (try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isSymbolicLink != true else {
            throw DescriptorError.invalid("The public runner descriptor must not be a symbolic link.")
        }
        let data = try RunnerDiscovery.smallData(at: file, limit: 128 * 1024)
        let descriptor = try JSONDecoder().decode(Self.self, from: RunnerDiscovery.removingBOM(data))
        try descriptor.validate()
        return descriptor
    }

    public func write(to directory: URL) throws {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 128 * 1024 else { throw DescriptorError.invalid("The public runner descriptor is too large.") }
        let file = directory.appendingPathComponent(Self.fileName)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func installedRunner(in directory: URL) throws -> InstalledRunner {
        try validate()
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        return InstalledRunner(name: SecretRedactor.redact(name), directory: root,
            githubURL: remoteURL, agentID: agentID, serviceLabel: serviceLabel, version: version,
            labels: labels.map(SecretRedactor.redact), provider: provider,
            executableURL: Self.resolve(executablePath, in: root),
            configurationURL: configurationPath.map { Self.resolve($0, in: root) },
            diagnosticURLs: diagnosticPaths.map { Self.resolve($0, in: root) }, capacity: capacity)
    }

    private func validate() throws {
        guard schemaVersion == 1, !name.isEmpty, name.utf8.count <= 1024,
              (1...256).contains(capacity), labels.count <= 100,
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }), diagnosticPaths.count <= 8 else {
            throw DescriptorError.invalid("The public runner descriptor has unsupported or invalid metadata.")
        }
        if let remoteURL {
            guard remoteURL.scheme == "https", remoteURL.host != nil, remoteURL.user == nil,
                  remoteURL.password == nil, remoteURL.query == nil, remoteURL.fragment == nil else {
                throw DescriptorError.invalid("The runner server URL must be HTTPS without credentials, a query or a fragment.")
            }
        }
        for path in [executablePath] + [configurationPath].compactMap({ $0 }) + diagnosticPaths {
            guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"),
                  !path.split(separator: "/").contains("..") else {
                throw DescriptorError.invalid("The public runner descriptor contains an invalid path.")
            }
        }
        guard diagnosticPaths.allSatisfy({ URL(fileURLWithPath: $0).pathExtension.lowercased() == "log" }) else {
            throw DescriptorError.invalid("Runner diagnostics must point to log files, never credential or configuration files.")
        }
    }
    private static func resolve(_ path: String, in root: URL) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
    }
    private enum DescriptorError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let value) = self { return value }; return nil }
    }
}
