import Foundation

/// How long the monitoring loop waits between refreshes. Pure, so every
/// combination is unit-tested; `AppModel` supplies the live inputs.
enum PollingCadence {
    /// Someone is looking, a job runs or a stop-after-job request waits for idle.
    static let foreground: Duration = .seconds(3)
    /// Runners are online but nothing needs prompt attention.
    static let background: Duration = .seconds(10)
    /// No runner is running and nothing is draining.
    static let dormant: Duration = .seconds(60)
    /// The longest wait while a runner is online. Sampled utilisation only counts
    /// consecutive observations up to 15 seconds apart (`RunnerActivityStore`), so
    /// this leaves room for the refresh itself and the timer tolerance. Longer
    /// background waits would drop idle time from coverage and inflate busy shares.
    static let onlineLimit: Duration = .seconds(10)

    /// - Parameters:
    ///   - uiVisible: the main window is on screen or the menu bar panel is open.
    ///   - keepAwake: keep-awake is on; it polls promptly while a runner is online so
    ///     sleep prevention starts soon after a job does.
    ///   - lowPower: Low Power Mode doubles the wait, except for pending
    ///     stop-after-job requests, which must stop the runner soon after its job.
    static func pollInterval(uiVisible: Bool, anyBusy: Bool, anyDraining: Bool,
                             keepAwake: Bool, lowPower: Bool, anyRunning: Bool) -> Duration {
        if anyDraining { return foreground }
        let base: Duration
        if uiVisible || anyBusy || (keepAwake && anyRunning) { base = foreground }
        else if anyRunning { base = background }
        else { base = dormant }
        let interval = lowPower ? base * 2 : base
        return anyRunning ? min(interval, onlineLimit) : interval
    }

    /// Lets the system coalesce wake-ups; a tenth of the interval keeps the
    /// online limit plus tolerance well inside the 15-second sampling gap.
    static func tolerance(for interval: Duration) -> Duration { interval / 10 }
}

/// The polling loop's wait. `wake()` ends the current wait early, so opening the
/// window or the menu refreshes at once instead of after a background interval.
/// Cancelling the waiting task ends the wait too.
@MainActor final class PollingTimer {
    private var sleeper: Task<Void, Never>?

    func sleep(for interval: Duration) async {
        let sleeper = Task { _ = try? await Task.sleep(for: interval, tolerance: PollingCadence.tolerance(for: interval)) }
        self.sleeper = sleeper
        await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
    }

    func wake() { sleeper?.cancel() }
}
