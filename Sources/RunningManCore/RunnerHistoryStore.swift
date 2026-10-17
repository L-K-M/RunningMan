import Foundation

/// A private, bounded local history. Completed records never regress to running on a later merge.
public actor RunnerHistoryStore {
    /// Decodes one array element without failing the whole file when that element is invalid.
    private struct LossyJob: Decodable {
        var job: RunnerJob?
        init(from decoder: Decoder) throws { job = try? RunnerJob(from: decoder) }
    }
    private let fileURL: URL
    private let maximumJobs = 2_000
    private let maximumFileBytes = 8 * 1024 * 1024
    private let maximumEncodedBytes = 6 * 1024 * 1024
    private var cache: [RunnerJob]?
    private var recoveryNotice: String?
    public init(fileURL: URL) { self.fileURL = fileURL }

    /// An unusable file never disables history. A file that cannot be decoded at all is moved
    /// aside and history starts empty; invalid records are left out after the original file is
    /// copied aside. Read errors still throw, so a file that may be valid is never set aside.
    public func load() throws -> [RunnerJob] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { cache = []; return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try SavedStoreFile.contents(of: fileURL, limit: maximumFileBytes),
              let records = try? decoder.decode([LossyJob].self, from: data) else {
            let moved = try SavedStoreFile.moveAside(fileURL)
            recoveryNotice = "Your saved job history could not be read. It was moved to \(Self.displayPath(moved)), and a new history was started."
            cache = []
            return []
        }
        let valid = records.compactMap { $0.job.flatMap(Self.sanitized) }
        var seen = Set<String>()
        let retained = Array(valid.sorted(by: Self.newestFirst).filter { seen.insert($0.id).inserted }.prefix(maximumJobs))
        let skipped = records.count - valid.count
        guard skipped > 0 else { cache = retained; return retained }

        // Rewrite without the invalid records so the next launch neither warns nor copies again.
        // If that write fails, the cached history keeps working and the next changing merge retries it.
        let copy = try SavedStoreFile.copyAside(fileURL)
        recoveryNotice = (skipped == 1 ? "1 saved job record could not be read and was" : "\(skipped) saved job records could not be read and were")
            + " left out. The original file was kept at \(Self.displayPath(copy))."
        cache = retained
        return try write(retained)
    }
    /// Returns the message about a recovered history file once, then nil.
    public func takeRecoveryNotice() -> String? {
        defer { recoveryNotice = nil }
        return recoveryNotice
    }
    public func merge(_ incoming: [RunnerJob]) throws -> [RunnerJob] {
        let previous = try load()
        var indexed = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for value in incoming {
            // Most polls report jobs that are already stored unchanged; skip redaction and rebuilding for them.
            guard indexed[value.id] != value, let job = Self.sanitized(value) else { continue }
            guard let old = indexed[job.id] else { indexed[job.id] = job; changed = true; continue }
            let completed = old.finishedAt != nil && job.finishedAt == nil
            let merged = RunnerJob(id: job.id, runnerID: job.runnerID,
                name: job.name.hasPrefix("Job ") && !old.name.hasPrefix("Job ") ? old.name : job.name,
                repository: job.repository ?? old.repository, workflow: job.workflow ?? old.workflow,
                runURL: job.runURL ?? old.runURL, startedAt: min(old.startedAt, job.startedAt),
                finishedAt: completed ? old.finishedAt : job.finishedAt ?? old.finishedAt,
                outcome: completed ? old.outcome : job.outcome)
            guard merged != old else { continue }
            indexed[job.id] = merged; changed = true
        }
        guard changed else { return previous }
        let retained = Array(indexed.values.sorted(by: Self.newestFirst).prefix(maximumJobs))
        guard retained != previous else { return previous }
        return try write(retained)
    }
    /// Writes compact JSON within `maximumEncodedBytes` with private permissions and caches what was written.
    private func write(_ jobs: [RunnerJob]) throws -> [RunnerJob] {
        var retained = jobs
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(retained)
        while data.count > maximumEncodedBytes, !retained.isEmpty {
            // Scale down in one step, then remeasure actual JSON bytes (including escaping).
            let target = max(0, min(retained.count - 1, retained.count * maximumEncodedBytes / data.count))
            retained = Array(retained.prefix(target))
            data = try encoder.encode(retained)
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        cache = retained
        return retained
    }
    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        cache = []
    }
    private static func displayPath(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
    private static func newestFirst(_ lhs: RunnerJob, _ rhs: RunnerJob) -> Bool {
        lhs.startedAt == rhs.startedAt ? lhs.id < rhs.id : lhs.startedAt > rhs.startedAt
    }
    private static func sanitized(_ job: RunnerJob) -> RunnerJob? {
        // Identifiers must remain exact; dropping a malformed oversized record is safer than
        // truncating its runner path and accidentally associating it with another runner.
        guard !job.id.isEmpty, !job.runnerID.isEmpty,
              job.id.utf8.count <= 4096, job.runnerID.utf8.count <= 4096 else { return nil }
        var result = job
        result.name = bounded(SecretRedactor.redact(job.name), bytes: 1024)
        result.repository = job.repository.map { bounded(SecretRedactor.redact($0), bytes: 512) }
        result.workflow = job.workflow.map { bounded(SecretRedactor.redact($0), bytes: 1024) }
        if let url = job.runURL {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil; components?.fragment = nil; components?.user = nil; components?.password = nil
            let clean = components?.scheme == "https" ? components?.url : nil
            result.runURL = (clean?.absoluteString.utf8.count ?? 0) <= 2048 ? clean : nil
        }
        return result
    }
    private static func bounded(_ string: String, bytes: Int) -> String {
        guard string.utf8.count > bytes else { return string }
        var prefix = Array(string.utf8.prefix(bytes))
        while !prefix.isEmpty {
            if let valid = String(bytes: prefix, encoding: .utf8) { return valid }
            prefix.removeLast()
        }
        return ""
    }
}
