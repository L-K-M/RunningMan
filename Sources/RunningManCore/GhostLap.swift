import Foundation

// A ghost lap races a running job against earlier runs of the same job. The track is laid out in
// the reference run's time: each step is a sector as long as it usually takes. The ghost moves at
// constant speed along that axis; the live runner crosses a sector as fast as the step finishes.
// While a step runs, nothing says how far along it is, so the runner advances at the ghost's speed
// and stops just short of the sector's end; when the step finishes it surges to the boundary. The
// lead is therefore exact at every step boundary and never guessed in between.

/// Identifies the same job across runs, so earlier runs can pace a new one.
public struct LapKey: Hashable, Codable, Sendable {
    public var provider: RunnerProvider
    public var repository: String
    public var workflow: String
    public var job: String

    public init(provider: RunnerProvider, repository: String?, workflow: String?, job: String) {
        self.provider = provider; self.repository = repository ?? ""; self.workflow = workflow ?? ""; self.job = job
    }

    public init(job: RunnerJob, provider: RunnerProvider) {
        self.init(provider: provider, repository: job.repository, workflow: job.workflow, job: job.name)
    }
}

/// One step of a finished run.
public struct LapSplit: Codable, Hashable, Sendable {
    public var name: String
    public var seconds: Double
    public var outcome: JobStepOutcome
    public init(name: String, seconds: Double, outcome: JobStepOutcome) {
        self.name = name; self.seconds = seconds; self.outcome = outcome
    }
}

/// A finished run of a job. Runs recorded without step times (Forgejo, or a job whose step log
/// was never read) have no splits and pace only the whole job.
public struct LapRecord: Codable, Hashable, Sendable {
    public var jobID: String
    public var finishedAt: Date
    public var outcome: JobOutcome
    public var seconds: Double
    public var splits: [LapSplit]

    public init(jobID: String, finishedAt: Date, outcome: JobOutcome, seconds: Double, splits: [LapSplit] = []) {
        self.jobID = jobID; self.finishedAt = finishedAt; self.outcome = outcome; self.seconds = seconds; self.splits = splits
    }

    /// A finished step log as a lap, or nil while the job runs or when it has no timed steps.
    public init?(log: JobStepLog, outcome: JobOutcome) {
        guard log.isFinished, let first = log.steps.first, let end = log.steps.compactMap(\.finishedAt).max() else { return nil }
        let splits = log.steps.compactMap { step -> LapSplit? in
            guard let finished = step.finishedAt else { return nil }
            return LapSplit(name: step.name, seconds: max(0, finished.timeIntervalSince(step.startedAt)), outcome: step.outcome)
        }
        self.init(jobID: log.jobID, finishedAt: end, outcome: outcome, seconds: max(0, end.timeIntervalSince(first.startedAt)), splits: splits)
    }
}

/// Which earlier run the ghost replays.
public enum GhostPace: String, CaseIterable, Sendable {
    /// The median of recent successful runs, step by step.
    case usual
    /// The fastest successful run.
    case best
    /// The most recent successful run.
    case last

    public var title: String {
        switch self {
        case .usual: return "Usual"
        case .best: return "Best"
        case .last: return "Last run"
        }
    }

