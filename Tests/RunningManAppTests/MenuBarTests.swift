import AppKit
import XCTest
import RunningManCore
@testable import RunningMan

final class MenuBarTests: XCTestCase {
    /// A running Forgejo daemon is unknown whenever its activity cannot be verified, for
    /// example with server monitoring off; that is not a fault and needs no attention.
    func testUnverifiedForgejoActivityDoesNotNeedAttention() {
        let unverified = snapshot("forge", .unknown, provider: .forgejo, processID: 9051)
        XCTAssertFalse(unverified.needsAttention)
        XCTAssertTrue(unverified.isOnline)
        XCTAssertTrue(snapshot("forge", .unknown, provider: .forgejo).needsAttention, "Without a process the state is simply unreadable")
        XCTAssertTrue(snapshot("github", .unknown, processID: 8040).needsAttention)
        XCTAssertEqual(RunnerMenuView.runnerDetail(for: unverified), "Online, activity not verified")
    }

    /// The panel shows eight rows; in name order a busy or failing runner could be the
    /// ninth and never appear.
    @MainActor func testMenuShowsRunnersThatNeedAttentionAndBusyRunnersFirst() {
        let model = AppModel(demoMode: true)
        XCTAssertEqual(model.menuBarRunners.prefix(2).map(\.runner.name), ["forge-macos", "studio-release"])

        let runners = [
            snapshot("alpha", .disabled), snapshot("bravo", .stopped), snapshot("charlie", .idle),
            snapshot("delta", .busy), snapshot("echo", .unknown), snapshot("forge", .unknown, provider: .forgejo, processID: 9051),
            snapshot("runner-10", .idle), snapshot("runner-2", .idle), snapshot("zulu", .attention)
        ]
        XCTAssertEqual(AppModel.menuBarOrder(runners).map(\.runner.name),
                       ["echo", "zulu", "delta", "forge", "charlie", "runner-2", "runner-10", "bravo", "alpha"])
    }

    func testSummaryNeverPresentsAnUnknownQueueAsEmpty() {
        XCTAssertEqual(RunnerMenuView.summaryItems(attention: 0, draining: 0, queue: FleetQueueSummary()), [])
        var queue = FleetQueueSummary()
        queue.hasQueueEvidence = true
        XCTAssertEqual(RunnerMenuView.summaryItems(attention: 0, draining: 0, queue: queue), [], "An empty queue is not worth a capsule")
        queue.queuedCount = 3
        XCTAssertEqual(RunnerMenuView.summaryItems(attention: 0, draining: 0, queue: queue).map(\.text), ["3 queued"])
        queue.isIncomplete = true
        XCTAssertEqual(RunnerMenuView.summaryItems(attention: 0, draining: 0, queue: queue).map(\.text), ["3+ queued"])
        var unknown = FleetQueueSummary()
        unknown.queuedCount = 4
        XCTAssertEqual(RunnerMenuView.summaryItems(attention: 0, draining: 0, queue: unknown), [], "Counts without queue evidence are unknown")

        let items = RunnerMenuView.summaryItems(attention: 2, draining: 1, queue: queue)
        XCTAssertEqual(items.map(\.text), ["2 need attention", "3+ queued", "1 stopping when idle"])
        XCTAssertEqual(RunnerMenuView.summaryItems(attention: 1, draining: 0, queue: FleetQueueSummary()).map(\.text), ["1 needs attention"])
    }

    func testRunnerDetailUsesOnlineAndBusyVocabulary() {
        XCTAssertEqual(RunnerMenuView.runnerDetail(for: snapshot("a", .busy)), "Busy")
        var withJob = snapshot("a", .busy)
        withJob.currentJob = RunnerJob(id: "job", runnerID: withJob.id, name: "Release app", startedAt: Date(), outcome: .running)
        XCTAssertEqual(RunnerMenuView.runnerDetail(for: withJob), "Release app")
        XCTAssertEqual(RunnerMenuView.runnerDetail(for: snapshot("a", .idle)), "Idle")
        XCTAssertEqual(RunnerMenuView.runnerDetail(for: snapshot("a", .stopped)), "Stopped")
        XCTAssertEqual(RunnerMenuView.runnerDetail(for: snapshot("a", .unknown)), "Unknown")
    }

    private func snapshot(_ name: String, _ status: RunnerStatus, provider: RunnerProvider = .github, processID: Int32? = nil) -> RunnerSnapshot {
        let runner = InstalledRunner(name: name, directory: URL(fileURLWithPath: "/Users/demo/Runners/\(name)"), provider: provider)
        return RunnerSnapshot(runner: runner, status: status, processID: processID ?? (status.isRunning ? 4242 : nil))
    }
}
