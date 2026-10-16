import Foundation

/// Reconciles historical log evidence with positive current process observations.
/// Missing completion records stay undated and unknown; the app never invents a result.
public enum JobReconciler {
    public static func reconcile(jobs: [RunnerJob], snapshots: [RunnerSnapshot]) -> [RunnerJob] {
        let capacity = Dictionary(snapshots.filter { $0.status == .busy }.map { ($0.id, max(1, $0.runner.capacity)) }, uniquingKeysWith: max)
        let unfinished = Dictionary(grouping: jobs.filter { $0.finishedAt == nil }, by: \.runnerID)
        var liveIDs = Set<String>()
        for (runnerID, slots) in capacity {
            let latest = (unfinished[runnerID] ?? []).sorted {
                $0.startedAt == $1.startedAt ? $0.id > $1.id : $0.startedAt > $1.startedAt
            }.prefix(slots)
            liveIDs.formUnion(latest.map(\.id))
        }
        return jobs.map { job in
            guard job.outcome == .running, job.finishedAt == nil else { return job }
            guard liveIDs.contains(job.id) else {
                var unknown = job
                unknown.outcome = .unknown
                return unknown
            }
            return job
        }
    }
}
