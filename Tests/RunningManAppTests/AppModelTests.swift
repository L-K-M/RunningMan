import Foundation
import XCTest
import RunningManCore
import RunningManServices
@testable import RunningMan

final class AppModelTests: XCTestCase {
    @MainActor func testCleanupEvidenceIsSeparateFromJobSuccessAndSearchesRunner() {
        let model = AppModel(demoMode: true)
        XCTAssertEqual(model.cleanupRecords.count, 4)
        XCTAssertTrue(model.cleanupRecords.contains { $0.status == .pending && $0.finishedAt == nil })
        XCTAssertTrue(model.cleanupRecords.contains { $0.status == .failed })
        let jobsBefore = model.jobs
        model.section = .cleanup
        model.searchText = "nightly-checks"
        XCTAssertEqual(model.filteredCleanupRecords.count, 1)
        XCTAssertEqual(model.filteredCleanupRecords.first?.status, .failed)
        XCTAssertEqual(model.jobs, jobsBefore)
        XCTAssertNotNil(model.latestCleanup(for: model.runners[0].id))
        XCTAssertNil(model.latestCleanup(for: model.runners[4].id))
    }

    @MainActor func testBusyStopRequiresConfirmationAndCancellationPreservesRunner() {
        let model = AppModel(demoMode: true)
        let busy = model.runners.first { $0.status == .busy }!
        model.perform(.stop, on: busy)
        XCTAssertNotNil(model.confirmation)
        XCTAssertEqual(model.runners.first { $0.id == busy.id }?.status, .busy)
        model.cancelPendingAction()
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(model.runners.first { $0.id == busy.id }?.status, .busy)
        model.perform(.stop, on: busy)
        model.confirmPendingAction()
        XCTAssertEqual(model.runners.first { $0.id == busy.id }?.status, .stopped)
    }

    @MainActor func testDemoImportAndStartupNeverWriteRealPreferences() {
        let preferences = UserDefaults.standard
        let previousPaths = preferences.stringArray(forKey: "importedRunnerDirectories")
        let previousRefresh = preferences.object(forKey: "refreshAutomatically") as? Bool
        let previousAwake = preferences.object(forKey: "keepAwakeWhileBusy") as? Bool
        let model = AppModel(demoMode: true)
        model.importRunner()
        XCTAssertNotNil(model.errorMessage)
        model.refreshAutomatically = false
        model.keepAwakeWhileBusy = true
        let runner = model.runners[0]
        model.setStartup(false, for: runner)
        XCTAssertFalse(model.runners[0].startsAtLogin)
        XCTAssertEqual(preferences.stringArray(forKey: "importedRunnerDirectories"), previousPaths)
        XCTAssertEqual(preferences.object(forKey: "refreshAutomatically") as? Bool, previousRefresh)
        XCTAssertEqual(preferences.object(forKey: "keepAwakeWhileBusy") as? Bool, previousAwake)
    }

    @MainActor func testDemoCreationIsInMemoryAndRejectsUnsafeNames() async {
        let model = AppModel(demoMode: true)
        let initial = model.runners.count
        let invalid = await model.createRunner(githubURL: "https://github.com/example/weather", name: "../escape",
                                               labels: "release", startsAtLogin: true)
        XCTAssertFalse(invalid)
        XCTAssertEqual(model.runners.count, initial)
        let created = await model.createRunner(githubURL: "https://github.com/example/weather", name: "test-runner",
                                               labels: "release, arm", startsAtLogin: false)
        XCTAssertTrue(created)
        XCTAssertEqual(model.runners.count, initial + 1)
        XCTAssertEqual(model.selectedRunner?.runner.name, "test-runner")
        XCTAssertEqual(model.selectedRunner?.startsAtLogin, false)
    }

    @MainActor func testDemoForgejoCreationUsesNativeProviderAndRequestedCapacity() async {
        let model = AppModel(demoMode: true)
        let count = model.runners.count
        let created = await model.createForgejoRunner(server: "https://forge.example.com", scope: .repository,
            scopeName: "example/weather", name: "forge-test", labels: "macos-arm64:host", capacity: 3, startsAtLogin: false)
        XCTAssertTrue(created)
        XCTAssertEqual(model.runners.count, count + 1)
        XCTAssertEqual(model.selectedRunner?.runner.provider, .forgejo)
        XCTAssertEqual(model.selectedRunner?.runner.capacity, 3)
        XCTAssertEqual(model.selectedRunner?.startsAtLogin, false)
        XCTAssertEqual(model.selectedRunner?.runner.directory.path, "/Users/demo/Runners/forge-test")
    }

