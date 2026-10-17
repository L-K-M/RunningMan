import Foundation

/// Serialises refresh passes without dropping requests.
///
/// A request that arrives while a pass is running is coalesced into exactly one
/// follow-up pass, however many requests arrive. Its caller resumes only after
/// that follow-up finishes, so code that awaits a refresh after changing runner
/// state always observes a pass that started after its change.
///
///     poll:    [pass 1 ......][pass 2 ......]
///     action:        ^ request (waits)       ^ resumes
///
/// A pass must never await `run(_:)` itself: it would wait for its own follow-up.
@MainActor final class RefreshCoalescer {
    private var isRunning = false
    private var followUpRequested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Passes started since creation; a test seam for coalescing.
    private(set) var passCount = 0
    /// A request arrived while the current pass was running, so the current pass may
    /// describe state from before that request.
    var hasPendingFollowUp: Bool { followUpRequested }

    /// Follow-up passes reuse the operation of the call that started the run.
    func run(_ pass: @MainActor () async -> Void) async {
        guard !isRunning else {
            followUpRequested = true
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        isRunning = true
        defer { isRunning = false }
        repeat {
            followUpRequested = false
            // Requests made during the previous pass are satisfied by this one.
            let satisfied = waiters
            waiters = []
            passCount += 1
            await pass()
            for waiter in satisfied { waiter.resume() }
        } while followUpRequested
    }
}
