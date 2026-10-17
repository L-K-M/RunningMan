import AppKit
import XCTest
import RunningManCore
@testable import RunningMan

final class MenuBarTests: XCTestCase {
    func testCadenceScalesWithBusyRunnersAndStopsWhenNothingIsBusy() throws {
        XCTAssertNil(MenuBarAnimator.framesPerSecond(busyRunners: 0), "No busy runner must mean no timer at all")
        XCTAssertNil(MenuBarAnimator.framesPerSecond(busyRunners: -1))
        let jog = try XCTUnwrap(MenuBarAnimator.framesPerSecond(busyRunners: 1))
        XCTAssertEqual(jog, 3.5, accuracy: 0.5, "One busy runner jogs at about 3 to 4 frames per second")
        let rates = (1...10).compactMap { MenuBarAnimator.framesPerSecond(busyRunners: $0) }
        XCTAssertEqual(rates.count, 10)
        XCTAssertEqual(rates, rates.sorted(), "More busy runners never slow the figure down")
        XCTAssertEqual(MenuBarAnimator.framesPerSecond(busyRunners: 3), 6)
        XCTAssertEqual(rates.max(), 6, "Three or more busy runners sprint at about 6 frames per second, never faster")
    }

    func testFigureFollowsTheFleet() {
        XCTAssertEqual(MenuBarStatus(runners: []).figure, .standing)
        XCTAssertEqual(MenuBarStatus(runners: [snapshot("a", .stopped), snapshot("b", .disabled)]).figure, .standing)
        XCTAssertEqual(MenuBarStatus(runners: [snapshot("a", .idle), snapshot("b", .stopped)]).figure, .ready)
        let busy = MenuBarStatus(runners: [snapshot("a", .busy), snapshot("b", .busy), snapshot("c", .idle)])
        XCTAssertEqual(busy.figure, .running)
        XCTAssertEqual(busy.busy, 2)
        XCTAssertEqual(busy.online, 3)
        XCTAssertEqual(MenuBarStatus(runners: [snapshot("a", .attention)]).figure, .fallen)
        let tripped = MenuBarStatus(runners: [snapshot("a", .busy), snapshot("b", .unknown)])
        XCTAssertEqual(tripped.figure, .fallen, "A runner whose state cannot be read outranks a busy one")
        XCTAssertEqual(tripped.attention, 1)
    }

    /// A running Forgejo daemon is unknown whenever its activity cannot be verified, for
    /// example with server monitoring off; that is not a fault and needs no attention.
    func testUnverifiedForgejoActivityDoesNotNeedAttention() {
        let unverified = snapshot("forge", .unknown, provider: .forgejo, processID: 9051)
        XCTAssertFalse(unverified.needsAttention)
        XCTAssertTrue(unverified.isOnline)
        XCTAssertEqual(MenuBarStatus(runners: [unverified]).figure, .ready)
        XCTAssertTrue(snapshot("forge", .unknown, provider: .forgejo).needsAttention, "Without a process the state is simply unreadable")
        XCTAssertTrue(snapshot("github", .unknown, processID: 8040).needsAttention)
        XCTAssertEqual(RunnerMenuView.runnerDetail(for: unverified), "Online, activity not verified")
    }

    func testAccessibilityLabelNamesTheStateAndBusyCount() {
        XCTAssertEqual(MenuBarStatus().accessibilityLabel, "RunningMan, no runners online")
        XCTAssertEqual(MenuBarStatus(online: 1).accessibilityLabel, "RunningMan, 1 runner online, none busy")
        XCTAssertEqual(MenuBarStatus(online: 3, busy: 1).accessibilityLabel, "RunningMan, 1 runner busy")
        XCTAssertEqual(MenuBarStatus(online: 3, busy: 2).accessibilityLabel, "RunningMan, 2 runners busy")
        XCTAssertEqual(MenuBarStatus(online: 3, busy: 2, attention: 1).accessibilityLabel, "RunningMan, 1 runner needs attention, 2 busy")
        XCTAssertEqual(MenuBarStatus(attention: 2).accessibilityLabel, "RunningMan, 2 runners need attention")
    }