    @MainActor func testUnknownActivityRequiresExplicitStopAndDrainDoesNotInterrupt() {
        let model = AppModel(demoMode: true)
        var runner = model.runners[0]
        runner.status = .unknown
        runner.processID = 9001
        model.runners[0] = runner
        model.perform(.drain, on: runner)
        XCTAssertTrue(model.drainingRunnerIDs.contains(runner.id))
        XCTAssertEqual(model.runners[0].status, .unknown)
        XCTAssertNil(model.confirmation)
        model.perform(.stop, on: runner)
        XCTAssertNotNil(model.confirmation)
        XCTAssertEqual(model.runners[0].status, .unknown)
        model.cancelPendingAction()
        XCTAssertEqual(model.runners[0].status, .unknown)
    }

    @MainActor func testStopAfterJobEndsWhenRunnerStopsOutsideRunningMan() {
        let model = AppModel(demoMode: true)
        let busy = model.runners.first { $0.status == .busy && $0.runner.provider == .github }!
        model.perform(.drain, on: busy)
        XCTAssertTrue(model.drainingRunnerIDs.contains(busy.id))
        let index = model.runners.firstIndex { $0.id == busy.id }!
        model.runners[index].status = .stopped
        model.runners[index].processID = nil
        model.runners[index].currentJob = nil
        model.processDrainRequests()
        XCTAssertFalse(model.drainingRunnerIDs.contains(busy.id))
        XCTAssertTrue(model.events.contains { $0.title == "Stop after job ended: \(busy.runner.name) is no longer running" })
        // A later manual start must not be followed by an automatic stop.
        model.runners[index].status = .idle
        model.runners[index].processID = 8040
        model.processDrainRequests()
        XCTAssertEqual(model.runners[index].status, .idle)
        // Starting a runner ends a request left over from before it stopped.
        model.runners[index].status = .stopped
        model.runners[index].processID = nil
        model.drainingRunnerIDs.insert(busy.id)
        model.perform(.start, on: model.runners[index])
        XCTAssertFalse(model.drainingRunnerIDs.contains(busy.id))
    }

    @MainActor func testStopAfterJobSurvivesUnverifiableStateAndEndsForRemovedRunner() {
        let model = AppModel(demoMode: true)
        let busy = model.runners.first { $0.status == .busy && $0.runner.provider == .github }!
        model.perform(.drain, on: busy)
        let index = model.runners.firstIndex { $0.id == busy.id }!
        // A transient process-read failure is not evidence that the runner stopped.
        model.runners[index].status = .unknown
        model.runners[index].processID = nil
        model.processDrainRequests()
        XCTAssertTrue(model.drainingRunnerIDs.contains(busy.id))
        model.runners.remove(at: index)
        model.processDrainRequests()
        XCTAssertTrue(model.drainingRunnerIDs.isEmpty)
        XCTAssertTrue(model.events.contains { $0.title == "Stop after job ended: \(busy.runner.name) is no longer running" })
    }

    @MainActor func testStopAfterJobEndsWhenActivityStaysUnverifiable() {
        let model = AppModel(demoMode: true)
        let busy = model.runners.first { $0.status == .busy && $0.runner.provider == .github }!
        model.perform(.drain, on: busy)
        let index = model.runners.firstIndex { $0.id == busy.id }!
        let start = Date()
        model.runners[index].status = .unknown
        model.processDrainRequests(now: start)
        model.processDrainRequests(now: start.addingTimeInterval(AppModel.drainUnknownLimit - 1))
        XCTAssertTrue(model.drainingRunnerIDs.contains(busy.id))
        // A verified state in between restarts the wait.
        model.runners[index].status = .busy
        model.processDrainRequests(now: start.addingTimeInterval(AppModel.drainUnknownLimit))
        model.runners[index].status = .unknown
        model.processDrainRequests(now: start.addingTimeInterval(AppModel.drainUnknownLimit + 1))
        XCTAssertTrue(model.drainingRunnerIDs.contains(busy.id))
        model.processDrainRequests(now: start.addingTimeInterval(2 * AppModel.drainUnknownLimit + 1))
        XCTAssertFalse(model.drainingRunnerIDs.contains(busy.id))
        XCTAssertTrue(model.events.contains { $0.title == "Stop after job cancelled: \(busy.runner.name)’s activity could not be verified" })
    }

