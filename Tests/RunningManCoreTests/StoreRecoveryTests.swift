import XCTest
@testable import RunningManCore

/// Saved stores must survive unreadable or inconsistent files instead of failing on every poll.
final class StoreRecoveryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("store-recovery-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func invalidCopies(of file: URL) throws -> [URL] {
        let prefix = file.deletingPathExtension().lastPathComponent + ".invalid-"
        return try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
    }
    private func modificationDate(of file: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    }
    private func job(_ id: String, at seconds: TimeInterval) -> RunnerJob {
        RunnerJob(id: id, runnerID: "runner", name: "Build \(id)", startedAt: Date(timeIntervalSince1970: seconds),
            finishedAt: Date(timeIntervalSince1970: seconds + 10), outcome: .success)
    }

    func testJobOutcomeDecodesUnrecognisedValuesAsUnknownAndEncodesUnchanged() throws {
        let decoded = try JSONDecoder().decode([JobOutcome].self, from: Data(#"["success","queued",""]"#.utf8))
        XCTAssertEqual(decoded, [.success, .unknown, .unknown])
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(JobOutcome.allCases), as: UTF8.self),
            #"["running","success","failure","cancelled","unknown"]"#)
    }

    func testHistoryKeepsValidRecordsAroundOneMalformedRecord() async throws {
        let file = root.appendingPathComponent("jobs.json")
        let original = Data("""
        [{"id":"newer","runnerID":"runner","name":"Newer","startedAt":"2026-10-16T10:00:00Z","outcome":"queued"},
         {"id":"broken","runnerID":"runner","name":"Broken","startedAt":"not a date","outcome":"success"},
         {"id":"older","runnerID":"runner","name":"Older","startedAt":"2026-10-15T10:00:00Z","finishedAt":"2026-10-15T10:05:00Z","outcome":"success"}]
        """.utf8)
        try original.write(to: file)
        let store = RunnerHistoryStore(fileURL: file)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.map(\.id), ["newer", "older"])
        XCTAssertEqual(loaded.first?.outcome, .unknown)
        let notice = await store.takeRecoveryNotice()
        let repeated = await store.takeRecoveryNotice()
        XCTAssertNil(repeated)

        // The original is kept byte for byte; the history file no longer contains the bad record,
        // so the next launch neither warns again nor makes another copy.
        let copies = try invalidCopies(of: file)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, original)
        XCTAssertTrue(notice?.contains("1 saved job record") == true, notice ?? "no notice")
        XCTAssertTrue(copies.first.map { notice?.contains($0.lastPathComponent) == true } == true, notice ?? "no notice")
        let relaunched = RunnerHistoryStore(fileURL: file)
        let reloaded = try await relaunched.load()
        XCTAssertEqual(reloaded, loaded)
        let relaunchNotice = await relaunched.takeRecoveryNotice()
        XCTAssertNil(relaunchNotice)
        XCTAssertEqual(try invalidCopies(of: file).count, 1)
    }

    func testHistoryMovesUnreadableFileAsideAndKeepsWorking() async throws {
        let cases: [(String, Data)] = [("text", Data("not json".utf8)), ("object", Data(#"{"jobs":[]}"#.utf8)),
            ("oversized", Data(count: 8 * 1024 * 1024 + 1))]
        for (name, contents) in cases {
            let file = root.appendingPathComponent(name).appendingPathComponent("jobs.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file)
            let store = RunnerHistoryStore(fileURL: file)
            let loaded = try await store.load()
            XCTAssertTrue(loaded.isEmpty, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), name)
            let copies = try invalidCopies(of: file)
            XCTAssertEqual(copies.count, 1, name)
            XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, contents, name)
            let notice = await store.takeRecoveryNotice()
            XCTAssertTrue(copies.first.map { notice?.contains($0.lastPathComponent) == true } == true, name)
            let repeated = await store.takeRecoveryNotice()
            XCTAssertNil(repeated, name)

            let merged = try await store.merge([job("fresh", at: 1_000)])
            XCTAssertEqual(merged.map(\.id), ["fresh"], name)
            let reloaded = try await RunnerHistoryStore(fileURL: file).load()
            XCTAssertEqual(reloaded, merged, name)
        }
    }

    func testIdenticalHistoryMergeDoesNotRewriteCompactFile() async throws {
        let file = root.appendingPathComponent("jobs.json")
        let store = RunnerHistoryStore(fileURL: file)
        let jobs = [job("a", at: 1_000), job("b", at: 2_000)]
        let first = try await store.merge(jobs)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("\n"))
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
        let second = try await store.merge(jobs.reversed())
        XCTAssertEqual(second, first)
        XCTAssertEqual(try modificationDate(of: file), past)

        var changed = jobs[0]; changed.workflow = "Release"
        let third = try await store.merge([changed])
        XCTAssertEqual(third.first { $0.id == "a" }?.workflow, "Release")
        XCTAssertNotEqual(try modificationDate(of: file), past)
    }

    func testActivitySurvivesBackwardClockJump() async throws {
        let file = root.appendingPathComponent("observed-activity.json")
        let runner = InstalledRunner(name: "observed", directory: root)
        func snapshot(_ status: RunnerStatus) -> [RunnerSnapshot] { [RunnerSnapshot(runner: runner, status: status)] }
        let store = RunnerActivityStore(fileURL: file)
        for second in stride(from: 0.0, through: 60, by: 3) {
            try await store.record(snapshots: snapshot(.idle), at: Date(timeIntervalSince1970: second))
        }
        try await store.record(snapshots: snapshot(.stopped), at: Date(timeIntervalSince1970: 63))
        // The clock is corrected 50 seconds backwards while the runner comes back online.
        for second in stride(from: 13.0, through: 100, by: 3) {
            try await store.record(snapshots: snapshot(.idle), at: Date(timeIntervalSince1970: second))
        }
        // Coverage resumes once the corrected clock passes the saved end at 60: 0...60 plus 61...100.
        let now = Date(timeIntervalSince1970: 100)
        let live = try await store.metrics(for: runner.id, now: now, window: 3600)
        XCTAssertEqual(live.observedSeconds, 99)
        XCTAssertEqual(live.busySeconds, 0)
        let reloaded = try await RunnerActivityStore(fileURL: file).metrics(for: runner.id, now: now, window: 3600)
        XCTAssertGreaterThan(reloaded.observedSeconds, 60)
        XCTAssertLessThanOrEqual(reloaded.observedSeconds, 100)
        XCTAssertEqual(reloaded.busySeconds, 0)
    }

    func testActivityLoadsOverlappingSavedObservations() async throws {
        let file = root.appendingPathComponent("observed-activity.json")
        let runner = InstalledRunner(name: "observed", directory: root)
        try Data("""
        {"schemaVersion":1,"samples":{"\(runner.id)":{"date":150,"busy":true}},"segments":[
         {"runnerID":"\(runner.id)","start":0,"end":100,"busy":false},
         {"runnerID":"\(runner.id)","start":10,"end":20,"busy":true},
         {"runnerID":"\(runner.id)","start":50,"end":150,"busy":true}]}
        """.utf8).write(to: file)
        let store = RunnerActivityStore(fileURL: file)
        let usage = try await store.metrics(for: runner.id, now: Date(timeIntervalSince1970: 150), window: 3600)
        XCTAssertEqual(usage.observedSeconds, 150)
        XCTAssertEqual(usage.busySeconds, 50)
        try await store.record(snapshots: [RunnerSnapshot(runner: runner, status: .busy)], at: Date(timeIntervalSince1970: 155))
        let extended = try await store.metrics(for: runner.id, now: Date(timeIntervalSince1970: 155), window: 3600)
        XCTAssertEqual(extended.observedSeconds, 155)
        XCTAssertEqual(extended.busySeconds, 55)
    }

    func testActivityCheckpointsWhenSavedObservationsAreInTheFuture() async throws {
        let file = root.appendingPathComponent("observed-activity.json")
        let runner = InstalledRunner(name: "observed", directory: root)
        try Data("""
        {"schemaVersion":1,"samples":{"\(runner.id)":{"date":5000,"busy":false}},"segments":[{"runnerID":"\(runner.id)","start":4900,"end":5000,"busy":false}]}
        """.utf8).write(to: file)
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
        let store = RunnerActivityStore(fileURL: file)
        try await store.record(snapshots: [RunnerSnapshot(runner: runner, status: .idle)], at: Date(timeIntervalSince1970: 100))
        XCTAssertNotEqual(try modificationDate(of: file), past)
    }

    func testActivityMovesUnreadableFileAsideAndStartsOver() async throws {
        let runner = InstalledRunner(name: "observed", directory: root)
        let busy = [RunnerSnapshot(runner: runner, status: .busy)]
        for (name, contents) in [("text", "not json"), ("schema", #"{"schemaVersion":2,"samples":{},"segments":[]}"#)] {
            let file = root.appendingPathComponent(name).appendingPathComponent("observed-activity.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
            let store = RunnerActivityStore(fileURL: file)
            let empty = try await store.metrics(for: runner.id, now: Date(timeIntervalSince1970: 10))
            XCTAssertEqual(empty.observedSeconds, 0, name)
            let copies = try invalidCopies(of: file)
            XCTAssertEqual(copies.count, 1, name)
            XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, Data(contents.utf8), name)

            try await store.record(snapshots: busy, at: Date(timeIntervalSince1970: 0))
            try await store.record(snapshots: busy, at: Date(timeIntervalSince1970: 10))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), name)
            let usage = try await store.metrics(for: runner.id, now: Date(timeIntervalSince1970: 10))
            XCTAssertEqual(usage.busySeconds, 10, name)
        }
    }
}
