import Foundation

public enum RunnerCleanupStatus: String, Codable, CaseIterable, Sendable {
    case pending, success, partial, failed, skipped
    public var title: String {
        switch self {
        case .pending: return "Awaiting cleanup"
        case .success: return "Cleaned"
        case .partial: return "Partly cleaned"
        case .failed: return "Cleanup failed"
        case .skipped: return "Cleanup skipped"
        }
    }
}

public struct RunnerCleanupPath: Codable, Hashable, Sendable {
    public var path: String
    public var status: RunnerCleanupStatus
    /// Estimated logical bytes, not measured free disk space (APFS can share blocks).
    public var bytesRemoved: Int64
    public var filesRemoved: Int64
    public var message: String?
    public init(path: String, status: RunnerCleanupStatus, bytesRemoved: Int64 = 0,
                filesRemoved: Int64 = 0, message: String? = nil) {
        self.path = path; self.status = status; self.bytesRemoved = bytesRemoved
        self.filesRemoved = filesRemoved; self.message = message
    }
}

public struct RunnerCleanupRecord: Codable, Hashable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var id: String
    /// Bound to the discovered runner by the reader, never trusted from disk.
    public var runnerID: String
    public var repository: String
    public var runID: String
    public var runAttempt: String
    public var job: String
    public var runURL: URL?
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunnerCleanupStatus
    public var bytesRemoved: Int64
    public var filesRemoved: Int64
    public var paths: [RunnerCleanupPath]
    public var message: String?
    public var date: Date { finishedAt ?? startedAt }
    public init(id: String, runnerID: String = "", repository: String, runID: String,
                runAttempt: String, job: String, runURL: URL? = nil, startedAt: Date,
                finishedAt: Date? = nil, status: RunnerCleanupStatus, bytesRemoved: Int64 = 0,
                filesRemoved: Int64 = 0, paths: [RunnerCleanupPath] = [], message: String? = nil,
                schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion; self.id = id; self.runnerID = runnerID
        self.repository = repository; self.runID = runID; self.runAttempt = runAttempt
        self.job = job; self.runURL = runURL; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.status = status; self.bytesRemoved = bytesRemoved; self.filesRemoved = filesRemoved
        self.paths = paths; self.message = message
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, runnerID, repository, runID, runAttempt, job, runURL
        case startedAt, finishedAt, status, bytesRemoved, filesRemoved, paths, message
    }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try v.decode(String.self, forKey: .id), runnerID: "",
            repository: try v.decode(String.self, forKey: .repository), runID: try v.decode(String.self, forKey: .runID),
            runAttempt: try v.decode(String.self, forKey: .runAttempt), job: try v.decode(String.self, forKey: .job),
            runURL: try v.decodeIfPresent(URL.self, forKey: .runURL), startedAt: try v.decode(Date.self, forKey: .startedAt),
            finishedAt: try v.decodeIfPresent(Date.self, forKey: .finishedAt), status: try v.decode(RunnerCleanupStatus.self, forKey: .status),
            bytesRemoved: try v.decode(Int64.self, forKey: .bytesRemoved), filesRemoved: try v.decode(Int64.self, forKey: .filesRemoved),
            paths: try v.decode([RunnerCleanupPath].self, forKey: .paths), message: try v.decodeIfPresent(String.self, forKey: .message),
            schemaVersion: try v.decode(Int.self, forKey: .schemaVersion))
    }
}

public struct CleanupScanResult: Sendable {
    public var records: [RunnerCleanupRecord]
    public var warnings: [String]
    public init(records: [RunnerCleanupRecord] = [], warnings: [String] = []) { self.records = records; self.warnings = warnings }
}

