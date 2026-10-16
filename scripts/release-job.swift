#!/usr/bin/env swift
import Foundation

// Canonical copy: L-K-M/RunningMan/scripts/release-job.swift.
// Only the uniquely marked scratch directory created by prepare can be removed.
// Receipts are local diagnostics, never credentials or a claim about free APFS space.
private let fm = FileManager.default
private let environment = ProcessInfo.processInfo.environment
private let markerName = ".runningman-release-owner.json"
private let prefix = "runningman-release-"

private struct Failure: Error, CustomStringConvertible { let description: String }
private func fail(_ text: String) -> Failure { Failure(description: text) }
private struct Identity: Codable, Equatable {
    let repository: String
    let runID: String
    let runAttempt: String
    let job: String
    init() throws {
        func required(_ key: String, pattern: String, limit: Int) throws -> String {
            guard let value = environment[key], !value.isEmpty, value.utf8.count <= limit,
                  value.range(of: pattern, options: .regularExpression) != nil else { throw fail("Missing or invalid \(key).") }
            return value
        }
        repository = try required("GITHUB_REPOSITORY", pattern: #"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z"#, limit: 256)
        runID = try required("GITHUB_RUN_ID", pattern: #"\A[0-9]+\z"#, limit: 32)
        runAttempt = try required("GITHUB_RUN_ATTEMPT", pattern: #"\A[0-9]+\z"#, limit: 16)
        job = try required("GITHUB_JOB", pattern: #"\A[A-Za-z0-9_.-]+\z"#, limit: 128)
    }
}
private struct Marker: Codable {
    let schemaVersion: Int
    let id: String
    let identity: Identity
    let rootPath: String
    let temporaryPath: String
    let receiptPath: String
}
private struct PathReceipt: Codable {
    var path: String
    var status: String
    var bytesRemoved: Int64
    var filesRemoved: Int64
    var message: String?
}
private struct Receipt: Codable {
    var schemaVersion = 1
    let id: String
    let repository: String
    let runID: String
    let runAttempt: String
    let job: String
    let runURL: String?
    let startedAt: String
    var finishedAt: String?
    var status: String
    var bytesRemoved: Int64 = 0
    var filesRemoved: Int64 = 0
    var paths: [PathReceipt]
    var message: String?
}
private func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
private func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
private func kind(_ url: URL) throws -> FileAttributeType {
    guard let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else { throw fail("Cannot determine the filesystem entry type.") }
    return type
}
private func absoluteEnvironmentURL(_ key: String) throws -> URL {
    guard let value = environment[key], value.hasPrefix("/"), value.utf8.count <= 4096,
          !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else { throw fail("Missing or invalid \(key).") }
    return URL(fileURLWithPath: value).standardizedFileURL
}
private func temporaryDirectory() throws -> URL {
    let url = try absoluteEnvironmentURL("RUNNER_TEMP")
    // Runner installations may themselves live under a macOS /var -> /private/var
    // alias. Canonicalize the parent, but reject a substituted _temp symlink.
    guard try kind(url) == .typeDirectory else { throw fail("RUNNER_TEMP must be a real directory.") }
    return url.resolvingSymlinksInPath().standardizedFileURL
}
private func receiptDirectory(_ temporary: URL, create: Bool) throws -> URL {
    let url = temporary.deletingLastPathComponent().appendingPathComponent(".runningman-cleanup")
    if !exists(url), create { try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    guard try kind(url) == .typeDirectory else { throw fail("Cleanup history must be a real directory.") }
    // Do not chmod an arbitrary existing work directory; only the dedicated
    // history directory has its privacy policy enforced here.
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}
private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
    guard try kind(url) == .typeRegular else { throw fail("Ownership and receipt files must be regular files.") }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 65537) ?? Data()
    guard data.count <= 65536 else { throw fail("Ownership or receipt file exceeds its size limit.") }
    return try JSONDecoder().decode(type, from: data)
}
private func write<T: Encodable>(_ value: T, to url: URL) throws {
    if exists(url), try kind(url) != .typeRegular { throw fail("Refusing to replace a non-regular receipt file.") }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard data.count <= 65536 else { throw fail("Receipt exceeds its size limit.") }
    // A private staging file plus rename keeps both first publication and later
    // replacement atomic, without exposing an intermediate world-readable file.
    let staging = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
    guard fm.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw fail("Could not create a private receipt.") }
    defer { try? fm.removeItem(at: staging) }
    if exists(url) { _ = try fm.replaceItemAt(url, withItemAt: staging) }
    else { try fm.moveItem(at: staging, to: url) }
}
private func git(_ arguments: [String], capture: Bool = false) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "init.templateDir="] + arguments
    // Do not inherit token-bearing Git headers, hooks, object alternates or
    // caller-supplied GIT_CONFIG_COUNT settings into the scratch checkout.
    var clean = environment.filter { !$0.key.hasPrefix("GIT_") }
    clean["GIT_CONFIG_GLOBAL"] = "/dev/null"; clean["GIT_CONFIG_NOSYSTEM"] = "1"
    clean["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = clean
    let pipe = Pipe()
    process.standardOutput = capture ? pipe : FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw fail("Git could not prepare the isolated release checkout.") }
    guard data.count <= 8192 else { throw fail("Git metadata exceeds its size limit.") }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
private func originURL(in source: URL) throws -> String {
    let value = try git(["-C", source.path, "remote", "get-url", "origin"], capture: true)
    guard let url = URL(string: value), ["https", "ssh"].contains(url.scheme?.lowercased() ?? ""),
          url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          !value.contains("\n"), !value.contains("\r") else { throw fail("The checkout origin must be a remote URL without embedded credentials.") }
    return value
}
private func export(_ entries: [(String, String)]) throws {
    let file = try absoluteEnvironmentURL("GITHUB_ENV")
    guard try kind(file) == .typeRegular else { throw fail("GITHUB_ENV must be a regular file.") }
    let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
    try handle.seekToEnd()
    for (key, value) in entries {
        guard !value.contains("\n"), !value.contains("\r") else { throw fail("A release scratch path contains a newline.") }
        try handle.write(contentsOf: Data("\(key)=\(value)\n".utf8))
    }
}
private func prepare() throws {
    let identity = try Identity()
    let temporary = try temporaryDirectory()
    let source = try absoluteEnvironmentURL("GITHUB_WORKSPACE").resolvingSymlinksInPath()
    guard try kind(source) == .typeDirectory, source != temporary else { throw fail("The source checkout is not a valid directory.") }
    let head = try git(["-C", source.path, "rev-parse", "--verify", "HEAD"], capture: true)
    guard head.range(of: #"\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z"#, options: .regularExpression) != nil else { throw fail("The source checkout has no valid commit.") }
    let origin = try originURL(in: source)
    let id = UUID().uuidString
    let root = temporary.appendingPathComponent(prefix + id)
    let workspace = root.appendingPathComponent("source")
    let receipts = try receiptDirectory(temporary, create: true)
    let receiptURL = receipts.appendingPathComponent(id + ".json")
    try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let marker = Marker(schemaVersion: 1, id: id, identity: identity, rootPath: root.path,
        temporaryPath: temporary.path, receiptPath: receiptURL.path)
    let server = environment["GITHUB_SERVER_URL"] ?? "https://github.com"
    let runURL: String?
    if let url = URL(string: server), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
       url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" {
        runURL = server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/\(identity.repository)/actions/runs/\(identity.runID)"
    } else { runURL = nil }
    var receipt = Receipt(id: id, repository: identity.repository, runID: identity.runID,
        runAttempt: identity.runAttempt, job: identity.job, runURL: runURL, startedAt: timestamp(),
        status: "pending", paths: [PathReceipt(path: root.path, status: "pending", bytesRemoved: 0, filesRemoved: 0)])
    do {
        try write(marker, to: root.appendingPathComponent(markerName))
        try write(receipt, to: receiptURL)
        // Export before clone so a later always() cleanup can remove even a
        // partially prepared checkout. No global TMPDIR: post-actions run later.
        try export([("RELEASE_JOB_ROOT", root.path), ("RELEASE_JOB_WORKSPACE", workspace.path), ("RELEASE_CLEANUP_RECEIPT", receiptURL.path)])
        try fm.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try git(["clone", "--local", "--no-hardlinks", "--no-checkout", "--", source.path, workspace.path])
        _ = try git(["-C", workspace.path, "remote", "set-url", "origin", origin])
        _ = try git(["-C", workspace.path, "checkout", "--detach", head])
        print("Prepared an isolated release checkout at commit \(head).")
    } catch {
        receipt.status = "failed"; receipt.finishedAt = timestamp()
        receipt.message = "Release checkout preparation failed; any remaining owned scratch requires cleanup."
        receipt.paths[0].status = "failed"; receipt.paths[0].message = receipt.message
        try? write(receipt, to: receiptURL)
        throw error
    }
}
private struct Inventory { var bytes: Int64 = 0; var files: Int64 = 0; var complete = true }
private func inventory(_ root: URL) -> Inventory {
    var result = Inventory()
    guard exists(root) else { return result }
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in result.complete = false; return true }) else { result.complete = false; return result }
    for case let file as URL in enumerator {
        do {
            let attributes = try fm.attributesOfItem(atPath: file.path)
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink { enumerator.skipDescendants() }
            if type != .typeDirectory {
                result.files += 1
                let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                result.bytes = result.bytes > Int64.max - max(0, bytes) ? Int64.max : result.bytes + max(0, bytes)
            }
        } catch { result.complete = false; enumerator.skipDescendants() }
    }
    return result
}
private func cleanup() throws {
    let identity = try Identity()
    let temporary = try temporaryDirectory()
    let root = try absoluteEnvironmentURL("RELEASE_JOB_ROOT")
    let receiptURL = try absoluteEnvironmentURL("RELEASE_CLEANUP_RECEIPT")
    let name = root.lastPathComponent
    guard root.deletingLastPathComponent() == temporary, name.hasPrefix(prefix),
          let uuid = UUID(uuidString: String(name.dropFirst(prefix.count))),
          name == prefix + uuid.uuidString else { throw fail("Cleanup target is not an owned immediate child of RUNNER_TEMP.") }
    let receipts = try receiptDirectory(temporary, create: false)
    guard receiptURL == receipts.appendingPathComponent(uuid.uuidString + ".json") else { throw fail("Cleanup receipt does not match the owned scratch directory.") }
    var receipt = try read(Receipt.self, at: receiptURL)
    guard receipt.schemaVersion == 1, receipt.id == uuid.uuidString, receipt.repository == identity.repository,
          receipt.runID == identity.runID, receipt.runAttempt == identity.runAttempt, receipt.job == identity.job,
          receipt.paths.count == 1, receipt.paths[0].path == root.path else { throw fail("Cleanup receipt belongs to another job.") }
    // Repeated successful cleanup is harmless; no filesystem target is followed.
    if !exists(root), receipt.status == "success" { print("Release scratch was already cleaned."); return }
    let marker: Marker
    do {
        guard try kind(root) == .typeDirectory, root.resolvingSymlinksInPath().standardizedFileURL == root else { throw fail("Cleanup target is missing or is a symbolic link.") }
        marker = try read(Marker.self, at: root.appendingPathComponent(markerName))
        guard marker.schemaVersion == 1, marker.id == uuid.uuidString, marker.identity == identity,
              marker.rootPath == root.path, marker.temporaryPath == temporary.path, marker.receiptPath == receiptURL.path else { throw fail("Cleanup ownership marker does not match this job.") }
    } catch {
        receipt.finishedAt = timestamp(); receipt.status = "failed"
        receipt.message = "Ownership validation failed. No scratch files were removed."
        receipt.paths[0].status = "failed"; receipt.paths[0].message = receipt.message
        try write(receipt, to: receiptURL)
        throw error
    }
    let before = inventory(root)
    var removalFailed = false
    // Keep the ownership marker until every other entry has been removed, so a
    // permissions failure remains safely retryable. removeItem unlinks symbolic
    // links themselves; neither measurement nor deletion follows their targets.
    do {
        for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where child.lastPathComponent != markerName {
            do { try fm.removeItem(at: child) } catch { removalFailed = true }
        }
        if !removalFailed {
            try fm.removeItem(at: root.appendingPathComponent(markerName))
            do { try fm.removeItem(at: root) }
            catch {
                removalFailed = true
                if exists(root), (try? kind(root)) == .typeDirectory { try? write(marker, to: root.appendingPathComponent(markerName)) }
            }
        }
    } catch { removalFailed = true }
    let remains = exists(root)
    let after = remains ? inventory(root) : Inventory()
    receipt.finishedAt = timestamp()
    let removedBytes = max(0, before.bytes - after.bytes)
    let removedFiles = max(0, before.files - after.files)
    // A retry completes the same job receipt, preserving the work already done.
    receipt.bytesRemoved = max(0, receipt.bytesRemoved) > Int64.max - removedBytes ? Int64.max : max(0, receipt.bytesRemoved) + removedBytes
    receipt.filesRemoved = max(0, receipt.filesRemoved) > Int64.max - removedFiles ? Int64.max : max(0, receipt.filesRemoved) + removedFiles
    if !remains && !removalFailed {
        receipt.status = "success"
        receipt.message = before.complete ? "Removed job-owned release scratch. Byte counts are estimated logical sizes." : "Removed job-owned release scratch. Some logical sizes could not be measured."
    } else {
        receipt.status = receipt.filesRemoved > 0 || receipt.bytesRemoved > 0 ? "partial" : "failed"
        receipt.message = "Could not remove all job-owned release scratch. Remaining files were preserved; byte counts are estimates."
    }
    receipt.paths = [PathReceipt(path: root.path, status: receipt.status, bytesRemoved: receipt.bytesRemoved,
        filesRemoved: receipt.filesRemoved, message: receipt.message)]
    try write(receipt, to: receiptURL)
    guard receipt.status == "success" else { throw fail("Release scratch cleanup did not complete; see the local cleanup receipt.") }
    print("Cleaned release scratch: \(receipt.filesRemoved) files, approximately \(receipt.bytesRemoved) logical bytes.")
    summary("Cleaned \(receipt.filesRemoved) job-owned files (approximately \(receipt.bytesRemoved) logical bytes).")
}

