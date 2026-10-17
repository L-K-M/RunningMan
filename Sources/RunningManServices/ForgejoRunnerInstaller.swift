import Foundation
import RunningManCore

public enum ForgejoRunnerScope: String, Codable, CaseIterable, Sendable {
    case repository, organization, user, instance
}

public struct CreateForgejoRunnerRequest: Sendable {
    public var serverURL: URL
    public var scope: ForgejoRunnerScope
    public var scopeName: String
    public var name: String
    public var labels: [String]
    public var directory: URL
    public var capacity: Int
    public var startsAtLogin: Bool
    public var startImmediately: Bool
    public var registrationUUID: String?
    public var registrationToken: String?
    public var registrationID: Int?
    public init(serverURL: URL, scope: ForgejoRunnerScope = .repository, scopeName: String = "",
                name: String, labels: [String], directory: URL, capacity: Int = 1,
                startsAtLogin: Bool = true, startImmediately: Bool = true,
                registrationUUID: String? = nil, registrationToken: String? = nil, registrationID: Int? = nil) {
        self.serverURL = serverURL; self.scope = scope; self.scopeName = scopeName
        self.name = name; self.labels = labels; self.directory = directory; self.capacity = capacity
        self.startsAtLogin = startsAtLogin; self.startImmediately = startImmediately
        self.registrationUUID = registrationUUID; self.registrationToken = registrationToken; self.registrationID = registrationID
    }
}

