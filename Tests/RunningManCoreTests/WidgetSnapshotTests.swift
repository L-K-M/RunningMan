import Foundation
import XCTest
@testable import RunningManCore

final class WidgetSnapshotTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    func testFleetUsesLocalProcessEvidenceAndPreservesUnverifiedActivity() {
        let snapshot = WidgetSnapshot(runners: [
            runner(.idle), runner(.busy), runner(.stopped), runner(.disabled),
            runner(.attention), runner(.unknown), runner(.unknown, provider: .forgejo, processID: 42)
        ], jobs: [], updatedAt: date)
        XCTAssertEqual(snapshot.fleet.total, 7)
        XCTAssertEqual(snapshot.fleet.online, 3)
        XCTAssertEqual(snapshot.fleet.busy, 1)
        XCTAssertEqual(snapshot.fleet.attention, 2, "A live Forgejo daemon is unverified, not at fault")
        XCTAssertEqual(snapshot.fleet.stopped, 1)
        XCTAssertEqual(snapshot.fleet.disabled, 1)
        XCTAssertEqual(snapshot.fleet.unverified, 2)
        XCTAssertNil(snapshot.jobs.successRate)
        XCTAssertTrue(snapshot.isValid)
    }

    func testSuccessRateIncludesCancelledButExcludesUnfinishedAndUnknownJobs() {
        let snapshot = WidgetSnapshot(runners: [], jobs: jobs([.success, .success, .failure, .cancelled, .unknown, .running]), updatedAt: date)
        XCTAssertEqual(snapshot.jobs.total, 6)
        XCTAssertEqual(snapshot.jobs.completed, 4)
        XCTAssertEqual(snapshot.jobs.successRate, 0.5)
        XCTAssertEqual(snapshot.jobs.unknown, 1)
        XCTAssertEqual(snapshot.jobs.running, 1)
    }

    func testEncodedSnapshotContainsOnlyCountsAndTimestamp() throws {
        var installation = runner(.busy)
        installation.runner.name = "private-runner-name"
        installation.runner.directory = URL(fileURLWithPath: "/Users/private/install")
        installation.detail = "secret diagnostic text"
        let snapshot = WidgetSnapshot(runners: [installation], jobs: jobs([.success]), updatedAt: date)
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "updatedAt", "fleet", "jobs"])
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["private-runner-name", "/Users/private", "secret diagnostic", "private-job", "private/repository"] {
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testFreshnessExpiresAtBoundaryAndRejectsFutureDates() {
        let snapshot = WidgetSnapshot(runners: [], jobs: [], updatedAt: date)
        XCTAssertFalse(snapshot.isStale(at: date))
        XCTAssertFalse(snapshot.isStale(at: date.addingTimeInterval(WidgetSnapshot.staleInterval - 1)))
        XCTAssertTrue(snapshot.isStale(at: date.addingTimeInterval(WidgetSnapshot.staleInterval)))
        XCTAssertTrue(snapshot.isStale(at: date.addingTimeInterval(-1)))
    }

    func testStoreRoundTripAndReloadCoalescing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = WidgetSnapshotStore.fileURL(homeDirectory: directory)
        let store = WidgetSnapshotStore(fileURL: file)
        let missing = try await store.load()
        XCTAssertNil(missing)

        let first = WidgetSnapshot(runners: [runner(.idle)], jobs: [], updatedAt: date)
        let firstReload = try await store.publish(first)
        XCTAssertTrue(firstReload)
        let saved = try await store.load()
        XCTAssertEqual(saved, first)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        let heartbeat = WidgetSnapshot(runners: [runner(.idle)], jobs: [], updatedAt: date.addingTimeInterval(10))
        let heartbeatReload = try await store.publish(heartbeat)
        XCTAssertFalse(heartbeatReload)
        let unchanged = try await store.load()
        XCTAssertEqual(unchanged, first, "Do not rewrite unchanged counts on each poll")

        let changed = WidgetSnapshot(runners: [runner(.busy)], jobs: [], updatedAt: date.addingTimeInterval(20))
        let changedReload = try await store.publish(changed)
        XCTAssertFalse(changedReload)
        let changedSaved = try await store.load()
        XCTAssertEqual(changedSaved, changed, "Counts persist even while widget invalidation is throttled")

        let due = WidgetSnapshot(runners: [runner(.busy)], jobs: [], updatedAt: date.addingTimeInterval(5 * 60))
        let dueReload = try await store.publish(due)
        XCTAssertTrue(dueReload, "A change during cooldown must eventually invalidate the timeline")
        let oldReload = try await store.publish(first)
        XCTAssertFalse(oldReload)
        let latest = try await store.load()
        XCTAssertEqual(latest, due, "An older async publication must not overwrite a newer snapshot")

        let checkpoint = WidgetSnapshot(runners: [runner(.busy)], jobs: [], updatedAt: date.addingTimeInterval(6 * 60))
        let checkpointReload = try await store.publish(checkpoint)
        XCTAssertFalse(checkpointReload, "Freshness alone does not invalidate the timeline")
        let checkpointSaved = try await store.load()
        XCTAssertEqual(checkpointSaved, checkpoint, "An unchanged snapshot still advances its observation time")
    }

    func testPublisherSecuresAnExistingSnapshotDirectory() async throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = WidgetSnapshotStore.fileURL(homeDirectory: home)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        _ = try await WidgetSnapshotStore(fileURL: file).publish(.example(at: date))
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
    }

    func testStoreRejectsMalformedOversizedAndLinkedSnapshotsWithoutChangingThem() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("stats.json")
        let store = WidgetSnapshotStore(fileURL: file)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let valid = try encoder.encode(WidgetSnapshot.example(at: date))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var unsupported = original
        unsupported["version"] = WidgetSnapshot.schemaVersion + 1
        var negative = original
        var fleet = try XCTUnwrap(original["fleet"] as? [String: Any])
        fleet["online"] = -1
        negative["fleet"] = fleet
        var overflow = original
        var results = try XCTUnwrap(original["jobs"] as? [String: Any])
        results["succeeded"] = Int.max
        overflow["jobs"] = results

        for data in [Data("{".utf8), Data(repeating: 0x20, count: 16 * 1024 + 1),
                     try JSONSerialization.data(withJSONObject: unsupported),
                     try JSONSerialization.data(withJSONObject: negative),
                     try JSONSerialization.data(withJSONObject: overflow)] {
            try data.write(to: file)
            do { _ = try await store.load(); XCTFail("Expected invalid snapshot to fail") }
            catch { /* Invalid input must remain unavailable, not turn into zero counts. */ }
            XCTAssertEqual(try Data(contentsOf: file), data)
        }

        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("private.json")
        try valid.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        do { _ = try await store.load(); XCTFail("Expected linked snapshot to fail") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: target), valid)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func runner(_ status: RunnerStatus, provider: RunnerProvider = .github, processID: Int32? = nil) -> RunnerSnapshot {
        RunnerSnapshot(runner: InstalledRunner(name: "Test runner", directory: URL(fileURLWithPath: "/synthetic/runner"), provider: provider),
                       status: status, processID: processID)
    }

    private func jobs(_ outcomes: [JobOutcome]) -> [RunnerJob] {
        outcomes.enumerated().map { index, outcome in
            RunnerJob(id: "job-\(index)", runnerID: "/synthetic/runner", name: "private-job", repository: "private/repository",
                      startedAt: date.addingTimeInterval(-60), finishedAt: outcome == .running ? nil : date, outcome: outcome)
        }
    }
}
