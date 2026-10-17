import Foundation

public enum RunnerProvider: String, Codable, CaseIterable, Sendable {
    case github, forgejo
    public var title: String { self == .github ? "GitHub" : "Forgejo" }
}

/// The launchd domain that owns a runner's service. RunningMan controls only
/// per-user services; system LaunchDaemons are observed read-only.
public enum RunnerServiceDomain: String, Codable, Sendable {
    case user, system
}

public enum RunnerStatus: String, Codable, CaseIterable, Sendable {
    case idle, busy, stopped, disabled, attention, unknown
    public var title: String {
        switch self {
        case .idle: return "Idle"
        case .busy: return "Running a job"
        case .stopped: return "Stopped"
        case .disabled: return "Disabled"
        case .attention: return "Needs attention"
        case .unknown: return "Unknown"
        }
    }
    public var isRunning: Bool { self == .idle || self == .busy }
}

/// The Runners list's status segments. Online covers every started service,
/// idle or busy; Busy narrows that to runners currently running a job.
public enum RunnerStatusFilter: String, CaseIterable, Sendable {
    case all, busy, online, stopped, attention
    public var title: String {
        switch self {
        case .all: return "All"
        case .busy: return "Busy"
        case .online: return "Online"
        case .stopped: return "Stopped"
        case .attention: return "Attention"
        }
    }
    public func matches(_ status: RunnerStatus) -> Bool {
        switch self {
        case .all: return true
        case .busy: return status == .busy
        case .online: return status.isRunning
        case .stopped: return status == .stopped || status == .disabled
        case .attention: return status == .attention || status == .unknown
        }
    }
}

public struct InstalledRunner: Identifiable, Codable, Hashable, Sendable {
    public var id: String { directory.standardizedFileURL.path }
    public var name: String
    public var directory: URL
    public var githubURL: URL?
    public var agentID: Int?
    public var serviceLabel: String?
    public var version: String?
    public var labels: [String]
    public var provider: RunnerProvider
    public var executableURL: URL?
    public var configurationURL: URL?
    public var diagnosticURLs: [URL]
    public var capacity: Int
    /// Public GitHub workFolder metadata; never inferred from Forgejo credentials.
    public var workDirectoryURL: URL?
    public var serviceDomain: RunnerServiceDomain
    /// The existing storage name remains compatible with saved GitHub installations.
    public var remoteURL: URL? {
        get { githubURL }
        set { githubURL = newValue }
    }
    public var repository: String {
        guard let remoteURL else { return "Local runner" }
        let path = remoteURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? remoteURL.host ?? "Local runner" : path
    }
    public init(name: String, directory: URL, githubURL: URL? = nil, agentID: Int? = nil,
                serviceLabel: String? = nil, version: String? = nil, labels: [String] = [],
                provider: RunnerProvider = .github, executableURL: URL? = nil,
                configurationURL: URL? = nil, diagnosticURLs: [URL] = [], capacity: Int = 1,
                workDirectoryURL: URL? = nil, serviceDomain: RunnerServiceDomain = .user) {
        self.name = name; self.directory = directory; self.githubURL = githubURL
        self.agentID = agentID; self.serviceLabel = serviceLabel; self.version = version; self.labels = labels
        self.provider = provider; self.executableURL = executableURL; self.configurationURL = configurationURL
        self.diagnosticURLs = diagnosticURLs; self.capacity = max(1, min(capacity, 256))
        self.workDirectoryURL = workDirectoryURL
        self.serviceDomain = serviceDomain
    }

