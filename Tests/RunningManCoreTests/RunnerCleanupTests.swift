import XCTest
@testable import RunningManCore

final class RunnerCleanupTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-core-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func receipt(id: String = UUID().uuidString, status: RunnerCleanupStatus = .success, path: String = "/synthetic/job-scratch") -> RunnerCleanupRecord {
        RunnerCleanupRecord(id: id, runnerID: "untrusted", repository: "example/desktop", runID: "123", runAttempt: "1", job: "release", runURL: URL(string: "https://github.com/example/desktop/actions/runs/123"), startedAt: Date(timeIntervalSince1970: 100), finishedAt: status == .pending ? nil : Date(timeIntervalSince1970: 200), status: status, bytesRemoved: status == .pending ? 0 : 8192, filesRemoved: status == .pending ? 0 : 3, paths: [RunnerCleanupPath(path: path, status: status, bytesRemoved: status == .pending ? 0 : 8192, filesRemoved: status == .pending ? 0 : 3)])
    }
    private func save(_ receipt: RunnerCleanupRecord, in work: URL) throws -> URL {
        let url = work.appendingPathComponent(".runningman-cleanup/\(receipt.id).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: url)
        return url
    }
    func testGitHubWorkFolderDiscoveryAndBackwardCompatibleModel() async throws {
        let directory = root.appendingPathComponent("runner")
        try write("", directory.appendingPathComponent("bin/Runner.Listener"))
        try write(#"{"agentName":"example","workFolder":"jobs"}"#, directory.appendingPathComponent(".runner"))
        let found = await RunnerDiscovery(homeDirectory: root).discover()
        XCTAssertEqual(found.runners.first?.workDirectoryURL, directory.appendingPathComponent("jobs"))
        try write(#"{"agentName":"example","workFolder":"/synthetic/external-work"}"#, directory.appendingPathComponent(".runner"))
        let absolute = await RunnerDiscovery(homeDirectory: root).discover()
        XCTAssertEqual(absolute.runners.first?.workDirectoryURL?.path, "/synthetic/external-work")
        try write(#"{"agentName":"example"}"#, directory.appendingPathComponent(".runner"))
        let fallback = await RunnerDiscovery(homeDirectory: root).discover()
        XCTAssertEqual(fallback.runners.first?.workDirectoryURL, directory.appendingPathComponent("_work"))
        let old = try JSONDecoder().decode(InstalledRunner.self, from: Data(#"{"name":"example","directory":"file:///synthetic/runner"}"#.utf8))
        XCTAssertNil(old.workDirectoryURL)
        XCTAssertEqual(try JSONDecoder().decode(InstalledRunner.self, from: JSONEncoder().encode(found.runners[0])), found.runners[0])
    }
    func testReadOnlyReceiptScanBindsRunnerAndRetainsPendingWithoutInferringSuccess() async throws {
        let work = root.appendingPathComponent("custom-work")
        let runner = InstalledRunner(name: "example", directory: root.appendingPathComponent("runner"), workDirectoryURL: work)
        let external = root.appendingPathComponent("untouched"); try write("keep", external)
        let pending = receipt(status: .pending, path: external.path)
        let pendingURL = try save(pending, in: work)
        let completed = receipt()
        _ = try save(completed, in: work)
        let before = try Data(contentsOf: pendingURL)
        let monitor = RunnerCleanupMonitor()
        let result = await monitor.scan(runners: [runner])
        XCTAssertTrue(result.warnings.isEmpty); XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(result.records.allSatisfy { $0.runnerID == runner.id })
        XCTAssertEqual(result.records.first { $0.id == pending.id }?.status, .pending)
        XCTAssertNil(result.records.first { $0.id == pending.id }?.finishedAt)
        XCTAssertEqual(try Data(contentsOf: pendingURL), before)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "keep")
        let again = await monitor.scan(runners: [runner]); XCTAssertEqual(again.records, result.records)
    }
    func testReceiptReaderRejectsSymlinksMalformedCountersAndCredentialURLsAndRedacts() async throws {
        let work = root.appendingPathComponent("_work")
        let runner = InstalledRunner(name: "example", directory: root)
        var valid = receipt(); valid.message = "token=PRIVATE_VALUE"
        valid.runURL = URL(string: "https://user:password@github.com/example/desktop?token=PRIVATE_VALUE")
        _ = try save(valid, in: work)
        var bad = receipt(); bad.bytesRemoved = -1
        _ = try save(bad, in: work)
        var missingCompletion = receipt(); missingCompletion.finishedAt = nil
        _ = try save(missingCompletion, in: work)
        var falsePending = receipt(status: .pending); falsePending.filesRemoved = 1
        _ = try save(falsePending, in: work)
        var invalidRun = receipt(); invalidRun.runID = "not-a-run"
        _ = try save(invalidRun, in: work)
        var inconsistent = receipt(); inconsistent.paths[0].status = .failed
        _ = try save(inconsistent, in: work)
        let outside = root.appendingPathComponent("outside.json")
        try write("do not read", outside)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent(".runningman-cleanup/\(UUID().uuidString).json"), withDestinationURL: outside)
        let result = await RunnerCleanupMonitor().scan(runners: [runner])
        XCTAssertEqual(result.records.count, 1); XCTAssertNil(result.records[0].runURL)
        XCTAssertFalse(result.records[0].message!.contains("PRIVATE_VALUE")); XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "do not read")
    }
    func testUnicodeReceiptMessagesAreRedactedAndBoundedForDisplay() async throws {
        let runner = InstalledRunner(name: "example", directory: root)
        var large = receipt()
        large.message = "token=PRIVATE_VALUE " + String(repeating: "🔥", count: 6000)
        large.paths[0].message = "token=PATH_PRIVATE " + String(repeating: "a\u{0301}", count: 4000)
        let file = try save(large, in: root.appendingPathComponent("_work"))
        let original = try Data(contentsOf: file)
        let result = await RunnerCleanupMonitor().scan(runners: [runner])
        XCTAssertTrue(result.warnings.isEmpty)
        let record = try XCTUnwrap(result.records.first)
        XCTAssertLessThanOrEqual(record.message!.utf8.count, 2048)
        XCTAssertLessThanOrEqual(record.paths[0].message!.utf8.count, 1024)
        XCTAssertFalse(record.message!.contains("PRIVATE_VALUE"))
        XCTAssertFalse(record.paths[0].message!.contains("PATH_PRIVATE"))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testReceiptScanCapsLatestHistoryAndSkipsForgejoWithoutReadingConfig() async throws {
        let runner = InstalledRunner(name: "example", directory: root)
        let work = root.appendingPathComponent("_work")
        for index in 0..<110 {
            let file = try save(receipt(), in: work)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: file.path)
        }
        let result = await RunnerCleanupMonitor().scan(runners: [runner])
        XCTAssertEqual(result.records.count, 100)
        let forgejo = InstalledRunner(name: "native", directory: root, provider: .forgejo, configurationURL: root.appendingPathComponent("config.yaml"))
        try write("must not be read", forgejo.configurationURL!)
        let ignored = await RunnerCleanupMonitor().scan(runners: [forgejo]); XCTAssertTrue(ignored.records.isEmpty)
    }
}

#if os(macOS)
final class ReleaseJobScriptTests: XCTestCase {
    private static var compiled: URL!
    private var root: URL!
    private var env: [String: String]!
    private var script: URL { URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/release-job.swift") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("release-job-test-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work/_temp"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("checkout"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("environment").path, contents: Data())
        env = ProcessInfo.processInfo.environment
        env["RUNNER_TEMP"] = root.appendingPathComponent("work/_temp").path
        env["GITHUB_WORKSPACE"] = root.appendingPathComponent("checkout").path
        env["GITHUB_ENV"] = root.appendingPathComponent("environment").path
        env["GITHUB_REPOSITORY"] = "example/desktop"; env["GITHUB_RUN_ID"] = "123"; env["GITHUB_RUN_ATTEMPT"] = "2"; env["GITHUB_JOB"] = "release-mac"
        if Self.compiled == nil {
            Self.compiled = FileManager.default.temporaryDirectory.appendingPathComponent("release-job-test-binary-\(UUID().uuidString)")
            XCTAssertEqual(try run("/usr/bin/swiftc", [script.path, "-o", Self.compiled.path]).0, 0)
        }
        _ = try git(["init", "-q"])
        _ = try git(["config", "user.name", "Synthetic Test"]); _ = try git(["config", "user.email", "test@example.test"])
        _ = try git(["remote", "add", "origin", "https://github.com/example/desktop.git"])
        try Data("first\n".utf8).write(to: root.appendingPathComponent("checkout/tracked"))
        _ = try git(["add", "tracked"]); _ = try git(["commit", "-qm", "First synthetic commit"])
        try Data("second\n".utf8).write(to: root.appendingPathComponent("checkout/tracked"))
        _ = try git(["commit", "-am", "Second synthetic commit", "-q"])
        try Data("developer dirty\n".utf8).write(to: root.appendingPathComponent("checkout/tracked"))
        try Data("developer untracked\n".utf8).write(to: root.appendingPathComponent("checkout/private-untracked"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    override class func tearDown() { if let compiled { try? FileManager.default.removeItem(at: compiled) }; compiled = nil }
    private func run(_ executable: String, _ arguments: [String], _ customEnv: [String: String]? = nil) throws -> (Int32, String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = customEnv ?? env
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
    private func git(_ args: [String], at path: URL? = nil) throws -> String {
        let result = try run("/usr/bin/git", ["-C", (path ?? root.appendingPathComponent("checkout")).path] + args)
        XCTAssertEqual(result.0, 0, result.1); return result.1.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func prepare() throws -> URL {
        let result = try run(Self.compiled.path, ["prepare"]); XCTAssertEqual(result.0, 0, result.1)
        let entries = try String(contentsOf: root.appendingPathComponent("environment"), encoding: .utf8).split(separator: "\n")
        for entry in entries { let pair = entry.split(separator: "=", maxSplits: 1).map(String.init); env[pair[0]] = pair[1] }
        return URL(fileURLWithPath: try XCTUnwrap(env["RELEASE_JOB_ROOT"]))
    }
    private func receipt() throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(env["RELEASE_CLEANUP_RECEIPT"])))) as? [String: Any])
    }
    func testPrepareClonesExactCommittedHistoryWithoutDeveloperFilesThenCleansWithoutFollowingLinks() async throws {
        let owned = try prepare(); let clone = owned.appendingPathComponent("source")
        XCTAssertEqual(try git(["rev-parse", "HEAD"], at: clone), try git(["rev-parse", "HEAD"]))
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"], at: clone), "2")
        XCTAssertEqual(try git(["remote", "get-url", "origin"], at: clone), "https://github.com/example/desktop.git")
        XCTAssertEqual(try String(contentsOf: clone.appendingPathComponent("tracked"), encoding: .utf8), "second\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.appendingPathComponent("private-untracked").path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: owned.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertNil(env["RELEASE_TMPDIR"])
        XCTAssertEqual(try receipt()["status"] as? String, "pending")
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100000).write(to: outside.appendingPathComponent("keep"))
        try FileManager.default.createSymbolicLink(at: owned.appendingPathComponent("external-link"), withDestinationURL: outside)
        try Data(repeating: 1, count: 8192).write(to: owned.appendingPathComponent("build-output"))
        let cleaned = try run(Self.compiled.path, ["cleanup"]); XCTAssertEqual(cleaned.0, 0, cleaned.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep").path))
        XCTAssertEqual(try receipt()["status"] as? String, "success")
        XCTAssertGreaterThan(try XCTUnwrap(try receipt()["bytesRemoved"] as? Int), 8192)
        XCTAssertLessThan(try XCTUnwrap(try receipt()["bytesRemoved"] as? Int), 100000)
        let runner = InstalledRunner(name: "synthetic", directory: root, workDirectoryURL: root.appendingPathComponent("work"))
        let visible = await RunnerCleanupMonitor().scan(runners: [runner])
        XCTAssertTrue(visible.warnings.isEmpty); XCTAssertEqual(visible.records.count, 1)
        XCTAssertEqual(visible.records.first?.status, .success)
        XCTAssertEqual(visible.records.first?.runID, "123")
        XCTAssertEqual(visible.records.first?.runnerID, runner.id)
        XCTAssertEqual(try run(Self.compiled.path, ["cleanup"]).0, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("checkout/tracked"), encoding: .utf8), "developer dirty\n")
        let mode = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(env["RELEASE_CLEANUP_RECEIPT"]))[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testRejectsAnotherJobAndWrongRootAndRootSymlinkWithoutDeletingTargets() throws {
        let owned = try prepare()
        var other = env!; other["GITHUB_JOB"] = "someone-else"
        XCTAssertNotEqual(try run(Self.compiled.path, ["cleanup"], other).0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
        var broad = env!; broad["RELEASE_JOB_ROOT"] = root.appendingPathComponent("work").path
        XCTAssertNotEqual(try run(Self.compiled.path, ["cleanup"], broad).0, 0)
        let moved = root.appendingPathComponent("moved-owned")
        try FileManager.default.moveItem(at: owned, to: moved)
        try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: moved)
        XCTAssertNotEqual(try run(Self.compiled.path, ["cleanup"]).0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("source/tracked").path))
    }
    func testPartialDeletionFailureRecordsFailureAndPreservesOwnershipForRetry() throws {
        let owned = try prepare()
        let blocked = owned.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("retained".utf8).write(to: blocked.appendingPathComponent("child"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let result = try run(Self.compiled.path, ["cleanup"])
        XCTAssertNotEqual(result.0, 0, result.1)
        XCTAssertNotEqual(try receipt()["status"] as? String, "success")
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.appendingPathComponent("child").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.appendingPathComponent(".runningman-release-owner.json").path))
        let firstRemoved = try XCTUnwrap(try receipt()["bytesRemoved"] as? Int)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        XCTAssertEqual(try run(Self.compiled.path, ["cleanup"]).0, 0)
        XCTAssertGreaterThan(try XCTUnwrap(try receipt()["bytesRemoved"] as? Int), firstRemoved)
    }
    func testTamperedMarkerAndHistorySymlinkNeverAuthorizeDeletion() throws {
        let owned = try prepare()
        let marker = owned.appendingPathComponent(".runningman-release-owner.json")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any]); object["rootPath"] = root.path
        try JSONSerialization.data(withJSONObject: object).write(to: marker)
        XCTAssertNotEqual(try run(Self.compiled.path, ["cleanup"]).0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.appendingPathComponent("source/tracked").path))
        let history = root.appendingPathComponent("work/.runningman-cleanup")
        let moved = root.appendingPathComponent("external-history")
        try FileManager.default.moveItem(at: history, to: moved)
        try FileManager.default.createSymbolicLink(at: history, withDestinationURL: moved)
        XCTAssertNotEqual(try run(Self.compiled.path, ["cleanup"]).0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }
}
#endif
