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
        XCTAssertEqual(late.lead, 30 - (3 + 6), accuracy: 0.001, "The lead counts the time past the step's usual length")
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
        let book24 = await book.record(lap("run-24", [("Build", 1)], at: 99), for: key)
        let again = try XCTUnwrap(book24[key])
        XCTAssertEqual(again.count, LapBook.lapsPerJob)
        XCTAssertEqual(again.first?.jobID, "run-5")
        XCTAssertEqual(again.last?.splits.first?.seconds, 54, "A repeat of a recorded job is ignored")
        let reloaded = await LapBook(fileURL: url).load()
        XCTAssertEqual(reloaded[key]?.count, LapBook.lapsPerJob)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAnUndecodableLapBookIsSetAsideAndStartsEmpty() async throws {
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

    func testTheJobsOwnOutcomeWinsOverItsSteps() {
        // A job cancelled between steps never crossed the line, however its steps ended.
        let cancelled = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Restore cache", 6, .success)]), reference: usualReference,
                                         jobStarted: start, isFinished: true, jobOutcome: .cancelled, now: start.addingTimeInterval(9))
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertEqual(cancelled.live, 9, accuracy: 0.001)
        // A failed step allowed to continue on error leaves the job successful.
        let continued = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Restore cache", 2, .failure), ("Build", 50, .success)]),
                                         reference: usualReference, jobStarted: start, isFinished: true, jobOutcome: .success, now: start.addingTimeInterval(55))
        XCTAssertEqual(continued.outcome, .success)
        XCTAssertEqual(continued.live, continued.total, accuracy: 0.001)
        // Until the job's outcome is known, its steps decide.
        let pending = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Restore cache", 6, .success), ("Build", 50, .success)]),
                                       reference: usualReference, jobStarted: start, isFinished: true, jobOutcome: .running, now: start.addingTimeInterval(59))
        XCTAssertEqual(pending.outcome, .success)
    }

    func testTheRunnerStaysWhereTheJobFirstStopped() {
        let progress = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Restore cache", 6, .success), ("Build", 20, .failure), ("Post cache", 4, .cancelled)]),
                                        reference: usualReference, jobStarted: start, isFinished: true, now: start.addingTimeInterval(40))
        XCTAssertEqual(progress.outcome, .failure)
        XCTAssertEqual(progress.failedSector, 2)
        XCTAssertEqual(progress.live, 9 + 20, accuracy: 0.001)
    }

    func testAReferenceStepTheRunPassedOverLeavesTheEstimate() {
        // This run restores no cache; once the build runs, that step is behind it.
        let progress = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Build", nil, .running)]),
                                        reference: usualReference, jobStarted: start, isFinished: false, now: start.addingTimeInterval(13))
        XCTAssertEqual(progress.remaining ?? 0, 52 - 10, accuracy: 0.001)
    }

    func testWholeJobPacingStopsAtAFailureWhileCleanupRuns() throws {
        let laps = [60.0, 70, 80].enumerated().map { LapRecord(jobID: "\($0)", finishedAt: start.addingTimeInterval(Double($0)), outcome: .success, seconds: $1) }
        let reference = try XCTUnwrap(LapReference.make(from: laps, pace: .usual))
        let progress = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Build", 20, .failure), ("Complete job", nil, .running)]),
                                        reference: reference, jobStarted: start, isFinished: false, now: start.addingTimeInterval(25))
        XCTAssertEqual(progress.outcome, .failure)
        XCTAssertEqual(progress.live, 23, accuracy: 0.001)
        XCTAssertNil(progress.remaining)
        // Without steps, the job's own outcome still decides the finish.
        let cancelled = LapProgress.make(steps: [], reference: reference, jobStarted: start, isFinished: true, jobOutcome: .cancelled,
                                         now: start.addingTimeInterval(30))
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertFalse(cancelled.sectors[0].isPersonalBest)
    }

    func testALapWithTooManyStepsIsKeptAsAWholeJob() async throws {
        let key = LapKey(provider: .github, repository: "example/app", workflow: "CI", job: "Matrix")
        let long = lap("long", (0..<(LapBook.maximumSplits + 1)).map { ("Step \($0)", 1.0) })
        let book = await LapBook(fileURL: nil).record(long, for: key)
        let stored = try XCTUnwrap(book[key]?.first)
        XCTAssertTrue(stored.splits.isEmpty, "Cutting steps off would make the ghost finish early")
        XCTAssertEqual(stored.seconds, Double(LapBook.maximumSplits + 1))
    }

    func testRecordingReturnsTheWholeBookWithinItsBounds() async {
        let book = LapBook(fileURL: nil)
        var latest: [LapKey: [LapRecord]] = [:]
        for index in 0...LapBook.maximumJobs {
            let key = LapKey(provider: .github, repository: "example/app", workflow: "CI", job: "Job \(index)")
            latest = await book.record(lap("run-\(index)", [("Build", 3)], at: Double(index)), for: key)
        }
        XCTAssertEqual(latest.count, LapBook.maximumJobs)
        XCTAssertNil(latest[LapKey(provider: .github, repository: "example/app", workflow: "CI", job: "Job 0")], "The job that ran longest ago goes first")
    }

    func testALoadedLapBookIsDeduplicatedOrderedAndBounded() async throws {
        struct Entry: Encodable { let key: LapKey; let laps: [LapRecord] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lapbook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("laps.json")
        let key = LapKey(provider: .github, repository: "example/app", workflow: "CI", job: "Build")
        let repeated = [lap("b", [("Build", 30)], at: 2), lap("a", [("Build", 31)], at: 1), lap("b", [("Build", 30)], at: 2), lap("b", [("Build", 30)], at: 2)]
        let long = lap("long", (0..<(LapBook.maximumSplits + 1)).map { ("Step \($0)", 1.0) }, at: 3)
        var entries = [Entry(key: key, laps: repeated + [long])]
        for index in 0..<(LapBook.maximumJobs + 5) {
            entries.append(Entry(key: LapKey(provider: .github, repository: "example/app", workflow: "CI", job: "Job \(index)"),
                                 laps: [lap("job-\(index)", [("Build", 3)], at: Double(index) - 1_000)]))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url)
        let loaded = await LapBook(fileURL: url).load()
        XCTAssertEqual(loaded[key]?.map(\.jobID), ["a", "b", "long"])
        XCTAssertEqual(loaded[key]?.last?.splits.isEmpty, true)
        XCTAssertEqual(loaded.count, LapBook.maximumJobs)
    }

    /// Steps as worker logs time them: starts to the fraction, ends in whole seconds, so a short
    /// gap separates each step's end from the next step's start.
    private func gappedSteps(_ items: [(String, start: Double, end: Double?, JobStepOutcome)]) -> [JobStep] {
        items.enumerated().map { index, item in
            JobStep(id: index, name: item.0, startedAt: start.addingTimeInterval(item.start), finishedAt: item.end.map { start.addingTimeInterval($0) },
                    outcome: item.3, lines: [])
        }
    }

    func testSplitsKeepTheTimeBetweenStepsSoAnIdenticalRunIsLevel() throws {
        let run = gappedSteps([("Set up job", 0, 2, .success), ("Build", 2.6, 30, .success), ("Upload", 30.4, 35, .success)])
        let log = JobStepLog(jobID: "a", runnerID: "r", isFinished: true, hasOutput: true, isTruncated: false, revision: 1, steps: run)
        let record = try XCTUnwrap(LapRecord(log: log, outcome: .success))
        XCTAssertEqual(record.splits.map(\.seconds).reduce(0, +), record.seconds, accuracy: 0.001)
        XCTAssertEqual(record.splits.map(\.seconds)[0], 2.6, accuracy: 0.001)
        let laps = ["a", "b", "c"].enumerated().map { LapRecord(jobID: $1, finishedAt: start.addingTimeInterval(Double($0)), outcome: .success,
                                                                 seconds: record.seconds, splits: record.splits) }
        let reference = try XCTUnwrap(LapReference.make(from: laps, pace: .usual))
        let again = LapProgress.make(steps: run, reference: reference, jobStarted: start, isFinished: true, jobOutcome: .success,
                                     now: start.addingTimeInterval(40))
        XCTAssertEqual(again.lead, 0, accuracy: 0.001, "The same run again is level, not behind by its gaps")
        XCTAssertEqual(again.sectors.compactMap(\.split), [0, 0, 0])
        // Mid-run, the gap after a finished step belongs to that step once the next one starts.
        let midway = LapProgress.make(steps: Array(run.prefix(2)).enumerated().map { index, step in
            index == 1 ? JobStep(id: 1, name: step.name, startedAt: step.startedAt, finishedAt: nil, outcome: .running, lines: []) : step
        }, reference: reference, jobStarted: start, isFinished: false, now: start.addingTimeInterval(10))
        XCTAssertEqual(midway.lead, 0, accuracy: 0.001)
    }

    func testTheLeadIsMeasuredAgainstTheGhostNotTheCappedRunner() throws {
        // A running step at exactly its usual time is level, though the figure waits at 98%.
        let reference = usualReference  // 3, 6, 52
        let level = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Restore cache", nil, .running)]), reference: reference,
                                     jobStarted: start, isFinished: false, now: start.addingTimeInterval(9))
        XCTAssertEqual(level.lead, 0, accuracy: 0.001)
        XCTAssertEqual(level.live, 3 + 6 * LapProgress.runningCap, accuracy: 0.001)
        let late = LapProgress.make(steps: steps([("Set up job", 3, .success), ("Restore cache", nil, .running)]), reference: reference,
                                    jobStarted: start, isFinished: false, now: start.addingTimeInterval(14))
        XCTAssertEqual(late.lead, 5, accuracy: 0.001)
        // Paced as a whole: level until the usual time, then behind by exactly the overrun.
        let laps = [600.0, 600, 600].enumerated().map { LapRecord(jobID: "\($0)", finishedAt: start.addingTimeInterval(Double($0)), outcome: .success, seconds: $1) }
        let whole = try XCTUnwrap(LapReference.make(from: laps, pace: .usual))
        let before = LapProgress.make(steps: [], reference: whole, jobStarted: start, isFinished: false, now: start.addingTimeInterval(595))
        XCTAssertEqual(before.lead, 0, accuracy: 0.001)
        let after = LapProgress.make(steps: [], reference: whole, jobStarted: start, isFinished: false, now: start.addingTimeInterval(660))
        XCTAssertEqual(after.lead, 60, accuracy: 0.001)
    }

    func testOnlyAWholeTimelineMakesALap() {
        let finished = steps([("Set up job", 2, .success), ("Build", 30, .success)])
        let partial = JobStepLog(jobID: "a", runnerID: "r", isFinished: true, hasOutput: true, isTruncated: false, revision: 1, steps: finished,
                                 isComplete: false)
        XCTAssertNil(LapRecord(log: partial, outcome: .success), "The listener said done before the worker log was read to its end")
        let cut = JobStepLog(jobID: "b", runnerID: "r", isFinished: true, hasOutput: true, isTruncated: false, revision: 1,
                             steps: steps([("Set up job", 2, .success), ("Build", nil, .unknown)]))
        XCTAssertNil(LapRecord(log: cut, outcome: .success), "A step without an end would shorten the lap")
    }

    func testSkippedRunsOfAStepStayOutOfItsBestAndHistory() throws {
        let laps = [
            lap("a", [("Build", 30), ("Publish", 45)], at: 1),
            LapRecord(jobID: "b", finishedAt: start.addingTimeInterval(2), outcome: .success, seconds: 30,
                      splits: [LapSplit(name: "Build", seconds: 30, outcome: .success), LapSplit(name: "Publish", seconds: 0, outcome: .skipped)]),
            lap("c", [("Build", 30), ("Publish", 44)], at: 3),
            lap("d", [("Build", 30), ("Publish", 46)], at: 4),
        ]
        let reference = try XCTUnwrap(LapReference.make(from: laps, pace: .usual))
        let publish = try XCTUnwrap(reference.sectors.first { $0.name == "Publish" })
        XCTAssertEqual(publish.history, [45, 44, 46])
        XCTAssertEqual(publish.best, 44)
    }

    func testAnUnreadableLapBookIsKeptAndNotOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lapbook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("laps.json")
        let key = LapKey(provider: .github, repository: "example/app", workflow: "CI", job: "Build")
        await LapBook(fileURL: url).record(lap("saved", [("Build", 30)], at: 1), for: key)
        let saved = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        let book = LapBook(fileURL: url)
        let unreadable = await book.load()
        XCTAssertTrue(unreadable.isEmpty)
        let held = await book.record(lap("new", [("Build", 31)], at: 2), for: key)
        XCTAssertEqual(held[key]?.map(\.jobID), ["new"], "Laps recorded meanwhile are kept in memory")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["laps.json"], "A file that could not be read is neither set aside nor replaced")

        // Once the file can be read again, the book merges what it held.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        let merged = await book.load()
        XCTAssertEqual(merged[key]?.map(\.jobID), ["saved", "new"])
    }
}