    @MainActor func testStopAfterJobCanBeCancelledWhileAnActionRuns() {
        let model = AppModel(demoMode: true)
        let busy = model.runners.first { $0.status == .busy && $0.runner.provider == .github }!
        model.perform(.drain, on: busy)
        model.busyRunnerIDs.insert(busy.id)
        model.perform(.drain, on: busy)
        XCTAssertFalse(model.drainingRunnerIDs.contains(busy.id))
        // The in-flight stop failing afterwards concerns no request any more.
        model.noteAutomaticStopFailure(runnerID: busy.id, message: "Synthetic failure")
        XCTAssertFalse(model.events.contains { $0.kind == .failure && $0.runnerID == busy.id })
        XCTAssertNil(model.drainFailures[busy.id])
        // A new request still waits for the action to finish.
        model.perform(.drain, on: busy)
        XCTAssertFalse(model.drainingRunnerIDs.contains(busy.id))
    }

    @MainActor func testEndedDrainRequestsIgnoreRunnersWithActionsInProgress() {
        let runner = InstalledRunner(name: "synthetic", directory: URL(fileURLWithPath: "/synthetic/runner"))
        let stopped = RunnerSnapshot(runner: runner, status: .stopped)
        XCTAssertEqual(AppModel.endedDrainRequests([runner.id, "/synthetic/gone"], runners: [stopped], inProgress: []),
                       [runner.id, "/synthetic/gone"])
        XCTAssertEqual(AppModel.endedDrainRequests([runner.id], runners: [stopped], inProgress: [runner.id]), [])
        XCTAssertEqual(AppModel.endedDrainRequests([runner.id], runners: [RunnerSnapshot(runner: runner, status: .disabled, processID: 42)],
                                                   inProgress: []), [])
    }

    @MainActor func testForgejoStopAfterJobCanBeCancelledAfterMonitoringTurnsOff() {
        let model = AppModel(demoMode: true)
        let forgejo = model.runners.first { $0.runner.provider == .forgejo && $0.status == .busy }!
        model.perform(.drain, on: forgejo)
        XCTAssertTrue(model.drainingRunnerIDs.contains(forgejo.id))
        model.remoteMonitoringEnabled = false
        XCTAssertFalse(model.drainingRunnerIDs.contains(forgejo.id))
        XCTAssertTrue(model.events.contains {
            $0.title == "Stop after job cancelled: Forgejo activity can no longer be verified" && $0.runnerID == forgejo.id
        })
        // A request restored from an earlier launch can still be cancelled while monitoring is off.
        model.drainingRunnerIDs.insert(forgejo.id)
        model.perform(.drain, on: forgejo)
        XCTAssertFalse(model.drainingRunnerIDs.contains(forgejo.id))
        XCTAssertNil(model.errorMessage)
        // A new request is refused because nothing could confirm the job finished.
        model.perform(.drain, on: forgejo)
        XCTAssertFalse(model.drainingRunnerIDs.contains(forgejo.id))
        XCTAssertNotNil(model.errorMessage)
        // A restored request is ended by the next refresh instead of waiting forever.
        model.drainingRunnerIDs.insert(forgejo.id)
        model.processDrainRequests()
        XCTAssertFalse(model.drainingRunnerIDs.contains(forgejo.id))
    }

    @MainActor func testForgejoStopAfterJobRequiresVerifiableActivity() {
        let model = AppModel(demoMode: true)
        let index = model.runners.firstIndex { $0.runner.provider == .forgejo && $0.status == .idle }!
        model.runners[index].status = .unknown
        let runner = model.runners[index]
        model.perform(.drain, on: runner)
        XCTAssertFalse(model.drainingRunnerIDs.contains(runner.id))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(model.runners[index].status, .unknown)
    }

