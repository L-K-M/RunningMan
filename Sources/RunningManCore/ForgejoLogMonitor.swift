import Foundation

/// Reads only public daemon logs. Forgejo normally sends job outcomes to its server,
/// so a task-start line alone is deliberately retained as unknown, never live/busy.
public actor ForgejoLogMonitor {
    private struct Cursor {
        var offset: UInt64 = 0
        var inode = ""
        var prefix = Data()
        var partial = Data()
        /// False until the file has been read once; only a first read may jump to the tail.
        var seen = false
        /// Set after a jump into the file: bytes up to the next newline end a cut line.
        var discardsFragment = false
        var privateKey = false
        var privateKeyLines = 0
    }
    /// The parts of a structured (JSON or logrus text) daemon log line.
    private struct Record {
        var message: String
        var date: Date?
        var fields: [String: Any]
    }
    private var cursors: [String: Cursor] = [:]
    private var jobs: [String: RunnerJob] = [:]
    private var tails: [String: String] = [:]
    private var tailBuffers: [String: LogTailBuffer] = [:]
    private let dateFormatter = ISO8601DateFormatter()
    private let fractionalFormatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private let readBudget = 2 * 1024 * 1024
    private let startPattern = try! NSRegularExpression(pattern: #"task ([0-9]+) repo is ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:\s|$)"#)
    // Bounded and lazy: job names may contain commas (matrix values), but a line repeating
    // the prefix must not make every occurrence scan to the end of the line.
    private let receivedPattern = try! NSRegularExpression(pattern: #"received task ([0-9]{1,20}) of job ([^\n]{1,512}?), (?:be )?triggered by event:"#)
    private let serverResultPattern = try! NSRegularExpression(pattern: #"UpdateTask returned task result (RESULT_[A-Z]+) for a task"#)
    private let timePattern = try! NSRegularExpression(pattern: #"time="([^"]+)""#)
    // The official daemon uses logrus TextFormatter with FullTimestamp.
    private let fieldPatterns: [(key: String, regex: NSRegularExpression)] = ["task_id", "jobResult", "stage"].map { key in
        (key, try! NSRegularExpression(pattern: "(?:^|\\s)" + key + "=(?:\"([^\"]*)\"|([^\\s]+))"))
    }
    public init() {}

    public func scan(runners: [InstalledRunner]) -> LogScanResult {
        var warnings: [String] = []
        var events: [ActivityEvent] = []
        var paths = Set<String>()
        for runner in runners where runner.provider == .forgejo {
            let candidates = runner.diagnosticURLs.isEmpty ? ["runner.log", "error.log"].map { runner.directory.appendingPathComponent("_diag/" + $0) } : runner.diagnosticURLs
            let context = LogRunnerContext(runner)
            var budget = readBudget
            for file in Array(Set(candidates)).sorted(by: { $0.path < $1.path }).prefix(8) {
                guard file.isFileURL, file.pathExtension.lowercased() == "log" else { continue }
                // A file skipped for budget keeps its cursor and resumes on a later scan.
                paths.insert(file.path)
                guard budget > 0 else { continue }
                do {
                    // The safe open refuses a log symlink, which could redirect a read into .runner/config credentials.
                    let log = try DiagnosticLogFile.open(file)
                    let handle = log.handle; defer { try? handle.close() }
                    let prefix = try handle.read(upToCount: 64) ?? Data()
                    var cursor = cursors[file.path] ?? Cursor()
                    if cursor.inode != log.identity || log.size < cursor.offset || (!cursor.prefix.isEmpty && !prefix.starts(with: cursor.prefix)) { cursor = Cursor(); cursor.inode = log.identity }
                    cursor.prefix = prefix
                    // Without budget for the whole tail window, wait for a later scan rather than
                    // landing the cursor near the end and skipping the newest tasks for good.
                    if !cursor.seen && log.size > DiagnosticLogLimits.largeFile {
                        guard budget >= DiagnosticLogLimits.tailWindow else { cursors[file.path] = nil; continue }
                        cursor.offset = log.size - UInt64(DiagnosticLogLimits.tailWindow); cursor.discardsFragment = true
                        warnings.append("Older Forgejo daemon log details were skipped for \(runner.name).")
                    }
                    cursor.seen = true
                    try handle.seek(toOffset: cursor.offset)
                    let data = try handle.read(upToCount: min(DiagnosticLogLimits.readChunk, budget)) ?? Data()
                    budget -= data.count; cursor.offset += UInt64(data.count)
                    var combined = cursor.partial; combined.append(data)
                    var start = combined.startIndex
                    if cursor.discardsFragment {
                        if let newline = combined.firstIndex(of: 10) { start = combined.index(after: newline); cursor.discardsFragment = false }
                        else { start = combined.endIndex }
                    }
                    while let newline = combined[start...].firstIndex(of: 10) {
                        process(String(decoding: combined[start..<newline], as: UTF8.self), runner: context, cursor: &cursor, events: &events)
                        start = combined.index(after: newline)
                    }
                    cursor.partial = Data(combined[start...])
                    if cursor.partial.count > DiagnosticLogLimits.partialLine { cursor.partial.removeAll(); cursor.discardsFragment = true }
                    cursors[file.path] = cursor
                } catch DiagnosticLogFile.OpenError.missing {
                    continue
                } catch DiagnosticLogFile.OpenError.symbolicLink {
                    warnings.append("A symbolic-link diagnostic file for \(runner.name) was skipped.")
                } catch DiagnosticLogFile.OpenError.notRegularFile {
                    warnings.append("A diagnostic entry for \(runner.name) that is not a regular file was skipped.")
                } catch { warnings.append("Could not read Forgejo logs for \(runner.name): \(SecretRedactor.redact(error.localizedDescription))") }
            }
        }
        cursors = cursors.filter { paths.contains($0.key) }
        let runnerIDs = Set(runners.filter { $0.provider == .forgejo }.map(\.id))
        tailBuffers = tailBuffers.filter { runnerIDs.contains($0.key) }
        for id in Array(tailBuffers.keys) {
            if let tail = tailBuffers[id]?.render() { tails[id] = tail }
        }
        tails = tails.filter { runnerIDs.contains($0.key) }
        if jobs.count > 2000 { jobs = Dictionary(uniqueKeysWithValues: jobs.values.sorted { $0.startedAt > $1.startedAt }.prefix(2000).map { ($0.id, $0) }) }
        return LogScanResult(jobs: jobs.values.sorted { $0.startedAt > $1.startedAt }, events: events,
            warnings: Array(Set(warnings)).sorted(), tails: tails)
    }

    private func process(_ line: String, runner: LogRunnerContext, cursor: inout Cursor, events: inout [ActivityEvent]) {
        let record = record(line)
        if cursor.privateKey {
            if record == nil {
                cursor.privateKeyLines += 1
                if PrivateKeyMarker.ends(line) || cursor.privateKeyLines >= DiagnosticLogLimits.privateKeyLines { cursor.privateKey = false }
                return
            }
            // A structured daemon line is never part of a PEM body, so a header mentioned
            // without its END line cannot hide the rest of the log.
            cursor.privateKey = false
        }
        if PrivateKeyMarker.begins(line) {
            cursor.privateKey = !PrivateKeyMarker.ends(line); cursor.privateKeyLines = 0
            return
        }
        tailBuffers[runner.id, default: LogTailBuffer()].append(line)
        guard let record, let date = record.date else { return }
        let message = DiagnosticLogLimits.parsedPrefix(record.message), fields = record.fields
        if message.containsBytes(" repo is "), let values = captures(startPattern, in: message) {
            let key = "\(runner.id)::forgejo-task-\(values[0])"
            if jobs[key] == nil {
                jobs[key] = RunnerJob(id: key, runnerID: runner.id, name: "Task \(values[0])",
                    repository: values[1], startedAt: date, outcome: .unknown)
                events.append(ActivityEvent(date: date, runnerID: runner.id, title: "Forgejo task observed", detail: values[1]))
            }
        }
        if message.containsBytes("received task "), message.containsBytes("triggered by event:"), let values = captures(receivedPattern, in: message) {
            let key = "\(runner.id)::forgejo-task-\(values[0])"
            var job = jobs[key] ?? RunnerJob(id: key, runnerID: runner.id, name: "Task \(values[0])", startedAt: date, outcome: .unknown)
            job.name = String(SecretRedactor.redact(values[1]).prefix(256)); jobs[key] = job
        }
        // The Reporter logs at info level when the server cancels or fails a task;
        // the job then terminates locally. A later trace jobResult line still wins.
        if let rawID = fields["task_id"], message.containsBytes("UpdateTask returned task result "),
           let values = captures(serverResultPattern, in: message) {
            switch values[0] {
            case "RESULT_CANCELLED": complete(rawID, runner: runner, outcome: .cancelled, at: date, events: &events)
            case "RESULT_FAILURE": complete(rawID, runner: runner, outcome: .failure, at: date, events: &events)
            default: break
            }
        }
        // The official Reporter emits these structured fields only in trace logs.
        // A per-step result (stage=Main) must never complete the whole job.
        if let rawID = fields["task_id"], let result = fields["jobResult"] as? String, fields["stage"] as? String != "Main" {
            switch result {
            case "success": complete(rawID, runner: runner, outcome: .success, at: date, events: &events)
            case "failure": complete(rawID, runner: runner, outcome: .failure, at: date, events: &events)
            case "cancelled": complete(rawID, runner: runner, outcome: .cancelled, at: date, events: &events)
            default: return
            }
        }
    }
    /// Parses a JSON or logrus text line. JSON is only attempted for a line that starts
    /// with "{", and the text fields only when their key appears in the line.
    private func record(_ line: String) -> Record? {
        if line.utf8.first(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") }) == UInt8(ascii: "{"),
           let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] {
            return Record(message: object["msg"] as? String ?? "", date: (object["time"] as? String).flatMap(parseDate), fields: object)
        }
        guard line.containsBytes("time=\""), let time = captures(timePattern, in: line)?.first else { return nil }
        var fields: [String: Any] = [:]
        for (key, regex) in fieldPatterns where line.containsBytes(key + "=") {
            if let values = captures(regex, in: line) { fields[key] = values.first(where: { !$0.isEmpty }) }
        }
        return Record(message: line, date: parseDate(time), fields: fields)
    }
    /// Records the activity event only for the first completion, so a later trace result
    /// for the same task, or a rescan after a cursor reset, never repeats it.
    private func complete(_ rawID: Any, runner: LogRunnerContext, outcome: JobOutcome, at date: Date, events: inout [ActivityEvent]) {
        let taskID = String(describing: rawID)
        guard taskID.allSatisfy(\.isNumber), !taskID.isEmpty else { return }
        let key = "\(runner.id)::forgejo-task-\(taskID)"
        guard var job = jobs[key] else { return }
        let firstCompletion = job.finishedAt == nil
        job.finishedAt = max(job.startedAt, date); job.outcome = outcome; jobs[key] = job
        if firstCompletion { events.append(.jobFinished(job, at: date)) }
    }
    private func parseDate(_ text: String) -> Date? {
        DiagnosticTimestamp.parseUTC(text[...], separator: .letterT) ?? fractionalFormatter.date(from: text) ?? dateFormatter.date(from: text)
    }
    private func captures(_ regex: NSRegularExpression, in text: String) -> [String]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
