import XCTest
@testable import RunningMan

final class PollingCadenceTests: XCTestCase {
    private func interval(visible: Bool = false, busy: Bool = false, draining: Bool = false,
                          keepAwake: Bool = false, lowPower: Bool = false, running: Bool = false) -> Duration {
        PollingCadence.pollInterval(uiVisible: visible, anyBusy: busy, anyDraining: draining,
                                    keepAwake: keepAwake, lowPower: lowPower, anyRunning: running)
    }

    func testVisibleWorkAndDrainsPollEveryThreeSeconds() {
        XCTAssertEqual(interval(visible: true, running: true), .seconds(3))
        XCTAssertEqual(interval(visible: true), .seconds(3), "An open window stays fresh even with nothing running.")
        XCTAssertEqual(interval(busy: true, running: true), .seconds(3))
        XCTAssertEqual(interval(draining: true, running: true), .seconds(3))
        XCTAssertEqual(interval(keepAwake: true, running: true), .seconds(3))
    }

    func testBackgroundAndDormantPollLessOften() {
        XCTAssertEqual(interval(running: true), .seconds(10))
        XCTAssertEqual(interval(), .seconds(60))
        XCTAssertEqual(interval(keepAwake: true), .seconds(60), "Keep-awake has nothing to watch without a running runner.")
    }

    func testLowPowerModeDoublesExceptForDrains() {
        XCTAssertEqual(interval(visible: true, lowPower: true, running: true), .seconds(6))
        XCTAssertEqual(interval(busy: true, lowPower: true, running: true), .seconds(6))
        XCTAssertEqual(interval(lowPower: true), .seconds(120))
        XCTAssertEqual(interval(draining: true, lowPower: true, running: true), .seconds(3))
        XCTAssertEqual(interval(draining: true, lowPower: true), .seconds(3))
    }

    func testOnlineRunnersNeverWaitBeyondTheSamplingLimit() {
        // RunnerActivityStore only counts observations up to 15 seconds apart.
        for visible in [false, true] {
            for busy in [false, true] {
                for keepAwake in [false, true] {
                    for lowPower in [false, true] {
                        let wait = interval(visible: visible, busy: busy, keepAwake: keepAwake, lowPower: lowPower, running: true)
                        XCTAssertLessThanOrEqual(wait + PollingCadence.tolerance(for: wait), .seconds(11))
                    }
                }
            }
        }
        XCTAssertEqual(interval(lowPower: true, running: true), .seconds(10))
    }

    @MainActor func testWakeEndsAWaitEarly() async {
        let timer = PollingTimer()
        let start = ContinuousClock.now
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            timer.wake()
        }
        await timer.sleep(for: .seconds(30))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    @MainActor func testCancellingTheWaitingTaskEndsTheWait() async {
        let timer = PollingTimer()
        let start = ContinuousClock.now
        let waiter = Task { @MainActor in await timer.sleep(for: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await waiter.value
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }
}
