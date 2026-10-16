import Foundation

/// Reads only public daemon logs. Forgejo normally sends job outcomes to its server,
/// so a task-start line alone is deliberately retained as unknown, never live/busy.
public actor ForgejoLogMonitor {
    private struct Cursor {
        var offset: UInt64 = 0
        var inode = ""
        var prefix = Data()
        var partial = Data()
        var privateKey = false
    }
    private var cursors: [String: Cursor] = [:]
    private var jobs: [String: RunnerJob] = [:]
    private var tails: [String: String] = [:]
    private let dateFormatter = ISO8601DateFormatter()
    private let fractionalFormatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    private let startPattern = try! NSRegularExpression(pattern: #"task ([0-9]+) repo is ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:\s|$)"#)
    private let receivedPattern = try! NSRegularExpression(pattern: #"received task ([0-9]+) of job (.+?), (?:be )?triggered by event:"#)
    public init() {}

    public func scan(runners: [InstalledRunner]) -> LogScanResult {
        var warnings: [String] = []
        var events: [ActivityEvent] = []
        var paths = Set<String>()
        for runner in runners where runner.provider == .forgejo {
            let candidates = runner.diagnosticURLs.isEmpty ? ["runner.log", "error.log"].map { runner.directory.appendingPathComponent("_diag/" + $0) } : runner.diagnosticURLs
            var budget = 2 * 1024 * 1024
            for file in Array(Set(candidates)).sorted(by: { $0.path < $1.path }).prefix(8) where budget > 0 {
                guard file.isFileURL, file.pathExtension.lowercased() == "log",
                      FileManager.default.fileExists(atPath: file.path) else { continue }
                // A log symlink must not redirect a read into .runner/config credentials.
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isSymbolicLink) == false else {
                    warnings.append("A symbolic-link diagnostic file for \(runner.name) was skipped."); continue
                }
                paths.insert(file.path)
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let inode = String(describing: attributes[.systemFileNumber] ?? "")
                    let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                    let prefix = try handle.read(upToCount: 64) ?? Data()
                    var cursor = cursors[file.path] ?? Cursor()
                    if cursor.inode != inode || size < cursor.offset || (!cursor.prefix.isEmpty && !prefix.starts(with: cursor.prefix)) { cursor = Cursor(); cursor.inode = inode }
                    cursor.prefix = prefix
                    var skipPartial = false
                    if cursor.offset == 0 && size > 1024 * 1024 {
                        cursor.offset = size - UInt64(min(budget, 512 * 1024)); skipPartial = true
                        warnings.append("Older Forgejo daemon log details were skipped for \(runner.name).")
                    }
                    try handle.seek(toOffset: cursor.offset)
                    let data = try handle.read(upToCount: min(1024 * 1024, budget)) ?? Data()
                    budget -= data.count; cursor.offset += UInt64(data.count)
                    var combined = cursor.partial; combined.append(data)
                    var start = combined.startIndex
                    while let newline = combined[start...].firstIndex(of: 10) {
                        let line = String(decoding: combined[start..<newline], as: UTF8.self)
                        if skipPartial { skipPartial = false }
                        else { process(line, runner: runner, cursor: &cursor, events: &events) }
                        start = combined.index(after: newline)
                    }
                    cursor.partial = Data(combined[start...])
                    if cursor.partial.count > 128 * 1024 { cursor.partial.removeAll() }
                    cursors[file.path] = cursor
                } catch { warnings.append("Could not read Forgejo logs for \(runner.name): \(SecretRedactor.redact(error.localizedDescription))") }
            }
        }
        cursors = cursors.filter { paths.contains($0.key) }
        tails = tails.filter { id, _ in runners.contains { $0.id == id && $0.provider == .forgejo } }
        if jobs.count > 2000 { jobs = Dictionary(uniqueKeysWithValues: jobs.values.sorted { $0.startedAt > $1.startedAt }.prefix(2000).map { ($0.id, $0) }) }
        return LogScanResult(jobs: jobs.values.sorted { $0.startedAt > $1.startedAt }, events: events,
            warnings: Array(Set(warnings)).sorted(), tails: tails)
    }

    private func process(_ line: String, runner: InstalledRunner, cursor: inout Cursor, events: inout [ActivityEvent]) {
        if line.contains("-----BEGIN ") && line.contains("PRIVATE KEY-----") { cursor.privateKey = true }
        if cursor.privateKey {
            if line.contains("-----END ") && line.contains("PRIVATE KEY-----") { cursor.privateKey = false }
            return
        }
        let safe = SecretRedactor.redact(line)
        let tail = (tails[runner.id] ?? "") + safe + "\n"
        tails[runner.id] = tail.utf8.count <= 64 * 1024 ? tail : String(tail.suffix(16 * 1024))
        var message = line
        var date: Date?
        var fields: [String: Any] = [:]
        if let data = line.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            fields = object
            message = object["msg"] as? String ?? ""
            date = (object["time"] as? String).flatMap(parseDate)
        } else if let range = line.range(of: #"time=\"[^\"]+\""#, options: .regularExpression) {
            date = parseDate(String(line[range]).dropFirst(6).dropLast().description)
            // The official daemon uses logrus TextFormatter with FullTimestamp.
            for key in ["task_id", "jobResult", "stage"] {
                let pattern = "(?:^|\\s)" + key + "=(?:\"([^\"]*)\"|([^\\s]+))"
                if let regex = try? NSRegularExpression(pattern: pattern), let values = captures(regex, in: line) {
                    fields[key] = values.first(where: { !$0.isEmpty })
                }
            }
        }
        guard let date else { return }
        if let values = captures(startPattern, in: message) {
            let key = "\(runner.id)::forgejo-task-\(values[0])"
            if jobs[key] == nil {
                jobs[key] = RunnerJob(id: key, runnerID: runner.id, name: "Task \(values[0])",
                    repository: values[1], startedAt: date, outcome: .unknown)
                events.append(ActivityEvent(date: date, runnerID: runner.id, title: "Forgejo task observed", detail: values[1]))
            }
        }
        if let values = captures(receivedPattern, in: message) {
            let key = "\(runner.id)::forgejo-task-\(values[0])"
            var job = jobs[key] ?? RunnerJob(id: key, runnerID: runner.id, name: "Task \(values[0])", startedAt: date, outcome: .unknown)
            job.name = String(SecretRedactor.redact(values[1]).prefix(256)); jobs[key] = job
        }
        // The official Reporter emits these structured fields only in trace logs.
        // A per-step result (stage=Main) must never complete the whole job.
        if let rawID = fields["task_id"], let result = fields["jobResult"] as? String, fields["stage"] as? String != "Main" {
            let taskID = String(describing: rawID)
            guard taskID.allSatisfy(\.isNumber), !taskID.isEmpty else { return }
            let key = "\(runner.id)::forgejo-task-\(taskID)"
            guard var job = jobs[key] else { return }
            let outcome: JobOutcome
            switch result { case "success": outcome = .success; case "failure": outcome = .failure; case "cancelled": outcome = .cancelled; default: return }
            job.finishedAt = max(job.startedAt, date); job.outcome = outcome; jobs[key] = job
        }
    }
    private func parseDate(_ text: String) -> Date? { fractionalFormatter.date(from: text) ?? dateFormatter.date(from: text) }
    private func captures(_ regex: NSRegularExpression, in text: String) -> [String]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
