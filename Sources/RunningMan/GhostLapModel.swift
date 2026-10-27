import Foundation
import RunningManCore

// Ghost laps: each running job races earlier runs of the same job. The model keeps a lap book of
// finished runs; views turn it into a reference and compute progress at display rate.

extension AppModel {
    func lapKey(for job: RunnerJob) -> LapKey {
        let provider = runners.first { $0.id == job.runnerID }?.runner.provider ?? .github
        return LapKey(job: job, provider: provider)
    }

    /// The run the ghost replays for `job`: recorded step laps of the same job, or else the
    /// durations of its earlier successful runs in the job history, which pace the whole job.
    func lapReference(for job: RunnerJob, pace: GhostPace? = nil) -> LapReference? {
        let pace = pace ?? ghostPace
        let key = lapKey(for: job)
        let recorded = (laps[key] ?? []).filter { $0.jobID != job.id }
        if let reference = LapReference.make(from: recorded, pace: pace) { return reference }
        // The same key, so a GitHub and a Forgejo job of the same name never pace each other.
        let earlier = jobs.filter {
            $0.id != job.id && $0.outcome == .success && $0.finishedAt != nil && $0.name == job.name && lapKey(for: $0) == key
        }.map { LapRecord(jobID: $0.id, finishedAt: $0.finishedAt!, outcome: .success, seconds: $0.duration) }
        return LapReference.make(from: earlier, pace: pace)
    }

    /// The job a runner's lap card shows: its running job, or one that finished in the last
    /// few minutes, so the finish stays visible for a moment.
    func lapJob(for runnerID: String, now: Date = Date()) -> RunnerJob? {
        // Read so views ask again when a finished job's time on screen ends.
        _ = lapLingerRevision
        if let current = runners.first(where: { $0.id == runnerID })?.currentJob { return current }
        guard let log = stepLogs[runnerID], let job = jobs(for: runnerID).first(where: { $0.id == log.jobID }) else { return nil }
        // A refresh publishes runners before history and step logs, so for a moment a job that
        // just finished is neither current nor finished. Rebuilding its card would lose the finish.
        if job.outcome == .running { return job }
        guard log.isFinished, let finished = job.finishedAt, now.timeIntervalSince(finished) < Self.lapFinishLinger else { return nil }
        return job
    }

    static let lapFinishLinger: TimeInterval = 10 * 60

    /// Whether RunningMan saw this job finish before, whatever the outcome; without a successful
    /// run there is no ghost, but the job is not new either.
    func hasEarlierRuns(of job: RunnerJob) -> Bool {
        let key = lapKey(for: job)
        if (laps[key] ?? []).contains(where: { $0.jobID != job.id }) { return true }
        return jobs.contains { $0.id != job.id && $0.finishedAt != nil && $0.name == job.name && lapKey(for: $0) == key }
    }

    /// Hands each newly finished step log to the lap book once: the latest job of each runner,
    /// and finished jobs a newer one replaced before a refresh could show them.
    func recordFinishedLaps(also displaced: [JobStepLog] = []) {
        let logs = Array(stepLogs.values) + displaced
        // Only the latest job of each runner has a step log, so older IDs can never come back.
        recordedLapJobIDs.formIntersection(logs.map(\.jobID))
        var pending: [(lap: LapRecord, key: LapKey)] = []
        for log in logs where log.isFinished && !recordedLapJobIDs.contains(log.jobID) {
            // A log missing its end is skipped for now and recorded once it is complete.
            guard let job = jobs.first(where: { $0.id == log.jobID }), [.success, .failure, .cancelled].contains(job.outcome),
                  let lap = LapRecord(log: log, outcome: job.outcome) else { continue }
            recordedLapJobIDs.insert(log.jobID)
            pending.append((lap, lapKey(for: job)))
        }
        scheduleLingerEnds(Array(stepLogs.values))
        guard !pending.isEmpty else { return }
        // Each batch waits for the one before, so a slower batch never publishes an older book.
        let previous = lapRecording
        lapRecording = Task { [weak self, lapBook] in
            await previous?.value
            var book: [LapKey: [LapRecord]]?
            for item in pending { book = await lapBook.record(item.lap, for: item.key) }
            // The whole book, so jobs it forgot leave the model too.
            if let book { self?.laps = book }
        }
    }
}