    @MainActor func testConfirmedStopDoesNotRunWhileAnotherActionOwnsTheRunner() {
        let model = AppModel(demoMode: true)
        let busy = model.runners.first { $0.status == .busy && $0.runner.provider == .github }!
        model.perform(.stop, on: busy)
        XCTAssertNotNil(model.confirmation)
        model.busyRunnerIDs.insert(busy.id)
        model.confirmPendingAction()
        XCTAssertNil(model.confirmation)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.runners.first { $0.id == busy.id }?.status, .busy)
        XCTAssertTrue(model.busyRunnerIDs.contains(busy.id))
    }

    @MainActor func testConfirmedActionForRemovedRunnerReportsErrorAndDoesNothing() {
        let model = AppModel(demoMode: true)
        let busy = model.runners.first { $0.status == .busy && $0.runner.provider == .github }!
        model.perform(.delete, on: busy)
        XCTAssertNotNil(model.confirmation)
        model.runners.removeAll { $0.id == busy.id }
        let remaining = model.runners
        let eventCount = model.events.count
        model.confirmPendingAction()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.runners, remaining)
        XCTAssertEqual(model.events.count, eventCount)
    }

    @MainActor func testClearHistoryStillRequiresConfirmation() async throws {
        let model = AppModel(demoMode: true)
        XCTAssertFalse(model.jobs.isEmpty)
        model.clearHistory()
        XCTAssertNotNil(model.confirmation)
        model.cancelPendingAction()
        XCTAssertFalse(model.jobs.isEmpty)
        model.clearHistory()
        model.confirmPendingAction()
        for _ in 0..<50 where !model.jobs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.jobs.isEmpty)
    }

    @MainActor func testDemoStopAfterJobFinishesTheJobAndStopsTheRunner() async throws {
        let model = AppModel(demoMode: true)
        model.demoDrainDelay = .milliseconds(20)
        let busy = model.runners.first { $0.status == .busy && $0.runner.provider == .github }!
        let jobID = try XCTUnwrap(busy.currentJob?.id)
        model.perform(.drain, on: busy)
        XCTAssertEqual(model.runners.first { $0.id == busy.id }?.status, .busy)
        for _ in 0..<200 where model.drainingRunnerIDs.contains(busy.id) { try await Task.sleep(for: .milliseconds(10)) }
        let runner = try XCTUnwrap(model.runners.first { $0.id == busy.id })
        XCTAssertEqual(runner.status, .stopped)
        XCTAssertNil(runner.processID)
        XCTAssertNil(runner.currentJob)
        XCTAssertFalse(model.drainingRunnerIDs.contains(busy.id))
        let job = try XCTUnwrap(model.jobs.first { $0.id == jobID })
        XCTAssertEqual(job.outcome, .success)
        XCTAssertNotNil(job.finishedAt)

        // An idle runner still stops at once.
        let idle = model.runners.first { $0.status == .idle && $0.runner.provider == .github }!
        model.perform(.drain, on: idle)
        XCTAssertEqual(model.runners.first { $0.id == idle.id }?.status, .stopped)
    }

    @MainActor func testCancelledDemoStopAfterJobLeavesTheRunnerBusy() async throws {
        let model = AppModel(demoMode: true)
        model.demoDrainDelay = .milliseconds(20)
        let forgejo = model.runners.first { $0.status == .busy && $0.runner.provider == .forgejo }!
        model.perform(.drain, on: forgejo)
        model.perform(.drain, on: forgejo)
        XCTAssertFalse(model.drainingRunnerIDs.contains(forgejo.id))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.runners.first { $0.id == forgejo.id }?.status, .busy)
    }

    func testDrainRequestStoreRoundTripsThroughSuite() throws {
        let suiteName = "RunningManTests.drain.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let ids: Set<String> = ["/synthetic/runners/alpha", "/synthetic/runners/beta"]
        DrainRequestStore(defaults: defaults).save(ids)
        XCTAssertEqual(DrainRequestStore(defaults: defaults).load(), ids)
        DrainRequestStore(defaults: defaults).save([])
        XCTAssertNil(defaults.object(forKey: DrainRequestStore.key))
        XCTAssertEqual(DrainRequestStore(defaults: defaults).load(), [])
        defaults.set(["relative/path", "/synthetic/runners/gamma"], forKey: DrainRequestStore.key)
        XCTAssertEqual(DrainRequestStore(defaults: defaults).load(), ["/synthetic/runners/gamma"])
    }

    @MainActor func testDemoStopAfterJobNeverWritesPreferencesOrAsksBeforeQuitting() {
        let before = UserDefaults.standard.stringArray(forKey: DrainRequestStore.key)
        let model = AppModel(demoMode: true)
        let busy = model.runners.first { $0.status == .busy && $0.runner.provider == .github }!
        model.perform(.drain, on: busy)
        XCTAssertTrue(model.drainingRunnerIDs.contains(busy.id))
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: DrainRequestStore.key), before)
        XCTAssertNil(model.quitWarning)
    }

    func testQuitWarningNamesEveryInterruptedOperation() throws {
        XCTAssertNil(AppModel.quitWarning(isCreating: false, actionsInProgress: 0, drainRequests: 0))
        let drains = try XCTUnwrap(AppModel.quitWarning(isCreating: false, actionsInProgress: 0, drainRequests: 2))
        XCTAssertEqual(drains.title, "Quit while runners wait to stop?")
        XCTAssertTrue(drains.message.contains("2 runners are waiting to stop after their jobs."))
        XCTAssertTrue(drains.message.contains("must be running"))
        let all = try XCTUnwrap(AppModel.quitWarning(isCreating: true, actionsInProgress: 1, drainRequests: 1))
        XCTAssertEqual(all.title, "Quit while a runner is being created?")
        XCTAssertTrue(all.message.contains("A runner is being created."))
        XCTAssertTrue(all.message.contains("A runner action is still in progress"))
        XCTAssertTrue(all.message.contains("1 runner is waiting to stop after its job."))
    }

    func testDrainFailureRetriesBackOffAndCapAtFiveMinutes() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var failure: DrainFailure?
        var delays: [TimeInterval] = []
        for _ in 0..<6 {
            failure = DrainFailure.after(failure, message: "Synthetic failure", at: start)
            delays.append(failure!.retryDate.timeIntervalSince(start))
        }
        XCTAssertEqual(delays, [30, 60, 120, 240, 300, 300])
        XCTAssertFalse(DrainFailure(attempts: DrainFailure.attemptLimit - 1, message: "", date: start).exhaustsAttempts)
        XCTAssertTrue(DrainFailure(attempts: DrainFailure.attemptLimit, message: "", date: start).exhaustsAttempts)
    }

    @MainActor func testAutomaticStopFailuresStayQuietAndGiveUpWithWarning() {
        let model = AppModel(demoMode: true)
        let busy = model.runners.first { $0.status == .busy && $0.runner.provider == .github }!
        model.perform(.drain, on: busy)
        let start = Date()
        let reason = "Cannot verify whether this runner is busy. No action was taken."
        model.noteAutomaticStopFailure(runnerID: busy.id, message: reason, at: start)
        model.noteAutomaticStopFailure(runnerID: busy.id, message: reason, at: start.addingTimeInterval(31))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.events.filter { $0.title == "Automatic stop failed" }.count, 1)
        XCTAssertEqual(model.drainFailures[busy.id]?.attempts, 2)
        for attempt in 3...DrainFailure.attemptLimit {
            model.noteAutomaticStopFailure(runnerID: busy.id, message: "Synthetic launchctl failure \(attempt)",
                                           at: start.addingTimeInterval(Double(attempt) * 300))
        }
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.drainingRunnerIDs.contains(busy.id))
        XCTAssertNil(model.drainFailures[busy.id])
        XCTAssertEqual(model.events.filter { $0.title == "Automatic stop failed" }.count, DrainFailure.attemptLimit - 2)
        XCTAssertTrue(model.events.contains {
            $0.title == "Stop after job cancelled: \(busy.runner.name) could not be stopped" && $0.kind == .warning
        })
    }

    @MainActor func testAutomaticStopWaitsForBackoffBeforeRetrying() {
        let model = AppModel(demoMode: true)
        let idle = model.runners.first { $0.status == .idle && $0.runner.provider == .github }!
        model.drainingRunnerIDs.insert(idle.id)
        let start = Date()
        model.noteAutomaticStopFailure(runnerID: idle.id, message: "Synthetic failure", at: start)
        model.processDrainRequests(now: start.addingTimeInterval(29))
        XCTAssertEqual(model.runners.first { $0.id == idle.id }?.status, .idle)
        XCTAssertTrue(model.drainingRunnerIDs.contains(idle.id))
        model.processDrainRequests(now: start.addingTimeInterval(31))
        XCTAssertEqual(model.runners.first { $0.id == idle.id }?.status, .stopped)
        XCTAssertFalse(model.drainingRunnerIDs.contains(idle.id))
        XCTAssertNil(model.drainFailures[idle.id])
    }

    func testHistoricalActivityDeduplicatesAcrossRelaunchAndDatePrecision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("activity.json")
        let first = ActivityEvent(date: Date(timeIntervalSince1970: 1_700_000_000.123),
            runnerID: "/synthetic/runner", title: "Job completed", detail: "Build", kind: .success)
        let store = ActivityStore(url: url)
        await store.append(first)
        let reloaded = ActivityStore(url: url)
        let repeated = ActivityEvent(date: first.date, runnerID: first.runnerID, title: first.title,
                                    detail: first.detail, kind: first.kind)
        await reloaded.append(repeated)
        let values = await reloaded.load()
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(ActivityIdentity(values[0]), ActivityIdentity(repeated))
    }
}
