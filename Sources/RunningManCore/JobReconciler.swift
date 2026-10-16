import Foundation

/// Reconciles historical log evidence with positive current process observations.
/// Missing completion records stay undated and unknown; the app never invents a result.
public enum JobReconciler {
    public static func reconcile(jobs: [RunnerJob], snapshots: [RunnerSnapshot]) -> [RunnerJob] {
        let busy = Set(snapshots.filter { $0.status == .busy }.map(\.id))
        var newest: [String: RunnerJob] = [:]
        for job in jobs where job.finishedAt == nil {
            if let existing = newest[job.runnerID],
               existing.startedAt > job.startedAt || (existing.startedAt == job.startedAt && existing.id > job.id) { continue }
            newest[job.runnerID] = job
        }
        return jobs.map { job in
            guard job.outcome == .running, job.finishedAt == nil else { return job }
            guard busy.contains(job.runnerID), newest[job.runnerID]?.id == job.id else {
                var unknown = job
                unknown.outcome = .unknown
                return unknown
            }
            return job
        }
    }
}
