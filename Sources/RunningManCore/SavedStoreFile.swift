import Foundation

/// Reads RunningMan's own saved JSON stores and sets unusable ones aside. A file is renamed or
/// copied next to the original, never deleted, so it stays available for inspection or recovery.
enum SavedStoreFile {
    /// Returns nil when the file is larger than `limit`. Read failures still throw, so a transient
    /// I/O error never sets aside a store that may be valid.
    static func contents(of url: URL, limit: Int) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        return data.count <= limit ? data : nil
    }

    /// Renames `url` to `<name>.invalid-<yyyyMMdd-HHmmss>.<extension>` in the same directory.
    static func moveAside(_ url: URL, at date: Date = Date()) throws -> URL {
        let destination = invalidURL(for: url, at: date)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Copies `url` to the name `moveAside` would use and leaves the original in place.
    static func copyAside(_ url: URL, at date: Date = Date()) throws -> URL {
        let destination = invalidURL(for: url, at: date)
        try FileManager.default.copyItem(at: url, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    private static func invalidURL(for url: URL, at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = url.deletingLastPathComponent()
        let base = "\(url.deletingPathExtension().lastPathComponent).invalid-\(formatter.string(from: date))"
        // A second recovery within the same second gets a numeric suffix; earlier copies are never replaced.
        let named = { (name: String) in
            url.pathExtension.isEmpty ? directory.appendingPathComponent(name) : directory.appendingPathComponent(name).appendingPathExtension(url.pathExtension)
        }
        var candidate = named(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = named("\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }
}
