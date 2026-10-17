import XCTest
@testable import RunningManCore

final class JobStepLogTests: XCTestCase {
    private let timeline = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let jobID = "11111111-1111-1111-1111-111111111111"
    private let buildRecord = "22222222-2222-2222-2222-222222222222"
    private var temporary: URL!
    private var runner: InstalledRunner!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("JobStepLogTests-\(UUID().uuidString)")
        let directory = temporary.appendingPathComponent("actions-runner-example")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("_diag/pages"), withIntermediateDirectories: true)
        runner = InstalledRunner(name: "build-example", directory: directory, githubURL: URL(string: "https://github.com/example/desktop"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private var pages: URL { runner.directory.appendingPathComponent("_diag/pages") }
    private func page(record: String, number: Int = 1) -> URL { pages.appendingPathComponent("\(timeline)_\(record)_\(number).log") }
    private func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
    private func worker(_ lines: [String]) -> String {
        lines.map { "[2026-10-16 \($0)\n" }.joined()
    }
    private var workerLog: URL { runner.directory.appendingPathComponent("_diag/Worker_20261016-100000-utc.log") }
    private func stepLog(_ monitor: RunnerLogMonitor) async throws -> JobStepLog {
        let result = await monitor.scan(runners: [runner])
        return try XCTUnwrap(result.stepLogs[runner.id])
    }
    private func date(_ time: String) -> Date { ISO8601DateFormatter().date(from: "2026-10-16T\(time)Z")! }

    private var completedWorkerLog: String {
        worker([
            "10:00:01Z INFO JobRunner] Job ID \(jobID)",
            "10:00:03Z INFO StepsRunner] Processing step: DisplayName='Run actions/checkout@v4'",
            "10:00:05Z INFO StepsRunner] Step result: Succeeded",
            "10:00:05Z INFO StepsRunner] Processing step: DisplayName='Build'",
            "10:00:06Z INFO CompositeActionHandler] Processing embedded step: DisplayName='Inner'",
            "10:00:06Z INFO CompositeActionHandler] Step result: Succeeded",
            "10:00:08Z INFO StepsRunner] Step result: Failed",
            "10:00:08Z INFO StepsRunner] Processing step: DisplayName='Upload'",
            "10:00:08Z INFO StepsRunner] Skipping step due to condition evaluation.",
            "10:00:09Z INFO JobRunner] Finalize job.",
            "10:00:10Z INFO JobRunner] Job result after all job steps finish: Failed"
        ])
    }

    private var jobPage: String {
        """
        2026-10-16T10:00:01.2000000Z Current runner version: '2.337.0'
        2026-10-16T10:00:03.1000000Z ##[group]Run actions/checkout@v4
        2026-10-16T10:00:03.1100000Z with:
        2026-10-16T10:00:03.1200000Z ##[endgroup]
        2026-10-16T10:00:05.1000000Z checkout done
        2026-10-16T10:00:05.3000000Z ##[group]Run make
        2026-10-16T10:00:05.3100000Z ##[endgroup]
        2026-10-16T10:00:06.0000000Z ##[command]/usr/bin/make release
        2026-10-16T10:00:06.5000000Z export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz123456
        2026-10-16T10:00:07.0000000Z -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAA
        -----END OPENSSH PRIVATE KEY-----
        2026-10-16T10:00:07.5000000Z ##[error]Process completed with exit code 2.
        2026-10-16T10:00:09.5000000Z Cleaning up orphan processes

        """
    }

    func testTimelineReadsStepsAndIgnoresCompositeInnerResults() {
        var timeline = JobStepTimeline(jobID: jobID.uppercased(), startedAt: date("10:00:01"))
        let monitorFormat = completedWorkerLog.split(separator: "\n").dropFirst()
        for line in monitorFormat {
            let text = String(line)
            let seconds = String(text.dropFirst("[2026-10-16 ".count).prefix(8))
            _ = timeline.consume(text, date: date(seconds))
        }

        XCTAssertEqual(timeline.jobID, jobID)
        XCTAssertTrue(timeline.isFinished)
        XCTAssertEqual(timeline.entries.map(\.name), ["Set up job", "Run actions/checkout@v4", "Build", "Upload", "Complete job"])
        XCTAssertEqual(timeline.entries.map(\.outcome), [.success, .success, .failure, .skipped, .success])
        // The composite action's inner result at 10:00:06 must not close the outer step.
        XCTAssertEqual(timeline.entries[2].finishedAt, date("10:00:08"))
    }

    func testMonitorGroupsJobOutputByStepAndRedactsIt() async throws {
        try write(completedWorkerLog, to: workerLog)
        try write(jobPage, to: page(record: jobID))

        let result = await RunnerLogMonitor().scan(runners: [runner])
        let log = try XCTUnwrap(result.stepLogs[runner.id])

        XCTAssertEqual(log.jobID, "\(runner.id)::\(jobID)")
        XCTAssertTrue(log.isFinished)
        XCTAssertTrue(log.hasOutput)
        XCTAssertFalse(log.isTruncated)
        let text = log.steps.map { $0.lines.map(\.text) }
        XCTAssertEqual(text[0], ["Current runner version: '2.337.0'"])
        // "checkout done" shares a second with the next step's start; the group header marks the real boundary.
        XCTAssertEqual(text[1], ["Run actions/checkout@v4", "with:", "checkout done"])
        XCTAssertEqual(text[2].first, "Run make")
        XCTAssertTrue(text[2].contains("/usr/bin/make release"))
        XCTAssertTrue(text[3].isEmpty)
        XCTAssertEqual(text[4], ["Cleaning up orphan processes"])

        let all = text.joined().joined(separator: "\n")
        XCTAssertFalse(all.contains("ghp_abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertTrue(all.contains("[REDACTED]"))
        XCTAssertFalse(all.contains("b3BlbnNzaC1rZXktdjEAAAAA"))
        XCTAssertTrue(all.contains("Private key omitted from the job log."))

        let build = log.steps[2].lines
        XCTAssertEqual(build.first?.kind, .groupHeader)
        XCTAssertEqual(build.first { $0.text.hasPrefix("/usr/bin/make") }?.kind, .command)
        XCTAssertEqual(build.last?.kind, .error)
        XCTAssertEqual(log.steps[1].lines[1].isGrouped, true)
        XCTAssertEqual(log.steps[1].lines[2].isGrouped, false)
    }

    func testOutputSurvivesPageDeletionAndResetsForTheNextJob() async throws {
        try write(worker([
            "10:00:01Z INFO JobRunner] Job ID \(jobID)",
            "10:00:03Z INFO StepsRunner] Processing step: DisplayName='Build'"
        ]), to: workerLog)
        try write("2026-10-16T10:00:03.5000000Z partial", to: page(record: jobID))
        let monitor = RunnerLogMonitor()

        var log = try await stepLog(monitor)
        XCTAssertFalse(log.isFinished)
        XCTAssertEqual(log.steps.last?.outcome, .running)
        XCTAssertTrue(log.steps.allSatisfy { $0.lines.isEmpty }, "An unterminated line waits for its newline")

        try append(" line\n2026-10-16T10:00:04.0000000Z second\n", to: page(record: jobID))
        log = try await stepLog(monitor)
        XCTAssertEqual(log.steps[1].lines.map(\.text), ["partial line", "second"])
        let revision = log.revision

        // Nothing changed: the same revision is reported, so the app can skip the update.
        let unchanged = try await stepLog(monitor)
        XCTAssertEqual(unchanged.revision, revision)

        // The runner uploads and deletes its pages; read output stays, and the unread tail is marked.
        try FileManager.default.removeItem(at: page(record: jobID))
        try append(worker(["10:00:05Z INFO StepsRunner] Step result: Succeeded"]), to: workerLog)
        log = try await stepLog(monitor)
        XCTAssertEqual(log.steps[1].outcome, .success)
        XCTAssertEqual(log.steps[1].lines.map(\.text).prefix(2), ["partial line", "second"])
        XCTAssertEqual(log.steps[1].lines.last?.kind, .omission)

        let nextJob = "33333333-3333-3333-3333-333333333333"
        try append(worker(["10:01:00Z INFO JobRunner] Job ID \(nextJob)"]), to: workerLog)
        log = try await stepLog(monitor)
        XCTAssertEqual(log.jobID, "\(runner.id)::\(nextJob)")
        XCTAssertFalse(log.hasOutput)
        XCTAssertEqual(log.steps.map(\.name), ["Set up job"])
    }

    func testRolledOverPagesAreReadInOrderAndMissingPagesAreMarked() async throws {
        try write(worker(["10:00:01Z INFO JobRunner] Job ID \(jobID)"]), to: workerLog)
        try write("2026-10-16T10:00:01.1000000Z page one\n", to: page(record: jobID, number: 1))
        try write("2026-10-16T10:00:01.2000000Z page two\n", to: page(record: jobID, number: 2))
        let monitor = RunnerLogMonitor()
        var log = try await stepLog(monitor)
        XCTAssertEqual(log.steps[0].lines.map(\.text), ["page one", "page two"])
        XCTAssertFalse(log.isTruncated)

        // Page 3 was uploaded and deleted before it could be read.
        try FileManager.default.removeItem(at: page(record: jobID, number: 1))
        try write("2026-10-16T10:00:01.4000000Z page four\n", to: page(record: jobID, number: 4))
        log = try await stepLog(monitor)
        XCTAssertTrue(log.isTruncated)
        XCTAssertEqual(log.steps[0].lines.map(\.kind), [.output, .output, .omission, .output])
        XCTAssertEqual(log.steps[0].lines.last?.text, "page four")
    }

    func testPageDeletedMidJobMarksPossiblyMissingTail() async throws {
        try write(worker(["10:00:01Z INFO JobRunner] Job ID \(jobID)"]), to: workerLog)
        try write("2026-10-16T10:00:01.1000000Z read before upload\n", to: page(record: jobID))
        let monitor = RunnerLogMonitor()
        _ = try await stepLog(monitor)

        try FileManager.default.removeItem(at: page(record: jobID))
        var log = try await stepLog(monitor)
        XCTAssertTrue(log.isTruncated)
        XCTAssertEqual(log.steps[0].lines.map(\.kind), [.output, .omission])

        // The marker is added once, not on every later scan.
        log = try await stepLog(monitor)
        XCTAssertEqual(log.steps[0].lines.count, 2)
    }

    func testPageReadAfterStepsFinishedIsNotMarkedWhenUploaded() async throws {
        try write(completedWorkerLog, to: workerLog)
        try write(jobPage, to: page(record: jobID))
        let monitor = RunnerLogMonitor()
        _ = try await stepLog(monitor)

        try FileManager.default.removeItem(at: page(record: jobID))
        let log = try await stepLog(monitor)
        XCTAssertFalse(log.isTruncated)
        XCTAssertEqual(log.steps.flatMap(\.lines).last?.text, "Cleaning up orphan processes")
    }

    func testStepPageStartRefinesBoundaryWithinTheSameSecond() async throws {
        try write(worker([
            "10:00:01Z INFO JobRunner] Job ID \(jobID)",
            "10:00:03Z INFO StepsRunner] Processing step: DisplayName='First'",
            "10:00:05Z INFO StepsRunner] Step result: Succeeded",
            "10:00:05Z INFO StepsRunner] Processing step: DisplayName='Second'"
        ]), to: workerLog)
        try write("""
        2026-10-16T10:00:03.2000000Z first starts
        2026-10-16T10:00:05.4000000Z first ends late
        2026-10-16T10:00:05.6000000Z second starts without a group header

        """, to: page(record: jobID))
        try write("2026-10-16T10:00:05.5999000Z second starts without a group header\n", to: page(record: buildRecord))

        let log = try await stepLog(RunnerLogMonitor())
        XCTAssertEqual(log.steps[1].lines.map(\.text), ["first starts", "first ends late"])
        XCTAssertEqual(log.steps[2].lines.map(\.text), ["second starts without a group header"])
    }

    func testStepsStartingInTheSameSecondKeepTheirOwnOutput() {
        let start = date("10:00:00")
        let entries = [
            JobStepTimeline.Entry(name: "Set up job", startedAt: start, finishedAt: start + 1, outcome: .success),
            JobStepTimeline.Entry(name: "First", startedAt: start + 2, finishedAt: start + 2, outcome: .success),
            JobStepTimeline.Entry(name: "Second", startedAt: start + 2, finishedAt: nil, outcome: .running)
        ]
        let lines = [
            JobStepLine(id: 0, date: start + 2.1, text: "Run first", kind: .groupHeader),
            JobStepLine(id: 1, date: start + 2.2, text: "first output"),
            JobStepLine(id: 2, date: start + 2.6, text: "Run second", kind: .groupHeader),
            JobStepLine(id: 3, date: start + 2.7, text: "second output")
        ]
        let withPages = JobStepAssembler.steps(entries: entries, lines: lines, stepStarts: [start + 2.1, start + 2.6], isFinished: false)
        XCTAssertEqual(withPages.map { $0.lines.map(\.text) }, [[], ["Run first", "first output"], ["Run second", "second output"]])
        let fromHeaders = JobStepAssembler.steps(entries: entries, lines: lines, stepStarts: [], isFinished: false)
        XCTAssertEqual(fromHeaders.map { $0.lines.map(\.text) }, [[], ["Run first", "first output"], ["Run second", "second output"]])
    }

    func testAssemblerLeavesSilentAndSkippedStepsEmpty() {
        let start = date("10:00:00")
        let entries = [
            JobStepTimeline.Entry(name: "Set up job", startedAt: start, finishedAt: start + 1, outcome: .success),
            JobStepTimeline.Entry(name: "Silent", startedAt: start + 2, finishedAt: start + 2, outcome: .success),
            JobStepTimeline.Entry(name: "Skipped", startedAt: start + 2, finishedAt: start + 2, outcome: .skipped),
            JobStepTimeline.Entry(name: "Loud", startedAt: start + 2, finishedAt: nil, outcome: .running)
        ]
        let lines = [
            JobStepLine(id: 0, date: start + 0.5, text: "setup"),
            JobStepLine(id: 1, date: start + 2.5, text: "loud", kind: .groupHeader)
        ]
        let steps = JobStepAssembler.steps(entries: entries, lines: lines, stepStarts: [start + 2.5], isFinished: true)
        XCTAssertEqual(steps.map { $0.lines.map(\.text) }, [["setup"], [], [], ["loud"]])
        // A finished job cannot have a step still running.
        XCTAssertEqual(steps[3].outcome, .unknown)
        XCTAssertEqual(steps[0].startedAt, start)
    }

    func testPagesIgnoreLinksAndForeignNamesAndBoundLongLines() async throws {
        try write(worker(["10:00:01Z INFO JobRunner] Job ID \(jobID)"]), to: workerLog)
        let outside = temporary.appendingPathComponent("outside.log")
        try write("2026-10-16T10:00:01.1000000Z secret outside the runner\n", to: outside)
        try FileManager.default.createSymbolicLink(at: page(record: jobID), withDestinationURL: outside)
        try write("2026-10-16T10:00:01.1000000Z not a page\n", to: pages.appendingPathComponent("notes_\(jobID)_1.log"))

        let monitor = RunnerLogMonitor()
        var log = try await stepLog(monitor)
        XCTAssertFalse(log.hasOutput)

        try FileManager.default.removeItem(at: page(record: jobID))
        let long = String(repeating: "x", count: 200_000)
        try write("2026-10-16T10:00:01.1000000Z \(long)\n2026-10-16T10:00:01.2000000Z after\n", to: page(record: jobID))
        log = try await stepLog(monitor)
        let texts = log.steps[0].lines.map(\.text)
        XCTAssertEqual(texts.count, 2)
        XCTAssertLessThan(texts[0].utf8.count, 17 * 1024)
        XCTAssertTrue(texts[0].hasSuffix(" …"))
        XCTAssertEqual(texts[1], "after")
    }

    func testRetainedOutputIsBounded() async throws {
        try write(worker(["10:00:01Z INFO JobRunner] Job ID \(jobID)"]), to: workerLog)
        let body = (0..<50_000).map { "2026-10-16T10:00:02.0000000Z line \($0)\n" }.joined()
        try write(body, to: page(record: jobID))
        let monitor = RunnerLogMonitor()
        var log: JobStepLog?
        for _ in 0..<4 { log = await monitor.scan(runners: [runner]).stepLogs[runner.id] }

        let lines = try XCTUnwrap(log).steps[0].lines
        XCTAssertTrue(try XCTUnwrap(log).isTruncated)
        XCTAssertLessThanOrEqual(lines.count, 40_000)
        XCTAssertEqual(lines.last?.text, "line 49999")
    }
}