private func summary(_ message: String) {
    guard let value = environment["GITHUB_STEP_SUMMARY"], value.hasPrefix("/"), !value.contains("\n"), !value.contains("\r"),
          let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: value)) else { return }
    defer { try? handle.close() }
    try? handle.seekToEnd()
    try? handle.write(contentsOf: Data("\n### Release scratch cleanup\n\n\(message) Build and release results are reported by their own steps.\n".utf8))
}

do {
    guard CommandLine.arguments.count == 2 else { throw fail("Usage: swift scripts/release-job.swift prepare|cleanup") }
    switch CommandLine.arguments[1] {
    case "prepare": try prepare()
    case "cleanup": try cleanup()
    default: throw fail("Usage: swift scripts/release-job.swift prepare|cleanup")
    }
} catch {
    // Avoid reflecting arbitrary Git config, token-bearing argv or filesystem
    // error descriptions into a receipt or the workflow log.
    let message = (error as? Failure)?.description ?? "Release scratch operation failed. Check directory permissions and the local receipt."
    let isCleanup = CommandLine.arguments.dropFirst().first == "cleanup"
    FileHandle.standardError.write(Data("::\(isCleanup ? "warning" : "error")::\(message)\n".utf8))
    if isCleanup { summary("Cleanup did not complete. Review the warning and local cleanup receipt.") }
    exit(1)
}
