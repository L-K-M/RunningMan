import XCTest
@testable import RunningManCore

final class NotificationPlannerTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_800_000_000)
    private let all = NotificationPreferences(jobFailures: true, jobSuccesses: true, unexpectedStops: true)
    private let runner = InstalledRunner(name: "build-example", directory: URL(fileURLWithPath: "/synthetic/runners/build-example"),
                                         githubURL: URL(string: "https://github.com/example/desktop"))

    private func job(_ id: String = "job-1", started: TimeInterval = 60, finished: TimeInterval? = nil,
                     outcome: JobOutcome = .running) -> RunnerJob {
        RunnerJob(id: id, runnerID: runner.id, name: "Unit tests", repository: "example/desktop",
                  startedAt: launch.addingTimeInterval(started), finishedAt: finished.map(launch.addingTimeInterval), outcome: outcome)
    }
    private func snapshot(_ status: RunnerStatus, pid: Int32? = nil, job: RunnerJob? = nil) -> RunnerSnapshot {
        RunnerSnapshot(runner: runner, status: status, processID: pid, currentJob: job)
    }
    private func plan(previousJobs: [RunnerJob] = [], currentJobs: [RunnerJob] = [],
                      previousRunners: [RunnerSnapshot] = [], currentRunners: [RunnerSnapshot] = [],
                      actions: [String: Date] = [:], notified: Set<String> = [],
                      preferences: NotificationPreferences? = nil, now: TimeInterval = 300) -> [PlannedNotification] {
        NotificationPlanner.plan(previousJobs: previousJobs, currentJobs: currentJobs,
                                 previousRunners: previousRunners, currentRunners: currentRunners,
                                 recentUserActions: actions, monitoringStartedAt: launch, alreadyNotified: notified,
                                 preferences: preferences ?? all, now: launch.addingTimeInterval(now))
    }

    func testHistoricalJobsReparsedAtLaunchNeverNotify() {
        let old = job(started: -600, finished: -300, outcome: .failure)
        XCTAssertTrue(plan(previousJobs: [], currentJobs: [old], now: 3).isEmpty)
        let unfinishedWhileClosed = job(started: -600)
        XCTAssertTrue(plan(previousJobs: [unfinishedWhileClosed], currentJobs: [old], now: 3).isEmpty)
    }

    func testRunningJobThatFailsNotifiesOnceWithContext() throws {
        let running = job()
        let failed = job(finished: 200, outcome: .failure)
        let planned = plan(previousJobs: [running], currentJobs: [failed], currentRunners: [snapshot(.idle, pid: 42)])
        XCTAssertEqual(planned.count, 1)
        let item = try XCTUnwrap(planned.first)
        XCTAssertEqual(item.kind, .jobFailed)
        XCTAssertEqual(item.title, "Unit tests failed")
        XCTAssertEqual(item.body, "example/desktop · build-example")
        XCTAssertEqual(item.runnerID, runner.id)
        XCTAssertEqual(item.jobID, failed.id)
    }

    func testRepeatedPlanningDoesNotDuplicate() {
        let running = job()
        let failed = job(finished: 200, outcome: .failure)
        let first = plan(previousJobs: [running], currentJobs: [failed])
        XCTAssertEqual(first.count, 1)
        // The same transition replayed, as after clearing saved history, is deduplicated by key.
        XCTAssertTrue(plan(previousJobs: [running], currentJobs: [failed], notified: Set(first.map(\.id))).isEmpty)
        // A later refresh sees the job already finished.
        XCTAssertTrue(plan(previousJobs: [failed], currentJobs: [failed], now: 303).isEmpty)
        let doubled = plan(previousJobs: [], currentJobs: [failed, failed])
        XCTAssertEqual(doubled.count, 1)
    }

    func testOutcomesFollowPreferences() {
        let running = job()
        let success = job(finished: 200, outcome: .success)
        let cancelled = job(finished: 200, outcome: .cancelled)
        let unknown = job(finished: 200, outcome: .unknown)
        let failuresOnly = NotificationPreferences(jobFailures: true)
        XCTAssertTrue(plan(previousJobs: [running], currentJobs: [success], preferences: failuresOnly).isEmpty)
        XCTAssertEqual(plan(previousJobs: [running], currentJobs: [cancelled], preferences: failuresOnly).first?.kind, .jobCancelled)
        XCTAssertEqual(plan(previousJobs: [running], currentJobs: [success], preferences: NotificationPreferences(jobSuccesses: true)).first?.title,
                       "Unit tests succeeded")
        XCTAssertTrue(plan(previousJobs: [running], currentJobs: [cancelled], preferences: NotificationPreferences(jobSuccesses: true)).isEmpty)
        XCTAssertTrue(plan(previousJobs: [running], currentJobs: [unknown]).isEmpty)
        XCTAssertTrue(plan(previousJobs: [running], currentJobs: [job(finished: 200, outcome: .failure)],
                           preferences: NotificationPreferences()).isEmpty)
    }

    func testStaleCompletionDoesNotNotify() {
        let failed = job(finished: 200, outcome: .failure)
        XCTAssertTrue(plan(previousJobs: [], currentJobs: [failed], now: 200 + NotificationPlanner.maximumJobAge + 1).isEmpty)
    }

    func testShortJobFirstSeenFinishedNotifies() {
        let failed = job(started: 100, finished: 110, outcome: .failure)
        XCTAssertEqual(plan(previousJobs: [], currentJobs: [failed]).count, 1)
    }

    func testForgejoUnknownTaskThatFinishesWithFailureNotifiesOnce() {
        let observed = RunnerJob(id: "\(runner.id)::forgejo-task-7", runnerID: runner.id, name: "Task 7",
                                 repository: "example/native", startedAt: launch.addingTimeInterval(30), outcome: .unknown)
        var finished = observed
        finished.finishedAt = launch.addingTimeInterval(240)
        finished.outcome = .failure
        let planned = plan(previousJobs: [observed], currentJobs: [finished])
        XCTAssertEqual(planned.map(\.title), ["Task 7 failed"])
        XCTAssertTrue(plan(previousJobs: [finished], currentJobs: [finished], notified: Set(planned.map(\.id))).isEmpty)
    }

    func testUserStopDoesNotNotify() {
        let actions = [runner.id: launch.addingTimeInterval(290)]
        XCTAssertTrue(plan(previousRunners: [snapshot(.idle, pid: 42)], currentRunners: [snapshot(.stopped)], actions: actions).isEmpty)
        XCTAssertTrue(plan(previousRunners: [snapshot(.busy, pid: 42)], currentRunners: [snapshot(.disabled)], actions: actions).isEmpty)
        let expired = [runner.id: launch.addingTimeInterval(300 - NotificationPlanner.userActionGrace - 1)]
        XCTAssertEqual(plan(previousRunners: [snapshot(.idle, pid: 42)], currentRunners: [snapshot(.stopped)], actions: expired).count, 1)
    }

    func testCrashNotifiesOncePerProcess() throws {
        let busyJob = job()
        let planned = plan(previousRunners: [snapshot(.busy, pid: 42, job: busyJob)], currentRunners: [snapshot(.stopped)])
        XCTAssertEqual(planned.count, 1)
        let item = try XCTUnwrap(planned.first)
        XCTAssertEqual(item.kind, .runnerStopped)
        XCTAssertEqual(item.title, "build-example stopped unexpectedly")
        XCTAssertEqual(item.body, "example/desktop · build-example\nIt was running Unit tests.")
        XCTAssertNil(item.jobID)
        XCTAssertTrue(plan(previousRunners: [snapshot(.busy, pid: 42)], currentRunners: [snapshot(.stopped)],
                           notified: [item.id]).isEmpty)
        XCTAssertEqual(plan(previousRunners: [snapshot(.idle, pid: 43)], currentRunners: [snapshot(.stopped)],
                            notified: [item.id]).count, 1)
        // A Forgejo daemon with unverified activity still had a live process.
        XCTAssertEqual(plan(previousRunners: [snapshot(.unknown, pid: 44)], currentRunners: [snapshot(.stopped)]).count, 1)
        XCTAssertTrue(plan(previousRunners: [snapshot(.idle, pid: 42)], currentRunners: [snapshot(.stopped)],
                           preferences: NotificationPreferences(jobFailures: true)).isEmpty)
    }

    func testUnknownTransitionsDoNotNotify() {
        XCTAssertTrue(plan(previousRunners: [snapshot(.idle, pid: 42)], currentRunners: [snapshot(.unknown)]).isEmpty)
        XCTAssertTrue(plan(previousRunners: [snapshot(.unknown)], currentRunners: [snapshot(.stopped)]).isEmpty)
        XCTAssertTrue(plan(previousRunners: [snapshot(.stopped)], currentRunners: [snapshot(.disabled)]).isEmpty)
        // A runner seen for the first time, or one that disappeared, has no transition.
        XCTAssertTrue(plan(previousRunners: [], currentRunners: [snapshot(.stopped)]).isEmpty)
        XCTAssertTrue(plan(previousRunners: [snapshot(.idle, pid: 42)], currentRunners: []).isEmpty)
    }

    func testNotificationTextIsRedacted() {
        var secret = job(finished: 200, outcome: .failure)
        secret.name = "Deploy ghp_abcdefghijklmnop"
        let planned = plan(previousJobs: [], currentJobs: [secret])
        XCTAssertEqual(planned.first?.title, "Deploy [REDACTED] failed")
    }
}
