import Foundation

/// Incremental, bounded diagnostic reader. All file work is serialized off the UI actor.
public actor RunnerLogMonitor {
    private struct Cursor {
        var offset: UInt64 = 0
        var identity: String = ""
        var prefix = Data()
        var partial = Data()
        /// False until the file has been read once; only a first read may jump to the tail.
        var seen = false
        /// Set after a jump into the file: bytes up to the next newline end a cut line.
        var discardsFragment = false
        /// Set after a jump to the tail: untimestamped lines may continue a skipped job message or key.
        var suppressesUntimestamped = false
        var pendingID: String?
        var activeID: String?
        var workerID: String?
        var message: JobMessage?
        var messageDate: Date?
        var inJobContext = false
        var inPrivateKey = false
        var privateKeyLines = 0
    }
    /// Collects a multi-line job message as bytes and tracks brace depth outside JSON
    /// strings, so the message is parsed once, when its outermost object closes.
    private struct JobMessage {
        enum Progress { case open, closed, malformed }
        private(set) var data = Data()
        private var depth = 0
        private var inString = false
        private var escaped = false

        mutating func append(_ line: String) -> Progress {
            data.append(contentsOf: line.utf8); data.append(10)
            for byte in line.utf8 {
                if inString {
                    if escaped { escaped = false }
                    else if byte == UInt8(ascii: "\\") { escaped = true }
                    else if byte == UInt8(ascii: "\"") { inString = false }
                    continue
                }
                switch byte {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"): depth += 1
                case UInt8(ascii: "}"):
                    depth -= 1
                    if depth < 0 { return .malformed }
                    if depth == 0 { return .closed }
                default: break
                }
            }
            return .open
        }
    }
    /// Which log reported a job's result. The listener reports what GitHub recorded,
    /// so its result may replace the worker's but not the reverse.
    private enum ResultSource: Int, Comparable {
        case worker, listener
        static func < (left: ResultSource, right: ResultSource) -> Bool { left.rawValue < right.rawValue }
    }
    private var cursors: [String: Cursor] = [:]
    private var jobs: [String: RunnerJob] = [:]
    private var resultSources: [String: ResultSource] = [:]
    private var tails: [String: String] = [:]
    private var tailBuffers: [String: LogTailBuffer] = [:]
    private let formatter = ISO8601DateFormatter()
    private let fractionalFormatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private let readBudget = 8 * 1024 * 1024
    private let headerBytes = 128 * 1024
    private let maxMessage = 512 * 1024
    private var expressions: [String: NSRegularExpression] = [:]
    public init() {}

    public func scan(runners: [InstalledRunner]) -> LogScanResult {
        var warnings: [String] = []
        var events: [ActivityEvent] = []
        var livePaths = Set<String>()
        for runner in runners where runner.provider == .github {
            let directory = runner.directory.appendingPathComponent("_diag")
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            // A log symlink must not redirect a read into .credentials or other runner secrets.
            let logs = urls.filter { url in
                let name = url.lastPathComponent
                guard url.pathExtension == "log", name.hasPrefix("Runner_") || name.hasPrefix("Worker_"),
                      let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { return false }
                if values.isSymbolicLink == true {
                    warnings.append("A symbolic-link diagnostic file for \(runner.name) was skipped."); return false
                }
                if values.isRegularFile != true {
                    warnings.append("A diagnostic entry for \(runner.name) that is not a regular file was skipped."); return false
                }
                return true
            }
            let files = Array(logs.filter { $0.lastPathComponent.hasPrefix("Runner_") }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(8))
                + Array(logs.filter { $0.lastPathComponent.hasPrefix("Worker_") }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(24))
            // Parse runner timelines first, then enrich those jobs with the worker's JSON context.
            let ordered = files.sorted {
                let left = $0.lastPathComponent, right = $1.lastPathComponent
                if left.hasPrefix("Runner_") != right.hasPrefix("Runner_") { return left.hasPrefix("Runner_") }
                return left < right
            }
            let context = LogRunnerContext(runner)
            var budget = readBudget
            for file in ordered {
                // A file skipped for budget keeps its cursor and resumes on a later scan.
                livePaths.insert(file.path)
                guard budget > 0 else { continue }
                do {
                    let log = try DiagnosticLogFile.open(file)
                    let handle = log.handle
                    defer { try? handle.close() }
                    var cursor = cursors[file.path] ?? Cursor()
                    if cursor.identity != log.identity || log.size < cursor.offset { cursor = Cursor(); cursor.identity = log.identity }
                    let prefix = try handle.read(upToCount: 64) ?? Data()
                    if !cursor.prefix.isEmpty && !prefix.starts(with: cursor.prefix) {
                        cursor = Cursor(); cursor.identity = log.identity
                    }
                    cursor.prefix = prefix
                    // Keep the metadata header and the most recent activity of very large first-seen logs.
                    // Without budget for both, wait for a later scan: a smaller tail would land
                    // the cursor near the end and skip the newest jobs until the log rotates.
                    if !cursor.seen && log.size > DiagnosticLogLimits.largeFile {
                        guard budget >= headerBytes + DiagnosticLogLimits.tailWindow else { cursors[file.path] = nil; continue }
                        try handle.seek(toOffset: 0)
                        let header = try handle.read(upToCount: headerBytes) ?? Data()
                        budget -= header.count
                        consume(header, cursor: &cursor, runner: context, events: &events)
                        // Line state from the header does not describe the bytes after the jump.
                        // workerID stays: a Worker_ log belongs to exactly one job, and its ID in
                        // the header is what lets the result in the tail finish that job.
                        cursor.partial.removeAll(); cursor.message = nil
                        cursor.inJobContext = false; cursor.inPrivateKey = false
                        cursor.pendingID = nil; cursor.activeID = nil
                        cursor.discardsFragment = true; cursor.suppressesUntimestamped = true
                        cursor.offset = log.size - UInt64(DiagnosticLogLimits.tailWindow)
                        warnings.append("Older details in \(runner.name)’s large log were skipped; retained job history stays available.")
                    }
                    cursor.seen = true
                    try handle.seek(toOffset: cursor.offset)
                    let data = try handle.read(upToCount: min(DiagnosticLogLimits.readChunk, budget)) ?? Data()
                    cursor.offset += UInt64(data.count); budget -= data.count
                    consume(data, cursor: &cursor, runner: context, events: &events)
                    cursors[file.path] = cursor
                } catch DiagnosticLogFile.OpenError.missing {
                    continue
                } catch DiagnosticLogFile.OpenError.symbolicLink {
                    warnings.append("A symbolic-link diagnostic file for \(runner.name) was skipped.")
                } catch DiagnosticLogFile.OpenError.notRegularFile {
                    warnings.append("A diagnostic entry for \(runner.name) that is not a regular file was skipped.")
                } catch {
                    warnings.append("Could not read diagnostics for \(runner.name): \(SecretRedactor.redact(error.localizedDescription))")
                }
            }
        }
        cursors = cursors.filter { livePaths.contains($0.key) }
        let runnerIDs = Set(runners.map(\.id))
        tailBuffers = tailBuffers.filter { runnerIDs.contains($0.key) }
        for id in Array(tailBuffers.keys) {
            if let tail = tailBuffers[id]?.render() { tails[id] = tail }
        }
        tails = tails.filter { runnerIDs.contains($0.key) }
        if jobs.count > 2_000 {
            let retained = jobs.values.sorted { $0.startedAt > $1.startedAt }.prefix(2_000)
            jobs = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
            resultSources = resultSources.filter { jobs[$0.key] != nil }
        }
        return LogScanResult(jobs: jobs.values.sorted { $0.startedAt > $1.startedAt },
            events: events, warnings: Array(Set(warnings)).sorted(), tails: tails)
    }

    private func consume(_ data: Data, cursor: inout Cursor, runner: LogRunnerContext, events: inout [ActivityEvent]) {
        var combined = cursor.partial
        combined.append(data)
        var start = combined.startIndex
        if cursor.discardsFragment {
            guard let newline = combined.firstIndex(of: 10) else { cursor.partial.removeAll(); return }
            start = combined.index(after: newline); cursor.discardsFragment = false
        }
        while let newline = combined[start...].firstIndex(of: 10) {
            let line = String(decoding: combined[start..<newline], as: UTF8.self).trimmingCharacters(in: .newlines)
            process(line, cursor: &cursor, runner: runner, events: &events)
            start = combined.index(after: newline)
        }
        cursor.partial = Data(combined[start...])
        // A corrupt or malicious log must not retain an unlimited line in memory.
        // The rest of the dropped line arrives later and must not pass for a whole line.
        if cursor.partial.count > DiagnosticLogLimits.partialLine {
            appendTail("[An oversized diagnostic line was omitted.]", runnerID: runner.id)
            cursor.partial.removeAll(); cursor.message = nil; cursor.discardsFragment = true
        }
    }

    private func process(_ line: String, cursor: inout Cursor, runner: LogRunnerContext, events: inout [ActivityEvent]) {
        let date = timestamp(line)
        if cursor.suppressesUntimestamped {
            guard date != nil else { return }
            cursor.suppressesUntimestamped = false
        }
        if line.containsBytes("Worker] Job message:") {
            cursor.message = JobMessage(); cursor.messageDate = date; cursor.inJobContext = true
            appendTail("[Job context omitted from live logs to protect variables and credentials.]", runnerID: runner.id)
            return
        }
        if cursor.inJobContext {
            if date == nil { collectJobMessage(line, cursor: &cursor, runner: runner); return }
            cursor.message = nil; cursor.inJobContext = false
        }
        if cursor.inPrivateKey {
            if date == nil {
                cursor.privateKeyLines += 1
                if PrivateKeyMarker.ends(line) || cursor.privateKeyLines >= DiagnosticLogLimits.privateKeyLines { cursor.inPrivateKey = false }
                return
            }
            // A timestamped diagnostic line is never part of a PEM body, so a header
            // mentioned without its END line cannot hide the rest of the log.
            cursor.inPrivateKey = false
        }
        if PrivateKeyMarker.begins(line) {
            appendTail("[Private key omitted from diagnostics.]", runnerID: runner.id)
            cursor.inPrivateKey = !PrivateKeyMarker.ends(line); cursor.privateKeyLines = 0
            return
        }
        appendTail(line, runnerID: runner.id)
        guard let date else { return }
        // From here on only the bounded prefix is parsed; each pattern runs only after a cheap literal check.
        let line = DiagnosticLogLimits.parsedPrefix(line)
        if line.containsBytes("Job request "), let id = capture(#"Job request \d+ for plan \S+ job ([A-Za-z0-9-]+) received\."#, line) {
            cursor.pendingID = jobKey(runner: runner, id: id)
        }
        if line.containsBytes("Running job: "), let name = capture(#"Running job: (.+)$"#, line) {
            let id = cursor.pendingID ?? "\(runner.id)::\(date.timeIntervalSince1970)::\(name)"
            cursor.activeID = id; cursor.pendingID = nil
            let existing = jobs[id]
            jobs[id] = RunnerJob(id: id, runnerID: runner.id, name: metadata(name),
                repository: existing?.repository ?? runner.repository, workflow: existing?.workflow,
                runURL: existing?.runURL, startedAt: existing?.startedAt ?? date,
                finishedAt: existing?.finishedAt, outcome: existing?.outcome ?? .running)
            if existing == nil {
                events.append(ActivityEvent(date: date, runnerID: runner.id,
                    title: "Job started", detail: SecretRedactor.redact(name)))
            }
        }
        if line.containsBytes("finish job request for job "),
           let parts = captures(#"finish job request for job ([A-Za-z0-9-]+) with result: ([A-Za-z]+)"#, line), parts.count == 2 {
            let id = jobKey(runner: runner, id: parts[0])
            finish(id, outcome: outcome(parts[1]), source: .listener, date: date, events: &events)
            if cursor.activeID == id { cursor.activeID = nil }
        } else if line.containsBytes(" completed with result: "),
                  let parts = captures(#"Job ([^\n]{1,1024}?) completed with result: ([A-Za-z]+)"#, line), parts.count == 2 {
            let matching = cursor.activeID ?? jobs.values.filter {
                $0.runnerID == runner.id && $0.name == metadata(parts[0]) && $0.startedAt <= date && $0.finishedAt == nil
            }.max(by: { $0.startedAt < $1.startedAt })?.id
            if let id = matching { finish(id, outcome: outcome(parts[1]), source: .listener, date: date, events: &events) }
            cursor.activeID = nil
        }
        if line.containsBytes("JobRunner] Job ID "), let id = capture(#"JobRunner\] Job ID ([A-Za-z0-9-]+)"#, line) {
            cursor.workerID = jobKey(runner: runner, id: id)
            if jobs[cursor.workerID!] == nil {
                jobs[cursor.workerID!] = RunnerJob(id: cursor.workerID!, runnerID: runner.id,
                    name: "Job \(id.prefix(8))", repository: runner.repository, startedAt: date)
            }
        }
        if line.containsBytes("Job result after all job steps finish: "),
           let result = capture(#"Job result after all job steps finish: ([A-Za-z]+)"#, line), let id = cursor.workerID {
            finish(id, outcome: outcome(result), source: .worker, date: date, events: &events)
        }
    }

    private func collectJobMessage(_ line: String, cursor: inout Cursor, runner: LogRunnerContext) {
        guard let collected = cursor.message?.data.count else { return }
        guard collected + line.utf8.count + 1 <= maxMessage else { cursor.message = nil; return }
        // Mutated in place: copying the collected bytes per line would make long messages quadratic.
        switch cursor.message?.append(line) {
        case .closed:
            if let data = cursor.message?.data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                parseContext(object, runner: runner, cursor: &cursor)
            }
            cursor.message = nil
        case .malformed: cursor.message = nil
        case .open, nil: break
        }
    }

    private func parseContext(_ object: [String: Any], runner: LogRunnerContext, cursor: inout Cursor) {
        guard let rawID = object["jobId"] as? String, !rawID.isEmpty else { return }
        let id = jobKey(runner: runner, id: rawID)
        cursor.workerID = id
        let old = jobs[id]
        let name = object["jobDisplayName"] as? String ?? object["jobName"] as? String ?? old?.name ?? "Job \(rawID.prefix(8))"
        var context: [String: String] = [:]
        if let data = object["contextData"] as? [String: Any], let github = data["github"] as? [String: Any], let values = github["d"] as? [[String: Any]] {
            for pair in values {
                if let key = pair["k"] as? String, let value = pair["v"] as? String,
                   ["repository", "workflow", "run_id", "server_url"].contains(key) { context[key] = value }
            }
        }
        let repository = context["repository"] ?? old?.repository ?? runner.repository
        let server = context["server_url"] ?? "https://github.com"
        var runURL = old?.runURL
        if let runID = context["run_id"], runID.allSatisfy(\.isNumber),
           repository.split(separator: "/").count == 2,
           let base = URL(string: server), base.scheme == "https", base.host != nil, base.user == nil, base.password == nil {
            runURL = base.appendingPathComponent(repository).appendingPathComponent("actions/runs/\(runID)")
        }
        jobs[id] = RunnerJob(id: id, runnerID: runner.id, name: metadata(name),
            repository: metadata(repository), workflow: context["workflow"].map(metadata) ?? old?.workflow,
            runURL: (runURL?.absoluteString.utf8.count ?? 0) <= 2048 ? runURL : nil, startedAt: old?.startedAt ?? cursor.messageDate ?? Date(timeIntervalSince1970: 0),
            finishedAt: old?.finishedAt, outcome: old?.outcome ?? .running)
    }

    private func metadata(_ text: String) -> String {
        var prefix = Array(SecretRedactor.redact(text).utf8.prefix(1024))
        while !prefix.isEmpty {
            if let valid = String(bytes: prefix, encoding: .utf8) { return valid }
            prefix.removeLast()
        }
        return ""
    }

    private func finish(_ id: String, outcome: JobOutcome, source: ResultSource, date: Date, events: inout [ActivityEvent]) {
        guard var job = jobs[id] else { return }
        let changed = job.finishedAt == nil
        // The stored result must not depend on which scan reads which line: a confirmed
        // result beats an unrecognised one, and otherwise the listener beats the worker.
        let confirmed: (JobOutcome) -> Bool = { [.success, .failure, .cancelled].contains($0) }
        let accepted: Bool
        if let previous = resultSources[id] {
            accepted = confirmed(outcome) != confirmed(job.outcome) ? confirmed(outcome) : source >= previous
        } else { accepted = !(outcome == .unknown && confirmed(job.outcome)) }
        if accepted { job.outcome = outcome; resultSources[id] = source }
        // Prefer the listener's completed timestamp if both listener and worker report completion.
        job.finishedAt = max(job.finishedAt ?? date, date)
        jobs[id] = job
        if changed { events.append(.jobFinished(job, at: date)) }
    }
    private func appendTail(_ line: String, runnerID: String) {
        tailBuffers[runnerID, default: LogTailBuffer()].append(line)
    }
    private func timestamp(_ line: String) -> Date? {
        guard line.first == "[", let z = line.utf8.prefix(35).firstIndex(of: UInt8(ascii: "Z")) else { return nil }
        let text = line[line.index(after: line.startIndex)...z]
        if let date = DiagnosticTimestamp.parseUTC(text, separator: .spaceOrLetterT) { return date }
        let iso = text.replacingOccurrences(of: " ", with: "T")
        return formatter.date(from: iso) ?? fractionalFormatter.date(from: iso)
    }
    private func jobKey(runner: LogRunnerContext, id: String) -> String { "\(runner.id)::\(id.lowercased())" }
    private func outcome(_ text: String) -> JobOutcome {
        switch text.lowercased() {
        case "succeeded", "succeededwithissues", "success": return .success
        case "failed", "failure": return .failure
        case "canceled", "cancelled", "abandoned": return .cancelled
        default: return .unknown
        }
    }
    private func capture(_ pattern: String, _ text: String) -> String? { captures(pattern, text)?.first }
    private func captures(_ pattern: String, _ text: String) -> [String]? {
        let expression: NSRegularExpression
        if let cached = expressions[pattern] { expression = cached }
        else {
            guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
            expressions[pattern] = compiled; expression = compiled
        }
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