struct ForgejoRegistrationDetails: Decodable, Sendable {
    var id: Int?
    var uuid: String
    var token: String
    func validated() throws -> Self {
        guard UUID(uuidString: uuid) != nil, !token.isEmpty, token.count <= 4096,
              token.range(of: #"^[a-zA-Z0-9]+$"#, options: .regularExpression) != nil,
              id == nil || id! > 0 else { throw RunnerServiceError("Forgejo did not provide a valid runner UUID, connection token and identifier.") }
        return self
    }
}

struct ForgejoRegistrationLocation: Sendable {
    var serverURL: URL
    var remoteURL: URL
    var path: String
    init(serverURL: URL, scope: ForgejoRunnerScope, scopeName: String) throws {
        self.serverURL = try ForgejoConnectionStore.origin(for: serverURL)
        guard serverURL.path.isEmpty || serverURL.path == "/" else { throw RunnerServiceError("Enter the Forgejo server origin, without a repository or settings path.") }
        let pieces = scopeName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        func valid(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 100 && value != "." && value != ".." && value.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        }
        switch scope {
        case .repository:
            guard pieces.count == 2, pieces.allSatisfy(valid) else { throw RunnerServiceError("Enter the repository scope as owner/repository.") }
            path = "/repos/" + pieces.joined(separator: "/") + "/actions/runners"
            remoteURL = self.serverURL.appendingPathComponent(pieces.joined(separator: "/"))
        case .organization:
            guard pieces.count == 1, pieces.allSatisfy(valid) else { throw RunnerServiceError("Enter a single organization name.") }
            path = "/orgs/" + scopeName + "/actions/runners"
            remoteURL = self.serverURL.appendingPathComponent(scopeName)
        case .user:
            guard scopeName.isEmpty else { throw RunnerServiceError("User scope uses the signed-in account; leave the scope name empty.") }
            path = "/user/actions/runners"; remoteURL = self.serverURL
        case .instance:
            guard scopeName.isEmpty else { throw RunnerServiceError("Instance scope does not take a scope name.") }
            path = "/admin/actions/runners"; remoteURL = self.serverURL
        }
    }
    static func validatedPath(_ path: String) throws -> String {
        let patterns = [#"^/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runners$"#,
                        #"^/orgs/[A-Za-z0-9_.-]+/actions/runners$"#,
                        #"^/(user|admin)/actions/runners$"#]
        guard !path.split(separator: "/").contains(".."), patterns.contains(where: { path.range(of: $0, options: .regularExpression) != nil }) else {
            throw RunnerServiceError("This Forgejo installation has no valid registration scope. Its files were preserved.")
        }
        return path
    }
}

public actor ForgejoRunnerInstaller {
    private let homeDirectory: URL
    private let executor: any ProcessExecuting
    private let api: any ForgejoAPIRequesting
    /// Builds the one-shot client that tries a typed token without saving it.
    private let candidateAPI: @Sendable (any ForgejoTokenProviding) -> any ForgejoAPIRequesting
    private let brewOverride: String?
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                api: any ForgejoAPIRequesting = ForgejoAPIClient()) {
        self.homeDirectory = homeDirectory.standardizedFileURL; self.executor = SystemProcessExecutor()
        self.api = api; self.candidateAPI = { ForgejoAPIClient(tokens: $0) }; self.brewOverride = nil
    }
    init(homeDirectory: URL, executor: any ProcessExecuting, api: any ForgejoAPIRequesting, brewPath: String = "/opt/homebrew/bin/brew",
         candidateAPI: @escaping @Sendable (any ForgejoTokenProviding) -> any ForgejoAPIRequesting = { ForgejoAPIClient(tokens: $0) }) {
        self.homeDirectory = homeDirectory.standardizedFileURL; self.executor = executor; self.api = api
        self.candidateAPI = candidateAPI; self.brewOverride = brewPath
    }
    public func account(serverURL: URL) async throws -> String {
        try Self.login(from: await api.request(path: "/user", serverURL: serverURL, method: "GET", body: nil))
    }
    /// Returns the signed-in account. An empty `candidateToken` checks the saved
    /// connection. A typed token is verified with a one-shot client and saved only
    /// after Forgejo accepts it, so a typo or under-scoped token never replaces a
    /// working one or stays behind for a server that was never added.
    public func connect(serverURL: URL, candidateToken: String, savingTo store: any ForgejoTokenSaving) async throws -> String {
        guard !candidateToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return try await account(serverURL: serverURL) }
        let origin = try ForgejoConnectionStore.origin(for: serverURL)
        let token = try ForgejoConnectionStore.validatedToken(candidateToken)
        let login = try await account(serverURL: origin, candidateToken: token)
        try await store.setToken(token, for: origin)
        return login
    }
    private func account(serverURL origin: URL, candidateToken token: String) async throws -> String {
        let candidate = candidateAPI(EphemeralForgejoToken(origin: origin, token: token))
        return try Self.login(from: await candidate.request(path: "/user", serverURL: origin, method: "GET", body: nil))
    }
    private static func login(from data: Data) throws -> String {
        struct User: Decodable { var login: String }
        return SecretRedactor.redact(try JSONDecoder().decode(User.self, from: data).login)
    }
    public func create(_ request: CreateForgejoRunnerRequest, progress: @escaping @Sendable (String) -> Void) async throws -> InstalledRunner {
        let location = try ForgejoRegistrationLocation(serverURL: request.serverURL, scope: request.scope, scopeName: request.scopeName)
        guard request.name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil,
              (1...256).contains(request.capacity) else { throw RunnerServiceError("Choose a runner name of 1–64 letters, numbers, dots, underscores or hyphens, and a capacity from 1 to 256.") }
        let labels = try Self.hostLabels(request.labels)
        let destination = request.directory.standardizedFileURL
        try validateDestination(destination)
        let manual: ForgejoRegistrationDetails?
        if request.registrationUUID != nil || request.registrationToken != nil {
            guard let uuid = request.registrationUUID, let token = request.registrationToken else { throw RunnerServiceError("Manual setup requires both the runner UUID and connection token shown by Forgejo.") }
            manual = try ForgejoRegistrationDetails(id: request.registrationID, uuid: uuid, token: token).validated()
        } else { manual = nil }

        let brew = try brewOverride ?? Self.homebrewExecutable()
        let environment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
        progress("Installing the checksummed Homebrew Forgejo runner package…")
        // Official Forgejo releases do not provide a macOS binary. Homebrew core
        // verifies its source/bottle checksums and supplies a native Mac build.
        _ = try await checked(executor, ProcessRequest(executable: brew, arguments: ["install", "homebrew/core/forgejo-runner"], environment: environment, timeout: 600), operation: "Install native Forgejo runner")
        let prefix = try await checked(executor, ProcessRequest(executable: brew, arguments: ["--prefix", "homebrew/core/forgejo-runner"], environment: environment, timeout: 30), operation: "Locate Forgejo runner package")
        let prefixPath = prefix.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefixPath.hasPrefix("/"), !prefixPath.contains("\n") else { throw RunnerServiceError("Homebrew returned an invalid Forgejo runner path.") }
        let source = URL(fileURLWithPath: prefixPath).appendingPathComponent("bin/forgejo-runner").resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: source.path) else { throw RunnerServiceError("Homebrew did not install an executable Forgejo runner.") }
        let versionResult = try await checked(executor, ProcessRequest(executable: source.path, arguments: ["--version"], timeout: 15), operation: "Check Forgejo runner version")
        let version = try Self.supportedVersion(versionResult.output)
        try validateDestination(destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        let executable = destination.appendingPathComponent("forgejo-runner")
        let configuration = destination.appendingPathComponent("config.yaml")
        let diagnostics = destination.appendingPathComponent("_diag", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("_work"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let label = ManagedServiceLabel.forgejoNew + UUID().uuidString.lowercased()
        var registration: ForgejoRegistrationDetails?
        do {
            if let manual { registration = manual }
            else {
                progress("Registering the Forgejo runner with the selected scope…")
                let body = try JSONSerialization.data(withJSONObject: ["name": request.name, "description": "Native macOS runner managed by RunningMan", "ephemeral": false])
                let response = try await api.request(path: location.path, serverURL: location.serverURL, method: "POST", body: body)
                registration = try JSONDecoder().decode(ForgejoRegistrationDetails.self, from: response).validated()
            }
            guard let registration else { throw RunnerServiceError("Forgejo registration did not complete.") }
            let tokenFile = destination.appendingPathComponent("connection-token")
            try Self.writePrivate(Data(registration.token.utf8), to: tokenFile)
            let yaml = try Self.configuration(serverURL: location.serverURL, uuid: registration.uuid, tokenURL: tokenFile, labels: labels, capacity: request.capacity, directory: destination)
            try Self.writePrivate(Data(yaml.utf8), to: configuration)
            let descriptor = RunnerInstallationDescriptor(provider: .forgejo, name: request.name, remoteURL: location.remoteURL,
                agentID: registration.id, serviceLabel: label, version: version, labels: labels.map { String($0.dropLast(5)) },
                capacity: request.capacity, executablePath: "forgejo-runner", configurationPath: "config.yaml",
                diagnosticPaths: ["_diag/runner.log", "_diag/error.log"], registrationPath: location.path)
            try descriptor.write(to: destination)
            let runner = try descriptor.installedRunner(in: destination)
            let controller = RunnerServiceController(homeDirectory: homeDirectory, executor: executor, forgejoAPI: api)
            progress("Installing a private service for your macOS account…")
            try await controller.setStartsAtLogin(request.startsAtLogin, for: runner)
            try await controller.setEnabled(true, for: runner)
            if request.startImmediately { try await controller.start(runner) }
            progress("Forgejo runner created at \(destination.path).")
            return runner
        } catch {
            // A remote registration can already exist. Keep credential and public
            // metadata evidence instead of silently removing the installation.
            throw RunnerServiceError("Forgejo setup did not finish. Files were preserved at \(destination.path). If registration completed, check the server’s runners page and import this installation to inspect it. \(error.localizedDescription)")
        }
    }

    private func validateDestination(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix(homeDirectory.path + "/"), !FileManager.default.fileExists(atPath: url.path),
              url.resolvingSymlinksInPath().path == url.path, !url.pathComponents.contains(".git"), !url.pathComponents.contains(".ssh") else {
            throw RunnerServiceError("Choose a new dedicated directory inside your home folder, without symbolic links. Existing installations are never overwritten.")
        }
    }
    static func homebrewExecutable() throws -> String {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] where FileManager.default.isExecutableFile(atPath: path) { return path }
        throw RunnerServiceError("Install Homebrew from brew.sh before creating a native Forgejo runner. Existing runners can still be managed.")
    }
    static func supportedVersion(_ output: String) throws -> String {
        let regex = try NSRegularExpression(pattern: #"(?:version\s+v?|^v?)(\d+)\.(\d+)\.(\d+)"#)
        let text = output as NSString
        guard let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: text.length)),
              let major = Int(text.substring(with: match.range(at: 1))), let minor = Int(text.substring(with: match.range(at: 2))),
              major > 13 || (major == 13 && minor >= 2) else { throw RunnerServiceError("Forgejo Runner 13.2 or later is required. Update the Homebrew forgejo-runner package before retrying.") }
        return text.substring(with: match.range(at: 0)).replacingOccurrences(of: "version ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func hostLabels(_ labels: [String]) throws -> [String] {
        let labels = labels.isEmpty ? ["self-hosted", "macos"] : labels
        guard labels.count <= 100 else { throw RunnerServiceError("Use at most 100 runner labels.") }
        return try labels.map { label in
            let bare = label.hasSuffix(":host") ? String(label.dropLast(5)) : label
            guard bare.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,255}$"#, options: .regularExpression) != nil else {
                throw RunnerServiceError("Native Mac runner labels must use letters, numbers, dots, underscores or hyphens, optionally followed by :host.")
            }
            return bare + ":host"
        }
    }
    static func configuration(serverURL: URL, uuid: String, tokenURL: URL, labels: [String], capacity: Int, directory: URL) throws -> String {
        func quote(_ string: String) throws -> String { String(decoding: try JSONEncoder().encode(string), as: UTF8.self) }
        let labelValues = try labels.map(quote).joined(separator: ", ")
        return """
        log:
          level: info
          job_level: info
        runner:
          capacity: \(capacity)
          labels: [\(labelValues)]
          insecure: false
          env_file: ""
          shutdown_timeout: 0s
        cache:
          enabled: false
        host:
          workdir_parent: \(try quote(directory.appendingPathComponent("_work").path))
        server:
          connections:
            runningman:
              url: \(try quote(serverURL.absoluteString))
              uuid: \(try quote(uuid))
              token_url: \(try quote("file:" + tokenURL.path))
        """ + "\n"
    }
    private static func writePrivate(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw RunnerServiceError("Could not create the runner’s private configuration.") }
    }
}
