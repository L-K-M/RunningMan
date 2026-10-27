import Foundation

/// Step times of finished runs, kept per job so a new run can race its ghost. Private, bounded
/// and written atomically like the job history. A file that cannot be decoded is set aside, never
/// deleted; one that cannot be read is left alone while new laps wait in memory.
public actor LapBook {
    private struct Stored: Codable {
        var key: LapKey
        var laps: [LapRecord]
    }

    public static let lapsPerJob = LapReference.historyLimit
    public static let maximumJobs = 300
    public static let maximumSplits = 80
    private static let maximumFileBytes = 2 * 1024 * 1024

    private let fileURL: URL?
    private var cache: [LapKey: [LapRecord]]?
    /// Laps recorded while the file could not be read. They stay in memory, the file is left as
    /// it is, and they join the book once a later read succeeds.
    private var unsaved: [LapKey: [LapRecord]] = [:]

    /// Without a file the book lives in memory only, as in demo mode, starting from `seed`.
    public init(fileURL: URL?, seed: [LapKey: [LapRecord]] = [:]) {
        self.fileURL = fileURL
        if fileURL == nil { cache = seed }
    }

    public func load() -> [LapKey: [LapRecord]] {
        if let cache { return cache }
        guard var loaded = readFile() else { return unsaved }
        for (key, laps) in unsaved { loaded[key] = Self.normalized((loaded[key] ?? []) + laps) }
        loaded = Self.bounded(loaded)
        unsaved = [:]
        cache = loaded
        return loaded
    }

    /// The saved book, empty when there is none or it was unusable, or nil when reading failed.
    /// Like the history store, only a file that is too large or cannot be decoded is set aside;
    /// a read error may be transient, so the file stays for a later attempt.
    private func readFile() -> [LapKey: [LapRecord]]? {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data: Data?
        do { data = try SavedStoreFile.contents(of: fileURL, limit: Self.maximumFileBytes) } catch { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data, let stored = try? decoder.decode([Stored].self, from: data) else {
            _ = try? SavedStoreFile.moveAside(fileURL)
            return [:]
        }
        // A decodable file still gets the bounds the book keeps when it writes.
        var loaded: [LapKey: [LapRecord]] = [:]
        for entry in stored { loaded[entry.key, default: []] += entry.laps }
        return loaded.mapValues(Self.normalized)
    }

    /// Adds a finished run unless the same job is already recorded, and returns the updated book.
    @discardableResult
    public func record(_ lap: LapRecord, for key: LapKey) -> [LapKey: [LapRecord]] {
        var book = load()
        let laps = book[key] ?? []
        guard !laps.contains(where: { $0.jobID == lap.jobID }) else { return book }
        book[key] = Self.normalized(laps + [lap])
        book = Self.bounded(book)
        guard cache != nil else {
            unsaved = book
            return book
        }
        cache = book
        save(book)
        return book
    }

    /// One lap per job run, oldest first, at most `lapsPerJob`. A lap with more steps than the book
    /// keeps is paced as a whole: cutting steps off would make its ghost finish early.
    private static func normalized(_ laps: [LapRecord]) -> [LapRecord] {
        var seen: Set<String> = []
        let unique = laps.filter { seen.insert($0.jobID).inserted }.sorted { $0.finishedAt < $1.finishedAt }
        return unique.suffix(lapsPerJob).map { lap in
            var kept = lap
            if kept.splits.count > maximumSplits { kept.splits = [] }
            return kept
        }
    }

    /// Forgets the jobs that ran longest ago once the book holds more than `maximumJobs`.
    private static func bounded(_ book: [LapKey: [LapRecord]]) -> [LapKey: [LapRecord]] {
        guard book.count > maximumJobs else { return book }
        let keep = book.sorted { ($0.value.last?.finishedAt ?? .distantPast) > ($1.value.last?.finishedAt ?? .distantPast) }.prefix(maximumJobs)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func save(_ book: [LapKey: [LapRecord]]) {
        guard let fileURL else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let stored = book.map { Stored(key: $0.key, laps: $0.value) }
            .sorted { ($0.laps.last?.finishedAt ?? .distantPast) > ($1.laps.last?.finishedAt ?? .distantPast) }
        do {
            var data = try encoder.encode(stored)
            // Drop the oldest jobs until the file fits; a ghost for an old job matters least.
            var trimmed = stored
            while data.count > Self.maximumFileBytes, !trimmed.isEmpty {
                trimmed.removeLast(max(1, trimmed.count / 10))
                data = try encoder.encode(trimmed)
            }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Laps are a nicety; the cached book keeps pacing this session if storage is unavailable.
        }
    }
}
