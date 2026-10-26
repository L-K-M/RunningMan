import XCTest
@testable import RunningManCore

final class GhostLapTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func lap(_ id: String, _ splits: [(String, Double)], outcome: JobOutcome = .success, at offset: Double = 0) -> LapRecord {
        let total = splits.reduce(0) { $0 + $1.1 }
        return LapRecord(jobID: id, finishedAt: start.addingTimeInterval(offset), outcome: outcome, seconds: total,
                         splits: splits.map { LapSplit(name: $0.0, seconds: $0.1, outcome: .success) })
    }

    /// Steps that started at `start`, one after another; nil seconds means still running.
    private func steps(_ items: [(String, Double?, JobStepOutcome)]) -> [JobStep] {
        var cursor = start
        return items.enumerated().map { index, item in
            defer { if let seconds = item.1 { cursor = cursor.addingTimeInterval(seconds) } }
            return JobStep(id: index, name: item.0, startedAt: cursor, finishedAt: item.1.map { cursor.addingTimeInterval($0) },
                           outcome: item.2, lines: [])
        }
    }

    private var usualReference: LapReference {
        let laps = [
            lap("a", [("Set up job", 3), ("Restore cache", 6), ("Build", 50)], at: 1),
            lap("b", [("Set up job", 4), ("Restore cache", 5), ("Build", 54)], at: 2),
            lap("c", [("Set up job", 3), ("Restore cache", 7), ("Build", 52)], at: 3),
        ]
        return LapReference.make(from: laps, pace: .usual)!
    }

    func testUsualPaceIsTheMedianOfSuccessfulRunsStepByStep() throws {
        let laps = [
            lap("a", [("Set up job", 3), ("Build", 50)], at: 1),
            lap("b", [("Set up job", 5), ("Build", 70)], at: 2),
            lap("c", [("Set up job", 4), ("Build", 60)], at: 3),
            lap("failed", [("Set up job", 1), ("Build", 2)], outcome: .failure, at: 4),
        ]
        let usual = try XCTUnwrap(LapReference.make(from: laps, pace: .usual))
        XCTAssertEqual(usual.pace, .usual)
        XCTAssertEqual(usual.sectors.map(\.seconds), [4, 60])
        XCTAssertEqual(usual.total, 64)
        XCTAssertEqual(usual.runs, 3, "A failed run stops early and would make the ghost look slow")
        XCTAssertEqual(usual.sectors[1].best, 50)
        XCTAssertEqual(usual.bestTotal, 53)
        XCTAssertEqual(try XCTUnwrap(LapReference.make(from: laps, pace: .best)).total, 53)
        XCTAssertEqual(try XCTUnwrap(LapReference.make(from: laps, pace: .last)).total, 64)
    }

    func testFewerThanThreeRunsReplayTheLastRunAndClaimNoBests() throws {
        let reference = try XCTUnwrap(LapReference.make(from: [lap("a", [("Build", 40)], at: 1), lap("b", [("Build", 30)], at: 2)], pace: .usual))
        XCTAssertEqual(reference.pace, .last)
        XCTAssertEqual(reference.total, 30)
        XCTAssertNil(reference.sectors[0].best)
        XCTAssertNil(reference.bestTotal)
        XCTAssertNil(LapReference.make(from: [lap("x", [("Build", 3)], outcome: .failure)], pace: .usual))
    }

    func testRepeatedStepNamesMatchByOccurrence() throws {
        let laps = (1...3).map { lap("\($0)", [("Run script", 2), ("Build", 30), ("Run script", 10)], at: Double($0)) }
        let reference = try XCTUnwrap(LapReference.make(from: laps, pace: .usual))
        let progress = LapProgress.make(steps: steps([("Run script", 2, .success), ("Build", 30, .success), ("Run script", nil, .running)]),
                                        reference: reference, jobStarted: start, isFinished: false, now: start.addingTimeInterval(33))
        XCTAssertEqual(progress.sectors.map(\.reference), [2, 30, 10])
        XCTAssertEqual(progress.currentSector, 2)
    }

    func testRunnerKeepsTheGhostsSpeedInsideAStepAndHoldsShortOfItsEnd() {
        let reference = usualReference  // 3, 6, 52 → 61
        let live = steps([("Set up job", 3, .success), ("Restore cache", nil, .running)])
        let early = LapProgress.make(steps: live, reference: reference, jobStarted: start, isFinished: false, now: start.addingTimeInterval(5))
        XCTAssertEqual(early.live, 5, accuracy: 0.001)
        XCTAssertEqual(early.ghost, 5, accuracy: 0.001)
        XCTAssertEqual(early.lead, 0, accuracy: 0.001)
        XCTAssertFalse(early.sectors[1].isOverrun)
        // The cache step runs long: the runner waits at 98% of its sector while the ghost runs on.
        let late = LapProgress.make(steps: live, reference: reference, jobStarted: start, isFinished: false, now: start.addingTimeInterval(30))
        XCTAssertEqual(late.live, 3 + 6 * LapProgress.runningCap, accuracy: 0.001)
        XCTAssertEqual(late.ghost, 30, accuracy: 0.001)
        XCTAssertEqual(late.lead, 30 - (3 + 6 * LapProgress.runningCap), accuracy: 0.001)
        XCTAssertTrue(late.sectors[1].isOverrun, "27 s against a usual 6 s is an overrun")
        XCTAssertEqual(late.remaining ?? 0, 0.9 + 52, accuracy: 0.001)
    }

    func testFinishingAStepEarlySurgesAheadAndSplitsItAsAPersonalBest() {
        let reference = usualReference
        let progress = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Restore cache", 6, .success), ("Build", 40, .success)]),
                                        reference: reference, jobStarted: start, isFinished: true, now: start.addingTimeInterval(60))
        XCTAssertEqual(progress.outcome, .success)
        XCTAssertEqual(progress.elapsed, 49)
        XCTAssertEqual(progress.live, 61)
        XCTAssertEqual(progress.lead, -12, accuracy: 0.001)
        XCTAssertEqual(progress.sectors[2].split, -12)
        XCTAssertTrue(progress.sectors[2].isPersonalBest, "Faster than every recorded Build")
        XCTAssertEqual(progress.sectors[0].split, 0, "Within two seconds is on pace")
        XCTAssertNil(progress.remaining)
    }

    func testAFailedStepStopsTheRunnerInsideItsSector() {
        let progress = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Restore cache", 6, .success), ("Build", 20, .failure)]),
                                        reference: usualReference, jobStarted: start, isFinished: true, now: start.addingTimeInterval(40))
        XCTAssertEqual(progress.outcome, .failure)
        XCTAssertEqual(progress.failedSector, 2)
        XCTAssertEqual(progress.live, 9 + 20, accuracy: 0.001)
        XCTAssertNil(progress.sectors[2].split)
        // Cleanup steps that run after the failure do not carry the runner past it.
        let cleanedUp = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Restore cache", 6, .success), ("Build", 20, .failure), ("Complete job", 1, .success)]),
                                         reference: usualReference, jobStarted: start, isFinished: true, now: start.addingTimeInterval(40))
        XCTAssertEqual(cleanedUp.live, 9 + 20, accuracy: 0.001)
        XCTAssertEqual(cleanedUp.outcome, .failure)
        // Nor does a cleanup step that is still running.
        let cleaning = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Restore cache", 6, .success), ("Build", 20, .failure), ("Complete job", nil, .running)]),
                                        reference: usualReference, jobStarted: start, isFinished: false, now: start.addingTimeInterval(31))
        XCTAssertEqual(cleaning.live, 9 + 20, accuracy: 0.001)
        XCTAssertEqual(cleaning.outcome, .failure)
    }

    func testAStepTheReferenceLacksGetsAZeroLengthSectorInPlace() {
        let progress = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Lint", 4, .success), ("Restore cache", nil, .running)]),
                                        reference: usualReference, jobStarted: start, isFinished: false, now: start.addingTimeInterval(9))
        XCTAssertEqual(progress.sectors.map(\.name), ["Set up job", "Lint", "Restore cache", "Build"])
        XCTAssertEqual(progress.sectors[1].reference, 0)
        XCTAssertEqual(progress.sectors[1].state, .finished(.success))
        XCTAssertEqual(progress.lead, 9 - (3 + 2), accuracy: 0.001, "Lint costs time the ghost never spends")
    }

    func testWithoutStepTimesTheGhostPacesTheWholeJob() throws {
        let laps = [60.0, 70, 80].enumerated().map { LapRecord(jobID: "\($0)", finishedAt: start.addingTimeInterval(Double($0)), outcome: .success, seconds: $1) }
        let reference = try XCTUnwrap(LapReference.make(from: laps, pace: .usual))
        XCTAssertEqual(reference.total, 70)
        let running = LapProgress.make(steps: [], reference: reference, jobStarted: start, isFinished: false, now: start.addingTimeInterval(30))
        XCTAssertEqual(running.sectors.count, 1)
        XCTAssertEqual(running.live, 30)
        XCTAssertEqual(running.remaining ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(running.lead, 0)
    }

    func testNoReferenceMeansNoLeadAndNoEstimate() {
        let progress = LapProgress.make(steps: steps([("Set up job", 2, .success), ("Build", nil, .running)]),
                                        reference: nil, jobStarted: start, isFinished: false, now: start.addingTimeInterval(10))
        XCTAssertEqual(progress.lead, 0)
        XCTAssertNil(progress.remaining)
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.sectors.count, 2)
    }

    func testLeadIsDescribedInWords() {
        XCTAssertEqual(LapProgress.describeLead(-14.2), "14 s ahead")
        XCTAssertEqual(LapProgress.describeLead(62), "1:02 behind")
        XCTAssertEqual(LapProgress.describeLead(0.3), "level")
    }

    func testLapFromAFinishedStepLog() throws {
        let log = JobStepLog(jobID: "job-1", runnerID: "/synthetic/runner", isFinished: true, hasOutput: true, isTruncated: false, revision: 1,
                             steps: steps([("Set up job", 2, .success), ("Build", 30, .success)]))
        let record = try XCTUnwrap(LapRecord(log: log, outcome: .success))
        XCTAssertEqual(record.seconds, 32)
        XCTAssertEqual(record.splits.map(\.seconds), [2, 30])
        let running = JobStepLog(jobID: "job-2", runnerID: "/synthetic/runner", isFinished: false, hasOutput: true, isTruncated: false, revision: 1,
                                 steps: steps([("Set up job", nil, .running)]))
        XCTAssertNil(LapRecord(log: running, outcome: .running))
    }

    func testLapBookKeepsTheNewestRunsPerJobAndIgnoresRepeats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lapbook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("laps.json")
        let key = LapKey(provider: .github, repository: "example/app", workflow: "CI", job: "Build")
        let book = LapBook(fileURL: url)
        for index in 0..<25 { await book.record(lap("run-\(index)", [("Build", Double(30 + index))], at: Double(index)), for: key) }
        let again = await book.record(lap("run-24", [("Build", 1)], at: 99), for: key)
        XCTAssertEqual(again.count, LapBook.lapsPerJob)
        XCTAssertEqual(again.first?.jobID, "run-5")
        XCTAssertEqual(again.last?.splits.first?.seconds, 54, "A repeat of a recorded job is ignored")
        let reloaded = await LapBook(fileURL: url).load()
        XCTAssertEqual(reloaded[key]?.count, LapBook.lapsPerJob)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAnUnreadableLapBookIsSetAsideAndStartsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lapbook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("laps.json")
        try Data("not json".utf8).write(to: url)
        let loaded = await LapBook(fileURL: url).load()
        XCTAssertTrue(loaded.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("laps.invalid-") }, "\(names)")
    }
}
