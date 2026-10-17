import Foundation

public struct ObservedRunnerUsage: Equatable, Sendable {
    public var observedSeconds: TimeInterval
    public var busySeconds: TimeInterval
    public var busyFraction: Double?
    public var windowStart: Date
    public var windowEnd: Date
    public init(observedSeconds: TimeInterval, busySeconds: TimeInterval, busyFraction: Double?, windowStart: Date, windowEnd: Date) {
        self.windowStart = windowStart; self.windowEnd = max(windowStart, windowEnd)
        let duration = self.windowEnd.timeIntervalSince(windowStart)
        self.observedSeconds = observedSeconds.isFinite ? min(duration, max(0, observedSeconds)) : 0
        self.busySeconds = busySeconds.isFinite ? min(self.observedSeconds, max(0, busySeconds)) : 0
        self.busyFraction = self.observedSeconds > 0 ? busyFraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } ?? self.busySeconds / self.observedSeconds : nil
    }
}

/// Sampled online activity, separate from incomplete job history. Only consecutive
/// known observations no more than 15 seconds apart contribute coverage. State
/// transitions receive no busy credit; this is a conservative sampling estimate.
public actor RunnerActivityStore {
    private struct Sample: Codable { var date: Date; var busy: Bool }
    private struct Segment: Codable { var runnerID: String; var start: Date; var end: Date; var busy: Bool }
    private struct Storage: Codable { var schemaVersion = 1; var samples: [String: Sample]; var segments: [Segment] }
    private let fileURL: URL
    private var storage = Storage(samples: [:], segments: [])
    private var loaded = false
    private var persistedAt: Date?
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func record(snapshots: [RunnerSnapshot], at date: Date = Date()) throws {
        try load()
        let cutoff = date.addingTimeInterval(-48 * 3600)
        let current = snapshots.reduce(into: [String: RunnerSnapshot]()) { result, snapshot in result[snapshot.id] = snapshot }
        storage.samples = storage.samples.filter { current[$0.key] != nil && $0.value.date >= cutoff }
        for snapshot in current.values.prefix(256) {
            let id = snapshot.id
            guard id.utf8.count <= 4096 else { continue }
            guard snapshot.status == .idle || snapshot.status == .busy else {
                storage.samples.removeValue(forKey: id)
                continue
            }
            let busy = snapshot.status == .busy
            if let previous = storage.samples[id] {
                let elapsed = date.timeIntervalSince(previous.date)
                if elapsed > 0 && elapsed <= 15 {
                    append(Segment(runnerID: id, start: previous.date, end: date, busy: previous.busy && busy))
                } else if elapsed <= 0 { continue }
            } else if let end = storage.segments.lazy.filter({ $0.runnerID == id }).map(\.end).max(), date < end {
                // The clock moved back since this runner was last observed. Wait until it passes
                // the saved coverage instead of starting an interval that overlaps it.
                continue
            }
            storage.samples[id] = Sample(date: date, busy: busy)
        }
        prune(before: cutoff)
        // Observations are kept live in memory; disk checkpoints are bounded to
        // once per 30 seconds. A crash may lose the most recent checkpoint window.
        // A checkpoint dated in the future (the clock moved back) is due immediately.
        if persistedAt.map({ $0 > date || date.timeIntervalSince($0) >= 30 }) ?? true {
            try persist(at: date)
        }
    }

    public func metrics(for runnerID: String, now: Date = Date(), window: TimeInterval = 86_400) throws -> ObservedRunnerUsage {
        try load()
        let seconds = window.isFinite && window > 0 ? min(window, 48 * 3600) : 86_400
        let start = now.addingTimeInterval(-seconds)
        var observed = 0.0, busy = 0.0
        for segment in storage.segments where segment.runnerID == runnerID {
            let interval = max(0, min(now, segment.end).timeIntervalSince(max(start, segment.start)))
            observed += interval
            if segment.busy { busy += interval }
        }
        return ObservedRunnerUsage(observedSeconds: observed, busySeconds: busy,
            busyFraction: observed > 0 ? min(1, busy / observed) : nil,
            windowStart: start, windowEnd: now)
    }

    private func append(_ segment: Segment) {
        if let index = storage.segments.lastIndex(where: { $0.runnerID == segment.runnerID }),
           storage.segments[index].busy == segment.busy, storage.segments[index].end == segment.start {
            storage.segments[index].end = segment.end
        } else { storage.segments.append(segment) }
    }
    private func prune(before cutoff: Date) {
        storage.segments = storage.segments.filter { $0.end > cutoff && $0.end > $0.start && $0.runnerID.utf8.count <= 4096 }
            .map { segment in var value = segment; value.start = max(cutoff, value.start); return value }
            .sorted { $0.end < $1.end }
        if storage.segments.count > 5000 { storage.segments = Array(storage.segments.suffix(5000)) }
    }
    private func load() throws {
        guard !loaded else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { loaded = true; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            let text = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid activity timestamp")
            }
            return date
        }
        guard let data = try SavedStoreFile.contents(of: fileURL, limit: 5 * 1024 * 1024),
              let value = try? decoder.decode(Storage.self, from: data),
              value.schemaVersion == 1, value.samples.count <= 256, value.segments.count <= 5000 else {
            // Observed activity is a best-effort estimate: keep the unusable file for
            // inspection and start over rather than failing every refresh.
            _ = try SavedStoreFile.moveAside(fileURL)
            loaded = true
            return
        }
        // Older builds and clock corrections can leave overlapping intervals. Start each one no
        // earlier than the previous end for its runner so overlap is never counted twice, and
        // drop what becomes empty. A sample older than that end would overlap again; drop it too.
        var ends: [String: Date] = [:]
        var segments: [Segment] = []
        for var segment in value.segments.sorted(by: { $0.start < $1.start }) where segment.runnerID.utf8.count <= 4096 {
            if let end = ends[segment.runnerID] { segment.start = max(segment.start, end) }
            guard segment.start < segment.end else { continue }
            segments.append(segment)
            ends[segment.runnerID] = segment.end
        }
        storage = Storage(samples: value.samples.filter { sample in ends[sample.key].map { sample.value.date >= $0 } ?? true },
                          segments: segments.sorted { $0.end < $1.end })
        loaded = true
        persistedAt = value.samples.values.map(\.date).max()
    }
    private func persist(at date: Date) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(storage)
        while data.count > 5 * 1024 * 1024 && !storage.segments.isEmpty {
            storage.segments.removeFirst(max(1, storage.segments.count / 4))
            data = try encoder.encode(storage)
        }
        guard data.count <= 5 * 1024 * 1024 else { throw ActivityError.invalid }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        persistedAt = date
    }
    private enum ActivityError: LocalizedError {
        case invalid
        var errorDescription: String? { "Runner activity is too large to save." }
    }
}
