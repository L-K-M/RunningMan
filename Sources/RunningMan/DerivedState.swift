import Foundation
import RunningManCore

/// Fleet-wide queue figures for the Workload metrics.
struct FleetQueueSummary: Equatable {
    /// At least one scope reports a compatible queue.
    var hasQueueEvidence = false
    /// Some scope is partial, unavailable or cannot match labels, so counts are a lower bound.
    var isIncomplete = false
    var queuedCount = 0
    var oldestQueuedAt: Date?

    init() {}

    init(scopes: [WorkloadScopeSnapshot]) {
        // A job can be visible through several scopes; count it once.
        var compatible: [String: WorkloadJob] = [:]
        for scope in scopes {
            guard let queued = scope.compatibleQueuedJobs, let running = scope.compatibleRunningJobs else { continue }
            for job in queued + running { compatible[job.id] = job }
        }
        let queued = compatible.values.filter { $0.state == .queued }
        hasQueueEvidence = scopes.contains { $0.compatibleQueuedJobs != nil }
        isIncomplete = scopes.contains { $0.state != .available || $0.compatibleQueuedJobs == nil }
        queuedCount = queued.count
        oldestQueuedAt = queued.compactMap(\.createdAt).min()
    }

    /// Queued jobs whose labels match each runner, from the first scope that lists
    /// it. A runner without an entry has an unknown queue, which is not an empty one.
    static func compatibleQueueCounts(scopes: [WorkloadScopeSnapshot], runnerIDs: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for id in runnerIDs {
            guard let scope = scopes.first(where: { $0.runnerIDs.contains(id) }), let queued = scope.compatibleQueuedJobs,
                  let labels = scope.runnerLabels[id] else { continue }
            counts[id] = queued.filter { WorkloadScopeSnapshot.matches(jobLabels: $0.labels, runnerLabels: labels, provider: scope.provider) }.count
        }
        return counts
    }
}

/// The figures the Workload page shows: a rounded busy percentage and whole
/// minutes of observed and busy time.
private struct ObservedUsageDisplay: Equatable {
    var percent: Int?
    var observedMinutes: Int
    var busyMinutes: Int

    init(_ usage: ObservedRunnerUsage) {
        percent = usage.busyFraction.map { Int(($0 * 100).rounded()) }
        observedMinutes = Int(usage.observedSeconds / 60)
        busyMinutes = Int(usage.busySeconds / 60)
    }
}

extension AppModel {
    /// Sampled usage changes on every poll because its window ends now. Publishing it
    /// only when a displayed figure changes keeps the Workload page from re-rendering
    /// every three seconds.
    nonisolated static func observedUsageDisplayChanged(from current: [String: ObservedRunnerUsage],
                                                        to next: [String: ObservedRunnerUsage]) -> Bool {
        current.mapValues(ObservedUsageDisplay.init) != next.mapValues(ObservedUsageDisplay.init)
    }

    nonisolated static func isSameDisplayedMinute(_ previous: Date?, _ next: Date) -> Bool {
        guard let previous else { return false }
        return (previous.timeIntervalSince1970 / 60).rounded(.down) == (next.timeIntervalSince1970 / 60).rounded(.down)
    }
}
