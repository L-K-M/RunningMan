import Foundation
import RunningManCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct RunnerServiceError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = SecretRedactor.redact(message) }
    public var errorDescription: String? { message }
}

struct ProcessRequest: Sendable {
    var executable: String
    var arguments: [String] = []
    var directory: URL? = nil
    var environment: [String: String] = [:]
    var timeout: TimeInterval = 20
    var secrets: [String] = []
    var outputLimit: Int = 2_000_000
}
struct ProcessResult: Sendable {
    var status: Int32
    var output: String
    var error: String
    var timedOut: Bool = false
    var truncated: Bool = false
}
protocol ProcessExecuting: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var didTruncate = false
    private var ended = false
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; if bytes.isEmpty { ended = true }; let available = max(0, limit - data.count); if bytes.count > available { didTruncate = true }; data.append(bytes.prefix(available)) }
    var complete: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return didTruncate }
    func string() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

struct SystemProcessExecutor: ProcessExecuting {
    static var toolPath: String {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + current
    }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try await Task.detached(priority: .utility) { try Self.execute(request) }.value
    }
    private static func execute(_ request: ProcessRequest) throws -> ProcessResult {
            let process = Process()
            // A static wrapper establishes a private process group for the command.
            // config.sh launches Runner.Listener as a child: terminating only its
            // shell could otherwise leave registration running after a timeout.
            // The requested executable and arguments are passed as positional
            // parameters, never interpolated into shell source.
            let wrapper = #"""
            set -m
            "$@" &
            child=$!
            set +m
            trap 'trap "" TERM INT; kill -TERM -- -"$child" 2>/dev/null; /bin/sleep 0.15; kill -KILL -- -"$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT
            wait "$child"
            result=$?
            exit "$result"
            """#
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", wrapper, "runningman-process", request.executable] + request.arguments
            process.currentDirectoryURL = request.directory
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = Self.toolPath
            environment["GH_PROMPT_DISABLED"] = "1"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GH_PAGER"] = "cat"
            environment["PAGER"] = "cat"
            // Never inherit a release job's credentials or runner-input secrets.
            for key in environment.keys where key.hasPrefix("ACTIONS_RUNNER_INPUT_") { environment.removeValue(forKey: key) }
            environment.merge(request.environment) { _, new in new }
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe(), stderr = Pipe()
            let out = OutputBuffer(limit: request.outputLimit), err = OutputBuffer(limit: request.outputLimit)
            process.standardOutput = stdout; process.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { handle in out.append(handle.availableData) }
            stderr.fileHandleForReading.readabilityHandler = { handle in err.append(handle.availableData) }
            defer {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
            }
            do { try process.run() }
            catch { throw RunnerServiceError("Could not launch \(URL(fileURLWithPath: request.executable).lastPathComponent): \(error.localizedDescription)") }
            let deadline = Date().addingTimeInterval(max(0.1, request.timeout))
            var timedOut = false
            while process.isRunning {
                if Date() >= deadline {
                    timedOut = true; process.terminate()
                    let grace = Date().addingTimeInterval(1)
                    while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    break
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            process.waitUntilExit()
            // Give EOF readers a bounded chance to finish. Never synchronously read
            // a pipe: a surviving child may still hold its write handle.
            let drainDeadline = Date().addingTimeInterval(0.25)
            while !(out.complete && err.complete) && Date() < drainDeadline { Thread.sleep(forTimeInterval: 0.005) }
            // Output stays bounded even for noisy tools.
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            return ProcessResult(status: process.terminationStatus, output: out.string(), error: err.string(), timedOut: timedOut, truncated: out.truncated || err.truncated)
    }
}

func checked(_ executor: any ProcessExecuting, _ request: ProcessRequest, operation: String) async throws -> ProcessResult {
    let result = try await executor.run(request)
    guard result.status == 0 && !result.timedOut && !result.truncated else {
        var detail = String((result.error.isEmpty ? result.output : result.error).suffix(2500))
        for secret in request.secrets where !secret.isEmpty { detail = detail.replacingOccurrences(of: secret, with: "[REDACTED]") }
        throw RunnerServiceError("\(operation) \(result.timedOut ? "timed out" : result.truncated ? "returned too much output to validate safely" : "failed (\(result.status))"). \(detail)")
    }
    return result
}

func githubCLI() throws -> String {
    for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) { return path }
    for parent in SystemProcessExecutor.toolPath.split(separator: ":") {
        let path = String(parent) + "/gh"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    throw RunnerServiceError("GitHub CLI is required for registration. Install it with brew install gh, then sign in using gh auth login in Terminal. Existing runners can still be managed without it.")
}

func runnerText(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    guard data.count <= 1_000_000 else { throw RunnerServiceError("Runner metadata is unexpectedly large.") }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\n\r \t"))
}

func runnerMetadata(at directory: URL) throws -> [String: Any] {
    let text = try runnerText(directory.appendingPathComponent(".runner"))
    guard let data = text.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["agentName"] is String, object["gitHubUrl"] is String else { throw RunnerServiceError("The selected directory does not contain valid GitHub runner metadata.") }
    return object
}
