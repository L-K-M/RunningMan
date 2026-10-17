import Foundation
import XCTest
import RunningManCore
@testable import RunningMan

/// The checker with a suite `UserDefaults` and a counting fetch: nothing here
/// touches the network or the real preferences.
final class AppUpdateCheckerTests: XCTestCase {
    private final class Recorder {
        var fetches = 0
        var messages: [String] = []
    }

    private func manifest(_ version: String) -> Data {
        Data("""
        {"tag_name": "v\(version)", "html_url": "https://github.com/L-K-M/RunningMan/releases/tag/v\(version)",
         "draft": false, "prerelease": false}
        """.utf8)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "RunningManTests.AppUpdateChecker.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @MainActor private func updateValues(_ defaults: UserDefaults) -> [String: String] {
        let keys = [AppUpdateChecker.lastCheckKey, AppUpdateChecker.manifestKey, AppUpdateChecker.skippedKey, AppUpdateChecker.automaticKey]
        return keys.reduce(into: [:]) { values, key in values[key] = defaults.object(forKey: key).map { String(describing: $0) } }
    }

    @MainActor private func makeChecker(_ mode: AppUpdateChecker.Mode, defaults: UserDefaults, recorder: Recorder,
                                        serving version: String = "9.0.0") -> AppUpdateChecker {
        let data = manifest(version)
        return AppUpdateChecker(mode: mode, defaults: defaults, appVersion: "0.2.0",
                                fetch: { _ in recorder.fetches += 1; return data },
                                presentMessage: { title, _ in recorder.messages.append(title) })
    }

    @MainActor private func waitUntilIdle(_ checker: AppUpdateChecker) async {
        for _ in 0..<200 where checker.checking { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @MainActor func testOfflineModeIgnoresAStoredNewerRelease() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(manifest("9.0.0"), forKey: AppUpdateChecker.manifestKey)
        let recorder = Recorder()

        let live = makeChecker(.live, defaults: defaults, recorder: recorder)
        XCTAssertEqual(live.available?.version, "9.0.0", "Control: the stored manifest announces a release in live mode.")

        let offline = makeChecker(.offline, defaults: defaults, recorder: recorder)
        XCTAssertNil(offline.available)
        XCTAssertFalse(offline.showsBanner)
    }

    @MainActor func testOfflineModeNeverFetchesOrWritesPreferences() async throws {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(manifest("0.2.0"), forKey: AppUpdateChecker.manifestKey)
        defaults.set(Date(timeIntervalSinceNow: -3 * 86_400), forKey: AppUpdateChecker.lastCheckKey)
        let before = updateValues(defaults)
        let recorder = Recorder()
        let checker = makeChecker(.offline, defaults: defaults, recorder: recorder, serving: "0.2.0")

        checker.startAutomatic()
        checker.checkIfDue()
        checker.checkNow()
        checker.skip(try AppUpdateCheck.release(from: manifest("9.0.0")))
        try await Task.sleep(for: .milliseconds(100))
        await waitUntilIdle(checker)

        XCTAssertEqual(recorder.fetches, 0)
        XCTAssertEqual(recorder.messages, ["Update checks are off in the preview workspace"])
        XCTAssertNil(checker.lastCheck)
        XCTAssertNil(checker.available)
        XCTAssertEqual(updateValues(defaults), before)
    }

    @MainActor func testAutomaticChecksReadThePreferenceEachTime() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: AppUpdateChecker.automaticKey)
        let recorder = Recorder()
        let checker = makeChecker(.live, defaults: defaults, recorder: recorder)

        checker.checkIfDue()
        await waitUntilIdle(checker)
        XCTAssertEqual(recorder.fetches, 0, "Automatic checks are off.")

        defaults.set(true, forKey: AppUpdateChecker.automaticKey)
        checker.checkIfDue()
        await waitUntilIdle(checker)
        XCTAssertEqual(recorder.fetches, 1)
        XCTAssertEqual(checker.available?.version, "9.0.0")
        XCTAssertNotNil(checker.lastCheck)
        XCTAssertTrue(recorder.messages.isEmpty, "Automatic checks never show an alert.")

        checker.checkIfDue()
        await waitUntilIdle(checker)
        XCTAssertEqual(recorder.fetches, 1, "The next check is not due for a day.")
    }

    @MainActor func testDevelopmentBuildsNeverCheckAutomatically() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let recorder = Recorder()
        let checker = AppUpdateChecker(mode: .live, defaults: defaults, appVersion: "",
                                       fetch: { _ in recorder.fetches += 1; return Data() },
                                       presentMessage: { title, _ in recorder.messages.append(title) })
        checker.checkIfDue()
        await waitUntilIdle(checker)
        XCTAssertEqual(recorder.fetches, 0)
        XCTAssertTrue(recorder.messages.isEmpty)
    }
}
