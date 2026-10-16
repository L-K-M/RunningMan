import Foundation
import CryptoKit
import RunningManCore

public struct CreateRunnerRequest: Sendable {
    public var githubURL: URL
    public var name: String
    public var labels: [String]
    public var directory: URL
    public var startsAtLogin: Bool
    public var startImmediately: Bool
    public init(githubURL: URL, name: String, labels: [String], directory: URL,
                startsAtLogin: Bool = true, startImmediately: Bool = true) {
        self.githubURL = githubURL; self.name = name; self.labels = labels; self.directory = directory
        self.startsAtLogin = startsAtLogin; self.startImmediately = startImmediately
    }
}

struct GitHubRunnerScope: Sendable {
    var url: URL
    var apiPrefix: String
    init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host?.lowercased() == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              !components.percentEncodedPath.contains("%") else {
            throw RunnerServiceError("Enter a GitHub.com repository or organization URL, such as https://github.com/owner/repository.")
        }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }),
              !components.path.contains("//"), !parts[0].contains("."), !parts[0].contains("_"),
              parts[0].count <= 39, !parts[0].hasPrefix("-"), !parts[0].hasSuffix("-") else {
            throw RunnerServiceError("Use an exact GitHub organization or owner/repository URL, without a settings page or other suffix.")
        }
        self.url = URL(string: "https://github.com/" + parts.joined(separator: "/"))!
        self.apiPrefix = (parts.count == 1 ? "orgs/" : "repos/") + parts.joined(separator: "/") + "/actions/runners"
    }
}

struct OfficialRunnerAsset: Decodable {
    var name: String
    var browser_download_url: String
    var digest: String?
}
struct OfficialRunnerRelease: Decodable {
    var tag_name: String
    var assets: [OfficialRunnerAsset]
}

