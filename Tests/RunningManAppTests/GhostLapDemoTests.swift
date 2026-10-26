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
}