extension AppModel {
    /// A finished job's card stays for `lapFinishLinger`. On a fleet where nothing else changes,
    /// nothing would redraw it after that, so each end is scheduled as a change of its own.
    private func scheduleLingerEnds(_ logs: [JobStepLog]) {
        lingeringJobIDs.formIntersection(logs.map(\.jobID))
        for log in logs where log.isFinished && !lingeringJobIDs.contains(log.jobID) {
            guard let finished = jobs.first(where: { $0.id == log.jobID })?.finishedAt else { continue }
            lingeringJobIDs.insert(log.jobID)
            let delay = finished.addingTimeInterval(Self.lapFinishLinger).timeIntervalSinceNow
            guard delay > 0 else { continue }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay + 1))
                self?.lapLingerRevision += 1
            }
        }
    }
}

// MARK: - Demo race

/// The demo has one GitHub runner racing scripted runs of its release job in real time. Forgejo
/// runners keep no local record of a running job, so the demo gives them none either. Everything
/// here is fictional.
extension AppModel {
    struct DemoRaceStep {
        let name: String
        let seconds: Double
        let outcome: JobStepOutcome
    }

    static let demoRaceJobName = "Build & publish macOS app"
    static let demoRaceWorkflow = "Release"
    /// How far into the first run the demo opens: during the build, ten seconds before the
    /// runner overtakes its ghost.
    static let demoRaceOpeningOffset: Double = 62
    /// The loaded demo job that becomes the opening run.
    static let demoRaceOpeningJobID = "demo-job-0"

    /// Usual step times of the demo release job.
    static let demoUsualSteps: [(String, Double)] = [
        ("Set up job", 3), ("Run actions/checkout@v4", 5), ("Restore build cache", 6), ("Resolve packages", 9),
        ("Build app bundle", 52), ("Run tests", 26), ("Sign & package", 8), ("Upload artifact", 6),
        ("Post Run actions/checkout@v4", 1), ("Complete job", 1),
    ]

    /// A cache miss loses time, then a fast build overtakes the ghost; a clean record run; a test failure.
    static let demoRaces: [[DemoRaceStep]] = [
        [2, 4, 22, 8, 35, 22, 7, 5, 1, 1].enumerated().map { DemoRaceStep(name: demoUsualSteps[$0].0, seconds: Double($1), outcome: .success) },
        [2, 4, 5, 8, 44, 22, 7, 5, 1, 1].enumerated().map { DemoRaceStep(name: demoUsualSteps[$0].0, seconds: Double($1), outcome: .success) },
        [3, 5, 6, 9, 50].enumerated().map { DemoRaceStep(name: demoUsualSteps[$0].0, seconds: Double($1), outcome: .success) } + [
            DemoRaceStep(name: "Run tests", seconds: 14, outcome: .failure),
            DemoRaceStep(name: "Sign & package", seconds: 0, outcome: .skipped),
            DemoRaceStep(name: "Upload artifact", seconds: 0, outcome: .skipped),
            DemoRaceStep(name: "Post Run actions/checkout@v4", seconds: 1, outcome: .success),
            DemoRaceStep(name: "Complete job", seconds: 1, outcome: .success),
        ],
    ]

