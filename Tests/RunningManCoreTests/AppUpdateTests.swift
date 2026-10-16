import XCTest
@testable import RunningManCore

/// The pure side of the update check: manifest validation, version compare and
/// due-ness. `fetch` is the only network part and is not exercised here.
final class AppUpdateTests: XCTestCase {
    private func manifestData(tag: String = "v0.3.0",
                              url: String = "https://github.com/L-K-M/RunningMan/releases/tag/v0.3.0",
                              draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("""
        {
          "tag_name": "\(tag)",
          "name": "RunningMan \(tag.dropFirst())",
          "html_url": "\(url)",
          "published_at": "2026-10-16T09:30:00Z",
          "draft": \(draft),
          "prerelease": \(prerelease)
        }
        """.utf8)
    }

    func testReleaseFromValidManifest() throws {
        let release = try AppUpdateCheck.release(from: manifestData())
        XCTAssertEqual(release.version, "0.3.0")
        XCTAssertEqual(release.tag, "v0.3.0")
        XCTAssertEqual(release.releasePage.absoluteString,
                       "https://github.com/L-K-M/RunningMan/releases/tag/v0.3.0")
    }

    func testReleaseRejectsDraftsAndPrereleases() {
        XCTAssertThrowsError(try AppUpdateCheck.release(from: manifestData(draft: true)))
        XCTAssertThrowsError(try AppUpdateCheck.release(from: manifestData(prerelease: true)))
    }

    func testReleaseRejectsForeignAndPartialUrls() {
        XCTAssertThrowsError(try AppUpdateCheck.release(from: manifestData(
            url: "https://github.com/other/repo/releases/tag/v0.3.0")))
        XCTAssertThrowsError(try AppUpdateCheck.release(from: manifestData(
            url: "https://github.com/L-K-M/RunningMan/releases/download/v0.3.0/x.zip")))
        XCTAssertThrowsError(try AppUpdateCheck.release(from: manifestData(
            url: "https://evil.example.com/")))
    }

    func testReleaseRejectsNonVersionTagsAndGarbage() {
        XCTAssertThrowsError(try AppUpdateCheck.release(from: manifestData(tag: "nightly")))
        XCTAssertThrowsError(try AppUpdateCheck.release(from: manifestData(tag: "v1.2")))
        XCTAssertThrowsError(try AppUpdateCheck.release(from: Data("not json".utf8)))
    }

    func testStatusOffersOnlyStrictlyNewerReleases() throws {
        let release = try AppUpdateCheck.release(from: manifestData())
        XCTAssertEqual(AppUpdateCheck.status(of: release, runningVersion: "0.2.9", skippedVersion: nil),
                       .available(release))
        XCTAssertEqual(AppUpdateCheck.status(of: release, runningVersion: "0.3.0", skippedVersion: nil),
                       .upToDate(newest: release))
        XCTAssertEqual(AppUpdateCheck.status(of: release, runningVersion: "0.4.0", skippedVersion: nil),
                       .upToDate(newest: release))
        // A development build (no release version) never gets an offer.
        XCTAssertEqual(AppUpdateCheck.status(of: release, runningVersion: "dev", skippedVersion: nil),
                       .upToDate(newest: release))
    }

    func testStatusHonoursSkippedVersion() throws {
        let release = try AppUpdateCheck.release(from: manifestData())
        XCTAssertEqual(AppUpdateCheck.status(of: release, runningVersion: "0.2.0", skippedVersion: "0.3.0"),
                       .skipped(release))
        XCTAssertEqual(AppUpdateCheck.status(of: release, runningVersion: "0.2.0", skippedVersion: "0.3.1"),
                       .available(release))
    }

    func testIsDue() {
        let now = Date()
        XCTAssertTrue(AppUpdateCheck.isDue(lastSuccess: nil, now: now))
        XCTAssertFalse(AppUpdateCheck.isDue(lastSuccess: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(AppUpdateCheck.isDue(lastSuccess: now.addingTimeInterval(-25 * 3600), now: now))
        // A clock skew into the future must not block checks forever.
        XCTAssertTrue(AppUpdateCheck.isDue(lastSuccess: now.addingTimeInterval(3600), now: now))
    }

    func testCompareVersions() {
        XCTAssertEqual(AppUpdateCheck.compareVersions("1.2.0", "1.2"), .orderedSame)
        XCTAssertEqual(AppUpdateCheck.compareVersions("0.3.0", "0.2.9"), .orderedDescending)
        XCTAssertEqual(AppUpdateCheck.compareVersions("0.2.9", "0.3.0"), .orderedAscending)
        XCTAssertEqual(AppUpdateCheck.compareVersions("1.10.0", "1.9.9"), .orderedDescending)
    }
}
