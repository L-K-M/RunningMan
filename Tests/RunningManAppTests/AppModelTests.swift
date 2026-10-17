import Foundation
import XCTest
import RunningManCore
import RunningManServices
@testable import RunningMan

final class AppModelTests: XCTestCase {
    @MainActor func testCleanupEvidenceIsSeparateFromJobSuccessAndSearchesRunner() {
        let model = AppModel(demoMode: true)
        XCTAssertEqual(model.cleanupRecords.count, 4)
        XCTAssertTrue(model.cleanupRecords.contains { $0.status == .pending && $0.finishedAt == nil })
        XCTAssertTrue(model.cleanupRecords.contains { $0.status == .failed })
        let jobsBefore = model.jobs
        model.section = .cleanup
        model.searchText = "nightly-checks"
        XCTAssertEqual(model.filteredCleanupRecords.count, 1)
        XCTAssertEqual(model.filteredCleanupRecords.first?.status, .failed)
        XCTAssertEqual(model.jobs, jobsBefore)
        XCTAssertNotNil(model.latestCleanup(for: model.runners[0].id))
        XCTAssertNil(model.latestCleanup(for: model.runners[4].id))
    }

    @MainActor func testBusyStopRequiresConfirmationAndCancellationPreservesRunner() {
        let model = AppModel(demoMode: true)
        let busy = model.runners.first { $0.status == .busy }!
        model.perform(.stop, on: busy)
        XCTAssertNotNil(model.confirmation)
        XCTAssertEqual(model.runners.first { $0.id == busy.id }?.status, .busy)
        model.cancelPendingAction()
        XCTAssertNil(model.confirmation)
        XCTAssertEqual(model.runners.first { $0.id == busy.id }?.status, .busy)
        model.perform(.stop, on: busy)
        model.confirmPendingAction()
        XCTAssertEqual(model.runners.first { $0.id == busy.id }?.status, .stopped)
    }

    @MainActor func testDemoImportAndStartupNeverWriteRealPreferences() {
        let preferences = UserDefaults.standard
        let previousPaths = preferences.stringArray(forKey: "importedRunnerDirectories")
        let previousRefresh = preferences.object(forKey: "refreshAutomatically") as? Bool
        let previousAwake = preferences.object(forKey: "keepAwakeWhileBusy") as? Bool
        let model = AppModel(demoMode: true)
        model.importRunner()
        XCTAssertNotNil(model.errorMessage)
        model.refreshAutomatically = false
        model.keepAwakeWhileBusy = true
        let runner = model.runners[0]
        model.setStartup(false, for: runner)
        XCTAssertFalse(model.runners[0].startsAtLogin)
        XCTAssertEqual(preferences.stringArray(forKey: "importedRunnerDirectories"), previousPaths)
        XCTAssertEqual(preferences.object(forKey: "refreshAutomatically") as? Bool, previousRefresh)
        XCTAssertEqual(preferences.object(forKey: "keepAwakeWhileBusy") as? Bool, previousAwake)
    }

    @MainActor func testDemoCreationIsInMemoryAndRejectsUnsafeNames() async {
        let model = AppModel(demoMode: true)
        let initial = model.runners.count
        let invalid = await model.createRunner(githubURL: "https://github.com/example/weather", name: "../escape",
                                               labels: "release", startsAtLogin: true)
        XCTAssertFalse(invalid)
        XCTAssertEqual(model.runners.count, initial)
        let created = await model.createRunner(githubURL: "https://github.com/example/weather", name: "test-runner",
                                               labels: "release, arm", startsAtLogin: false)
        XCTAssertTrue(created)
        XCTAssertEqual(model.runners.count, initial + 1)
        XCTAssertEqual(model.selectedRunner?.runner.name, "test-runner")
        XCTAssertEqual(model.selectedRunner?.startsAtLogin, false)
    }

    @MainActor func testDemoForgejoCreationUsesNativeProviderAndRequestedCapacity() async {
        let model = AppModel(demoMode: true)
        let count = model.runners.count
        let created = await model.createForgejoRunner(server: "https://forge.example.com", scope: .repository,
            scopeName: "example/weather", name: "forge-test", labels: "macos-arm64:host", capacity: 3, startsAtLogin: false)
        XCTAssertTrue(created)
        XCTAssertEqual(model.runners.count, count + 1)
        XCTAssertEqual(model.selectedRunner?.runner.provider, .forgejo)
        XCTAssertEqual(model.selectedRunner?.runner.capacity, 3)
        XCTAssertEqual(model.selectedRunner?.startsAtLogin, false)
        XCTAssertEqual(model.selectedRunner?.runner.directory.path, "/Users/demo/Runners/forge-test")
    }