    static let demoOutput: [String: [String]] = [
        "Set up job": ["Current runner version: '2.337.0'", "> Operating System", "  macOS", "  15.5", "Prepare workflow directory",
                       "Prepare all required actions", "Download action repository 'actions/checkout@v4'"],
        "Run actions/checkout@v4": ["> Run actions/checkout@v4", "  with:", "    repository: octocat/WeatherKit", "Syncing repository: octocat/WeatherKit",
                                    "$ /usr/bin/git version", "git version 2.50.1", "Checking out the ref"],
        "Restore build cache": ["> Run actions/cache@v4", "  with:", "    path: .build", "    key: macos-spm-example",
                                "! Cache not found for input keys: macos-spm-example", "Downloading package dependencies…"],
        "Resolve packages": ["> Run swift package resolve", "Fetching https://github.com/octocat/forecast-kit", "Computed https://github.com/octocat/forecast-kit at 2.4.1"],
        "Build app bundle": ["> Run scripts/build-app.sh release", "Building for production...", "compile WeatherCore (24 files)",
                             "compile WeatherKit (61 files)", "! Sources/WeatherKit/ForecastView.swift:88:13: 'foregroundColor' is deprecated: use foregroundStyle",
                             "link WeatherKit", "codesign: build/WeatherKit.app: valid on disk"],
        "Run tests": ["> Run swift test --parallel", "Building for debugging...", "Test Suite 'All tests' started",
                      "Executed 214 tests, with 0 failures (0 unexpected) in 18.2 seconds"],
        "Sign & package": ["> Run scripts/package.sh", "Created build/WeatherKit.zip (38.2 MB)"],
        "Upload artifact": ["> Run actions/upload-artifact@v4", "Artifact WeatherKit.zip uploaded"],
        "Post Run actions/checkout@v4": ["Post job cleanup.", "$ /usr/bin/git version"],
        "Complete job": ["Cleaning up orphan processes"],
    ]

    /// Twenty earlier runs of each demo job, spread around the usual step times.
    func loadDemoLaps(now: Date) {
        guard runners.count >= 2 else { return }
        let runner = runners[0], tests = runners[1]
        let raceKey = LapKey(provider: .github, repository: runner.runner.repository, workflow: Self.demoRaceWorkflow, job: Self.demoRaceJobName)
        func spread(_ seconds: Double, _ run: Int, _ step: Int) -> Double {
            // Deterministic variation from 86% to 108% of usual, in whole seconds as worker logs
            // report them. One earlier run was quick throughout, so the opening run is second fastest.
            let wave = sin(Double(run) * 1.73 + Double(step) * 0.91) * 0.5 + 0.5
            let quick = run == 13 ? 0.88 : 0.86 + 0.22 * wave
            return max(1, (seconds * quick).rounded())
        }
        let raceLaps = (0..<20).map { run in
            let splits = Self.demoUsualSteps.enumerated().map { LapSplit(name: $1.0, seconds: spread($1.1, run, $0), outcome: .success) }
            return LapRecord(jobID: "demo-lap-\(run)", finishedAt: now.addingTimeInterval(-Double(20 - run) * 4_000), outcome: .success,
                             seconds: splits.reduce(0) { $0 + $1.seconds }, splits: splits)
        }
        let testSteps: [(String, Double)] = [("Set up job", 2), ("Run actions/checkout@v4", 3), ("Run swift test", 44), ("Upload test results", 0),
                                             ("Post Run actions/checkout@v4", 1), ("Complete job", 1)]
        let testKey = LapKey(provider: .github, repository: tests.runner.repository, workflow: "Continuous integration", job: "Unit tests")
        let testLaps = (0..<12).map { run in
            let splits = testSteps.enumerated().map { LapSplit(name: $1.0, seconds: $1.1 == 0 ? 0 : spread($1.1, run, $0),
                                                               outcome: $1.1 == 0 ? .skipped : .success) }
            return LapRecord(jobID: "demo-test-lap-\(run)", finishedAt: now.addingTimeInterval(-Double(12 - run) * 7_000), outcome: .success,
                             seconds: splits.reduce(0) { $0 + $1.seconds }, splits: splits)
        }
        laps = [raceKey: raceLaps, testKey: testLaps]
        lapBook = LapBook(fileURL: nil, seed: laps)
    }

    /// Puts the demo's GitHub runner `demoRaceOpeningOffset` seconds into a scripted run. Runs once
    /// at launch, so captures and tests see a race in progress.
    func setUpDemoRace(now: Date) {
        loadDemoLaps(now: now)
        guard !runners.isEmpty, let index = jobs.firstIndex(where: { $0.id == Self.demoRaceOpeningJobID }) else { return }
        let start = now.addingTimeInterval(-Self.demoRaceOpeningOffset)
        jobs[index].name = Self.demoRaceJobName
        jobs[index].workflow = Self.demoRaceWorkflow
        jobs[index].startedAt = start
        jobs[index].runnerID = runners[0].id
        runners[0].currentJob = jobs[index]
        stepLogs[runners[0].id] = Self.demoRaceLog(Self.demoRaces[0], jobID: Self.demoRaceOpeningJobID, runnerID: runners[0].id, start: start, now: now)
    }

