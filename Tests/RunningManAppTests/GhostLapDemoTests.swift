import XCTest
import RunningManCore
@testable import RunningMan

/// The demo race tells a fixed story; these pin it so data changes cannot quietly flatten it.
final class GhostLapDemoTests: XCTestCase {
    @MainActor func testDemoRacesTellTheirStory() throws {
        let model = AppModel(demoMode: true)
        let job = try XCTUnwrap(model.runners[0].currentJob)
        let reference = try XCTUnwrap(model.lapReference(for: job))
        XCTAssertEqual(reference.runs, 20)
        let best = try XCTUnwrap(reference.bestTotal)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func finished(_ script: [AppModel.DemoRaceStep]) -> LapProgress {
            let end = start.addingTimeInterval(300)
            let log = AppModel.demoRaceLog(script, jobID: "synthetic", runnerID: "synthetic", start: start, now: end)
            XCTAssertTrue(log.isFinished)
            return LapProgress.make(steps: log.steps, reference: reference, jobStarted: start, isFinished: true, now: end)
        }

        // A cache miss, then a record build overtakes the ghost; second fastest overall.
        let opening = finished(AppModel.demoRaces[0])
        XCTAssertEqual(opening.outcome, .success)
        XCTAssertLessThan(opening.lead, -3)
        XCTAssertGreaterThan(opening.elapsed, best, "Not an overall record, so the clean run can be one")
        XCTAssertEqual(opening.sectors.filter(\.isPersonalBest).map(\.name), ["Build app bundle"])
        XCTAssertGreaterThan(try XCTUnwrap(opening.sectors.first { $0.name == "Restore build cache" }?.split), 10)

        // A clean run sets the record.
        XCTAssertLessThan(finished(AppModel.demoRaces[1]).elapsed, best)

        // The third run fails in its tests and the runner stays where it fell.
        let failing = finished(AppModel.demoRaces[2])
        XCTAssertEqual(failing.outcome, .failure)
        XCTAssertEqual(failing.failedSector.map { failing.sectors[$0].name }, "Run tests")

        // The demo opens during the build, behind the ghost, ten seconds before the build ends.
        let log = try XCTUnwrap(model.stepLogs[model.runners[0].id])
        let now = job.startedAt.addingTimeInterval(AppModel.demoRaceOpeningOffset)
        let live = LapTrack.progress(job: job, steps: log.steps, isFinished: false, reference: reference, now: now)
        XCTAssertEqual(live.currentSector.map { live.sectors[$0].name }, "Build app bundle")
        XCTAssertGreaterThan(live.lead, 8)
    }

    @MainActor func testDemoWritesNoLapBook() async {
        let model = AppModel(demoMode: true)
        XCTAssertFalse(model.laps.isEmpty)
        // Demo laps live in memory only; the book has no file.
        let stored = await model.lapBook.load()
        XCTAssertEqual(Set(stored.keys), Set(model.laps.keys))
    }

    @MainActor func testWholeJobReferenceComesFromHistoryWhenNoStepsWereRecorded() throws {
        let model = AppModel(demoMode: true)
        let job = try XCTUnwrap(model.jobs.first { $0.name == "Unit tests" && $0.outcome == .success })
        model.laps = [:]
        let reference = try XCTUnwrap(model.lapReference(for: job))
        XCTAssertTrue(reference.isWholeJob)
        XCTAssertGreaterThanOrEqual(reference.runs, 1)
    }

    @MainActor func testHistoryFromAnotherProviderDoesNotPaceAJob() throws {
        let model = AppModel(demoMode: true)
        model.laps = [:]
        let job = try XCTUnwrap(model.jobs.first { $0.name == "Unit tests" && $0.outcome == .success })
        let forgejo = try XCTUnwrap(model.runners.first { $0.runner.provider == .forgejo })
        XCTAssertEqual(model.lapKey(for: job).provider, .github)
        for index in model.jobs.indices where model.jobs[index].id != job.id && model.jobs[index].name == job.name {
            model.jobs[index].runnerID = forgejo.id
        }
        XCTAssertNil(model.lapReference(for: job), "A Forgejo run of the same name is a different job")
    }

