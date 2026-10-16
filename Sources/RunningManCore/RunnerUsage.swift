import Foundation

public struct RunnerUsageMetrics: Equatable, Sendable {
    public var windowStart: Date
    public var windowEnd: Date
    public var capacity: Int
    public var recordedSlotSeconds: TimeInterval
    public var recordedBusySeconds: TimeInterval
    public var recordedUtilization: Double
    public var jobsStarted: Int
    public var completedJobs: Int
    public var jobsPerHour: Double
    public var medianDuration: TimeInterval?
    public var earliestRecordedJob: Date?
}

/// Local history is incomplete evidence, not a continuous availability record.
/// Callers should reconcile unfinished jobs with current state before calculation.
public enum RunnerUsage {
    public static func calculate(runner: InstalledRunner, jobs: [RunnerJob], now: Date = Date(),
                                 window: TimeInterval = 86_400) -> RunnerUsageMetrics {
        let duration = window.isFinite && window > 0 ? min(window, 366 * 86_400) : 86_400
        let start = now.addingTimeInterval(-duration)
        let capacity = max(1, min(runner.capacity, 256))
        let records = jobs.filter { $0.runnerID == runner.id }.reduce(into: [String: RunnerJob]()) { indexed, job in
            if let previous = indexed[job.id], previous.finishedAt != nil && job.finishedAt == nil { return }
            indexed[job.id] = job
        }.values
        var edges: [(Date, Int)] = []
        var durations: [TimeInterval] = []
        var started = 0
        var completed = 0
        for job in records {
            if job.startedAt >= start && job.startedAt <= now { started += 1 }
            if let end = job.finishedAt, end >= job.startedAt, end >= start, end <= now {
                completed += 1
                durations.append(end.timeIntervalSince(job.startedAt))
            }
            guard let end = job.finishedAt ?? (job.outcome == .running ? now : nil), end >= job.startedAt else { continue }
            let lower = max(start, job.startedAt), upper = min(now, end)
            guard upper > lower else { continue }
            edges.append((lower, 1)); edges.append((upper, -1))
        }
        edges.sort { $0.0 < $1.0 }
        var active = 0
        var previous = start
        var slotSeconds = 0.0
        var busySeconds = 0.0
        for (date, delta) in edges {
            let seconds = max(0, date.timeIntervalSince(previous))
            slotSeconds += seconds * Double(min(capacity, max(0, active)))
            if active > 0 { busySeconds += seconds }
            active += delta; previous = date
        }
        durations.sort()
        let median: TimeInterval?
        if durations.isEmpty { median = nil }
        else if durations.count.isMultiple(of: 2) { median = (durations[durations.count / 2 - 1] + durations[durations.count / 2]) / 2 }
        else { median = durations[durations.count / 2] }
        return RunnerUsageMetrics(windowStart: start, windowEnd: now, capacity: capacity,
            recordedSlotSeconds: slotSeconds, recordedBusySeconds: busySeconds,
            recordedUtilization: min(1, max(0, slotSeconds / (Double(capacity) * duration))),
            jobsStarted: started, completedJobs: completed, jobsPerHour: Double(completed) / (duration / 3600),
            medianDuration: median, earliestRecordedJob: records.map(\.startedAt).min())
    }
}