    /// The scripted run's step log at `now`. A cancelled run ends in the step running at `now`.
    static func demoRaceLog(_ script: [DemoRaceStep], jobID: String, runnerID: String, start: Date, now: Date,
                            cancelled: Bool = false) -> JobStepLog {
        var cursor = start
        var lineID = 0
        var steps: [JobStep] = []
        var stopped = false
        for (index, step) in script.enumerated() {
            guard cursor <= now, !stopped else { break }
            let end = cursor.addingTimeInterval(step.seconds)
            let finished = end <= now
            stopped = cancelled && !finished
            let output = demoOutput[step.name] ?? []
            // A running step shows output up to its share of the time so far.
            let shown = finished ? output.count : max(1, Int(Double(output.count) * min(1, now.timeIntervalSince(cursor) / max(step.seconds, 1))))
            let lines = (step.outcome == .skipped ? [] : output.prefix(shown)).map { raw -> JobStepLine in
                defer { lineID += 1 }
                if raw.hasPrefix("> ") { return JobStepLine(id: lineID, date: cursor, text: String(raw.dropFirst(2)), kind: .groupHeader) }
                if raw.hasPrefix("  ") { return JobStepLine(id: lineID, date: cursor, text: String(raw.dropFirst(2)), isGrouped: true) }
                if raw.hasPrefix("$ ") { return JobStepLine(id: lineID, date: cursor, text: String(raw.dropFirst(2)), kind: .command) }
                if raw.hasPrefix("! ") { return JobStepLine(id: lineID, date: cursor, text: String(raw.dropFirst(2)), kind: .warning) }
                return JobStepLine(id: lineID, date: cursor, text: raw)
            }
            let failureLine = step.outcome == .failure && finished
                ? [JobStepLine(id: lineID, date: end, text: "error: ForecastTests.testHourlyRollover failed: 3 is not equal to 4", kind: .error)] : []
            lineID += failureLine.count
            steps.append(JobStep(id: index, name: step.name, startedAt: cursor, finishedAt: finished ? end : stopped ? now : nil,
                                 outcome: finished ? step.outcome : stopped ? .cancelled : .running, lines: lines + failureLine))
            cursor = end
        }
        let total = script.reduce(0) { $0 + $1.seconds }
        return JobStepLog(jobID: jobID, runnerID: runnerID, isFinished: cancelled || now.timeIntervalSince(start) >= total, hasOutput: true,
                          isTruncated: false, revision: Int(now.timeIntervalSince1970 * 10), steps: steps)
    }

    /// Runs the demo race in real time on the first runner: the opening run continues, then the
    /// scripts repeat with a pause between runs. Stopping, disabling or removing the runner ends
    /// its run as cancelled; a stopped or disabled runner races again once it is started, and a
    /// removed one ends the race.
    func startDemoRace() {
        // The race belongs to the runner of the opening job; once that runner is removed, none races.
        guard demoMode, demoRaceTask == nil, SnapshotCapture.destination == nil,
              let runnerID = jobs.first(where: { $0.id == Self.demoRaceOpeningJobID })?.runnerID,
              runners.contains(where: { $0.id == runnerID }) else { return }
        demoRaceRunnerID = runnerID
        demoRaceTask = Task { [weak self] in
            var run = 0
            var opening = true
            while !Task.isCancelled {
                guard let self else { return }
                if !opening, await !waitForDemoRaceRunner(runnerID) { break }
                guard await runDemoRace(Self.demoRaces[run % Self.demoRaces.count], runnerID: runnerID, opening: opening) else { break }
                opening = false
                run += 1
                try? await Task.sleep(for: .seconds(9))
            }
            self?.demoRaceTask = nil
            self?.demoRaceRunnerID = nil
        }
    }