/// Reads only bounded, non-secret cleanup receipts. Receipt paths are display data,
/// never filesystem instructions. A pending receipt cannot prove a killed job cleaned up.
public actor RunnerCleanupMonitor {
    private struct Cached {
        var size: Int
        var modified: Date
        var record: RunnerCleanupRecord?
    }
    private var cache: [URL: Cached] = [:]
    public init() {}
    public func scan(runners: [InstalledRunner]) -> CleanupScanResult {
        var records: [RunnerCleanupRecord] = [], warnings: [String] = []
        var retained = Set<URL>()
        let fm = FileManager.default
        for runner in runners where runner.provider == .github {
            let work = runner.workDirectoryURL ?? runner.directory.appendingPathComponent("_work")
            let directory = work.appendingPathComponent(".runningman-cleanup")
            let info: URLResourceValues
            do { info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
            catch {
                let code = (error as NSError).code
                if code != NSFileReadNoSuchFileError && code != NSFileNoSuchFileError { warnings.append("Could not inspect cleanup history for \(runner.name).") }
                continue
            }
            guard info.isDirectory == true, info.isSymbolicLink != true else {
                warnings.append("Cleanup history for \(runner.name) is not a regular directory."); continue
            }
            do {
                // Lazy enumeration bounds directory metadata and JSON work, even if
                // a workflow or user has accumulated an unexpectedly large history.
                guard let iterator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { continue }
                var candidates: [(URL, Int, Date)] = []
                var entries = 0
                for case let file as URL in iterator {
                    entries += 1
                    if entries > 2000 { warnings.append("Cleanup history for \(runner.name) exceeds the 2,000-file scan limit."); break }
                    guard file.pathExtension == "json", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          let size = values.fileSize, size <= 64 * 1024, let modified = values.contentModificationDate else {
                        warnings.append("Ignored unsafe or oversized cleanup receipt for \(runner.name)."); continue
                    }
                    candidates.append((file, size, modified))
                }
                let newest = candidates.sorted { $0.2 > $1.2 }.prefix(100)
                for (file, size, modified) in newest {
                    retained.insert(file)
                    let record: RunnerCleanupRecord?
                    if let saved = cache[file], saved.size == size, saved.modified == modified { record = saved.record }
                    else {
                        record = try? Self.read(file)
                        cache[file] = Cached(size: size, modified: modified, record: record)
                    }
                    guard var record else { warnings.append("Could not read a cleanup receipt for \(runner.name)."); continue }
                    record.runnerID = runner.id
                    records.append(record)
                }
            } catch { warnings.append("Could not read cleanup history for \(runner.name).") }
        }
        cache = cache.filter { retained.contains($0.key) }
        return CleanupScanResult(records: records.sorted { $0.date > $1.date }, warnings: Array(Set(warnings)).sorted())
    }
    private static func read(_ file: URL) throws -> RunnerCleanupRecord {
        let data = try RunnerDiscovery.smallData(at: file, limit: 64 * 1024)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw InvalidReceipt.invalid }
            return date
        }
        var record = try decoder.decode(RunnerCleanupRecord.self, from: RunnerDiscovery.removingBOM(data))
        guard record.schemaVersion == 1, UUID(uuidString: record.id) != nil,
              record.id.lowercased() == file.deletingPathExtension().lastPathComponent.lowercased(),
              record.bytesRemoved >= 0, record.filesRemoved >= 0, !record.paths.isEmpty, record.paths.count <= 16,
              record.repository.utf8.count <= 512, record.job.utf8.count <= 256,
              record.runID.range(of: #"\A[0-9]{1,64}\z"#, options: .regularExpression) != nil,
              record.runAttempt.range(of: #"\A[0-9]{1,32}\z"#, options: .regularExpression) != nil,
              record.status == .pending ? (record.finishedAt == nil && record.bytesRemoved == 0 && record.filesRemoved == 0 && record.paths.allSatisfy { $0.status == .pending && $0.bytesRemoved == 0 && $0.filesRemoved == 0 }) : record.finishedAt != nil,
              record.startedAt.timeIntervalSince1970 >= 0,
              record.startedAt <= Date().addingTimeInterval(86400),
              (record.finishedAt == nil || (record.finishedAt! >= record.startedAt && record.finishedAt! <= Date().addingTimeInterval(86400))),
              record.status != .success || record.paths.allSatisfy({ $0.status == .success }),
              record.paths.allSatisfy({ $0.path.utf8.count <= 4096 && $0.bytesRemoved >= 0 && $0.filesRemoved >= 0 }) else { throw InvalidReceipt.invalid }
        record.repository = SecretRedactor.redact(record.repository)
        record.job = SecretRedactor.redact(record.job)
        record.message = record.message.map { boundedDisplay($0, utf8Limit: 2048) }
        record.paths = record.paths.map { path in
            var path = path; path.path = SecretRedactor.redact(path.path); path.message = path.message.map { boundedDisplay($0, utf8Limit: 1024) }; return path
        }
        if let url = record.runURL {
            guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.absoluteString.utf8.count <= 2048, SecretRedactor.redact(url.absoluteString) == url.absoluteString else { record.runURL = nil; return record }
        }
        return record
    }
    private static func boundedDisplay(_ value: String, utf8Limit: Int) -> String {
        let redacted = SecretRedactor.redact(value)
        guard redacted.utf8.count > utf8Limit else { return redacted }
        var result = "", bytes = 0
        // Scalar boundaries preserve valid UTF-8 while also bounding pathological
        // graphemes containing thousands of combining characters.
        for scalar in redacted.unicodeScalars {
            let count = scalar.utf8.count
            guard bytes + count <= utf8Limit - 3 else { break }
            result.unicodeScalars.append(scalar); bytes += count
        }
        return result + "…"
    }
    private enum InvalidReceipt: Error { case invalid }
}