    @MainActor func testEveryFrameIsATemplateOfTheSameSize() {
        let figures: [MenuBarStatus.Figure] = [.standing, .ready, .running, .fallen]
        for figure in figures {
            for frame in MenuBarAnimator.frames(for: figure) {
                XCTAssertTrue(frame.isTemplate, "\(figure) frames must adapt to the menu bar appearance")
                XCTAssertEqual(frame.size, MenuBarAnimator.canvas, "The menu bar item must not change width between states")
            }
        }
        let running = MenuBarAnimator.frames(for: .running)
        XCTAssertEqual(running.count, 4)
        XCTAssertEqual(Set(running.map(ObjectIdentifier.init)).count, 4)
        XCTAssertEqual(MenuBarAnimator.frames(for: .ready).count, 1)
    }

    @MainActor func testAnimatorTicksOnlyWhileBusyAndMotionIsAllowed() async throws {
        let animator = MenuBarAnimator(motion: .animated, reduceMotion: { false })
        XCTAssertNil(animator.frameRate)
        animator.show(MenuBarStatus(online: 3, busy: 3))
        XCTAssertEqual(animator.frameRate, 6)
        XCTAssertEqual(animator.frameIndex, 0)
        let first = animator.image
        let deadline = Date().addingTimeInterval(3)
        while animator.frameIndex == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotEqual(animator.frameIndex, 0, "The figure must advance while a job runs")
        XCTAssertFalse(animator.image === first)
        XCTAssertTrue(animator.image.isTemplate)

        animator.show(MenuBarStatus(online: 3, busy: 1))
        XCTAssertEqual(animator.frameRate, MenuBarAnimator.framesPerSecond(busyRunners: 1))

        animator.show(MenuBarStatus(online: 3))
        XCTAssertNil(animator.frameRate, "No timer may run while idle")
        XCTAssertEqual(animator.status.figure, .ready)
        XCTAssertEqual(animator.frameIndex, 0)
        let idle = animator.image
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(animator.image === idle, "A cancelled ticker must not advance the idle figure")
    }

    /// The status item reads its VoiceOver title from the image, and only when the image
    /// changes; a count change without a new figure must still replace the image.
    @MainActor func testVoiceOverTitleFollowsEveryStatusChange() {
        let animator = MenuBarAnimator(motion: .still)
        XCTAssertEqual(animator.image.accessibilityDescription, "RunningMan, no runners online")
        animator.show(MenuBarStatus(online: 3, busy: 2))
        let busy = animator.image
        XCTAssertEqual(busy.accessibilityDescription, "RunningMan, 2 runners busy")
        animator.show(MenuBarStatus(online: 3, busy: 1))
        XCTAssertFalse(animator.image === busy)
        XCTAssertEqual(animator.image.accessibilityDescription, "RunningMan, 1 runner busy")
        XCTAssertTrue(animator.image.isTemplate)
        XCTAssertNil(MenuBarAnimator.frames(for: .running)[0].accessibilityDescription, "Shared frames stay undescribed")
    }

    @MainActor func testReduceMotionAndStillCapturesShowOneBusyFrame() {
        for animator in [MenuBarAnimator(motion: .animated, reduceMotion: { true }), MenuBarAnimator(motion: .still, reduceMotion: { false })] {
            animator.show(MenuBarStatus(online: 2, busy: 2))
            XCTAssertNil(animator.frameRate)
            XCTAssertEqual(animator.status.figure, .running)
            XCTAssertEqual(animator.frameIndex, 0, "The first running frame keeps its motion lines, so busy still differs from idle")
        }
    }

    @MainActor func testAnimatorFollowsTheModel() async throws {
        let model = AppModel(demoMode: true)
        let animator = MenuBarAnimator(motion: .still)
        animator.follow(model)
        XCTAssertEqual(animator.status, MenuBarStatus(runners: model.runners))
        XCTAssertEqual(animator.status.figure, .running)
        for busy in model.runners where busy.status == .busy {
            model.perform(.stop, on: busy)
            model.confirmPendingAction()
        }
        let deadline = Date().addingTimeInterval(2)
        while animator.status.busy > 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(animator.status.busy, 0)
        XCTAssertEqual(animator.status.figure, .ready)
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