    /// Waits until the race runner is idle and enabled again; false once it is gone or the task ends.
    private func waitForDemoRaceRunner(_ runnerID: String) async -> Bool {
        while !Task.isCancelled {
            guard let runner = runners.first(where: { $0.id == runnerID }) else { return false }
            if runner.status == .idle, runner.isEnabled { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// Returns false when the task was cancelled or the runner is gone.
    private func runDemoRace(_ script: [DemoRaceStep], runnerID: String, opening: Bool) async -> Bool {
        guard let index = runners.firstIndex(where: { $0.id == runnerID }) else { return false }
        let jobID: String
        let start: Date
        if opening {
            // The opening run continues the job set up at launch, unless it was already ended.
            guard let job = runners[index].currentJob, job.id == Self.demoRaceOpeningJobID else {
                if let job = jobs.first(where: { $0.id == Self.demoRaceOpeningJobID }) {
                    cancelDemoRace(script, jobID: job.id, runnerID: runnerID, start: job.startedAt, at: Date())
                }
                return true
            }
            jobID = job.id
            start = job.startedAt
        } else {
            jobID = "demo-race-\(UUID().uuidString.prefix(8))"
            start = Date()
            let repository = runners[index].runner.repository
            let job = RunnerJob(id: jobID, runnerID: runnerID, name: Self.demoRaceJobName, repository: repository,
                                workflow: Self.demoRaceWorkflow, runURL: URL(string: "https://github.com/\(repository)/actions"),
                                startedAt: start)
            jobs.insert(job, at: 0)
            runners[index].status = .busy
            runners[index].currentJob = job
        }
        let ends = script.reduce(into: [Double]()) { $0.append(($0.last ?? 0) + $1.seconds) }
        let total = ends.last ?? 0
        while true {
            let now = Date()
            // A demo stop, disable or removal interrupts the run where it stands.
            guard let runner = runners.first(where: { $0.id == runnerID }), runner.isEnabled, runner.status == .busy,
                  runner.currentJob?.id == jobID else {
                cancelDemoRace(script, jobID: jobID, runnerID: runnerID, start: start, at: now)
                return runners.contains { $0.id == runnerID }
            }
            stepLogs[runnerID] = Self.demoRaceLog(script, jobID: jobID, runnerID: runnerID, start: start, now: now)
            let elapsed = now.timeIntervalSince(start)
            if elapsed >= total { break }
            // Wake at the next step boundary, or when a live refresh would come, on a whole second
            // with the readouts, so a running step's output grows as it does for a live runner.
            let next = ends.first { $0 > elapsed + 0.01 } ?? total
            let reference = now.timeIntervalSinceReferenceDate
            let refresh = (reference + Double(PollingCadence.foreground.components.seconds)).rounded(.down) - reference
            try? await Task.sleep(for: .seconds(min(refresh, max(0.05, next - elapsed))))
            if Task.isCancelled { return false }
        }
        let failed = script.contains { $0.outcome == .failure }
        if let index = jobs.firstIndex(where: { $0.id == jobID }) {
            jobs[index].finishedAt = start.addingTimeInterval(total)
            jobs[index].outcome = failed ? .failure : .success
        }
        if let index = runners.firstIndex(where: { $0.id == runnerID }) {
            runners[index].currentJob = nil
            runners[index].status = .idle
        }
        recordFinishedLaps()
        processDrainRequests()
        return true
    }

    /// Ends an interrupted run: its job and step log finish cancelled, so History shows no job
    /// running on a runner that has none, and a disabled runner gives up the job it was running.
    private func cancelDemoRace(_ script: [DemoRaceStep], jobID: String, runnerID: String, start: Date, at now: Date) {
        if let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].finishedAt == nil {
            jobs[index].finishedAt = now
            jobs[index].outcome = .cancelled
        }
        if stepLogs[runnerID]?.jobID == jobID {
            stepLogs[runnerID] = Self.demoRaceLog(script, jobID: jobID, runnerID: runnerID, start: start, now: now, cancelled: true)
        }
        if let index = runners.firstIndex(where: { $0.id == runnerID }), runners[index].currentJob?.id == jobID {
            runners[index].currentJob = nil
        }
        // As for a finish: the lap is kept and the card leaves after its linger.
        recordFinishedLaps()
    }
}