public actor GitHubRunnerInstaller {
    private let homeDirectory: URL
    private let executor: any ProcessExecuting
    private let githubCLIOverride: String?
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL; self.executor = SystemProcessExecutor(); self.githubCLIOverride = nil
    }
    init(homeDirectory: URL, executor: any ProcessExecuting, githubCLIPath: String = "/usr/bin/gh") { self.homeDirectory = homeDirectory.standardizedFileURL; self.executor = executor; self.githubCLIOverride = githubCLIPath }

    public func account() async throws -> String {
        let result = try await checked(executor, ProcessRequest(executable: try githubCLIOverride ?? githubCLI(), arguments: ["api", "--hostname", "github.com", "user", "--jq", ".login"], timeout: 35), operation: "Check GitHub sign-in")
        let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, !name.contains("\n") else { throw RunnerServiceError("GitHub did not return an account name.") }
        return name
    }

    public func create(_ request: CreateRunnerRequest, progress: @escaping @Sendable (String) -> Void) async throws -> InstalledRunner {
        let scope = try GitHubRunnerScope(url: request.githubURL)
        try Self.validateNameAndLabels(request)
        let destination = request.directory.standardizedFileURL
        try validateDestination(destination)
        let gh = try githubCLIOverride ?? githubCLI()
        progress("Checking the official GitHub Actions runner release…")
        let response = try await checked(executor, ProcessRequest(executable: gh, arguments: ["api", "--hostname", "github.com", "repos/actions/runner/releases/latest"], timeout: 35), operation: "Find official runner download")
        let release = try JSONDecoder().decode(OfficialRunnerRelease.self, from: Data(response.output.utf8))
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        let asset = try Self.validatedAsset(release, architecture: architecture)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("runningman-download-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("runner.tar.gz")
        progress("Downloading \(asset.name)…")
        _ = try await checked(executor, ProcessRequest(executable: "/usr/bin/curl", arguments: ["--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "15", "--max-time", "300", "--retry", "2", "--output", archive.path, asset.browser_download_url], timeout: 330), operation: "Download official runner")
        progress("Verifying SHA-256 and archive paths…")
        try Self.verifySHA256(file: archive, digest: asset.digest!)
        let names = try await checked(executor, ProcessRequest(executable: "/usr/bin/tar", arguments: ["-tzf", archive.path], timeout: 60, outputLimit: 8_000_000), operation: "Inspect runner archive")
        let listing = try await checked(executor, ProcessRequest(executable: "/usr/bin/tar", arguments: ["-tvzf", archive.path], timeout: 60, outputLimit: 10_000_000), operation: "Inspect runner archive links")
        try Self.validateArchive(names: names.output, verbose: listing.output)
        let extracted = temporary.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try await checked(executor, ProcessRequest(executable: "/usr/bin/tar", arguments: ["--no-same-owner", "-xzf", archive.path, "-C", extracted.path], timeout: 90), operation: "Extract verified runner")
        for file in ["config.sh", "env.sh", "svc.sh", "bin/Runner.Listener"] {
            guard FileManager.default.fileExists(atPath: extracted.appendingPathComponent(file).path) else { throw RunnerServiceError("The official runner archive is incomplete: \(file).") }
        }
        // Revalidate after the download, before publishing anything into the chosen location.
        try validateDestination(destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: extracted, to: destination)
        let ownership = "RunningMan installation\n" + UUID().uuidString + "\n"
        try Data(ownership.utf8).write(to: destination.appendingPathComponent(".runningman-owned"), options: .atomic)
        do {
            progress("Requesting short-lived registration permission from GitHub…")
            let tokenResponse = try await checked(executor, ProcessRequest(executable: gh, arguments: ["api", "--hostname", "github.com", "--method", "POST", scope.apiPrefix + "/registration-token"], timeout: 35), operation: "Request runner registration permission")
            let token = try Self.decodeToken(tokenResponse.output)
            progress("Registering \(request.name) with GitHub…")
            var arguments = [destination.appendingPathComponent("config.sh").path, "--unattended", "--url", scope.url.absoluteString, "--name", request.name, "--work", "_work"]
            if !request.labels.isEmpty { arguments += ["--labels", request.labels.joined(separator: ",")] }
            _ = try await checked(executor, ProcessRequest(executable: "/bin/bash", arguments: arguments, directory: destination,
                environment: ["ACTIONS_RUNNER_INPUT_TOKEN": token], timeout: 150, secrets: [token]), operation: "Register GitHub runner")
            let metadata = try runnerMetadata(at: destination)
            var runner = InstalledRunner(name: metadata["agentName"] as? String ?? request.name, directory: destination,
                                         githubURL: scope.url, agentID: metadata["agentId"] as? Int,
                                         version: String(release.tag_name.dropFirst()), labels: request.labels)
            progress("Installing the runner service for your macOS account…")
            _ = try await checked(executor, ProcessRequest(executable: "/bin/bash", arguments: [destination.appendingPathComponent("env.sh").path], directory: destination), operation: "Capture runner tool environment")
            _ = try await checked(executor, ProcessRequest(executable: "/bin/bash", arguments: [destination.appendingPathComponent("svc.sh").path, "install"], directory: destination), operation: "Install runner login service")
            let path = try runnerText(destination.appendingPathComponent(".service"))
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { runner.serviceLabel = plist["Label"] as? String }
            let controller = RunnerServiceController(homeDirectory: homeDirectory, executor: executor)
            try await controller.setStartsAtLogin(request.startsAtLogin, for: runner)
            try await controller.setEnabled(true, for: runner)
            if request.startImmediately {
                progress("Starting the runner…")
                try await controller.start(runner)
            }
            progress("Runner created. Its files are in \(destination.path).")
            return runner
        } catch {
            // Registration may already have succeeded remotely. Preserve the installation
            // and its diagnostics; never silently orphan it with recursive cleanup.
            throw RunnerServiceError("Setup did not finish. Files were preserved at \(destination.path). If registration completed, import that folder to inspect or remove the runner. If no runner was registered, move the incomplete folder to Trash before retrying. \(error.localizedDescription)")
        }
    }

    static func decodeToken(_ json: String) throws -> String {
        guard let data = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = value["token"] as? String, !token.isEmpty, token.count < 4096,
              token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else {
            throw RunnerServiceError("GitHub did not return a valid short-lived runner token. Check your repository or organization admin permissions.")
        }
        return token
    }
    static func validateNameAndLabels(_ request: CreateRunnerRequest) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !request.name.isEmpty, request.name.count <= 64, request.name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RunnerServiceError("Runner names must use 1–64 letters, numbers, dots, underscores, or hyphens.")
        }
        guard request.labels.count <= 100, request.labels.allSatisfy({ !$0.isEmpty && $0.count <= 256 && !$0.contains(",") && !$0.contains("\n") && !$0.contains("\r") }) else {
            throw RunnerServiceError("Use at most 100 nonempty labels without commas or newlines.")
        }
    }
    private func validateDestination(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix(homeDirectory.path + "/"),
              !FileManager.default.fileExists(atPath: url.path),
              url.resolvingSymlinksInPath().path == url.path,
              !url.pathComponents.contains(".git"), !url.pathComponents.contains(".ssh"),
              url.lastPathComponent != ".", url.lastPathComponent != ".." else {
            throw RunnerServiceError("Choose a new, dedicated directory inside your home folder, without symbolic links. Existing directories are never overwritten.")
        }
    }
    static func validatedAsset(_ release: OfficialRunnerRelease, architecture: String) throws -> OfficialRunnerAsset {
        guard release.tag_name.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { throw RunnerServiceError("The official runner release has an unexpected version.") }
        let name = "actions-runner-osx-\(architecture)-\(release.tag_name.dropFirst()).tar.gz"
        guard let asset = release.assets.first(where: { $0.name == name }),
              asset.browser_download_url == "https://github.com/actions/runner/releases/download/\(release.tag_name)/\(name)",
              let digest = asset.digest, digest.range(of: #"^sha256:[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else {
            throw RunnerServiceError("No matching macOS runner asset with an official SHA-256 digest is available. Nothing was installed.")
        }
        return asset
    }
    static func verifySHA256(file: URL, digest: String) throws {
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        var hasher = SHA256()
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard "sha256:" + actual == digest.lowercased() else { throw RunnerServiceError("Runner SHA-256 verification failed. The archive was not extracted.") }
    }
    static func validateArchive(names: String, verbose: String) throws {
        let entries = names.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !entries.isEmpty, entries.count < 100_000 else { throw RunnerServiceError("Unexpected runner archive contents.") }
        for name in entries {
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\r"),
                  !name.split(separator: "/").contains("..") else { throw RunnerServiceError("Runner archive contains an unsafe path.") }
        }
        for line in verbose.split(separator: "\n") {
            guard let kind = line.first else { continue }
            guard kind == "-" || kind == "d" || kind == "l" else { throw RunnerServiceError("Runner archive contains an unsupported file type.") }
            if kind == "l" {
                guard let arrow = line.range(of: " -> ") else { throw RunnerServiceError("Could not validate an archive symbolic link.") }
                let target = String(line[arrow.upperBound...])
                let prefix = String(line[..<arrow.lowerBound])
                guard let name = entries.first(where: { prefix.hasSuffix(" " + $0) }), !target.hasPrefix("/"), !target.contains("\\") else { throw RunnerServiceError("Runner archive contains an unsafe symbolic link.") }
                var stack = name.split(separator: "/").dropLast().filter { $0 != "." }.map(String.init)
                for part in target.split(separator: "/") {
                    if part == ".." { guard !stack.isEmpty else { throw RunnerServiceError("Runner archive link escapes its installation folder.") }; stack.removeLast() }
                    else if part != "." { stack.append(String(part)) }
                }
            }
        }
    }
}
