import Foundation

/// GitHub's `.runner` file records no labels; the server keeps them. RunningMan therefore
/// writes the labels it registered a runner with into this public sidecar, which never
/// holds credentials. Readers ignore a sidecar that is linked, oversized or invalid.
public enum GitHubLabelSidecar {
    public static let fileName = ".runningman-labels.json"
    static let sizeLimit = 16 * 1024
    private struct Contents: Codable { var labels: [String] }
    private struct InvalidLabels: LocalizedError {
        var errorDescription: String? { "The runner labels could not be saved locally." }
    }

    /// The label rules RunningMan applies before passing labels to `config.sh --labels`.
    /// They include the sidecar's size, so a set accepted before registration can
    /// always be recorded after it.
    public static func isValid(_ labels: [String]) -> Bool {
        guard labels.count <= 100,
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 256 && !$0.contains(",") && !$0.contains("\n") && !$0.contains("\r") }),
              let data = try? JSONEncoder().encode(Contents(labels: labels)) else { return false }
        return data.count <= sizeLimit
    }

    public static func write(_ labels: [String], to directory: URL) throws {
        guard isValid(labels) else { throw InvalidLabels() }
        let data = try JSONEncoder().encode(Contents(labels: labels))
        let file = directory.appendingPathComponent(fileName)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Unredacted labels, or none when the sidecar is missing, linked, oversized or invalid.
    static func read(from directory: URL) -> [String] {
        let file = directory.appendingPathComponent(fileName)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, values.isRegularFile == true,
              let data = try? RunnerDiscovery.smallData(at: file, limit: sizeLimit),
              let contents = try? JSONDecoder().decode(Contents.self, from: RunnerDiscovery.removingBOM(data)),
              isValid(contents.labels) else { return [] }
        return contents.labels
    }
}
