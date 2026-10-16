import XCTest
import Foundation
import RunningManCore
@testable import RunningManServices

private actor QueueExecutor: ProcessExecuting {
    var calls: [String] = []
    let responses: [String: String]
    let error: String?
    init(responses: [String: String] = [:], error: String? = nil) { self.responses = responses; self.error = error }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let path = request.arguments.last ?? ""; calls.append(path)
        if let error { return ProcessResult(status: 1, output: "", error: error) }
        if let value = responses[path] { return ProcessResult(status: 0, output: value, error: "") }
        if path.contains("/actions/runs?") { return ProcessResult(status: 0, output: #"{"total_count":0,"workflow_runs":[]}"#, error: "") }
        return ProcessResult(status: 1, output: "", error: "not in fixture")
    }
    func count() -> Int { calls.count }
}
private actor QueueForgejo: ForgejoAPIRequesting {
    let responses: [String: String]
    var hosts: [String] = []
    init(responses: [String: String] = [:]) { self.responses = responses }
    func request(path: String, serverURL: URL, method: String, body: Data?) async throws -> Data {
        hosts.append(serverURL.host ?? "")
        if let value = responses[path] { return Data(value.utf8) }
        if path.contains("/actions/runs?") { return Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8) }
        throw ForgejoAPIError("Unavailable fixture endpoint", statusCode: 404)
    }
}
final class WorkloadMonitorTests: XCTestCase {
    private func runner(labels: [String] = [], provider: RunnerProvider = .github) -> InstalledRunner {
        InstalledRunner(name: "mac", directory: URL(fileURLWithPath: "/tmp/fictional-mac"),
            githubURL: URL(string: provider == .github ? "https://github.com/example/project" : "https://forge.example/example/project"),
            agentID: 9, labels: labels, provider: provider, capacity: provider == .github ? 1 : 3)
    }
    func testLabelMatchingRequiresEveryLabelAndUsesProviderRules() {
        XCTAssertTrue(WorkloadScopeSnapshot.matches(jobLabels: ["self-hosted", "macOS"], runnerLabels: ["SELF-HOSTED", "macos", "ARM64"]))
        XCTAssertFalse(WorkloadScopeSnapshot.matches(jobLabels: ["macOS", "gpu"], runnerLabels: ["macOS"]))
        XCTAssertFalse(WorkloadScopeSnapshot.matches(jobLabels: [], runnerLabels: ["macOS"]))
        XCTAssertFalse(WorkloadScopeSnapshot.matches(jobLabels: ["macOS"], runnerLabels: ["macos"], provider: .forgejo))
    }
    func testGitHubEnrichesLabelsAndSeparatesQueuedWaitingAndPending() async {
        let fake = QueueExecutor(responses: [
            "repos/example/project/actions/runners?per_page=100&page=1": #"{"total_count":1,"runners":[{"id":9,"name":"mac","labels":[{"name":"self-hosted"},{"name":"macOS"},{"name":"ARM64"}]}]}"#,
            "repos/example/project/actions/runs?status=queued&per_page=20&page=1": #"{"total_count":1,"workflow_runs":[{"id":11,"name":"Release","created_at":"2026-01-01T00:00:00Z"}]}"#,
            "repos/example/project/actions/runs/11/jobs?per_page=100&page=1&filter=latest": #"{"total_count":5,"jobs":[{"id":1,"name":"Mac","status":"queued","labels":["self-hosted","macOS"]},{"id":2,"name":"Linux","status":"queued","labels":["linux"]},{"id":3,"name":"Approval","status":"waiting","labels":["macOS"]},{"id":4,"name":"Concurrency","status":"pending","labels":["macOS"]},{"id":5,"name":"Other Mac","status":"in_progress","runner_id":99,"labels":["macOS"]}]}"#
        ])
        let monitor = WorkloadMonitor(executor: fake, forgejo: QueueForgejo())
        let report = await monitor.refresh(runners: [runner()])
        let scope = report.scopes.first!
        XCTAssertEqual(scope.state, .available)
        XCTAssertEqual(scope.queuedCount, 1); XCTAssertEqual(scope.waitingCount, 2); XCTAssertEqual(scope.runningCount, 0)
        XCTAssertEqual(scope.capacity, 1)
        XCTAssertNil(scope.oldestQueuedAt, "Workflow creation is not exact queue entry time")
        XCTAssertEqual(scope.compatibleJobs(for: runner().id).count, 3)
        let count = await fake.count()
        _ = await monitor.refresh(runners: [runner()], force: true)
        let after = await fake.count(); XCTAssertEqual(after, count, "Manual refresh cannot bypass remote throttling")
    }
    func testUnknownLabelsDoNotBecomeAZeroQueue() async {
        let fake = QueueExecutor(responses: [
            "repos/example/project/actions/runs?status=queued&per_page=20&page=1": #"{"total_count":1,"workflow_runs":[{"id":11}]}"#,
            "repos/example/project/actions/runs/11/jobs?per_page=100&page=1&filter=latest": #"{"total_count":1,"jobs":[{"id":1,"status":"queued","labels":["macOS"]}]}"#
        ])
        let scope = await WorkloadMonitor(executor: fake, forgejo: QueueForgejo()).refresh(runners: [runner()]).scopes[0]
        XCTAssertEqual(scope.state, .partial); XCTAssertNil(scope.queuedCount); XCTAssertTrue(scope.jobs.isEmpty)
    }
    func testUnreadableGitHubScopeIsUnknownAndCached() async {
        let fake = QueueExecutor(error: "HTTP 429 rate limit")
        let monitor = WorkloadMonitor(executor: fake, forgejo: QueueForgejo())
        let scope = await monitor.refresh(runners: [runner()]).scopes[0]
        XCTAssertEqual(scope.state, .unavailable); XCTAssertNil(scope.queuedCount); XCTAssertNil(scope.runningCount)
        let count = await fake.count(); _ = await monitor.refresh(runners: [runner()], force: true)
        let after = await fake.count(); XCTAssertEqual(count, after)
    }
    func testWorkflowJobFailuresDoNotReturnAZeroQueue() async {
        let fake = QueueExecutor(responses: [
            "repos/example/project/actions/runners?per_page=100&page=1": #"{"runners":[{"id":9,"labels":[{"name":"macOS"}]}]}"#,
            "repos/example/project/actions/runs?status=queued&per_page=20&page=1": #"{"total_count":1,"workflow_runs":[{"id":11}]}"#
        ])
        let scope = await WorkloadMonitor(executor: fake, forgejo: QueueForgejo()).refresh(runners: [runner()]).scopes[0]
        XCTAssertEqual(scope.state, .unavailable); XCTAssertNil(scope.queuedCount)
    }
    func testForgejoKeepsUnknownAgesAndReportsOnlyAnActiveRunnerLowerBound() async {
        let api = QueueForgejo(responses: [
            "repos/example/project/actions/runners?limit=100&page=1&visible=true": #"[{"id":9,"name":"mac","labels":["macOS"],"status":"active"}]"#,
            "repos/example/project/actions/runs?status=waiting&limit=20&page=1": #"{"total_count":1,"workflow_runs":[{"id":11,"created":"2026-01-01T00:00:00Z","started":"2026-01-01T01:00:00Z","workflow_id":"release.yml","html_url":"https://forge.example/example/project/actions/runs/2"}]}"#,
            "repos/example/project/actions/runs/11/jobs": #"[{"id":1,"name":"Build","status":"waiting","runs_on":["macOS"]},{"id":2,"name":"Needs input","status":"blocked","runs_on":["macOS"]},{"id":3,"name":"Wrong case","status":"waiting","runs_on":["macos"]}]"#
        ])
        let local = runner(provider: .forgejo)
        let scope = await WorkloadMonitor(executor: QueueExecutor(), forgejo: api).refresh(runners: [local]).scopes[0]
        XCTAssertEqual(scope.queuedCount, 1); XCTAssertEqual(scope.waitingCount, 1)
        XCTAssertNil(scope.oldestQueuedAt); XCTAssertTrue(scope.jobs.allSatisfy { $0.startedAt == nil })
        XCTAssertEqual(scope.capacity, 3); XCTAssertEqual(scope.remoteBusyRunnerIDs, [local.id])
    }
    func testBusyOrganizationCannotStarveLaterScopesForever() async throws {
        var responses: [String: String] = [
            "orgs/a-org/actions/runners?per_page=100&page=1": #"{"runners":[{"id":9,"labels":[{"name":"macOS"}]}]}"#,
            "orgs/a-org/repos?type=all&per_page=100&page=1": #"[{"full_name":"a-org/one"},{"full_name":"a-org/two"}]"#,
            "repos/z-owner/project/actions/runners?per_page=100&page=1": #"{"runners":[{"id":10,"labels":[{"name":"macOS"}]}]}"#
        ]
        let page = String(decoding: try JSONSerialization.data(withJSONObject: ["total_count": 20, "workflow_runs": (1...20).map { ["id": $0] }]), as: UTF8.self)
        for repository in ["a-org/one", "a-org/two"] {
            responses["repos/\(repository)/actions/runs?status=queued&per_page=20&page=1"] = page
            for id in 1...20 { responses["repos/\(repository)/actions/runs/\(id)/jobs?per_page=100&page=1&filter=latest"] = #"{"total_count":0,"jobs":[]}"# }
        }
        let fake = QueueExecutor(responses: responses)
        let monitor = WorkloadMonitor(executor: fake, forgejo: QueueForgejo())
        var first = runner(); first.remoteURL = URL(string: "https://github.com/a-org")
        var later = runner(); later.directory = URL(fileURLWithPath: "/tmp/second-fictional-runner")
        later.remoteURL = URL(string: "https://github.com/z-owner/project"); later.agentID = 10
        let initial = await monitor.refresh(runners: [first, later])
        XCTAssertEqual(initial.scopes.first { $0.scopeURL == later.remoteURL }?.state, .unavailable)
        await monitor.invalidate()
        let next = await monitor.refresh(runners: [first, later])
        XCTAssertEqual(next.scopes.first { $0.scopeURL == later.remoteURL }?.state, .available)
    }
    func testKnownRunnerWithUnreportedJobLabelsHasUnknownCount() async {
        let fake = QueueExecutor(responses: [
            "repos/example/project/actions/runners?per_page=100&page=1": #"{"runners":[{"id":9,"labels":[{"name":"macOS"}]}]}"#,
            "repos/example/project/actions/runs?status=queued&per_page=20&page=1": #"{"total_count":1,"workflow_runs":[{"id":11}]}"#,
            "repos/example/project/actions/runs/11/jobs?per_page=100&page=1&filter=latest": #"{"total_count":1,"jobs":[{"id":1,"status":"queued"}]}"#
        ])
        let scope = await WorkloadMonitor(executor: fake, forgejo: QueueForgejo()).refresh(runners: [runner()]).scopes[0]
        XCTAssertNil(scope.queuedCount); XCTAssertNil(scope.compatibleQueuedJobs)
    }
    func testForgejoNamesAreNotRemoteIdentity() async {
        let api = QueueForgejo(responses: ["repos/example/project/actions/runners?limit=100&page=1&visible=true": #"[{"id":999,"name":"mac","labels":["wrong"],"status":"active"}]"#])
        var local = runner(labels: ["macOS"], provider: .forgejo); local.agentID = nil
        let scope = await WorkloadMonitor(executor: QueueExecutor(), forgejo: api).refresh(runners: [local]).scopes[0]
        XCTAssertEqual(scope.runnerLabels[local.id], ["macOS"]); XCTAssertTrue(scope.remoteBusyRunnerIDs.isEmpty)
    }
    func testCancelledRefreshDoesNotStartRemoteRequests() async {
        let fake = QueueExecutor()
        let monitor = WorkloadMonitor(executor: fake, forgejo: QueueForgejo())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await monitor.refresh(runners: [runner()])
        }
        _ = await task.value
        let count = await fake.count(); XCTAssertEqual(count, 0)
    }
    private func wideRunner(in root: URL, registration: String, id: Int, name: String) throws -> InstalledRunner {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = RunnerInstallationDescriptor(provider: .forgejo, name: name,
            remoteURL: URL(string: "https://forge.example"), agentID: id, labels: ["macOS"], capacity: 2,
            executablePath: "forgejo-runner", registrationPath: registration)
        try descriptor.write(to: directory)
        return try descriptor.installedRunner(in: directory)
    }
    func testAccountAndInstanceScopesRemainDistinctOnTheSameHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runningman-queue-scopes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = try wideRunner(in: root, registration: "/user/actions/runners", id: 1, name: "account-runner")
        let admin = try wideRunner(in: root, registration: "/admin/actions/runners", id: 2, name: "instance-runner")
        let api = QueueForgejo(responses: [
            "/user/actions/runners?limit=100&page=1": #"[{"id":1,"labels":["macOS"],"status":"idle"}]"#,
            "/admin/actions/runners?limit=100&page=1": #"[{"id":2,"labels":["macOS"],"status":"active"}]"#,
            "/user/actions/runners/jobs": #"[{"id":88,"name":"Shared job","repo_id":42,"status":"waiting","runs_on":["macOS"]}]"#,
            "/admin/actions/runners/jobs": #"[{"id":88,"name":"Shared job","repo_id":42,"status":"waiting","runs_on":["macOS"]},{"id":89,"name":"Active job","repo_id":43,"status":"running","runs_on":["macOS"]}]"#
        ])
        let report = await WorkloadMonitor(executor: QueueExecutor(), forgejo: api).refresh(runners: [user, admin])
        XCTAssertEqual(report.scopes.count, 2); XCTAssertEqual(Set(report.scopes.map(\.id)).count, 2)
        let account = report.scopes.first { $0.scopeTitle == "My account" }!
        let instance = report.scopes.first { $0.scopeTitle == "Entire instance" }!
        XCTAssertEqual(account.queuedCount, 1); XCTAssertEqual(instance.queuedCount, 1); XCTAssertEqual(instance.runningCount, 1)
        XCTAssertEqual(account.jobs.first?.repository, "Repository #42"); XCTAssertNil(account.oldestQueuedAt)
        XCTAssertEqual(account.jobs.first?.id, instance.jobs.first { $0.name == "Shared job" }?.id)
        XCTAssertEqual(instance.remoteBusyRunnerIDs, [admin.id])
        XCTAssertTrue(report.scopes.allSatisfy { $0.state == .partial && $0.message?.contains("omits blocked") == true })
    }
    func testAccountNullQueueIsKnownEmptyButUnsupportedInstanceAPIIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runningman-queue-scopes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = try wideRunner(in: root, registration: "/user/actions/runners", id: 1, name: "account-runner")
        let admin = try wideRunner(in: root, registration: "/admin/actions/runners", id: 2, name: "instance-runner")
        let api = QueueForgejo(responses: [
            "/user/actions/runners?limit=100&page=1": #"[{"id":1,"labels":["macOS"],"status":"idle"}]"#,
            "/user/actions/runners/jobs": "null"
        ])
        let report = await WorkloadMonitor(executor: QueueExecutor(), forgejo: api).refresh(runners: [user, admin])
        let account = report.scopes.first { $0.scopeTitle == "My account" }!
        let instance = report.scopes.first { $0.scopeTitle == "Entire instance" }!
        XCTAssertEqual(account.queuedCount, 0); XCTAssertEqual(account.compatibleQueuedJobs?.count, 0)
        XCTAssertEqual(instance.state, .unavailable); XCTAssertNil(instance.queuedCount)
        XCTAssertEqual(instance.scopeIdentifier, "/admin/actions/runners")
    }
    func testRootValidationSeparatesCredentialsByHostAndRejectsBasePaths() throws {
        XCTAssertEqual(try ForgejoConnectionStore.origin(for: URL(string: "https://Forge.Example:443/")!).absoluteString, "https://forge.example")
        for text in ["http://forge.example", "https://token@forge.example", "https://forge.example/prefix", "https://forge.example/?token=secret"] {
            XCTAssertThrowsError(try ForgejoConnectionStore.origin(for: URL(string: text)!))
        }
    }
}
