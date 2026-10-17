import Foundation
import Observation
import XCTest
import RunningManCore
@testable import RunningMan

final class QuietPollingTests: XCTestCase {
    @MainActor func testRefreshWithinTheSameMinuteDoesNotRepublishLastUpdated() async throws {
        let model = AppModel(demoMode: true)
        let before = try XCTUnwrap(model.lastUpdated)
        let changed = ObservationFlag()
        withObservationTracking { _ = model.lastUpdated } onChange: { changed.set() }
        await model.refresh()
        let minute = { (date: Date) in (date.timeIntervalSince1970 / 60).rounded(.down) }
        guard minute(before) == minute(Date()) else { throw XCTSkip("A minute boundary passed during the test.") }
        XCTAssertFalse(changed.value, "A refresh in the same minute must not invalidate views showing the time.")
        XCTAssertEqual(model.lastUpdated, before)
    }

    @MainActor func testRequestsDuringAPassRunExactlyOneFollowUpBeforeTheirCallersReturn() async {
        let coalescer = RefreshCoalescer()
        let gate = Gate()
        let log = Recorder()
        let poll = Task { @MainActor in
            await coalescer.run {
                let pass = coalescer.passCount
                log.entries.append("pass \(pass) start")
                await gate.wait()
                log.entries.append("pass \(pass) end")
            }
        }
        while coalescer.passCount == 0 { await Task.yield() }

        // Both requests arrive while pass 1 waits at the gate. Counting a request and
        // reaching the coalescer happen in one main-actor job, so a counted request
        // is already registered there.
        let registered = Recorder()
        let actions = (1...2).map { index in
            Task { @MainActor in
                registered.count += 1
                await coalescer.run { log.entries.append("unexpected operation \(index)") }
                log.entries.append("action \(index) resumed")
            }
        }
        while registered.count < 2 { await Task.yield() }
        XCTAssertEqual(coalescer.passCount, 1)
        XCTAssertTrue(coalescer.hasPendingFollowUp)
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("action") }, "A coalesced request must wait for its follow-up pass.")

        gate.open()
        await poll.value
        for action in actions { await action.value }

        XCTAssertEqual(coalescer.passCount, 2, "Two requests during one pass coalesce into exactly one follow-up.")
        XCTAssertFalse(coalescer.hasPendingFollowUp)
        XCTAssertEqual(Array(log.entries.prefix(4)), ["pass 1 start", "pass 1 end", "pass 2 start", "pass 2 end"])
        XCTAssertEqual(Set(log.entries.dropFirst(4)), ["action 1 resumed", "action 2 resumed"])
    }

    @MainActor func testIdleRequestRunsOnePassImmediately() async {
        let coalescer = RefreshCoalescer()
        var passes = 0
        await coalescer.run { passes += 1 }
        await coalescer.run { passes += 1 }
        XCTAssertEqual(passes, 2)
        XCTAssertEqual(coalescer.passCount, 2)
    }

    @MainActor func testOnlyManualRefreshPublishesProgress() async {
        let model = AppModel(demoMode: true)
        let manualChanged = ObservationFlag()
        withObservationTracking { _ = model.isManualRefreshing } onChange: { manualChanged.set() }
        await model.refresh()
        XCTAssertFalse(manualChanged.value, "Background polls must not animate the toolbar.")
        XCTAssertEqual(model.refreshPassCount, 1)

        withObservationTracking { _ = model.isManualRefreshing } onChange: { manualChanged.set() }
        await model.refreshNow()
        XCTAssertTrue(manualChanged.value)
        XCTAssertFalse(model.isManualRefreshing)
        XCTAssertEqual(model.refreshPassCount, 2)
    }

    @MainActor func testDerivedCachesMatchDirectComputationForDemoData() throws {
        let model = AppModel(demoMode: true)
        let newestFirst: (RunnerJob, RunnerJob) -> Bool = { $0.startedAt > $1.startedAt }
        XCTAssertFalse(model.jobs.isEmpty)
        for snapshot in model.runners {
            let expected = model.jobs.filter { $0.runnerID == snapshot.id }.sorted(by: newestFirst)
            XCTAssertEqual(model.jobs(for: snapshot.id), expected)
            XCTAssertEqual(model.jobCount(for: snapshot.id), expected.count)
            let cached = model.usage(for: snapshot.runner)
            XCTAssertEqual(cached, RunnerUsage.calculate(runner: snapshot.runner, jobs: model.jobs, now: cached.windowEnd))
            XCTAssertEqual(model.runnerName(for: snapshot.id), snapshot.runner.name)
        }
        XCTAssertEqual(model.recentJobs, Array(model.jobs.sorted(by: newestFirst).prefix(4)))
        XCTAssertEqual(model.filteredJobs, model.jobs.sorted(by: newestFirst))
        let completed = model.jobs.filter { [.success, .failure, .cancelled].contains($0.outcome) }
        let successRate = try XCTUnwrap(model.successRate)
        XCTAssertEqual(successRate, Double(model.jobs.filter { $0.outcome == .success }.count) / Double(completed.count), accuracy: 1e-12)

        let scopes = try XCTUnwrap(model.workload?.scopes)
        for snapshot in model.runners {
            var expected: Int?
            if let scope = scopes.first(where: { $0.runnerIDs.contains(snapshot.id) }), let queued = scope.compatibleQueuedJobs,
               let labels = scope.runnerLabels[snapshot.id] {
                expected = queued.filter { WorkloadScopeSnapshot.matches(jobLabels: $0.labels, runnerLabels: labels, provider: scope.provider) }.count
            }
            XCTAssertEqual(model.compatibleQueueCount(for: snapshot.id), expected, snapshot.runner.name)
        }
        XCTAssertEqual(model.compatibleQueueCount(for: model.runners[0].id), 3)
        var compatible: [String: WorkloadJob] = [:]
        for scope in scopes {
            guard let queued = scope.compatibleQueuedJobs, let running = scope.compatibleRunningJobs else { continue }
            for job in queued + running { compatible[job.id] = job }
        }
        let queued = compatible.values.filter { $0.state == .queued }
        XCTAssertEqual(model.fleetQueue.queuedCount, queued.count)
        XCTAssertEqual(model.fleetQueue.oldestQueuedAt, queued.compactMap(\.createdAt).min())
        XCTAssertTrue(model.fleetQueue.hasQueueEvidence)
        XCTAssertTrue(model.fleetQueue.isIncomplete, "The demo Forgejo scope is partial.")
    }

    @MainActor func testFleetQueueIgnoresWorkloadSearch() {
        let model = AppModel(demoMode: true)
        let fleet = model.fleetQueue
        model.section = .workload
        model.searchText = "WeatherKit"
        XCTAssertLessThan(model.visibleWorkloadScopes.count, model.workload?.scopes.count ?? 0)
        XCTAssertEqual(model.fleetQueue, fleet)
    }

    @MainActor func testEqualSourceAssignmentLeavesCachesUnpublishedAndRealChangesUpdateThem() {
        let model = AppModel(demoMode: true)
        let cachesChanged = ObservationFlag()
        withObservationTracking {
            _ = model.sortedJobs; _ = model.jobsByRunner; _ = model.recentJobs; _ = model.usageByRunner
            _ = model.runnerNames; _ = model.compatibleQueueByRunner; _ = model.fleetQueue
            _ = model.successfulJobs; _ = model.completedJobCount
        } onChange: { cachesChanged.set() }
        model.jobs = model.jobs
        model.runners = model.runners
        var busy = model.runners[1]
        busy.status = .busy
        model.runners[1] = busy
        XCTAssertFalse(cachesChanged.value, "Equal data or a status change must not invalidate job and usage caches.")

        let runner = model.runners[1]
        let job = RunnerJob(id: "synthetic-new-job", runnerID: runner.id, name: "Synthetic job",
                            startedAt: Date().addingTimeInterval(-60), finishedAt: Date().addingTimeInterval(-5), outcome: .success)
        let previousUsage = model.usage(for: runner.runner)
        model.jobs.append(job)
        XCTAssertTrue(cachesChanged.value)
        XCTAssertEqual(model.jobs(for: runner.id).first, job)
        XCTAssertEqual(model.recentJobs.first, job)
        XCTAssertEqual(model.usage(for: runner.runner).completedJobs, previousUsage.completedJobs + 1)
    }

    func testObservedUsagePublishesOnlyDisplayedChanges() {
        func usage(observed: TimeInterval, busy: TimeInterval) -> [String: ObservedRunnerUsage] {
            let end = Date(timeIntervalSince1970: 2_000_000_000)
            return ["runner": ObservedRunnerUsage(observedSeconds: observed, busySeconds: busy, busyFraction: busy / observed,
                                                  windowStart: end.addingTimeInterval(-86_400), windowEnd: end)]
        }
        let current = usage(observed: 600, busy: 300)
        XCTAssertFalse(AppModel.observedUsageDisplayChanged(from: current, to: usage(observed: 630, busy: 315)),
                       "Seconds within the same minute at the same rounded percentage are not displayed.")
        XCTAssertTrue(AppModel.observedUsageDisplayChanged(from: current, to: usage(observed: 660, busy: 330)))
        XCTAssertTrue(AppModel.observedUsageDisplayChanged(from: current, to: usage(observed: 630, busy: 340)))
        XCTAssertTrue(AppModel.observedUsageDisplayChanged(from: current, to: [:]))
        XCTAssertTrue(AppModel.observedUsageDisplayChanged(from: [:], to: current))
    }

    func testDisplayedMinuteComparison() {
        let minute = Date(timeIntervalSince1970: 2_000_000_080) // 40 seconds past a minute
        XCTAssertTrue(AppModel.isSameDisplayedMinute(minute, minute.addingTimeInterval(19)))
        XCTAssertFalse(AppModel.isSameDisplayedMinute(minute, minute.addingTimeInterval(20)))
        XCTAssertFalse(AppModel.isSameDisplayedMinute(nil, minute))
    }

    func testDayGroupsKeepOrderAndPutNewestDayFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let noon = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86_400) + 43_200)
        func job(_ id: String, _ offset: TimeInterval) -> RunnerJob {
            RunnerJob(id: id, runnerID: "/synthetic/runner", name: id, startedAt: noon.addingTimeInterval(offset))
        }
        let jobs = [job("a", 3_600), job("b", 0), job("c", -86_400), job("d", -90_000)]
        let groups = HistoryView.dayGroups(jobs, calendar: calendar)
        XCTAssertEqual(groups.map { $0.jobs.map(\.id) }, [["a", "b"], ["c", "d"]])
        XCTAssertEqual(groups.map(\.date), [calendar.startOfDay(for: noon), calendar.startOfDay(for: noon.addingTimeInterval(-86_400))])
        XCTAssertEqual(HistoryView.dayGroups([job("c", -86_400), job("a", 3_600), job("d", -90_000)], calendar: calendar)
            .map { $0.jobs.map(\.id) }, [["a"], ["c", "d"]], "Unsorted input still yields one group per day.")
    }

    func testDurationsOmitZeroComponents() {
        XCTAssertEqual(formattedDuration(0), "0s")
        XCTAssertEqual(formattedDuration(59), "59s")
        XCTAssertEqual(formattedDuration(60), "1m")
        XCTAssertEqual(formattedDuration(180), "3m")
        XCTAssertEqual(formattedDuration(184), "3m 4s")
        XCTAssertEqual(formattedDuration(3_600), "1h")
        XCTAssertEqual(formattedDuration(3_659), "1h")
        XCTAssertEqual(formattedDuration(3_660), "1h 1m")
        XCTAssertEqual(formattedDuration(7_200), "2h")
        XCTAssertEqual(formattedDuration(-5), "0s")
    }
}

@MainActor private final class Recorder {
    var entries: [String] = []
    var count = 0
}

/// Suspends refresh passes until a test opens it.
@MainActor private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Records an observation callback, which may arrive off the main actor.
private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