    @MainActor func testTheCardStaysWhileAFinishIsStillArriving() throws {
        let model = AppModel(demoMode: true)
        let runnerID = model.runners[0].id
        let job = try XCTUnwrap(model.runners[0].currentJob)
        // A refresh publishes runners before history and step logs: the job is no longer current
        // but is not finished yet either.
        model.runners[0].currentJob = nil
        XCTAssertEqual(model.lapJob(for: runnerID)?.id, job.id)
    }

    @MainActor func testAFinishedJobDisplacedFromItsStepLogIsRecorded() async throws {
        let model = AppModel(demoMode: true)
        var job = try XCTUnwrap(model.runners[0].currentJob)
        job.id = "synthetic-displaced"
        let start = job.startedAt
        job.finishedAt = start.addingTimeInterval(120)
        job.outcome = .success
        model.jobs.insert(job, at: 0)
        let log = AppModel.demoRaceLog(AppModel.demoRaces[1], jobID: job.id, runnerID: model.runners[0].id, start: start,
                                       now: start.addingTimeInterval(400))
        model.recordFinishedLaps(also: [log])
        await model.lapRecording?.value
        XCTAssertTrue(model.laps[model.lapKey(for: job)]?.contains { $0.jobID == job.id } ?? false)
    }

    @MainActor func testAJobThatNeverSucceededIsNotItsFirstRun() throws {
        let model = AppModel(demoMode: true)
        var job = try XCTUnwrap(model.jobs.first { $0.name == "Unit tests" && $0.outcome == .success })
        model.laps = [:]
        XCTAssertTrue(model.hasEarlierRuns(of: job))
        job.name = "A job never seen before"
        XCTAssertFalse(model.hasEarlierRuns(of: job))
    }

    /// Waits for the demo race to react to a change the user made, at most a few seconds.
    @MainActor private func waitForCancelledRun(_ model: AppModel) async throws -> RunnerJob? {
        for _ in 0..<50 {
            if let job = model.jobs.first(where: { $0.id == "demo-job-0" }), job.outcome == .cancelled { return job }
            try await Task.sleep(for: .milliseconds(100))
        }
        return model.jobs.first { $0.id == "demo-job-0" }
    }

    @MainActor func testStoppingTheRaceRunnerCancelsItsRun() async throws {
        let model = AppModel(demoMode: true)
        model.startDemoRace()
        defer { model.demoRaceTask?.cancel() }
        let runnerID = model.runners[0].id
        // What the demo's Stop does to a busy runner.
        model.runners[0].status = .stopped
        model.runners[0].currentJob = nil
        let job = try await waitForCancelledRun(model)
        XCTAssertEqual(job?.outcome, .cancelled)
        XCTAssertNotNil(job?.finishedAt, "An interrupted run must not stay Running in History")
        XCTAssertEqual(model.stepLogs[runnerID]?.isFinished, true)
        XCTAssertEqual(model.runners[0].status, .stopped)
    }

    @MainActor func testDisablingTheRaceRunnerEndsItsRun() async throws {
        let model = AppModel(demoMode: true)
        model.startDemoRace()
        defer { model.demoRaceTask?.cancel() }
        // What the demo's Disable does: the job stays assigned.
        model.runners[0].isEnabled = false
        model.runners[0].status = .disabled
        let job = try await waitForCancelledRun(model)
        XCTAssertEqual(job?.outcome, .cancelled)
        XCTAssertNil(model.runners[0].currentJob)
        XCTAssertEqual(model.runners[0].status, .disabled)
    }

    @MainActor func testTheDemoRaceStaysOnItsOwnRunner() {
        let model = AppModel(demoMode: true)
        // Only the GitHub runner races; Forgejo runners keep no local record of a running job.
        XCTAssertTrue(model.runners.filter { $0.runner.provider == .forgejo }.allSatisfy { model.lapJob(for: $0.id) == nil })
        let log = AppModel.demoRaceLog(AppModel.demoRaces[2], jobID: "synthetic", runnerID: "synthetic", start: Date(timeIntervalSince1970: 0),
                                       now: Date(timeIntervalSince1970: 400))
        let ids = log.steps.flatMap(\.lines).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Every output line has its own ID")
    }

    func testFinishRanksReadAsOrdinals() {
        XCTAssertEqual([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111, 112].map(LapCaption.ordinal),
                       ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st", "111th", "112th"])
    }
}
