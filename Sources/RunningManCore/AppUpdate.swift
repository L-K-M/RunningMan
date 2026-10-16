import Foundation

/// `runningman/latest.json` in the public ajila-tg-app-updates repository: the
/// newest RunningMan release, in the shape of GitHub's release API. Keeping the
/// answer in a static file means the app never needs a GitHub token to check.
public struct AppUpdateManifest: Decodable, Equatable, Sendable {
    public var tagName: String
    public var name: String?
    public var htmlURL: String
    public var publishedAt: String?
    public var draft: Bool?
    public var prerelease: Bool?

    enum CodingKeys: String, CodingKey {
        case name, draft, prerelease
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    public static func decode(_ data: Data) throws -> AppUpdateManifest {
        try JSONDecoder().decode(AppUpdateManifest.self, from: data)
    }
}

/// A published release that a valid manifest announces.
public struct AppRelease: Equatable, Sendable {
    /// The version without the tag's "v", e.g. "0.3.0".
    public var version: String
    public var tag: String
    /// The GitHub release page.
    public var releasePage: URL

    public init(version: String, tag: String, releasePage: URL) {
        self.version = version
        self.tag = tag
        self.releasePage = releasePage
    }
}

/// What a successful check means for the running app.
public enum AppUpdateStatus: Equatable, Sendable {
    /// The newest release is not newer than this build.
    case upToDate(newest: AppRelease)
    case available(AppRelease)
    /// Newer, but the user chose Skip This Version for exactly this version.
    case skipped(AppRelease)
}

public enum AppUpdateError: Error, LocalizedError, Equatable {
    case unreachable(String)
    case http(Int)
    case invalidManifest(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail): return "GitHub could not be reached: \(detail)"
        case .http(let code): return "GitHub answered HTTP \(code) for the update information."
        case .invalidManifest(let detail): return "The update information is not valid: \(detail)."
        }
    }
}

/// The once-a-day release check: one unauthenticated GET of a public file, no token,
/// no identifier. Everything except `fetch` is pure, so it is unit-tested without network.
public enum AppUpdateCheck {
    public static let manifestURL = URL(string: "https://raw.githubusercontent.com/ajilach/ajila-tg-app-updates/main/runningman/latest.json")!
    /// Release pages of this repository; a manifest pointing anywhere else is ignored.
    public static let releasePagePrefix = "https://github.com/L-K-M/RunningMan/releases/"
    /// A check is due once the last successful one is this old.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// The release a manifest announces: a plain vX.Y.Z tag, neither draft nor
    /// prerelease, with this repository's release page of exactly that tag.
    public static func release(from data: Data) throws -> AppRelease {
        let manifest: AppUpdateManifest
        do {
            manifest = try AppUpdateManifest.decode(data)
        } catch {
            throw AppUpdateError.invalidManifest("it is not the expected JSON")
        }
        return try release(from: manifest)
    }

    public static func release(from manifest: AppUpdateManifest) throws -> AppRelease {
        guard let numbers = tagNumbers(manifest.tagName) else {
            throw AppUpdateError.invalidManifest("\(manifest.tagName) is not a vX.Y.Z release tag")
        }
        guard manifest.draft != true, manifest.prerelease != true else {
            throw AppUpdateError.invalidManifest("\(manifest.tagName) is a draft or prerelease")
        }
        // The exact page the publisher writes: a mere prefix test would let
        // "releases/../../other/repo" through to the browser.
        guard manifest.htmlURL == releasePagePrefix + "tag/" + manifest.tagName, let page = URL(string: manifest.htmlURL) else {
            throw AppUpdateError.invalidManifest("its release page is not \(manifest.tagName) in L-K-M/RunningMan")
        }
        return AppRelease(version: numbers.map(String.init).joined(separator: "."), tag: manifest.tagName, releasePage: page)
    }

    /// Only a strictly newer release is offered, unless the user skipped exactly that
    /// version (compared numerically, so "v0.3.0" matches "0.3"). A running version that
    /// is not a plain release version never gets an offer.
    public static func status(of release: AppRelease, runningVersion: String, skippedVersion: String?) -> AppUpdateStatus {
        guard isNewer(release, than: runningVersion) else { return .upToDate(newest: release) }
        if let skippedVersion, isReleaseVersion(skippedVersion),
           compareVersions(release.version, plain(skippedVersion)) == .orderedSame {
            return .skipped(release)
        }
        return .available(release)
    }

    public static func status(of data: Data, runningVersion: String, skippedVersion: String?) throws -> AppUpdateStatus {
        status(of: try release(from: data), runningVersion: runningVersion, skippedVersion: skippedVersion)
    }

    public static func isNewer(_ release: AppRelease, than runningVersion: String) -> Bool {
        isReleaseVersion(runningVersion) && compareVersions(release.version, plain(runningVersion)) == .orderedDescending
    }

    /// Dotted numbers with an optional leading v ("0.2.0", "v1.2"); not "dev" or "1.2.0-rc1".
    public static func isReleaseVersion(_ text: String) -> Bool {
        numbers(plain(text)) != nil
    }

    /// Due when no check has succeeded yet, the last success is `interval` old, or the
    /// clock moved back before it (a future date would otherwise block checks for good).
    public static func isDue(lastSuccess: Date?, now: Date, interval: TimeInterval = AppUpdateCheck.interval) -> Bool {
        guard let lastSuccess else { return true }
        return lastSuccess > now || now.timeIntervalSince(lastSuccess) >= interval
    }

    /// One GET without cookies, cache or credentials; only an HTTP 200 body is returned.
    public static func fetch(appVersion: String, from url: URL = AppUpdateCheck.manifestURL, timeout: TimeInterval = 15) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "RunningMan/\(appVersion)"]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: AppUpdateError.unreachable(error.localizedDescription))
                } else if let response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: AppUpdateError.unreachable("no response"))
                }
            }.resume()
        }
        guard let http = response as? HTTPURLResponse else { throw AppUpdateError.unreachable("not an HTTP response") }
        guard http.statusCode == 200 else { throw AppUpdateError.http(http.statusCode) }
        return data
    }

    /// Numeric piece-by-piece compare, padding the shorter side with zeros
    /// ("1.2" equals "1.2.0"); non-numeric runs act as separators.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let right = rhs.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Exactly three numbers after a leading v or V, as release tags are cut.
    static func tagNumbers(_ tag: String) -> [Int]? {
        guard let first = tag.first, first == "v" || first == "V",
              let numbers = numbers(String(tag.dropFirst())), numbers.count == 3 else { return nil }
        return numbers
    }

    private static func plain(_ version: String) -> String {
        version.first == "v" || version.first == "V" ? String(version.dropFirst()) : version
    }

    private static func numbers(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            return Int(part)
        }
        return !parts.isEmpty && numbers.count == parts.count ? numbers : nil
    }
}
