import Foundation

/// A private, bounded local history. Completed records never regress to running on a later merge.
public actor RunnerHistoryStore {
    private let fileURL: URL
    private let maximumJobs = 2_000
    private let maximumEncodedBytes = 6 * 1024 * 1024
    private var cache: [RunnerJob]?
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> [RunnerJob] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { cache = []; return [] }
        let data = try RunnerDiscovery.smallData(at: fileURL, limit: 8 * 1024 * 1024)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([RunnerJob].self, from: data)
        let retained = Array(decoded.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }.prefix(maximumJobs)).compactMap(Self.sanitized)
        cache = retained
        return retained
    }
    public func merge(_ incoming: [RunnerJob]) throws -> [RunnerJob] {
        let previous = try load()
        var indexed = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for value in incoming {
            guard let job = Self.sanitized(value) else { continue }
            guard let old = indexed[job.id] else { indexed[job.id] = job; continue }
            let completed = old.finishedAt != nil && job.finishedAt == nil
            indexed[job.id] = RunnerJob(id: job.id, runnerID: job.runnerID,
                name: job.name.hasPrefix("Job ") && !old.name.hasPrefix("Job ") ? old.name : job.name,
                repository: job.repository ?? old.repository, workflow: job.workflow ?? old.workflow,
                runURL: job.runURL ?? old.runURL, startedAt: min(old.startedAt, job.startedAt),
                finishedAt: completed ? old.finishedAt : job.finishedAt ?? old.finishedAt,
                outcome: completed ? old.outcome : job.outcome)
        }
        var retained = Array(indexed.values.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }.prefix(maximumJobs))
        guard retained != previous else { return retained }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
