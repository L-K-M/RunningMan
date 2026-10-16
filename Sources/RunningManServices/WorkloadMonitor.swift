import Foundation
import RunningManCore

/// Opt-in remote observations, separate from the three-second local process poll.
public actor WorkloadMonitor {
    private struct Cached { var snapshot: WorkloadScopeSnapshot; var nextAttempt: Date }
    private let executor: any ProcessExecuting
    private let forgejo: any ForgejoAPIRequesting
    private let githubCLIPath: String?
    private var cached: [String: Cached] = [:]
    private var lastReport = WorkloadReport()
    private var refreshing = false
    private var nextScopeIndex = 0
    private var requestsRemaining = 40
    private var batchDeadline = Date.distantFuture
    private var githubRetryAfter: Date?
    private var forgejoRetryAfter: [String: Date] = [:]
    public init(forgejo: any ForgejoAPIRequesting = ForgejoAPIClient()) {
        executor = SystemProcessExecutor(); self.forgejo = forgejo; githubCLIPath = nil
    }
    init(executor: any ProcessExecuting, forgejo: any ForgejoAPIRequesting, githubCLIPath: String = "/usr/bin/gh") {
        self.executor = executor; self.forgejo = forgejo; self.githubCLIPath = githubCLIPath
    }
    public func invalidate() { cached.removeAll() }
    public func refresh(runners: [InstalledRunner], force: Bool = false) async -> WorkloadReport {
        guard !refreshing else { return lastReport }
        refreshing = true; requestsRemaining = 40; batchDeadline = Date().addingTimeInterval(60)
        defer { refreshing = false }
        let wideScopes = Dictionary(uniqueKeysWithValues: runners.compactMap { runner -> (String, String)? in
            Self.wideForgejoScope(for: runner).map { (runner.id, $0) }
        })
        let groups = Dictionary(grouping: runners.filter { $0.remoteURL != nil }) {
            $0.provider.rawValue + ":" + $0.remoteURL!.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                + (wideScopes[$0.id].map { "#" + $0 } ?? "")
        }
        var snapshots: [WorkloadScopeSnapshot] = []
        let keys = groups.keys.sorted()
        let start = keys.isEmpty ? 0 : nextScopeIndex % keys.count
        let orderedKeys = Array(keys.dropFirst(start)) + Array(keys.prefix(start))
        if !keys.isEmpty { nextScopeIndex = (start + 1) % keys.count }
        for key in orderedKeys {
            guard let group = groups[key], let first = group.first, let scopeURL = first.remoteURL else { continue }
            let now = Date()
            if let entry = cached[key], now < entry.nextAttempt {
                snapshots.append(entry.snapshot); continue
            }
            do {
                let snapshot = try await fetch(scopeURL: scopeURL, provider: first.provider, runners: group, wideScope: wideScopes[first.id])
                try Task.checkCancellation()
                cached[key] = Cached(snapshot: snapshot, nextAttempt: now.addingTimeInterval(60))
                snapshots.append(snapshot)
            } catch {
                let apiError = error as? ForgejoAPIError
                if error is CancellationError || Task.isCancelled { return lastReport }
                let message = error is BudgetExceeded ? "Request limit reached. Monitoring will continue on the next refresh." : SecretRedactor.redact(error.localizedDescription)
                let snapshot = WorkloadScopeSnapshot(scopeURL: scopeURL, provider: first.provider, state: .unavailable,
                    message: message, checkedAt: now, runnerIDs: group.map(\.id), capacity: group.reduce(0) { $0 + $1.capacity },
                    scopeIdentifier: wideScopes[first.id], scopeTitle: wideScopes[first.id].map(Self.wideScopeTitle))
                let next = apiError?.retryAfter ?? now.addingTimeInterval(apiError?.statusCode == 429 || apiError?.statusCode == 403 ? 300 : 60)
                cached[key] = Cached(snapshot: snapshot, nextAttempt: max(next, now.addingTimeInterval(30)))
                snapshots.append(snapshot)
            }
        }
        // The force argument permits a caller to ask for a refresh, but never bypasses
        // the remote minimum interval or a server's Retry-After deadline.
        _ = force
        cached = cached.filter { groups[$0.key] != nil }
        lastReport = WorkloadReport(scopes: snapshots.sorted { $0.id < $1.id })
        return lastReport
    }

    private struct BudgetExceeded: LocalizedError { var errorDescription: String? { "The remote request budget was reached." } }
    private func consumeRequest() throws {
        try Task.checkCancellation()
        // Leave enough time for one bounded API call without keeping a refresh
        // running for many minutes when several repositories are unreachable.
        guard requestsRemaining > 0, batchDeadline.timeIntervalSinceNow >= 25 else { throw BudgetExceeded() }
        requestsRemaining -= 1
    }
    private func github(_ path: String) async throws -> Any {
        if let retry = githubRetryAfter, retry > Date() {
            throw ForgejoAPIError("GitHub API rate limit reached. Monitoring will retry later.", statusCode: 429, retryAfter: retry)
        }
        try consumeRequest()
        let response = try await executor.run(ProcessRequest(executable: try githubCLIPath ?? githubCLI(),
            arguments: ["api", "--hostname", "github.com", path], timeout: 25, outputLimit: 4 * 1024 * 1024))
        guard response.status == 0, !response.timedOut, !response.truncated else {
            let rateLimited = response.error.localizedCaseInsensitiveContains("rate limit") || response.error.contains("429")
            if rateLimited { githubRetryAfter = Date().addingTimeInterval(300) }
            throw ForgejoAPIError(rateLimited ? "GitHub API rate limit reached. Monitoring will retry later." : "GitHub queue could not be read. Check GitHub CLI sign-in and Actions read permissions.",
                statusCode: rateLimited ? 429 : nil, retryAfter: rateLimited ? Date().addingTimeInterval(300) : nil)
        }
        return try JSONSerialization.jsonObject(with: Data(response.output.utf8))
    }
    private func forge(_ path: String, server: URL) async throws -> Any {
        if let retry = forgejoRetryAfter[server.absoluteString], retry > Date() {
            throw ForgejoAPIError("This Forgejo server requested a monitoring pause.", statusCode: 429, retryAfter: retry)
        }
        try consumeRequest()
        do {
            let data = try await forgejo.request(path: path, serverURL: server, method: "GET", body: nil)
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch let error as ForgejoAPIError {
            if error.statusCode == 429 || error.retryAfter != nil {
                forgejoRetryAfter[server.absoluteString] = error.retryAfter ?? Date().addingTimeInterval(300)
            }
            throw error
        }
    }

    private static func wideForgejoScope(for runner: InstalledRunner) -> String? {
        guard runner.provider == .forgejo, let descriptor = try? RunnerInstallationDescriptor.load(from: runner.directory),
              descriptor.provider == .forgejo, descriptor.name == runner.name,
              descriptor.remoteURL == runner.remoteURL,
              descriptor.agentID == runner.agentID,
              let registration = descriptor.registrationPath,
              ["/user/actions/runners", "/admin/actions/runners"].contains(registration) else { return nil }
        return registration
    }
    private static func wideScopeTitle(_ path: String) -> String { path.hasPrefix("/admin/") ? "Entire instance" : "My account" }

    private func fetch(scopeURL: URL, provider: RunnerProvider, runners: [InstalledRunner], wideScope: String? = nil) async throws -> WorkloadScopeSnapshot {
        if provider == .forgejo, let wideScope {
            return try await wideForgejoJobs(server: scopeURL, registrationPath: wideScope, runners: runners)
        }
        let parts = scopeURL.path.split(separator: "/").map(String.init)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw ForgejoAPIError("Monitor a repository or organization URL. Instance-wide queue monitoring is not supported.")
        }
        if provider == .github { _ = try GitHubRunnerScope(url: scopeURL) }
        var serverParts = URLComponents(url: scopeURL, resolvingAgainstBaseURL: false)
        serverParts?.path = ""; serverParts?.query = nil; serverParts?.fragment = nil
        guard let rootURL = serverParts?.url else { throw ForgejoAPIError("Invalid remote server URL.") }
        let server = try ForgejoConnectionStore.origin(for: rootURL)
        let scopePrefix = (parts.count == 1 ? "orgs/" : "repos/") + parts.joined(separator: "/")
        var messages: [String] = []
        var remoteBusyIDs: [String] = []
        var labelMap = Dictionary(uniqueKeysWithValues: runners.filter { provider == .forgejo && !$0.labels.isEmpty }.map { ($0.id, $0.labels) })
        do {
            let object = provider == .github
                ? try await github(scopePrefix + "/actions/runners?per_page=100&page=1")
                : try await forge(scopePrefix + "/actions/runners?limit=100&page=1&visible=true", server: server)
            let remote: [[String: Any]]
            if let array = object as? [[String: Any]] { remote = array }
            else if let dictionary = object as? [String: Any], let array = dictionary["runners"] as? [[String: Any]] {
                remote = array
                if (dictionary["total_count"] as? Int ?? array.count) > array.count { messages.append("Runner label coverage is limited to the first 100 visible runners.") }
            } else { throw ForgejoAPIError("The server returned an unsupported runner list.") }
            if remote.count == 100 { messages.append("The runner list may have additional pages.") }
            for runner in runners {
                let item = remote.first { value in
                    if let id = runner.agentID { return value["id"] as? Int == id }
                    return provider == .github && value["name"] as? String == runner.name
                }
                if let item {
                    if provider == .forgejo, item["status"] as? String == "active" { remoteBusyIDs.append(runner.id) }
                    let labels = (item["labels"] as? [String]) ?? (item["labels"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                    if !labels.isEmpty { labelMap[runner.id] = labels }
                }
            }
        } catch { messages.append("Runner labels could not be fully verified; only known compatible jobs are shown.") }
        if runners.contains(where: { labelMap[$0.id]?.isEmpty != false }) { messages.append("Some runner labels are unknown. Queue matching is incomplete.") }

        var repositories: [String]
        if parts.count == 2 { repositories = [parts.joined(separator: "/")] }
        else {
            let object = provider == .github
                ? try await github("orgs/\(parts[0])/repos?type=all&per_page=100&page=1")
                : try await forge("orgs/\(parts[0])/repos?limit=100&page=1", server: server)
            guard let array = object as? [[String: Any]] else { throw ForgejoAPIError("The server returned an unsupported repository list.") }
            repositories = Array(array.compactMap { $0["full_name"] as? String }.prefix(8))
            messages.append("Organization coverage includes up to eight repositories visible to this account; repository access policies and other repositories may hide additional jobs.")
        }
        var allJobs: [WorkloadJob] = []
        var successfulRepositories = 0
        for repository in repositories {
            let repositoryParts = repository.split(separator: "/")
            guard repositoryParts.count == 2, repositoryParts.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
                messages.append("An unsupported repository name was skipped."); continue
            }
            do {
                let jobs = provider == .github
                    ? try await githubJobs(repository: repository, messages: &messages)
                    : try await forgejoJobs(repository: repository, server: server, messages: &messages)
                allJobs += jobs
                successfulRepositories += 1
            } catch {
                messages.append("\(repository): queue coverage is unavailable for this refresh.")
            }
        }
        guard successfulRepositories > 0 || repositories.isEmpty else { throw ForgejoAPIError("No repository queues could be read. Check access and Actions API availability.") }
        var missingJobLabels = false
        let ids = Set(runners.compactMap(\.agentID))
        let compatible = allJobs.filter { job in
            if job.state == .running, let agent = job.runnerAgentID { return ids.contains(agent) }
            guard !job.labels.isEmpty else { missingJobLabels = true; return false }
            return labelMap.values.contains { WorkloadScopeSnapshot.matches(jobLabels: job.labels, runnerLabels: $0, provider: provider) }
        }
        if missingJobLabels { messages.append("Jobs without reported runner labels were omitted because compatibility cannot be verified.") }
        let deduplicated = Array(Dictionary(compatible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
            .sorted { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
        return WorkloadScopeSnapshot(scopeURL: scopeURL, provider: provider,
            state: messages.isEmpty ? .available : .partial,
            message: messages.isEmpty ? "Compatible queued jobs are shared by this runner pool; assignment is decided by the server." : Array(Set(messages)).sorted().joined(separator: " "),
            jobs: deduplicated, runnerIDs: runners.map(\.id), runnerLabels: labelMap,
            capacity: runners.reduce(0) { $0 + $1.capacity }, remoteBusyRunnerIDs: remoteBusyIDs,
            countsKnown: !missingJobLabels && !(labelMap.isEmpty && !allJobs.isEmpty))
    }

    private func wideForgejoJobs(server: URL, registrationPath: String, runners: [InstalledRunner]) async throws -> WorkloadScopeSnapshot {
        let origin = try ForgejoConnectionStore.origin(for: server)
        var messages = ["This Forgejo API exposes queued and running jobs but omits blocked or pending jobs. Queue age and per-job runner assignment are not reported."]
        var labels = Dictionary(uniqueKeysWithValues: runners.filter { !$0.labels.isEmpty }.map { ($0.id, $0.labels) })
        var busyIDs: [String] = []
        do {
            let response = try await forge(registrationPath + "?limit=100&page=1", server: origin)
            guard let entries = response as? [[String: Any]] else { throw ForgejoAPIError("Unsupported Forgejo runner metadata.") }
            if entries.count >= 100 { messages.append("Runner metadata includes only the first 100 visible runners.") }
            for runner in runners {
                guard let id = runner.agentID, let value = entries.first(where: { $0["id"] as? Int == id }) else { continue }
                if let found = value["labels"] as? [String], !found.isEmpty { labels[runner.id] = found }
                if value["status"] as? String == "active" { busyIDs.append(runner.id) }
            }
        } catch { messages.append("Runner metadata could not be verified; known local labels are used.") }
        // Forgejo 16's source filters these endpoints to all waiting/running jobs.
        // It supports only a labels parameter, not pagination or status filters.
        // Never send made-up filters or inspect only the newest workflow runs.
        let response = try await forge(registrationPath + "/jobs", server: origin)
        let entries: [[String: Any]]
        if response is NSNull { entries = [] }
        else if let values = response as? [[String: Any]] { entries = values }
        else { throw ForgejoAPIError("This Forgejo version does not expose the selected runner-scope queue.") }
        if entries.count > 200 { messages.append("Only the first 200 active jobs were inspected; additional compatible jobs may exist.") }
        var unknownLabels = false
        var unsupportedState = false
        var jobs: [WorkloadJob] = []
        for value in entries.prefix(200) {
            guard let id = value["id"] as? Int, let state = Self.forgejoState(value["status"] as? String) else { unsupportedState = true; continue }
            let required = value["runs_on"] as? [String] ?? []
            guard !required.isEmpty else { unknownLabels = true; continue }
            guard labels.values.contains(where: { WorkloadScopeSnapshot.matches(jobLabels: required, runnerLabels: $0, provider: .forgejo) }) else { continue }
            let repository = (value["repo_id"] as? Int).map { "Repository #\($0)" } ?? "Repository not reported"
            jobs.append(WorkloadJob(id: "forgejo:\(origin.absoluteString):\(id)", name: Self.safe(value["name"] as? String ?? "Job \(id)"),
                repository: repository, state: state, labels: required))
        }
        if unknownLabels { messages.append("Jobs with unreported labels could not be matched.") }
        if unsupportedState { messages.append("Some job states were not recognized and were omitted.") }
        let countsKnown = !unknownLabels && !unsupportedState && runners.allSatisfy { labels[$0.id]?.isEmpty == false }
        if !countsKnown { messages.append("Compatible queue totals are unknown because some labels or states were unavailable.") }
        return WorkloadScopeSnapshot(scopeURL: origin, provider: .forgejo, state: .partial,
            message: messages.joined(separator: " "), jobs: jobs, runnerIDs: runners.map(\.id), runnerLabels: labels,
            capacity: runners.reduce(0) { $0 + $1.capacity }, remoteBusyRunnerIDs: busyIDs, countsKnown: countsKnown,
            scopeIdentifier: registrationPath, scopeTitle: Self.wideScopeTitle(registrationPath))
    }

    private func githubJobs(repository: String, messages: inout [String]) async throws -> [WorkloadJob] {
        var runs: [[String: Any]] = []
        // Query every nonterminal run state. A newest-runs-only query would miss
        // long-lived queued work behind newer completed builds.
        for status in ["queued", "in_progress", "waiting", "pending", "requested"] {
            let object = try await github("repos/\(repository)/actions/runs?status=\(status)&per_page=20&page=1")
            guard let dictionary = object as? [String: Any], let page = dictionary["workflow_runs"] as? [[String: Any]] else { throw ForgejoAPIError("GitHub returned an unsupported workflow run list.") }
            runs += page
            if (dictionary["total_count"] as? Int ?? page.count) > page.count || page.count == 20 { messages.append("\(repository): active workflow coverage is capped at 20 runs per state.") }
        }
        let unique = Dictionary(runs.compactMap { run -> (Int, [String: Any])? in (run["id"] as? Int).map { ($0, run) } }, uniquingKeysWith: { first, _ in first })
        var jobs: [WorkloadJob] = []
        var readableJobLists = 0
        for id in unique.keys.sorted().prefix(20) {
            guard let run = unique[id] else { continue }
            do {
                let object = try await github("repos/\(repository)/actions/runs/\(id)/jobs?per_page=100&page=1&filter=latest")
                guard let dictionary = object as? [String: Any], let page = dictionary["jobs"] as? [[String: Any]] else { throw ForgejoAPIError("GitHub returned an unsupported workflow job list.") }
                readableJobLists += 1
                if (dictionary["total_count"] as? Int ?? page.count) > page.count || page.count == 100 { messages.append("\(repository): workflow job coverage is capped at 100 jobs per run.") }
                for item in page {
                    guard let jobID = item["id"] as? Int, let state = Self.githubState(item["status"] as? String) else { continue }
                    jobs.append(WorkloadJob(id: "github:\(repository):\(jobID)", name: Self.safe(item["name"] as? String ?? "Job \(jobID)"), repository: repository,
                        workflow: (run["name"] as? String).map(Self.safe), url: Self.safeURL(item["html_url"] as? String, host: "github.com"), state: state,
                        labels: item["labels"] as? [String] ?? [], runnerAgentID: item["runner_id"] as? Int,
                        createdAt: Self.date(item["created_at"] as? String), startedAt: Self.date(item["started_at"] as? String)))
                }
            } catch { messages.append("\(repository): one workflow's jobs could not be read.") }
        }
        if !unique.isEmpty && readableJobLists == 0 { throw ForgejoAPIError("Workflow jobs could not be read; queue counts are unknown.") }
        if unique.count > 20 { messages.append("\(repository): only 20 active workflow runs were inspected.") }
        return jobs
    }

    private func forgejoJobs(repository: String, server: URL, messages: inout [String]) async throws -> [WorkloadJob] {
        var runs: [[String: Any]] = []
        for status in ["waiting", "running", "blocked"] {
            let object = try await forge("repos/\(repository)/actions/runs?status=\(status)&limit=20&page=1", server: server)
            guard let dictionary = object as? [String: Any], let page = dictionary["workflow_runs"] as? [[String: Any]] else { throw ForgejoAPIError("This Forgejo version does not expose compatible Actions run data.") }
            runs += page
            if (dictionary["total_count"] as? Int ?? page.count) > page.count || page.count == 20 { messages.append("\(repository): active workflow coverage is capped at 20 runs per state.") }
        }
        let unique = Dictionary(runs.compactMap { run -> (Int, [String: Any])? in (run["id"] as? Int).map { ($0, run) } }, uniquingKeysWith: { first, _ in first })
        var jobs: [WorkloadJob] = []
        var readableJobLists = 0
        for id in unique.keys.sorted().prefix(20) {
            guard let run = unique[id] else { continue }
            do {
                let object = try await forge("repos/\(repository)/actions/runs/\(id)/jobs", server: server)
                guard let page = object as? [[String: Any]] else { throw ForgejoAPIError("This Forgejo version does not expose compatible Actions jobs.") }
                readableJobLists += 1
                if page.count > 200 { messages.append("\(repository): only 200 jobs per workflow were inspected.") }
                for item in page.prefix(200) {
                    guard let jobID = item["id"] as? Int, let state = Self.forgejoState(item["status"] as? String) else { continue }
                    jobs.append(WorkloadJob(id: "forgejo:\(server.absoluteString):\(jobID)", name: Self.safe(item["name"] as? String ?? "Job \(jobID)"), repository: repository,
                        workflow: (run["workflow_id"] as? String).map(Self.safe), url: Self.safeURL(run["html_url"] as? String, host: server.host), state: state,
                        labels: item["runs_on"] as? [String] ?? [], runnerAgentID: item["runner_id"] as? Int,
                        createdAt: nil, startedAt: nil))
                }
            } catch { messages.append("\(repository): one workflow's jobs are unavailable on this server version.") }
        }
        if !unique.isEmpty && readableJobLists == 0 { throw ForgejoAPIError("Workflow jobs could not be read; queue counts are unknown.") }
        if unique.count > 20 { messages.append("\(repository): only 20 active workflow runs were inspected.") }
        return jobs
    }

    static func githubState(_ status: String?) -> WorkloadJobState? {
        switch status { case "queued": return .queued; case "in_progress": return .running
        case "waiting", "requested": return .waiting; case "pending": return .pending; default: return nil }
    }
    static func forgejoState(_ status: String?) -> WorkloadJobState? {
        switch status { case "waiting": return .queued; case "running": return .running
        case "blocked": return .waiting; case "pending": return .pending; default: return nil }
    }
    private static func safe(_ text: String) -> String { String(SecretRedactor.redact(text).prefix(500)) }
    private static func safeURL(_ text: String?, host: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.host?.lowercased() == host?.lowercased(), url.user == nil, url.password == nil else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false); parts?.query = nil; parts?.fragment = nil
        return parts?.url
    }
    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text), date.timeIntervalSince1970 > 0 { return date }
        plain.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
    }
}
