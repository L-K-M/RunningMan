import XCTest
@testable import RunningManCore

final class LogMonitorHardeningTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("log-hardening-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func githubRunner(_ folder: String = "actions-runner-example") throws -> InstalledRunner {
        let url = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("_diag"), withIntermediateDirectories: true)
        return InstalledRunner(name: "build-example", directory: url, githubURL: URL(string: "https://github.com/example/desktop"))
    }
    private func diag(_ runner: InstalledRunner, _ name: String) -> URL { runner.directory.appendingPathComponent("_diag/" + name) }
    private func write(_ text: String, to url: URL) throws { try write(Data(text.utf8), to: url) }
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
    /// Whole lines of synthetic diagnostics, at most `bytes` long in total.
    private func filler(_ bytes: Int, line: String) -> Data {
        let row = Data((line + " " + String(repeating: "x", count: 160) + "\n").utf8)
        var data = Data(capacity: bytes)
        for _ in 0..<(bytes / row.count) { data.append(row) }
        return data
    }
    private func lines(_ tail: String?) -> Set<String> { Set((tail ?? "").split(separator: "\n").map(String.init)) }

    // MARK: Budget and large first-seen logs (LOG-1)

    func testBudgetDoesNotStrandNewestJobInLargeFirstSeenWorkerLog() async throws {
        let runner = try githubRunner()
        // Eight Runner logs just under 1 MiB use almost all of one scan's 8 MiB read budget.
        for index in 0..<8 {
            try write(filler(1_040_000, line: "[2026-10-16 09:00:00Z INFO Listener]"), to: diag(runner, "Runner_20261016-09000\(index)-utc.log"))
        }
        let guid = "33333333-3333-3333-3333-333333333333"
        var worker = filler(2 * 1024 * 1024 + 4096, line: "[2026-10-16 10:00:00Z INFO Step]")
        worker.append(Data("""
        [2026-10-16 10:00:00Z INFO JobRunner] Job ID \(guid)
        [2026-10-16 10:05:00Z INFO JobRunner] Job result after all job steps finish: Succeeded

        """.utf8))
        try write(worker, to: diag(runner, "Worker_20261016-100000-utc.log"))
        let monitor = RunnerLogMonitor()
        var found: RunnerJob?
        for _ in 0..<3 where found == nil {
            found = await monitor.scan(runners: [runner]).jobs.first { $0.id.hasSuffix(guid) }
        }
        XCTAssertEqual(found?.outcome, .success)
    }

    func testLargeFirstSeenWorkerTailInsideJobMessageDoesNotLeak() async throws {
        let runner = try githubRunner()
        let guid = "77777777-7777-7777-7777-777777777777"
        var data = filler(200 * 1024, line: "[2026-10-16 09:59:00Z INFO Step]")
        var message = "[2026-10-16 10:00:00Z INFO Worker] Job message:\n{\n  \"jobId\": \"\(guid)\",\n  \"variables\": {\n"
        var index = 0
        while message.utf8.count < 2 * 1024 * 1024 {
            message += "    \"setting_\(index)\": {\n      \"value\": \"public\",\n      \"isSecret\": false\n    },\n"
            index += 1
        }
        // The tail window starts inside this message, so its secret value sits on a line of its own.
        message += """
            "private_setting": {
              "isSecret": true,
              "value": "TAIL_SECRET_MARKER"
            }
          }
        }
        [2026-10-16 10:00:01Z INFO JobRunner] Job ID \(guid)
        [2026-10-16 10:03:00Z INFO JobRunner] Job result after all job steps finish: Succeeded

        """
        data.append(Data(message.utf8))
        try write(data, to: diag(runner, "Worker_20261016-100000-utc.log"))
        let result = await RunnerLogMonitor().scan(runners: [runner])
        XCTAssertFalse(result.tails[runner.id, default: ""].contains("TAIL_SECRET_MARKER"))
        XCTAssertFalse(result.tails[runner.id, default: ""].contains("\"public\""), "No line of the cut job message may reach the tail")
        XCTAssertEqual(result.jobs.first { $0.id.hasSuffix(guid) }?.outcome, .success)
        XCTAssertTrue(result.warnings.contains { $0.contains("large log") })
    }

    func testForgejoLargeFirstSeenLogWaitsForBudgetInsteadOfSkippingNewestTask() async throws {
        let directory = root.appendingPathComponent("forgejo-budget")
        let first = directory.appendingPathComponent("a.log"), second = directory.appendingPathComponent("b.log")
        let large = directory.appendingPathComponent("c.log")
        // Two logs just under 1 MiB leave almost none of the 2 MiB budget for the large one.
        for file in [first, second] { try write(filler(1_040_000, line: #"time="2026-10-16T09:00:00Z" level=info msg="poll""#), to: file) }
        var data = filler(3 * 1024 * 1024, line: #"time="2026-10-16T09:30:00Z" level=info msg="poll""#)
        data.append(Data(#"time="2026-10-16T10:00:00Z" level=info msg="task 77 repo is example/project https://data.forgejo.test https://forge.example.test/""#.utf8 + [10]))
        data.append(filler(100 * 1024, line: #"time="2026-10-16T10:00:10Z" level=info msg="step""#))
        try write(data, to: large)
        let runner = InstalledRunner(name: "forgejo-budget", directory: directory, provider: .forgejo, diagnosticURLs: [first, second, large])
        let monitor = ForgejoLogMonitor()
        var found: RunnerJob?
        for _ in 0..<3 where found == nil { found = await monitor.scan(runners: [runner]).jobs.first { $0.name == "Task 77" } }
        XCTAssertEqual(found?.repository, "example/project")
    }

    // MARK: Symbolic links (LOG-2)

    func testSymbolicLinkDiagnosticsAreNeverRead() async throws {
        let runner = try githubRunner()
        try write("[2026-10-16 10:00:00Z INFO Runner] Listener started\n", to: diag(runner, "Runner_20261016-100000-utc.log"))
        let target = root.appendingPathComponent("outside/credential-like")
        try write("[2026-10-16 10:00:00Z INFO Worker] SECRET_MARKER\n", to: target)
        try FileManager.default.createSymbolicLink(at: diag(runner, "Worker_20261016-100001-utc.log"), withDestinationURL: target)
        let result = await RunnerLogMonitor().scan(runners: [runner])
        XCTAssertFalse(result.tails[runner.id, default: ""].contains("SECRET_MARKER"))
        XCTAssertTrue(result.tails[runner.id, default: ""].contains("Listener started"))
        XCTAssertTrue(result.warnings.contains { $0.contains("symbolic-link") })

        let link = root.appendingPathComponent("forgejo/daemon.log")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let forgejo = InstalledRunner(name: "forgejo-link", directory: link.deletingLastPathComponent(), provider: .forgejo, diagnosticURLs: [link])
        let daemon = await ForgejoLogMonitor().scan(runners: [forgejo])
        XCTAssertFalse(daemon.tails[forgejo.id, default: ""].contains("SECRET_MARKER"))
        XCTAssertTrue(daemon.warnings.contains { $0.contains("symbolic-link") })
    }

    // MARK: Private-key mode (LOG-3)

    func testPrivateKeyMentionDoesNotHideLaterTimestampedLines() async throws {
        let runner = try githubRunner()
        let guid = "44444444-4444-4444-4444-444444444444"
        try write("""
        [2026-10-16 10:00:00Z INFO HostContext] Unexpected key format, expected -----BEGIN RSA PRIVATE KEY-----
        [2026-10-16 10:00:01Z INFO JobDispatcher] Job request 1 for plan p job \(guid) received.
        [2026-10-16 10:00:02Z INFO Terminal] Running job: build
        [2026-10-16 10:01:00Z INFO JobDispatcher] finish job request for job \(guid) with result: Succeeded

        """, to: diag(runner, "Runner_20261016-100000-utc.log"))
        let body = (0..<250).map { "KEYBODY\($0)" }.joined(separator: "\n")
        try write("""
        -----BEGIN PRIVATE KEY----- inline -----END PRIVATE KEY-----
        untimestamped line after an inline key
        -----BEGIN EC PRIVATE KEY-----
        \(body)

        """, to: diag(runner, "Worker_20261016-100001-utc.log"))
        let result = await RunnerLogMonitor().scan(runners: [runner])
        XCTAssertEqual(result.jobs.map(\.outcome), [.success])
        let tail = lines(result.tails[runner.id])
        XCTAssertTrue(tail.contains("[2026-10-16 10:00:02Z INFO Terminal] Running job: build"))
        XCTAssertTrue(tail.contains("untimestamped line after an inline key"))
        XCTAssertFalse(tail.contains { $0.contains("inline -----END") })
        // Key mode is capped: the first 200 body lines stay hidden, later lines show again.
        XCTAssertFalse(tail.contains("KEYBODY0")); XCTAssertFalse(tail.contains("KEYBODY199"))
        XCTAssertTrue(tail.contains("KEYBODY200"))
    }

    func testForgejoPrivateKeyMentionDoesNotHideLaterStructuredLines() async throws {
        let log = root.appendingPathComponent("forgejo/daemon.log")
        try write("""
        time="2026-10-16T10:00:00Z" level=warning msg="ignoring -----BEGIN RSA PRIVATE KEY----- in configuration"
        key-body-that-must-stay-hidden
        time="2026-10-16T10:00:05Z" level=info msg="task 12 repo is example/project https://data.forgejo.test https://forge.example.test/"

        """, to: log)
        let runner = InstalledRunner(name: "forgejo-key", directory: log.deletingLastPathComponent(), provider: .forgejo, diagnosticURLs: [log])
        let result = await ForgejoLogMonitor().scan(runners: [runner])
        XCTAssertEqual(result.jobs.map(\.name), ["Task 12"])
        XCTAssertFalse(result.tails[runner.id, default: ""].contains("key-body-that-must-stay-hidden"))
        XCTAssertTrue(result.tails[runner.id, default: ""].contains("task 12 repo is"))
    }

    // MARK: Job message parsing (LOG-4)

    func testNestedJobMessageIsParsedOnceAndQuickly() async throws {
        let runner = try githubRunner()
        let guid = "55555555-5555-5555-5555-555555555555"
        var rows = ["[2026-10-16 10:00:00Z INFO Worker] Job message:", "{", "\"jobId\": \"\(guid)\",", "\"jobDisplayName\": \"nested\",",
            #""contextData": {"github": {"t": 2, "d": [{"k": "workflow", "v": "Deep workflow"}, {"k": "note", "v": "a } brace, an escaped \" quote and a { brace"}]}},"#,
            "\"steps\": ["]
        // 3,000 nested objects, each closing on a line of its own.
        let pad = String(repeating: "p", count: 100)
        for chain in 0..<30 {
            for _ in 0..<100 { rows.append("{\"pad\": \"\(pad)\", \"n\":") }
            rows.append("1")
            for _ in 0..<100 { rows.append("}") }
            if chain < 29 { rows.append(",") }
        }
        rows += ["]", "}", "[2026-10-16 10:00:01Z INFO JobRunner] Job ID \(guid)", ""]
        try write(rows.joined(separator: "\n"), to: diag(runner, "Worker_20261016-100000-utc.log"))
        let started = Date()
        let result = await RunnerLogMonitor().scan(runners: [runner])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let job = result.jobs.first { $0.id.hasSuffix(guid) }
        XCTAssertEqual(job?.workflow, "Deep workflow"); XCTAssertEqual(job?.name, "nested")
    }

    // MARK: Long lines (LOG-6)

    func testPathologicalLongLinesScanQuickly() async throws {
        let runner = try githubRunner()
        let jobs = String(repeating: "Job ", count: 512 * 1024 / 4)
        try write("""
        [2026-10-16 10:00:00Z INFO Terminal] Step completed with result: \(jobs)
        [2026-10-16 10:00:01Z INFO Terminal] \(jobs)
        [2026-10-16 10:00:02Z INFO Terminal] after the long lines

        """, to: diag(runner, "Runner_20261016-100000-utc.log"))
        var started = Date()
        let github = await RunnerLogMonitor().scan(runners: [runner])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertTrue(github.tails[runner.id, default: ""].hasSuffix("after the long lines\n"))

        let log = root.appendingPathComponent("forgejo/daemon.log")
        let received = String(repeating: "received task 1 of job ", count: 512 * 1024 / 23)
        try write("time=\"2026-10-16T10:00:00Z\" level=info msg=\"triggered by event: \(received)\"\n", to: log)
        let forgejo = InstalledRunner(name: "forgejo-long", directory: log.deletingLastPathComponent(), provider: .forgejo, diagnosticURLs: [log])
        started = Date()
        _ = await ForgejoLogMonitor().scan(runners: [forgejo])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    // MARK: Result precedence (LOG-7)

    private let precedenceGUID = "66666666-6666-6666-6666-666666666666"
    private var listenerStart: String { """
        [2026-10-16 10:00:00Z INFO JobDispatcher] Job request 1 for plan p job \(precedenceGUID) received.
        [2026-10-16 10:00:01Z INFO Terminal] Running job: build

        """ }
    private func listenerResult(_ result: String) -> String {
        "[2026-10-16 10:02:00Z INFO JobDispatcher] finish job request for job \(precedenceGUID) with result: \(result)\n"
    }
    private func workerResult(_ result: String) -> String {
        "[2026-10-16 10:00:01Z INFO JobRunner] Job ID \(precedenceGUID)\n[2026-10-16 10:01:59Z INFO JobRunner] Job result after all job steps finish: \(result)\n"
    }

    func testListenerResultWinsOverWorkerResultInEitherOrder() async throws {
        // One scan reads Runner logs before Worker logs, so the listener result is seen first.
        let together = try githubRunner("listener-first")
        try write(listenerStart + listenerResult("Canceled"), to: diag(together, "Runner_20261016-100000-utc.log"))
        try write(workerResult("Failed"), to: diag(together, "Worker_20261016-100001-utc.log"))
        let combined = await RunnerLogMonitor().scan(runners: [together])
        XCTAssertEqual(combined.jobs.map(\.outcome), [.cancelled])
        XCTAssertEqual(combined.events.filter { $0.title.hasPrefix("Job ") && $0.title != "Job started" }.count, 1)

        // Here the worker result is seen first and the listener result arrives later.
        let split = try githubRunner("worker-first")
        let runnerLog = diag(split, "Runner_20261016-100000-utc.log")
        try write(listenerStart, to: runnerLog)
        try write(workerResult("Failed"), to: diag(split, "Worker_20261016-100001-utc.log"))
        let monitor = RunnerLogMonitor()
        let interim = await monitor.scan(runners: [split])
        XCTAssertEqual(interim.jobs.map(\.outcome), [.failure])
        try append(listenerResult("Canceled"), to: runnerLog)
        let final = await monitor.scan(runners: [split])
        XCTAssertEqual(final.jobs.map(\.outcome), [.cancelled])
        XCTAssertTrue(final.events.isEmpty, "A job finishes once; a later result only corrects the outcome")
    }

    func testUnrecognisedResultNeverReplacesConfirmedOutcome() async throws {
        let runner = try githubRunner()
        let runnerLog = diag(runner, "Runner_20261016-100000-utc.log")
        try write(listenerStart, to: runnerLog)
        try write(workerResult("Succeeded"), to: diag(runner, "Worker_20261016-100001-utc.log"))
        let monitor = RunnerLogMonitor()
        let succeeded = await monitor.scan(runners: [runner])
        XCTAssertEqual(succeeded.jobs.map(\.outcome), [.success])
        try append(listenerResult("Mystery"), to: runnerLog)
        let later = await monitor.scan(runners: [runner])
        XCTAssertEqual(later.jobs.map(\.outcome), [.success])
    }

    // MARK: Forgejo activity events (LOG-8)

    func testForgejoCompletionsRecordOneActivityEventEach() async throws {
        let log = root.appendingPathComponent("forgejo/stderr.log")
        try write("""
        time="2026-10-16T10:00:00Z" level=info msg="task 91 repo is example/project https://data.forgejo.test https://forge.example.test/"
        time="2026-10-16T10:00:30Z" level=info msg="UpdateTask returned task result RESULT_CANCELLED for a task that was in local state RESULT_UNSPECIFIED - beginning local task termination" task_id=91
        time="2026-10-16T10:00:31Z" level=trace msg="Job cancelled" jobResult=cancelled task_id=91 stage=Complete
        time="2026-10-16T10:01:00Z" level=info msg="task 92 repo is example/project https://data.forgejo.test https://forge.example.test/"
        time="2026-10-16T10:02:00Z" level=info msg="UpdateTask returned task result RESULT_FAILURE for a task that was in local state RESULT_UNSPECIFIED - beginning local task termination" task_id=92

        """, to: log)
        let runner = InstalledRunner(name: "forgejo-events", directory: log.deletingLastPathComponent(), provider: .forgejo, diagnosticURLs: [log])
        let monitor = ForgejoLogMonitor()
        let first = await monitor.scan(runners: [runner])
        let completions = first.events.filter { $0.title.hasPrefix("Job ") }.sorted { $0.date < $1.date }
        XCTAssertEqual(completions.map(\.title), ["Job cancelled", "Job failure"])
        XCTAssertEqual(completions.map(\.kind), [.warning, .failure])
        XCTAssertEqual(completions.map(\.detail), ["Task 91", "Task 92"])
        XCTAssertEqual(completions.first?.date, ISO8601DateFormatter().date(from: "2026-10-16T10:00:30Z"))
        let rescan = await monitor.scan(runners: [runner])
        XCTAssertTrue(rescan.events.isEmpty)
        try append("time=\"2026-10-16T10:03:00Z\" level=trace msg=\"Job failed\" jobResult=failure task_id=92 stage=Complete\n", to: log)
        let later = await monitor.scan(runners: [runner])
        XCTAssertTrue(later.events.isEmpty)
    }

    // MARK: Live tail (LOG-5)

    func testLiveTailIsCappedRedactedAndEndsWithLastLine() async throws {
        let runner = try githubRunner()
        let log = diag(runner, "Runner_20261016-100000-utc.log")
        var text = ""
        for index in 0..<3_000 { text += "[2026-10-16 10:00:00Z INFO Listener] line \(index) " + String(repeating: "y", count: 80) + "\n" }
        text += "[2026-10-16 10:00:01Z INFO Listener] token=TAIL_TOKEN_VALUE " + String(repeating: "z", count: 20_000) + "\n"
        text += "[2026-10-16 10:00:02Z INFO Listener] final line\n"
        try write(text, to: log)
        let monitor = RunnerLogMonitor()
        let tail = await monitor.scan(runners: [runner]).tails[runner.id] ?? ""
        XCTAssertLessThanOrEqual(tail.utf8.count, 64 * 1024)
        XCTAssertTrue(tail.hasSuffix("[2026-10-16 10:00:02Z INFO Listener] final line\n"))
        XCTAssertTrue(tail.contains("line 2999 "))
        XCTAssertFalse(tail.contains("TAIL_TOKEN_VALUE"))
        try append("[2026-10-16 10:00:03Z INFO Listener] password=APPENDED_SECRET\n", to: log)
        let next = await monitor.scan(runners: [runner]).tails[runner.id] ?? ""
        XCTAssertLessThanOrEqual(next.utf8.count, 64 * 1024)
        XCTAssertTrue(next.hasSuffix("[2026-10-16 10:00:03Z INFO Listener] password=[REDACTED]\n"))
        XCTAssertTrue(next.contains("final line\n"))
    }

    // MARK: Shared reading helpers

    func testSafeOpenRefusesLinksAndNonRegularFilesWithoutBlocking() throws {
        let file = root.appendingPathComponent("plain.log")
        try write("twelve bytes", to: file)
        let opened = try DiagnosticLogFile.open(file)
        XCTAssertEqual(opened.size, 12)
        XCTAssertEqual(try opened.handle.readToEnd(), Data("twelve bytes".utf8))
        try opened.handle.close()
        XCTAssertEqual(try DiagnosticLogFile.open(file).identity, opened.identity)

        let link = root.appendingPathComponent("link.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let folder = root.appendingPathComponent("folder.log")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A FIFO named like a log would block a plain read-only open until a writer appears.
        let fifo = root.appendingPathComponent("pipe.log")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let cases: [(URL, DiagnosticLogFile.OpenError)] = [(link, .symbolicLink), (folder, .notRegularFile),
            (fifo, .notRegularFile), (root.appendingPathComponent("absent.log"), .missing)]
        for (url, expected) in cases {
            XCTAssertThrowsError(try DiagnosticLogFile.open(url), url.lastPathComponent) { error in
                XCTAssertEqual(error as? DiagnosticLogFile.OpenError, expected, url.lastPathComponent)
            }
        }
    }

    func testFixedLayoutTimestampsMatchTheISOFormatter() {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = ["2026-10-16T10:00:00Z", "2026-10-16T10:00:00.5Z", "2026-10-16T10:00:00.12Z", "2026-10-16T10:00:00.123Z",
            "2024-02-29T23:59:59Z", "1970-01-01T00:00:00Z", "2100-03-01T00:00:00.001Z"]
        for text in parsed {
            XCTAssertEqual(DiagnosticTimestamp.parseUTC(text[...], separator: .letterT), plain.date(from: text) ?? fractional.date(from: text), text)
        }
        XCTAssertEqual(DiagnosticTimestamp.parseUTC("2026-10-16 10:00:00Z", separator: .spaceOrLetterT), plain.date(from: "2026-10-16T10:00:00Z"))
        // Anything outside the fixed layout is left to the formatter, which decides what it accepts.
        for text in ["2026-10-16 10:00:00Z", "2026-02-30T10:00:00Z", "2026-10-16T24:00:00Z", "2026-10-16T10:00:60Z",
                     "2026-10-16T10:00:00.1234Z", "2026-10-16T10:00:00+02:00", "2026-10-16T10:00:00.Z", "1969-12-31T23:59:59Z", "2026-1x-16T10:00:00Z"] {
            XCTAssertNil(DiagnosticTimestamp.parseUTC(text[...], separator: .letterT), text)
        }
    }

    func testTailBufferKeepsNewestLinesWithinCapacityAndRendersOnlyWhenChanged() throws {
        var buffer = LogTailBuffer(capacity: 1024)
        XCTAssertNil(buffer.render())
        for index in 0..<200 { buffer.append("line \(index) token=SECRET\(index)") }
        let first = try XCTUnwrap(buffer.render())
        XCTAssertLessThanOrEqual(first.utf8.count, 1024)
        XCTAssertTrue(first.hasSuffix("line 199 token=[REDACTED]\n"))
        XCTAssertFalse(first.contains("SECRET"))
        XCTAssertNil(buffer.render(), "An unchanged tail is not rebuilt")
        buffer.append("password=LONG_SECRET " + String(repeating: "é", count: 400))
        let shortened = try XCTUnwrap(buffer.render())
        XCTAssertLessThanOrEqual(shortened.utf8.count, 1024)
        XCTAssertTrue(shortened.hasSuffix(" [line shortened]\n"))
        XCTAssertFalse(shortened.contains("LONG_SECRET"))
    }

    func testByteSearchMatchesLiterals() {
        XCTAssertTrue("[2026-10-16 10:00:00Z INFO Terminal] Running job: café".containsBytes("Running job: "))
        XCTAssertTrue("café build".containsBytes("é b"))
        XCTAssertFalse("Running job".containsBytes("Running job: "))
        XCTAssertFalse("".containsBytes("x"))
        XCTAssertTrue("anything".containsBytes(""))
    }
}
