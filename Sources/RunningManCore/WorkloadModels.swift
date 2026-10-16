import Foundation

public enum WorkloadJobState: String, Codable, CaseIterable, Sendable {
    case queued, pending, waiting, running
    public var title: String { rawValue.capitalized }
}

/// A remote job is part of a compatible pool, not a reservation for one Mac.
public struct WorkloadJob: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var repository: String
    public var workflow: String?
    public var url: URL?
    public var state: WorkloadJobState
    public var labels: [String]
    public var runnerAgentID: Int?
    public var createdAt: Date?
    public var startedAt: Date?
    public init(id: String, name: String, repository: String, workflow: String? = nil,
                url: URL? = nil, state: WorkloadJobState, labels: [String] = [],
                runnerAgentID: Int? = nil, createdAt: Date? = nil, startedAt: Date? = nil) {
        self.id = id; self.name = name; self.repository = repository; self.workflow = workflow
        self.url = url; self.state = state; self.labels = labels; self.runnerAgentID = runnerAgentID
        self.createdAt = createdAt; self.startedAt = startedAt
    }
}

public enum WorkloadAvailability: String, Codable, Sendable { case available, partial, unavailable }

public struct WorkloadScopeSnapshot: Identifiable, Sendable {
    public var id: String { provider.rawValue + ":" + scopeURL.absoluteString + (scopeIdentifier.map { "#" + $0 } ?? "") }
    public var scopeIdentifier: String?
    public var scopeTitle: String?
    public var scopeURL: URL
    public var provider: RunnerProvider
    public var state: WorkloadAvailability
    public var message: String?
    public var jobs: [WorkloadJob]
    public var checkedAt: Date
    public var runnerIDs: [String]
    /// Server labels keyed by local runner ID. Missing entries are unknown, not empty.
    public var runnerLabels: [String: [String]]
    public var capacity: Int
    public var remoteBusyRunnerIDs: [String]
    public var countsKnown: Bool
    public var queuedCount: Int? { state == .unavailable || !countsKnown ? nil : jobs.filter { $0.state == .queued }.count }
    public var runningCount: Int? { state == .unavailable || !countsKnown ? nil : jobs.filter { $0.state == .running }.count }
    public var waitingCount: Int? { state == .unavailable || !countsKnown ? nil : jobs.filter { $0.state == .waiting || $0.state == .pending }.count }
    public var compatibleQueuedJobs: [WorkloadJob]? {
        guard state != .unavailable, countsKnown, !runnerIDs.isEmpty,
              runnerIDs.allSatisfy({ runnerLabels[$0]?.isEmpty == false }) else { return nil }
        return jobs.filter { $0.state == .queued }
    }
    public var compatibleRunningJobs: [WorkloadJob]? {
        guard state != .unavailable, countsKnown, !runnerIDs.isEmpty,
              runnerIDs.allSatisfy({ runnerLabels[$0]?.isEmpty == false }) else { return nil }
        return jobs.filter { $0.state == .running }
    }
    public var oldestQueuedAt: Date? { jobs.filter { $0.state == .queued }.compactMap(\.createdAt).min() }
    public init(scopeURL: URL, provider: RunnerProvider, state: WorkloadAvailability,
                message: String? = nil, jobs: [WorkloadJob] = [], checkedAt: Date = Date(),
                runnerIDs: [String] = [], runnerLabels: [String: [String]] = [:], capacity: Int = 0,
                remoteBusyRunnerIDs: [String] = [], countsKnown: Bool = true,
                scopeIdentifier: String? = nil, scopeTitle: String? = nil) {
        self.scopeURL = scopeURL; self.provider = provider; self.state = state; self.message = message
        self.jobs = jobs; self.checkedAt = checkedAt; self.runnerIDs = runnerIDs
        self.runnerLabels = runnerLabels; self.capacity = max(0, capacity)
        self.remoteBusyRunnerIDs = remoteBusyRunnerIDs; self.countsKnown = countsKnown
        self.scopeIdentifier = scopeIdentifier; self.scopeTitle = scopeTitle
    }
    public func compatibleJobs(for runnerID: String) -> [WorkloadJob] {
        guard let labels = runnerLabels[runnerID], !labels.isEmpty else { return [] }
        return jobs.filter { Self.matches(jobLabels: $0.labels, runnerLabels: labels, provider: provider) }
    }
    public static func matches(jobLabels: [String], runnerLabels: [String], provider: RunnerProvider = .github) -> Bool {
        guard !jobLabels.isEmpty, !runnerLabels.isEmpty else { return false }
        let available = Set(provider == .github ? runnerLabels.map { $0.lowercased() } : runnerLabels)
        return jobLabels.allSatisfy { available.contains(provider == .github ? $0.lowercased() : $0) }
    }
}

public struct WorkloadReport: Sendable {
    public var scopes: [WorkloadScopeSnapshot]
    public var fetchedAt: Date
    public init(scopes: [WorkloadScopeSnapshot] = [], fetchedAt: Date = Date()) {
        self.scopes = scopes; self.fetchedAt = fetchedAt
    }
}
