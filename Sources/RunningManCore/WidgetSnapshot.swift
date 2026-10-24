import Foundation

public enum RunnerWidgetKind: String, CaseIterable, Sendable {
    case fleet, jobs

    public var identifier: String { "ch.lkmc.RunningMan.widgets.\(rawValue)" }
    public var title: String { self == .fleet ? "Runner Fleet" : "Job Results" }
    public var url: URL { URL(string: "runningman://\(self == .fleet ? "overview" : "history")")! }
}

/// Only aggregate counts cross into the widget sandbox. No names, paths, URLs or logs.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let staleInterval: TimeInterval = 15 * 60

    public struct Fleet: Codable, Equatable, Sendable {
        public let total: Int
        public let online: Int
        public let busy: Int
        public let attention: Int
        public let stopped: Int
        public let disabled: Int
        public let unverified: Int
    }

    public struct Jobs: Codable, Equatable, Sendable {
        public let total: Int
        public let succeeded: Int
        public let failed: Int
        public let cancelled: Int
        public let running: Int
        public let unknown: Int

        public var completed: Int { succeeded + failed + cancelled }
        public var successRate: Double? { completed == 0 ? nil : Double(succeeded) / Double(completed) }
    }

    public let version: Int
    public let updatedAt: Date
    public let fleet: Fleet
    public let jobs: Jobs

    public init(runners: [RunnerSnapshot], jobs: [RunnerJob], updatedAt: Date) {
        version = Self.schemaVersion
        self.updatedAt = updatedAt
        fleet = Fleet(total: runners.count, online: runners.filter(\.isOnline).count,
                      busy: runners.filter { $0.status == .busy }.count,
                      attention: runners.filter(\.needsAttention).count,
                      stopped: runners.filter { $0.status == .stopped && !$0.isOnline }.count,
                      disabled: runners.filter { $0.status == .disabled && !$0.isOnline }.count,
                      unverified: runners.filter { $0.status == .unknown }.count)
        self.jobs = Jobs(total: jobs.count, succeeded: jobs.filter { $0.outcome == .success }.count,
                         failed: jobs.filter { $0.outcome == .failure }.count,
                         cancelled: jobs.filter { $0.outcome == .cancelled }.count,
                         running: jobs.filter { $0.outcome == .running }.count,
                         unknown: jobs.filter { $0.outcome == .unknown }.count)
    }

    private init(updatedAt: Date, fleet: Fleet, jobs: Jobs) {
        version = Self.schemaVersion
        self.updatedAt = updatedAt
        self.fleet = fleet
        self.jobs = jobs
    }

    /// Fictional gallery data, never written to the shared snapshot.
    public static func example(at date: Date) -> Self {
        Self(updatedAt: date,
             fleet: Fleet(total: 6, online: 3, busy: 2, attention: 1, stopped: 1, disabled: 1, unverified: 1),
             jobs: Jobs(total: 128, succeeded: 112, failed: 8, cancelled: 4, running: 2, unknown: 2))
    }

    public func isStale(at date: Date) -> Bool {
        let age = date.timeIntervalSince(updatedAt)
        return age < 0 || age >= Self.staleInterval
    }

    /// Validate decoded counts before any derived addition or percentage calculation.
    var isValid: Bool {
        guard version == Self.schemaVersion, updatedAt.timeIntervalSince1970.isFinite,
              fleet.total >= 0, jobs.total >= 0 else { return false }
        guard [fleet.online, fleet.busy, fleet.attention, fleet.stopped, fleet.disabled, fleet.unverified]
            .allSatisfy({ (0...fleet.total).contains($0) }), fleet.busy <= fleet.online else { return false }

        var remaining = jobs.total
        for count in [jobs.succeeded, jobs.failed, jobs.cancelled, jobs.running, jobs.unknown] {
            guard (0...remaining).contains(count) else { return false }
            remaining -= count
        }
        return remaining == 0
    }
}

/// Background-only file I/O. The widget receives read access to this directory alone.
public actor WidgetSnapshotStore {
    public static let relativeDirectory = "Library/Application Support/RunningMan/Widgets"
    private static let fileName = "stats.json"
    private static let byteLimit = 16 * 1024
    private static let heartbeatInterval: TimeInterval = 60
    private static let reloadInterval: TimeInterval = 5 * 60
    private let fileURL: URL
    private var lastWritten: WidgetSnapshot?
    private var lastReloaded: WidgetSnapshot?

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func fileURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(relativeDirectory, isDirectory: true).appendingPathComponent(fileName)
    }

    /// Persists changes promptly, checkpoints freshness once a minute, and bounds
    /// timeline invalidations. macOS decides when the requested reload runs.
    public func publish(_ snapshot: WidgetSnapshot) throws -> Bool {
        guard snapshot.isValid else { throw SnapshotError.invalid }
        if let previous = lastWritten {
            let elapsed = snapshot.updatedAt.timeIntervalSince(previous.updatedAt)
            guard elapsed >= 0 else { return false }
            if snapshot.fleet == previous.fleet, snapshot.jobs == previous.jobs,
               elapsed < Self.heartbeatInterval { return false }
        }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SnapshotError.invalid }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.byteLimit else { throw SnapshotError.invalid }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        lastWritten = snapshot

        if let previous = lastReloaded {
            guard snapshot.fleet != previous.fleet || snapshot.jobs != previous.jobs else { return false }
            guard snapshot.updatedAt.timeIntervalSince(previous.updatedAt) >= Self.reloadInterval else { return false }
        }
        lastReloaded = snapshot
        return true
    }

    public func load() throws -> WidgetSnapshot? {
        // Use the existing no-follow reader: URL resource metadata can stay cached
        // after a regular file is replaced by a link, and a separate check races.
        let file: DiagnosticLogFile
        do { file = try DiagnosticLogFile.open(fileURL) }
        catch DiagnosticLogFile.OpenError.missing { return nil }
        defer { try? file.handle.close() }
        guard file.size <= Self.byteLimit else { throw SnapshotError.invalid }
        let data = try file.handle.read(upToCount: Self.byteLimit + 1) ?? Data()
        guard data.count <= Self.byteLimit else { throw SnapshotError.invalid }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: data)
        guard snapshot.isValid else { throw SnapshotError.invalid }
        return snapshot
    }

    private enum SnapshotError: LocalizedError {
        case invalid
        var errorDescription: String? { "The widget snapshot is invalid or exceeds its size limit." }
    }
}