    public var next: GhostPace {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// The run the ghost replays, as sectors in order.
public struct LapReference: Sendable, Equatable {
    public struct Sector: Sendable, Equatable {
        public let name: String
        /// Steps with the same name are told apart by how often the name occurred before.
        public let occurrence: Int
        public let seconds: Double
        /// The fastest successful time recorded for this step, when there are enough runs to say.
        public let best: Double?
        /// Recent successful durations of this step, oldest first.
        public let history: [Double]
    }

    public static let historyLimit = 20

    /// Paces the whole job as one sector, because no recorded run has step times.
    public var isWholeJob: Bool { sectors.count == 1 && sectors[0].name.isEmpty }
    /// A personal best needs this many earlier runs; with fewer, every run would be one.
    public static let bestMinimumRuns = 3

    public let pace: GhostPace
    public let sectors: [Sector]
    public let total: Double
    /// How many successful runs the reference draws on.
    public let runs: Int
    public let bestTotal: Double?
    /// Total times of the successful runs drawn on, oldest first.
    public let totals: [Double]

    /// Successful runs only: a failed run stops early and would make the ghost look slow.
    /// With fewer than three runs a median is not meaningful, so "usual" replays the last run.
    public static func make(from laps: [LapRecord], pace: GhostPace) -> LapReference? {
        let successful = laps.filter { $0.outcome == .success && $0.seconds > 0 }
            .sorted { $0.finishedAt < $1.finishedAt }.suffix(historyLimit)
        guard let last = successful.last else { return nil }
        let runs = successful.count
        let effective: GhostPace = pace == .usual && runs < 3 ? .last : pace
        let template: LapRecord
        switch effective {
        case .best: template = successful.min { $0.seconds < $1.seconds }!
        case .usual, .last: template = last
        }
        let bestTotal = runs >= bestMinimumRuns ? successful.map(\.seconds).min() : nil
        // Without step times the whole job is one sector.
        guard !template.splits.isEmpty else {
            let seconds = effective == .usual ? median(successful.map(\.seconds)) : template.seconds
            let sector = Sector(name: "", occurrence: 0, seconds: seconds, best: bestTotal, history: successful.map(\.seconds))
            return LapReference(pace: effective, sectors: [sector], total: seconds, runs: runs, bestTotal: bestTotal, totals: successful.map(\.seconds))
        }
        var durations: [StepIdentity: [Double]] = [:]
        for lap in successful {
            for (identity, split) in identified(lap.splits) where split.outcome == .success || split.outcome == .skipped {
                durations[identity, default: []].append(split.seconds)
            }
        }
        let sectors = identified(template.splits).map { identity, split -> Sector in
            let history = durations[identity] ?? []
            let seconds = effective == .usual && !history.isEmpty ? median(history) : split.seconds
            let best = history.count >= bestMinimumRuns ? history.min() : nil
            return Sector(name: identity.name, occurrence: identity.occurrence, seconds: seconds, best: best, history: history)
        }
        return LapReference(pace: effective, sectors: sectors, total: sectors.reduce(0) { $0 + $1.seconds }, runs: runs, bestTotal: bestTotal,
                            totals: successful.map(\.seconds))
    }

    struct StepIdentity: Hashable {
        let name: String
        let occurrence: Int
    }

    static func identified<T>(_ items: [T], name: (T) -> String) -> [(StepIdentity, T)] {
        var counts: [String: Int] = [:]
        return items.map { item in
            let key = name(item)
            defer { counts[key, default: 0] += 1 }
            return (StepIdentity(name: key, occurrence: counts[key] ?? 0), item)
        }
    }

    private static func identified(_ splits: [LapSplit]) -> [(StepIdentity, LapSplit)] { identified(splits, name: \.name) }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// Where a running (or just finished) job stands against its ghost at one instant.
public struct LapProgress: Sendable, Equatable {
    public enum SectorState: Sendable, Equatable {
        case upcoming, running, finished(JobStepOutcome)
    }

    public struct Sector: Sendable, Equatable, Identifiable {
        public let id: Int
        public let name: String
        /// The job step this sector shows, once the job has reached it.
        public let stepID: Int?
        /// Where the sector starts on the track, in reference seconds.
        public let start: Double
        /// How long the ghost spends here; zero for a step the reference run did not have.
        public let reference: Double
        /// Time spent so far, or the finished step's duration.
        public let actual: Double?
        public let state: SectorState
        /// Finished time minus reference time; negative is faster.
        public let split: Double?
        /// Faster than every earlier recorded run of this step.
        public let isPersonalBest: Bool
        /// Running well past its usual time.
        public let isOverrun: Bool
        /// Recent successful durations, oldest first.
        public let history: [Double]
    }

    public enum Outcome: Sendable, Equatable {
        case running, success, failure, cancelled
    }

    /// While a step runs, the runner stops this far into its sector, so it never claims a
    /// finished sector before the step really finishes.
    public static let runningCap = 0.98
    /// A finished split is only shown when it differs from the reference by at least this,
    /// because worker-log step times are whole seconds.
    public static let splitThreshold = 2.0

    public let sectors: [Sector]
    /// Track length in reference seconds.
    public let total: Double
    public let elapsed: Double
    /// The live runner's position on the track, in reference seconds.
    public let live: Double
    /// The ghost's position on the track, in reference seconds.
    public let ghost: Double
    /// Seconds behind the ghost; negative means ahead.
    public let lead: Double
    /// Estimated seconds until the job finishes, when there is a reference to estimate from.
    public let remaining: Double?
    public let outcome: Outcome
    public let currentSector: Int?
    public let failedSector: Int?
    public let reference: LapReference?

    public var isFinished: Bool { outcome != .running }

    /// Lays the job's steps over the reference. Steps match by name and occurrence; a step the
    /// reference lacks gets a zero-length sector after the step before it.
    public static func make(steps: [JobStep], reference: LapReference?, jobStarted: Date, isFinished: Bool, now: Date) -> LapProgress {
        let end = isFinished ? (steps.compactMap(\.finishedAt).max() ?? now) : now
        let elapsed = max(0, end.timeIntervalSince(jobStarted))
        if let reference, reference.sectors.count == 1, reference.sectors[0].name.isEmpty {
            return jobLevel(reference: reference, steps: steps, elapsed: elapsed, isFinished: isFinished)
        }

        let identifiedSteps = LapReference.identified(steps, name: \.name)
        let stepsByIdentity = Dictionary(identifiedSteps.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        // Reference order, with live-only steps inserted after the last matched step before them.
        var plan: [(identity: LapReference.StepIdentity, reference: LapReference.Sector?)] =
            (reference?.sectors ?? []).map { (LapReference.StepIdentity(name: $0.name, occurrence: $0.occurrence), $0) }
        var insertAt = 0
        for (identity, _) in identifiedSteps {
            if let index = plan.firstIndex(where: { $0.identity == identity }) {
                insertAt = index + 1
            } else {
                plan.insert((identity, nil), at: insertAt)
                insertAt += 1
            }
        }

        var sectors: [Sector] = []
        var start = 0.0, live = 0.0, remaining = 0.0
        var current: Int?, failed: Int?
        var outcome: Outcome = isFinished ? .success : .running
        for (index, entry) in plan.enumerated() {
            let referenceSeconds = entry.reference?.seconds ?? 0
            var state = SectorState.upcoming
            var actual: Double?
            var split: Double?
            var personalBest = false, overrun = false
            let step = stepsByIdentity[entry.identity]
            if let step {
                if let finished = step.finishedAt, step.outcome != .running {
                    let seconds = max(0, finished.timeIntervalSince(step.startedAt))
                    actual = seconds
                    state = .finished(step.outcome)
                    switch step.outcome {
                    case .failure, .cancelled:
                        // The runner stops where the job stopped, inside the sector.
                        live = start + min(seconds, referenceSeconds * runningCap)
                        if step.outcome == .failure { failed = failed ?? index; outcome = .failure }
                        else if outcome != .failure { outcome = .cancelled }
                    default:
                        // Cleanup steps after a failure still run, but the runner stays where it fell.
                        if outcome == .success || outcome == .running { live = start + referenceSeconds }
                    }
                    if entry.reference != nil, step.outcome == .success {
                        let difference = seconds - referenceSeconds
                        split = abs(difference) >= splitThreshold ? difference : 0
                        // A best must also be clearly faster than usual, or a one-second step
                        // would claim one whenever the clock rounds its way.
                        if let best = entry.reference?.best, seconds < best, difference <= -splitThreshold { personalBest = true }
                    }
                } else {
                    let inStep = max(0, now.timeIntervalSince(step.startedAt))
                    actual = inStep
                    state = .running
                    current = index
                    // Cleanup steps keep running after a failure; the runner stays where it fell.
                    if failed == nil, outcome != .cancelled { live = start + min(inStep, referenceSeconds * runningCap) }
                    remaining += max(referenceSeconds - inStep, referenceSeconds * 0.15)
                    overrun = referenceSeconds > 0 && inStep > referenceSeconds * 1.5 && inStep > referenceSeconds + 15
                }
            } else if !isFinished {
                remaining += referenceSeconds
            }
            sectors.append(Sector(id: index, name: entry.identity.name, stepID: step?.id, start: start, reference: referenceSeconds, actual: actual,
                                  state: state, split: split, isPersonalBest: personalBest, isOverrun: overrun,
                                  history: entry.reference?.history ?? []))
            start += referenceSeconds
        }
        let total = start
        // A successful job has crossed the whole track, including sectors it skipped.
        if outcome == .success { live = total }
        return LapProgress(sectors: sectors, total: total, elapsed: elapsed, live: live, ghost: total > 0 ? min(elapsed, total) : 0,
                           lead: reference == nil ? 0 : elapsed - live,
                           remaining: reference == nil || isFinished ? nil : remaining, outcome: outcome,
                           currentSector: current, failedSector: failed, reference: reference)
    }

    /// Without step times the ghost paces the whole job; the runner holds just short of the line.
    private static func jobLevel(reference: LapReference, steps: [JobStep], elapsed: Double, isFinished: Bool) -> LapProgress {
        let total = reference.total
        let failed = steps.contains { $0.outcome == .failure }
        let cancelled = steps.contains { $0.outcome == .cancelled }
        let outcome: Outcome = !isFinished ? .running : failed ? .failure : cancelled ? .cancelled : .success
        let live = outcome == .success ? total : min(elapsed, total * runningCap)
        let sector = Sector(id: 0, name: "", stepID: nil, start: 0, reference: total, actual: elapsed,
                            state: isFinished ? .finished(outcome == .success ? .success : failed ? .failure : .cancelled) : .running,
                            split: isFinished && outcome == .success ? elapsed - total : nil,
                            isPersonalBest: outcome == .success && (reference.bestTotal.map { elapsed < $0 } ?? false),
                            isOverrun: !isFinished && elapsed > total * 1.5 && elapsed > total + 15, history: reference.sectors[0].history)
        return LapProgress(sectors: [sector], total: total, elapsed: elapsed, live: live, ghost: min(elapsed, total),
                           lead: elapsed - live, remaining: isFinished ? nil : max(total - elapsed, total * 0.15),
                           outcome: outcome, currentSector: isFinished ? nil : 0, failedSector: failed ? 0 : nil, reference: reference)
    }
}

extension LapProgress {
    /// The lead in words, for captions and VoiceOver: "14 s ahead", "1:02 behind", "level".
    public static func describeLead(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        guard rounded != 0 else { return "level" }
        return "\(clock(Double(abs(rounded)))) \(rounded < 0 ? "ahead" : "behind")"
    }

    /// Seconds as "14 s", "1:02" or "1:02:03".
    public static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
