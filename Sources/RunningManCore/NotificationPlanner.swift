import Foundation

/// The events the user opted into. Every kind stays off until the user turns it on.
public struct NotificationPreferences: Hashable, Sendable {
    public var jobFailures: Bool
    public var jobSuccesses: Bool
    public var unexpectedStops: Bool
    public var isAnyEnabled: Bool { jobFailures || jobSuccesses || unexpectedStops }
    public init(jobFailures: Bool = false, jobSuccesses: Bool = false, unexpectedStops: Bool = false) {
        self.jobFailures = jobFailures; self.jobSuccesses = jobSuccesses; self.unexpectedStops = unexpectedStops
    }
}

public enum NotificationKind: String, Sendable {
    case jobFailed, jobSucceeded, jobCancelled, runnerStopped
}

public struct PlannedNotification: Identifiable, Hashable, Sendable {
    /// Stable deduplication key; also suitable as the delivered notification's identifier.
    public var id: String
    public var kind: NotificationKind
    public var title: String
    public var body: String
    public var runnerID: String
    public var jobID: String?
    init(id: String, kind: NotificationKind, title: String, body: String, runnerID: String, jobID: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.body = body; self.runnerID = runnerID; self.jobID = jobID
    }
}

/// Decides which notifications one refresh produces by comparing the state before and
/// after it. Pure: the caller owns delivery, the monitoring start date, recent user
/// actions and the bounded set of keys it has already notified.
public enum NotificationPlanner {
    /// A stop this soon after the user acted on the runner from RunningMan is expected.
    public static let userActionGrace: TimeInterval = 30
    /// Completions older than this are stale. Together with the monitoring start date this
    /// keeps relaunch reparses and replays after clearing saved history quiet.
    static let maximumJobAge: TimeInterval = 15 * 60

    public static func plan(previousJobs: [RunnerJob], currentJobs: [RunnerJob],
                            previousRunners: [RunnerSnapshot], currentRunners: [RunnerSnapshot],
                            recentUserActions: [String: Date], monitoringStartedAt: Date,
                            alreadyNotified: Set<String>, preferences: NotificationPreferences,
                            now: Date) -> [PlannedNotification] {
        guard preferences.isAnyEnabled else { return [] }
        let planned = jobNotifications(previous: previousJobs, current: currentJobs, runners: previousRunners + currentRunners,
                                       monitoringStartedAt: monitoringStartedAt, preferences: preferences, now: now)
            + runnerNotifications(previous: previousRunners, current: currentRunners,
                                  recentUserActions: recentUserActions, preferences: preferences, now: now)
        var seen = alreadyNotified
        return planned.filter { seen.insert($0.id).inserted }
    }

    private static func jobNotifications(previous: [RunnerJob], current: [RunnerJob], runners: [RunnerSnapshot],
                                         monitoringStartedAt: Date, preferences: NotificationPreferences,
                                         now: Date) -> [PlannedNotification] {
        guard preferences.jobFailures || preferences.jobSuccesses else { return [] }
        let earliest = max(monitoringStartedAt, now.addingTimeInterval(-maximumJobAge))
        let finished = current.filter { job in
            guard let finishedAt = job.finishedAt, finishedAt >= earliest else { return false }
            return kind(for: job.outcome, preferences: preferences) != nil
        }
        guard !finished.isEmpty else { return [] }
        // Only a record seen unfinished (or not at all) that has now finished is news. So is a
        // finished job whose unrecognised result a later log line confirmed.
        let candidateIDs = Set(finished.map(\.id))
        let finishedBefore = Set(previous.lazy.filter { $0.finishedAt != nil && $0.outcome != .unknown && candidateIDs.contains($0.id) }.map(\.id))
        let runnerNames = Dictionary(runners.map { ($0.id, $0.runner.name) }, uniquingKeysWith: { _, latest in latest })
        return finished.sorted { ($0.finishedAt ?? now, $0.id) < ($1.finishedAt ?? now, $1.id) }.compactMap { job in
            guard !finishedBefore.contains(job.id), let kind = kind(for: job.outcome, preferences: preferences) else { return nil }
            let title: String
            switch kind {
            case .jobFailed: title = "\(job.name) failed"
            case .jobSucceeded: title = "\(job.name) succeeded"
            case .jobCancelled: title = "\(job.name) was cancelled"
            case .runnerStopped: return nil
            }
            return notification(id: "job:\(job.id)", kind: kind, title: title,
                                lines: [context(repository: job.repository, runner: runnerNames[job.runnerID])],
                                runnerID: job.runnerID, jobID: job.id)
        }
    }

    private static func runnerNotifications(previous: [RunnerSnapshot], current: [RunnerSnapshot],
                                            recentUserActions: [String: Date], preferences: NotificationPreferences,
                                            now: Date) -> [PlannedNotification] {
        guard preferences.unexpectedStops else { return [] }
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return current.compactMap { snapshot in
            // Only a positively observed stop counts. Unknown is never a target, and a previous
            // unknown state without a live process is not evidence that the runner was running.
            guard snapshot.status == .stopped || snapshot.status == .disabled,
                  let old = before[snapshot.id], old.status.isRunning || old.processID != nil else { return nil }
            if let acted = recentUserActions[snapshot.id], now.timeIntervalSince(acted) < userActionGrace { return nil }
            // The previous process identifies this stop, so a later crash after a restart is new.
            let instance = old.processID.map(String.init) ?? "t\(Int(now.timeIntervalSince1970))"
            let job = old.status == .busy ? old.currentJob?.name : nil
            return notification(id: "runner-stopped:\(snapshot.id):\(instance)", kind: .runnerStopped,
                                title: "\(snapshot.runner.name) stopped unexpectedly",
                                lines: [context(repository: snapshot.runner.repository, runner: snapshot.runner.name),
                                        job.map { "It was running \($0)." }],
                                runnerID: snapshot.id)
        }
    }

    private static func kind(for outcome: JobOutcome, preferences: NotificationPreferences) -> NotificationKind? {
        switch outcome {
        case .failure: return preferences.jobFailures ? .jobFailed : nil
        case .success: return preferences.jobSuccesses ? .jobSucceeded : nil
        case .cancelled: return preferences.jobFailures ? .jobCancelled : nil
        case .running, .unknown: return nil
        }
    }

    private static func context(repository: String?, runner: String?) -> String? {
        let parts = [repository, runner].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Inputs are already redacted history and discovery values; redacting again is defense in depth.
    private static func notification(id: String, kind: NotificationKind, title: String, lines: [String?],
                                     runnerID: String, jobID: String? = nil) -> PlannedNotification {
        PlannedNotification(id: id, kind: kind, title: SecretRedactor.redact(title),
                            body: SecretRedactor.redact(lines.compactMap { $0 }.joined(separator: "\n")),
                            runnerID: runnerID, jobID: jobID)
    }
}