    private enum CodingKeys: String, CodingKey {
        case name, directory, githubURL, agentID, serviceLabel, version, labels
        case provider, executableURL, configurationURL, diagnosticURLs, capacity, workDirectoryURL, serviceDomain
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try values.decode(String.self, forKey: .name), directory: try values.decode(URL.self, forKey: .directory),
            githubURL: try values.decodeIfPresent(URL.self, forKey: .githubURL), agentID: try values.decodeIfPresent(Int.self, forKey: .agentID),
            serviceLabel: try values.decodeIfPresent(String.self, forKey: .serviceLabel), version: try values.decodeIfPresent(String.self, forKey: .version),
            labels: try values.decodeIfPresent([String].self, forKey: .labels) ?? [],
            provider: try values.decodeIfPresent(RunnerProvider.self, forKey: .provider) ?? .github,
            executableURL: try values.decodeIfPresent(URL.self, forKey: .executableURL),
            configurationURL: try values.decodeIfPresent(URL.self, forKey: .configurationURL),
            diagnosticURLs: try values.decodeIfPresent([URL].self, forKey: .diagnosticURLs) ?? [],
            capacity: try values.decodeIfPresent(Int.self, forKey: .capacity) ?? 1,
            workDirectoryURL: try values.decodeIfPresent(URL.self, forKey: .workDirectoryURL),
            serviceDomain: try values.decodeIfPresent(RunnerServiceDomain.self, forKey: .serviceDomain) ?? .user)
    }
}

public enum JobOutcome: String, Codable, CaseIterable, Sendable {
    case running, success, failure, cancelled, unknown
    public var title: String { rawValue.capitalized }
}

public struct RunnerJob: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var runnerID: String
    public var name: String
    public var repository: String?
    public var workflow: String?
    public var runURL: URL?
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: JobOutcome
    public var duration: TimeInterval { max(0, (finishedAt ?? Date()).timeIntervalSince(startedAt)) }
    public init(id: String, runnerID: String, name: String, repository: String? = nil,
                workflow: String? = nil, runURL: URL? = nil, startedAt: Date,
                finishedAt: Date? = nil, outcome: JobOutcome = .running) {
        self.id = id; self.runnerID = runnerID; self.name = name; self.repository = repository
        self.workflow = workflow; self.runURL = runURL; self.startedAt = startedAt
        self.finishedAt = finishedAt; self.outcome = outcome
    }
}

public struct RunnerSnapshot: Identifiable, Hashable, Sendable {
    public var id: String { runner.id }
    public var runner: InstalledRunner
    public var status: RunnerStatus
    public var processID: Int32?
    public var startsAtLogin: Bool
    public var isEnabled: Bool
    public var currentJob: RunnerJob?
    public var detail: String?
    public init(runner: InstalledRunner, status: RunnerStatus = .unknown, processID: Int32? = nil,
                startsAtLogin: Bool = false, isEnabled: Bool = true, currentJob: RunnerJob? = nil,
                detail: String? = nil) {
        self.runner = runner; self.status = status; self.processID = processID
        self.startsAtLogin = startsAtLogin; self.isEnabled = isEnabled
        self.currentJob = currentJob; self.detail = detail
    }
}

public enum ActivityKind: String, Codable, Sendable { case info, success, warning, failure }

public struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var runnerID: String?
    public var title: String
    public var detail: String?
    public var kind: ActivityKind
    public init(id: UUID = UUID(), date: Date = Date(), runnerID: String? = nil,
                title: String, detail: String? = nil, kind: ActivityKind = .info) {
        self.id = id; self.date = date; self.runnerID = runnerID; self.title = title
        self.detail = detail; self.kind = kind
    }
}

public struct DiscoveryResult: Sendable {
    public var runners: [InstalledRunner]
    public var warnings: [String]
    public init(runners: [InstalledRunner] = [], warnings: [String] = []) { self.runners = runners; self.warnings = warnings }
}

public struct LogScanResult: Sendable {
    public var jobs: [RunnerJob]
    public var events: [ActivityEvent]
    public var warnings: [String]
    public var tails: [String: String]
    public init(jobs: [RunnerJob] = [], events: [ActivityEvent] = [], warnings: [String] = [], tails: [String: String] = [:]) {
        self.jobs = jobs; self.events = events; self.warnings = warnings; self.tails = tails
    }
}