    @MainActor func testUnknownActivityRequiresExplicitStopAndDrainDoesNotInterrupt() {
        let model = AppModel(demoMode: true)
        var runner = model.runners[0]
        runner.status = .unknown
        runner.processID = 9001
        model.runners[0] = runner
        model.perform(.drain, on: runner)
        XCTAssertTrue(model.drainingRunnerIDs.contains(runner.id))
        XCTAssertEqual(model.runners[0].status, .unknown)
        XCTAssertNil(model.confirmation)
        model.perform(.stop, on: runner)
        XCTAssertNotNil(model.confirmation)
        XCTAssertEqual(model.runners[0].status, .unknown)
        model.cancelPendingAction()
        XCTAssertEqual(model.runners[0].status, .unknown)
    }

    func testHistoricalActivityDeduplicatesAcrossRelaunchAndDatePrecision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("activity.json")
        let first = ActivityEvent(date: Date(timeIntervalSince1970: 1_700_000_000.123),
            runnerID: "/synthetic/runner", title: "Job completed", detail: "Build", kind: .success)
        let store = ActivityStore(url: url)
        await store.append(first)
        let reloaded = ActivityStore(url: url)
        let repeated = ActivityEvent(date: first.date, runnerID: first.runnerID, title: first.title,
                                    detail: first.detail, kind: first.kind)
        await reloaded.append(repeated)
        let values = await reloaded.load()
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(ActivityIdentity(values[0]), ActivityIdentity(repeated))
    }

    func testDiagnosticsReportCatchesTokensInPathsAndLogKeys() throws {
        // Assembled at runtime so the fixture never looks like a committed credential.
        let token = "gh" + "p_" + String(repeating: "A1", count: 18)
        let runner = InstalledRunner(name: "mac", directory: URL(fileURLWithPath: "/synthetic/setup-\(token)/runner"))
        let data = try AppModel.diagnosticsReportData(generatedAt: Date(timeIntervalSince1970: 1_000),
            runners: [RunnerSnapshot(runner: runner, status: .idle)], jobs: [], events: [], cleanup: [],
            logs: [runner.id: "listening"], warnings: [])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(token))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((report["logs"] as? [String: String])?.values.first, "listening")
    }

    func testDiagnosticsReportRedactsEachFieldOnceAndStaysValidJSON() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let runner = InstalledRunner(name: "build token=abc", directory: URL(fileURLWithPath: "/synthetic/runner"),
            githubURL: URL(string: "https://deploy:abc@forge.example/example/desktop"), labels: ["self-hosted", "password=abc"])
        let job = RunnerJob(id: "job", runnerID: runner.id, name: "Deploy token=abc", repository: "example/desktop secret=abc",
            workflow: "Release api_key=abc", runURL: URL(string: "https://deploy:abc@forge.example/example/desktop/actions/runs/1"),
            startedAt: start, finishedAt: start.addingTimeInterval(60), outcome: .success)
        let event = ActivityEvent(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, date: start, runnerID: runner.id,
            title: "Started token=abc", detail: "clone https://deploy:abc@forge.example/example/desktop.git")
        let cleanup = RunnerCleanupRecord(id: "cleanup", runnerID: runner.id, repository: "example/desktop", runID: "1",
            runAttempt: "1", job: "Deploy token=abc", startedAt: start, finishedAt: start.addingTimeInterval(5),
            status: .success, message: "Removed token=abc")
        // A quote after a redacted value and a truncated quoted assignment both broke the old
        // whole-file pass, which consumed the escaping backslash of the encoded quote.
        let log = "[2026-10-16 10:00:00Z INFO Worker] token=abc\" done\nclone https://deploy:abc@forge.example/example/desktop.git\nexport RUNNER_TOKEN=\""
        // Links without credentials must survive the export unchanged.
        let safeRunner = InstalledRunner(name: "mac", directory: URL(fileURLWithPath: "/synthetic/safe"),
            githubURL: URL(string: "https://github.com/example/desktop"))
        let safeJob = RunnerJob(id: "safe", runnerID: safeRunner.id, name: "Build",
            runURL: URL(string: "https://github.com/example/desktop/actions/runs/2"), startedAt: start)
        let data = try AppModel.diagnosticsReportData(generatedAt: start,
            runners: [RunnerSnapshot(runner: runner, status: .idle), RunnerSnapshot(runner: safeRunner, status: .idle)],
            jobs: [job, safeJob], events: [event], cleanup: [cleanup], logs: [runner.id: log], warnings: ["Could not read token=abc"])

        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("abc"), text)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let logs = try XCTUnwrap(report["logs"] as? [String: String])
        XCTAssertEqual(logs[runner.id], "[2026-10-16 10:00:00Z INFO Worker] token=[REDACTED]\" done\nclone https://[REDACTED]@forge.example/example/desktop.git\nexport RUNNER_TOKEN=\"")
        XCTAssertEqual(report["warnings"] as? [String], ["Could not read token=[REDACTED]"])
        XCTAssertTrue(text.contains("https:\\/\\/github.com\\/example\\/desktop\\/actions\\/runs\\/2"), text)
        let runners = try XCTUnwrap(report["runners"] as? [[String: Any]])
        let urls = runners.compactMap { ($0["runner"] as? [String: Any])?["githubURL"] as? String }
        XCTAssertEqual(urls, ["https://github.com/example/desktop"])
    }
}
