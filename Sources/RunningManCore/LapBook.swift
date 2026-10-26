import Foundation

/// Step times of finished runs, kept per job so a new run can race its ghost. Private, bounded
/// and written atomically like the job history; an unreadable file is set aside, never deleted.
public actor LapBook {
    private struct Stored: Codable {
        var key: LapKey
        var laps: [LapRecord]
    }

    public static let lapsPerJob = LapReference.historyLimit
    public static let maximumJobs = 300
    private static let maximumSplits = 80
    private static let maximumFileBytes = 2 * 1024 * 1024

    private let fileURL: URL?
    private var cache: [LapKey: [LapRecord]]?

    /// Without a file the book lives in memory only, as in demo mode, starting from `seed`.
    public init(fileURL: URL?, seed: [LapKey: [LapRecord]] = [:]) {
        self.fileURL = fileURL
        if fileURL == nil { cache = seed }
    }

    public func load() -> [LapKey: [LapRecord]] {
        if let cache { return cache }
        var loaded: [LapKey: [LapRecord]] = [:]
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let data = try? SavedStoreFile.contents(of: fileURL, limit: Self.maximumFileBytes),
               let stored = try? decoder.decode([Stored].self, from: data) {
                for entry in stored { loaded[entry.key] = Array(entry.laps.suffix(Self.lapsPerJob)) }
            } else {
                _ = try? SavedStoreFile.moveAside(fileURL)
            }
        }
        cache = loaded
        return loaded
    }

    /// Adds a finished run unless the same job is already recorded, and returns the updated laps of its key.
    @discardableResult
    public func record(_ lap: LapRecord, for key: LapKey) -> [LapRecord] {
        var book = load()
        var laps = book[key] ?? []
        guard !laps.contains(where: { $0.jobID == lap.jobID }) else { return laps }
        var bounded = lap
        bounded.splits = Array(bounded.splits.prefix(Self.maximumSplits))
        laps.append(bounded)
        laps.sort { $0.finishedAt < $1.finishedAt }
        laps = Array(laps.suffix(Self.lapsPerJob))
        book[key] = laps
        if book.count > Self.maximumJobs {
            // Forget the jobs that ran longest ago.
            let keep = book.sorted { ($0.value.last?.finishedAt ?? .distantPast) > ($1.value.last?.finishedAt ?? .distantPast) }.prefix(Self.maximumJobs)
            book = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        cache = book
        save(book)
        return laps
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
