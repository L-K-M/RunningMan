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
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; let available = max(0, limit - data.count); if bytes.count > available { didTruncate = true }; data.append(bytes.prefix(available)) }
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return didTruncate }
    func string() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

struct SystemProcessExecutor: ProcessExecuting {
    static var toolPath: String {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + current
    }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        // The command runs on its own dispatch queue and reports back through a
        // continuation, so a long command never occupies a Swift concurrency thread.
        let execution = ProcessExecution(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { execution.start($0) }
        } onCancel: {
            execution.cancel()
        }
    }
}

/// One subprocess run. All mutable state is confined to `queue`: termination,
/// pipe end-of-file, timers and cancellation all hop onto it, and nothing ever
/// waits synchronously for the child.
private final class ProcessExecution: @unchecked Sendable {
    private enum StopReason { case timedOut, cancelled }
    private static let terminationGrace: TimeInterval = 1
    private static let drainLimit: TimeInterval = 0.25
    // A static wrapper establishes a private process group for the command.
    // config.sh launches Runner.Listener as a child: terminating only its
    // shell could otherwise leave registration running after a timeout.
    // The requested executable and arguments are passed as positional
    // parameters, never interpolated into shell source. The trap exists before
    // the fork and reads $! itself: bash runs traps only between commands, so
    // $! is either empty (exiting then prevents the fork) or the child, and an
    // early SIGTERM cannot orphan the command's process group. It turns job
    // control off first so bash never reports the killed job on stderr.
    private static let wrapper = #"""
    trap 'trap "" TERM INT; set +m; child=$!; if [ -n "$child" ]; then kill -TERM -- -"$child" 2>/dev/null; /bin/sleep 0.15; kill -KILL -- -"$child" 2>/dev/null; wait "$child" 2>/dev/null; fi; exit 143' TERM INT
    set -m
    "$@" &
    child=$!
    set +m
    wait "$child"
    result=$?
    exit "$result"
    """#

    private let request: ProcessRequest
    private let queue = DispatchQueue(label: "RunningMan.ProcessExecution", qos: .utility)
    private let process = Process()
    private let stdout = Pipe(), stderr = Pipe()
    private let out: OutputBuffer, err: OutputBuffer
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var openHandles: [FileHandle] = []
    private var timers: [DispatchSourceTimer] = []
    private var stopReason: StopReason?
    private var launched = false, exited = false, finished = false

    init(_ request: ProcessRequest) {
        self.request = request
        out = OutputBuffer(limit: request.outputLimit); err = OutputBuffer(limit: request.outputLimit)
    }

    func start(_ continuation: CheckedContinuation<ProcessResult, Error>) { queue.async { self.launch(continuation) } }
    func cancel() { queue.async { self.stop(.cancelled) } }

    private func launch(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        self.continuation = continuation
        // A task cancelled before this point never starts its command.
        guard stopReason == nil else { finish(); return }
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", Self.wrapper, "runningman-process", request.executable] + request.arguments
        process.currentDirectoryURL = request.directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = SystemProcessExecutor.toolPath
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GH_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        // Never inherit a release job's credentials or runner-input secrets.
        for key in environment.keys where key.hasPrefix("ACTIONS_RUNNER_INPUT_") { environment.removeValue(forKey: key) }
        environment.merge(request.environment) { _, new in new }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        capture(stdout.fileHandleForReading, into: out); capture(stderr.fileHandleForReading, into: err)
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            queue.async { self.processExited() }
        }
        do { try process.run() }
        catch {
            finish(throwing: RunnerServiceError("Could not launch \(URL(fileURLWithPath: request.executable).lastPathComponent): \(error.localizedDescription)"))
            return
        }
        launched = true
        schedule(after: max(0.1, request.timeout)) { [weak self] in self?.stop(.timedOut) }
    }

    // Output stays bounded even for noisy tools. Never synchronously read a pipe:
    // a surviving descendant may still hold its write end.
    private func capture(_ handle: FileHandle, into buffer: OutputBuffer) {
        openHandles.append(handle)
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard data.isEmpty else { buffer.append(data); return }
            // End of file. Clearing the handler from its own callback guarantees
            // that no later call can read the handle after it is closed.
            handle.readabilityHandler = nil
            try? handle.close()
            guard let self else { return }
            queue.async { self.streamEnded(handle) }
        }
    }

    private func stop(_ reason: StopReason) {
        guard stopReason == nil, !exited, !finished else { return }
        // Foundation can record the exit before processExited() reaches this queue;
        // a command that already finished is neither timed out nor cancelled.
        guard !launched || process.isRunning else { return }
        stopReason = reason
        guard launched else { return }
        // SIGTERM reaches the wrapper, whose trap stops the command's process group.
        process.terminate()
        schedule(after: Self.terminationGrace) { [weak self] in
            guard let self, !exited, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func processExited() {
        exited = true
        guard openHandles.isEmpty else {
            // Give pipe readers a bounded chance to reach end of file.
            schedule(after: Self.drainLimit) { [weak self] in self?.finish() }
            return
        }
        finish()
    }

    private func streamEnded(_ handle: FileHandle) {
        openHandles.removeAll { $0 === handle }
        if exited && openHandles.isEmpty { finish() }
    }

    private func finish(throwing error: Error? = nil) {
        guard !finished, let continuation else { return }
        finished = true; self.continuation = nil
        timers.forEach { $0.cancel() }; timers = []
        // A stream still open here is held by a surviving descendant (or the launch
        // failed). Stop reading it, but leave closing to deallocation: a handler
        // call already in flight keeps the handle alive, so it is never closed
        // underneath that call.
        openHandles.forEach { $0.readabilityHandler = nil }; openHandles = []
        if let error { continuation.resume(throwing: error); return }
        if stopReason == .cancelled { continuation.resume(throwing: CancellationError()); return }
        continuation.resume(returning: ProcessResult(status: process.terminationStatus, output: out.string(), error: err.string(),
                                                     timedOut: stopReason == .timedOut, truncated: out.truncated || err.truncated))
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler(handler: action)
        timers.append(timer)
        timer.resume()
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
