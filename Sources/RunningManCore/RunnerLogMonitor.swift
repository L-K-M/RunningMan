import Foundation

/// Incremental, bounded diagnostic reader. All file work is serialized off the UI actor.
public actor RunnerLogMonitor {
    private struct Cursor {
        var offset: UInt64 = 0
        var identity: String = ""
        var prefix = Data()
        var partial = Data()
        var pendingID: String?
        var activeID: String?
        var workerID: String?
        var message: String?
        var messageDate: Date?
        var inJobContext = false
        var inPrivateKey = false
    }
    private var cursors: [String: Cursor] = [:]
    private var jobs: [String: RunnerJob] = [:]
    private var tails: [String: String] = [:]
    private let formatter = ISO8601DateFormatter()
    private let fractionalFormatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private let maxTail = 64 * 1024
    private var expressions: [String: NSRegularExpression] = [:]
    public init() {}

    public func scan(runners: [InstalledRunner]) -> LogScanResult {
        var warnings: [String] = []
        var events: [ActivityEvent] = []
        var livePaths = Set<String>()
        for runner in runners where runner.provider == .github {
            let directory = runner.directory.appendingPathComponent("_diag")
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            let logs = urls.filter { $0.pathExtension == "log" }
            let files = Array(logs.filter { $0.lastPathComponent.hasPrefix("Runner_") }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(8))
                + Array(logs.filter { $0.lastPathComponent.hasPrefix("Worker_") }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(24))
            // Parse runner timelines first, then enrich those jobs with the worker's JSON context.
            let ordered = files.sorted {
                let left = $0.lastPathComponent, right = $1.lastPathComponent
                if left.hasPrefix("Runner_") != right.hasPrefix("Runner_") { return left.hasPrefix("Runner_") }
                return left < right
            }
            var budget = 8 * 1024 * 1024
            for file in ordered where budget > 0 {
                livePaths.insert(file.path)
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let identity = String(describing: attributes[.systemFileNumber] ?? "")
                    var cursor = cursors[file.path] ?? Cursor()
                    if cursor.identity != identity || size < cursor.offset { cursor = Cursor(); cursor.identity = identity }
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    let prefix = try handle.read(upToCount: 64) ?? Data()
                    if !cursor.prefix.isEmpty && !prefix.starts(with: cursor.prefix) {
                        cursor = Cursor(); cursor.identity = identity
                    }
                    cursor.prefix = prefix
                    try handle.seek(toOffset: 0)
                    // Keep the metadata header and the most recent activity of very large first-seen logs.
                    if cursor.offset == 0 && size > 1024 * 1024 {
                        let header = try handle.read(upToCount: min(128 * 1024, budget)) ?? Data()
                        budget -= header.count
                        consume(header, cursor: &cursor, runner: runner, events: &events)
                        cursor.partial.removeAll(); cursor.message = nil
                        cursor.offset = size - UInt64(min(512 * 1024, budget))
                        try handle.seek(toOffset: cursor.offset)
                        // The first tail line may be incomplete, so discard it.
                        cursor.partial = Data()
                        warnings.append("Older details in \(runner.name)’s large log were skipped; retained job history stays available.")
                    } else { try handle.seek(toOffset: cursor.offset) }
                    let data = try handle.read(upToCount: min(1024 * 1024, budget)) ?? Data()
                    cursor.offset += UInt64(data.count); budget -= data.count
                    consume(data, cursor: &cursor, runner: runner, events: &events)
                    cursors[file.path] = cursor
                } catch {
                    warnings.append("Could not read diagnostics for \(runner.name): \(SecretRedactor.redact(error.localizedDescription))")
                }
            }
        }
        cursors = cursors.filter { livePaths.contains($0.key) }
        let runnerIDs = Set(runners.map(\.id))
        tails = tails.filter { runnerIDs.contains($0.key) }
        if jobs.count > 2_000 {
            let retained = jobs.values.sorted { $0.startedAt > $1.startedAt }.prefix(2_000)
            jobs = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        }
        return LogScanResult(jobs: jobs.values.sorted { $0.startedAt > $1.startedAt },
            events: events, warnings: Array(Set(warnings)).sorted(), tails: tails)
    }

    private func consume(_ data: Data, cursor: inout Cursor, runner: InstalledRunner, events: inout [ActivityEvent]) {
        var combined = cursor.partial
        combined.append(data)
        var start = combined.startIndex
        while let newline = combined[start...].firstIndex(of: 10) {
            let line = String(decoding: combined[start..<newline], as: UTF8.self).trimmingCharacters(in: .newlines)
            process(line, cursor: &cursor, runner: runner, events: &events)
            start = combined.index(after: newline)
        }
        cursor.partial = Data(combined[start...])
        // A corrupt or malicious log must not retain an unlimited line in memory.
        if cursor.partial.count > 128 * 1024 {
            appendTail("[An oversized diagnostic line was omitted.]", runnerID: runner.id)
            cursor.partial.removeAll(); cursor.message = nil
        }
    }

    private func process(_ line: String, cursor: inout Cursor, runner: InstalledRunner, events: inout [ActivityEvent]) {
        let date = timestamp(line)
        if line.contains("Worker] Job message:") {
            cursor.message = ""; cursor.messageDate = date; cursor.inJobContext = true
            appendTail("[Job context omitted from live logs to protect variables and credentials.]", runnerID: runner.id)
            return
        }
        if cursor.inJobContext {
            if date == nil {
                if var message = cursor.message {
                    message += line + "\n"
                    if message.utf8.count <= 512 * 1024 {
                        cursor.message = message
                        if line.trimmingCharacters(in: .whitespaces) == "}",
                           let data = message.data(using: .utf8),
                           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                            parseContext(object, runner: runner, cursor: &cursor)
                            cursor.message = nil
                        }
                    } else { cursor.message = nil }
                }
                return
            }
            cursor.message = nil; cursor.inJobContext = false
        }
        if line.contains("-----BEGIN ") && line.contains("PRIVATE KEY-----") {
            cursor.inPrivateKey = true
            appendTail("[Private key omitted from diagnostics.]", runnerID: runner.id)
        }
        if cursor.inPrivateKey {
            if line.contains("-----END ") && line.contains("PRIVATE KEY-----") { cursor.inPrivateKey = false }
            return
        }
        appendTail(line, runnerID: runner.id)
        guard let date else { return }
        if let id = capture(#"Job request \d+ for plan \S+ job ([A-Za-z0-9-]+) received\."#, line) {
            cursor.pendingID = jobKey(runner: runner, id: id)
        }
        if let name = capture(#"Running job: (.+)$"#, line) {
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
        if let parts = captures(#"finish job request for job ([A-Za-z0-9-]+) with result: ([A-Za-z]+)"#, line), parts.count == 2 {
            let id = jobKey(runner: runner, id: parts[0])
            finish(id, outcome: outcome(parts[1]), date: date, runner: runner, events: &events)
            if cursor.activeID == id { cursor.activeID = nil }
        } else if let parts = captures(#"Job (.+) completed with result: ([A-Za-z]+)"#, line), parts.count == 2 {
            let matching = cursor.activeID ?? jobs.values.filter {
                $0.runnerID == runner.id && $0.name == metadata(parts[0]) && $0.startedAt <= date && $0.finishedAt == nil
            }.max(by: { $0.startedAt < $1.startedAt })?.id
            if let id = matching { finish(id, outcome: outcome(parts[1]), date: date, runner: runner, events: &events) }
            cursor.activeID = nil
        }
        if let id = capture(#"JobRunner\] Job ID ([A-Za-z0-9-]+)"#, line) {
            cursor.workerID = jobKey(runner: runner, id: id)
            if jobs[cursor.workerID!] == nil {
                jobs[cursor.workerID!] = RunnerJob(id: cursor.workerID!, runnerID: runner.id,
                    name: "Job \(id.prefix(8))", repository: runner.repository, startedAt: date)
            }
        }
        if let result = capture(#"Job result after all job steps finish: ([A-Za-z]+)"#, line), let id = cursor.workerID {
            finish(id, outcome: outcome(result), date: date, runner: runner, events: &events)
        }
    }

    private func parseContext(_ object: [String: Any], runner: InstalledRunner, cursor: inout Cursor) {
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

    private func finish(_ id: String, outcome: JobOutcome, date: Date, runner: InstalledRunner, events: inout [ActivityEvent]) {
        guard var job = jobs[id] else { return }
        let changed = job.finishedAt == nil
        job.outcome = outcome
        // Prefer the listener's completed timestamp if both listener and worker report completion.
        job.finishedAt = max(job.finishedAt ?? date, date)
        jobs[id] = job
        if changed {
            events.append(ActivityEvent(date: date, runnerID: runner.id, title: "Job \(outcome.title.lowercased())",
                detail: job.name, kind: outcome == .success ? .success : outcome == .failure ? .failure : .warning))
        }
    }
    private func appendTail(_ line: String, runnerID: String) {
        let safe = SecretRedactor.redact(line)
        let combined = (tails[runnerID] ?? "") + safe + "\n"
        tails[runnerID] = combined.utf8.count <= maxTail ? combined : String(combined.suffix(maxTail / 2))
    }
    private func timestamp(_ line: String) -> Date? {
        guard line.first == "[", let z = line.firstIndex(of: "Z"), line.distance(from: line.startIndex, to: z) < 35 else { return nil }
        let text = String(line[line.index(after: line.startIndex)...z]).replacingOccurrences(of: " ", with: "T")
        return formatter.date(from: text) ?? fractionalFormatter.date(from: text)
    }
    private func jobKey(runner: InstalledRunner, id: String) -> String { "\(runner.id)::\(id.lowercased())" }
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
