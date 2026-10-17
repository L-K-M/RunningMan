import SwiftUI
import RunningManCore

struct WorkloadView: View {
    /// Whole minutes, so the value never shows seconds that stopped updating.
    static func queueAge(since date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        return minutes < 1 ? "<1m" : formattedDuration(TimeInterval(minutes * 60))
    }
    @Environment(AppModel.self) private var model
    /// Busiest first: longest compatible queue, then highest observed busy rate.
    private var rankedRunners: [RunnerSnapshot] {
        let queues = model.compatibleQueueByRunner, usage = model.observedUsage
        return model.runners.sorted { left, right in
            let a = queues[left.id] ?? -1, b = queues[right.id] ?? -1
            if a != b { return a > b }
            let busyA = usage[left.id]?.busyFraction ?? -1
            let busyB = usage[right.id]?.busyFraction ?? -1
            if busyA != busyB { return busyA > busyB }
            return left.runner.name.localizedStandardCompare(right.runner.name) == .orderedAscending
        }
    }

    var body: some View {
        // Bind derived values once per render. Queue metrics describe the whole fleet;
        // only the server queue list below follows the search field.
        let scopes = model.visibleWorkloadScopes
        let fleet = model.fleetQueue
        let activityRunners = rankedRunners
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) {
                    Text("Compatible server queues and activity observed on this Mac.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 12)
                    Button("Connect Forgejo…", systemImage: "network.badge.shield.half.filled") { model.showingForgejoConnection = true }
                        .controlSize(.small)
                    Button {
                        Task { await model.refreshWorkload(force: true) }
                    } label: {
                        Label(model.isRefreshingWorkload ? "Checking queues…" : "Refresh queues", systemImage: "arrow.clockwise")
                    }.controlSize(.small).disabled(model.isRefreshingWorkload || !model.remoteMonitoringEnabled)
                        .help("Queue snapshots refresh at most once a minute and respect server rate limits.")
                }
                if !model.remoteMonitoringEnabled {
                    Surface {
                        Label("Server monitoring is off", systemImage: "pause.circle").font(.headline)
                        Text("Local status and recorded usage still work. Enable server monitoring to read queued and active jobs.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
                        Button("Enable server monitoring") {
                            model.remoteMonitoringEnabled = true
                            Task { await model.refreshWorkload(force: true) }
                        }.padding(.top, 12)
                    }
                }
                MetricRow {
                    MetricTile(title: "Compatible queued", value: fleet.hasQueueEvidence ? "\(fleet.queuedCount)\(fleet.isIncomplete ? "+" : "")" : "—",
                               footnote: "Shared across matching runners", symbol: "tray.full",
                               tint: fleet.queuedCount > 0 ? StatusTone.warning.text : StatusTone.neutral.text)
                    // The age keeps growing while the queue stays the same, and quiet polls do not
                    // re-render an unchanged queue, so this tile keeps its own minute clock.
                    TimelineView(.everyMinute) { _ in
                        MetricTile(title: "Oldest queued", value: fleet.oldestQueuedAt.map { Self.queueAge(since: $0) } ?? "—",
                                   footnote: "When the server reports its age", symbol: "hourglass", tint: StatusTone.warning.text)
                    }
                    MetricTile(title: "Busy runners", value: "\(model.busyCount)", footnote: "At least one active job", symbol: "bolt.fill", tint: StatusTone.active.text)
                    MetricTile(title: "Configured slots", value: "\(model.runners.reduce(0) { $0 + $1.runner.capacity })",
                               footnote: "Local concurrency limit", symbol: "square.stack.3d.up", tint: RunningManStyle.accentText)
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "Runner activity", subtitle: "Last 24 hours · sampled while RunningMan is monitoring") { EmptyView() }
                    if model.runners.isEmpty {
                        Surface { EmptyPanel(symbol: "chart.bar", title: "Add a runner to begin", message: "Activity and compatible queues appear for installed runners.") }
                    } else {
                        Surface(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(activityRunners.enumerated()), id: \.element.id) { index, snapshot in
                                    RunnerWorkloadRow(snapshot: snapshot)
                                    if index < activityRunners.count - 1 { Divider().padding(.leading, 20) }
                                }
                            }
                        }
                    }
                    Text("Busy rate is sampled time with at least one active job divided by time observed. Gaps and uncertain states are excluded. It does not measure CPU load or occupied slots on multi-job runners.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeading(title: "Server queues", subtitle: "Jobs waiting for compatible labels, grouped by registration scope") {
                        if let date = scopes.map(\.checkedAt).min() {
                            Text("Data since \(date.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    if scopes.isEmpty {
                        Surface {
                            EmptyPanel(symbol: "network", title: model.isRefreshingWorkload ? "Reading server queues…" : "No queue data yet",
                                       message: "GitHub uses your signed-in CLI. Forgejo uses a server connection saved in Keychain. A configured runner supplies the scope to monitor.")
                                .frame(minHeight: 130)
                        }
                    } else {
                        ForEach(scopes) { scope in WorkloadScopeCard(scope: scope) }
                    }
                }
                Label("A queued job belongs to a compatible pool. Other machines may claim it. Partial access or scan limits are shown explicitly; unavailable data is never counted as an empty queue.",
                      systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(28).frame(maxWidth: 1400).frame(maxWidth: .infinity)
        }
    }
}

struct RunnerWorkloadRow: View {
    @Environment(AppModel.self) private var model
    let snapshot: RunnerSnapshot
    /// The runner detail already names the runner, so it hides the name and
    /// lets the figures share the row.
    var showsName = true
    // Cached in AppModel; these are lookups, not calculations.
    private var observed: ObservedRunnerUsage? { model.observedUsage[snapshot.id] }
    private var history: RunnerUsageMetrics { model.usage(for: snapshot.runner) }
    private var queue: Int? { model.compatibleQueueCount(for: snapshot.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsName {
                // The fixed stat columns need about 560 pt. A narrow window
                // stacks the stats under the name instead of letting the row
                // overflow and clip.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        identity.frame(minWidth: 140, alignment: .leading)
                        Spacer(minLength: 8)
                        busyStat(.trailing).frame(width: 125, alignment: .trailing)
                        jobsStat(.trailing).frame(width: 110, alignment: .trailing)
                        queueStat(.trailing).frame(width: 110, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        identity
                        sharedStats
                    }
                }
            } else {
                sharedStats
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.06))
                    Capsule().fill(StatusTone.active.fill).frame(width: geometry.size.width * min(1, observed?.busyFraction ?? 0))
                }
            }.frame(height: 5).accessibilityHidden(true)
            HStack {
                Text(observed.map { "\(wholeMinutes($0.observedSeconds)) observed · \(wholeMinutes($0.busySeconds)) busy" } ?? "Waiting for two activity samples")
                Spacer()
                if let duration = history.medianDuration { Text("Median job \(formattedDuration(duration))") }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(18)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(snapshot.runner.name) {
                model.selectedRunnerID = snapshot.id
                model.section = .runners
            }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
            Text("\(snapshot.runner.provider.title) · \(snapshot.runner.capacity) \(snapshot.runner.capacity == 1 ? "slot" : "slots")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var sharedStats: some View {
        HStack(alignment: .top, spacing: 12) {
            busyStat(.leading).frame(maxWidth: .infinity, alignment: .leading)
            jobsStat(.leading).frame(maxWidth: .infinity, alignment: .leading)
            queueStat(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func busyStat(_ alignment: HorizontalAlignment) -> some View {
        stat(observed?.busyFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", caption: "Busy while observed", size: 21, alignment: alignment)
    }

    private func jobsStat(_ alignment: HorizontalAlignment) -> some View {
        stat("\(history.completedJobs)", caption: "Recorded jobs · 24h", size: 18, alignment: alignment)
    }

    private func queueStat(_ alignment: HorizontalAlignment) -> some View {
        stat(queue.map(String.init) ?? "—", caption: "Compatible queue", size: 18, alignment: alignment,
             color: (queue ?? 0) > 0 ? StatusTone.warning.text : .primary)
    }

    /// Stats align trailing in the wide row and leading when they share the width.
    private func stat(_ value: String, caption: String, size: CGFloat, alignment: HorizontalAlignment, color: Color = .primary) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(value).font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color).numericValueTransition(value)
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// AppModel republishes sampled usage only when a whole minute or the rounded
    /// percentage changes, so seconds here would be stale.
    private func wholeMinutes(_ seconds: TimeInterval) -> String {
        formattedDuration((seconds / 60).rounded(.down) * 60)
    }
}

private struct WorkloadScopeCard: View {
    @Environment(AppModel.self) private var model
    let scope: WorkloadScopeSnapshot
    private var matching: [WorkloadJob] {
        let jobs = Dictionary(scope.jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return jobs.values.sorted {
            if $0.state == .queued && $1.state != .queued { return true }
            if $0.state != .queued && $1.state == .queued { return false }
            return ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture)
        }
    }
    private var countsKnown: Bool { scope.compatibleQueuedJobs != nil }
    var body: some View {
        Surface {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(scope.provider.title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(RunningManStyle.accentText)
                    Button(scope.scopeTitle.map { $0 + " · " + (scope.scopeURL.host ?? "") }
                        ?? scope.scopeURL.host.map { $0 + scope.scopeURL.path } ?? scope.scopeURL.absoluteString) { model.openServerLink(scope.scopeURL) }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                }
                Spacer()
                Label(scope.state == .available ? "Visible queue" : scope.state == .partial ? "Partial visibility" : "Unavailable",
                      systemImage: scope.state == .available ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(scope.state == .available ? StatusTone.positive.text : StatusTone.warning.text)
            }
            if let message = scope.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 10)
            }
            Text("Checked \(scope.checkedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6)
            if scope.state != .unavailable {
                HStack(spacing: 18) {
                    Label(scope.compatibleQueuedJobs.map { "\($0.count) compatible queued" } ?? "Queue count unavailable", systemImage: "tray.full")
                    Text(scope.compatibleRunningJobs.map { "\($0.count) running in compatible pools" } ?? "Running count unavailable")
                    Text("\(scope.capacity) local slots")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 13)
                if !matching.isEmpty {
                    Divider().padding(.vertical, 12)
                    ForEach(matching.prefix(6)) { job in
                        HStack(spacing: 10) {
                            Image(systemName: job.state == .running ? "bolt.fill" : job.state == .queued ? "hourglass" : "pause.circle")
                                .foregroundStyle(job.state == .queued ? StatusTone.warning.text : job.state == .running ? StatusTone.active.text : StatusTone.neutral.text)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(job.repository + (job.labels.isEmpty ? "" : " · " + job.labels.joined(separator: ", ")))
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(job.state.title).font(.system(size: 10)).foregroundStyle(.secondary)
                            if let url = job.url {
                                Button { model.openServerLink(url) } label: { Image(systemName: "arrow.up.right") }
                                    .buttonStyle(.plain).help("Open job on \(scope.provider.title)")
                            }
                        }.padding(.vertical, 7)
                    }
                    if matching.count > 6 { Text("\(matching.count - 6) more compatible jobs").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 7) }
                } else if countsKnown {
                    Text("No compatible jobs in this visible snapshot.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 11)
                }
            }
        }
    }
}

struct ForgejoConnectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(symbol: "network.badge.shield.half.filled", title: "Connect Forgejo", subtitle: "Keep credentials in your login Keychain.")
            TextField("Server URL", text: $server, prompt: Text("https://forge.example.com")).textFieldStyle(.roundedBorder).disabled(connecting)
            SecureField("Access token", text: $token, prompt: Text("Leave empty to check the saved connection")).textFieldStyle(.roundedBorder).disabled(connecting)
            Text("Use a token with read access to Actions jobs for monitoring. Creating or removing runners also needs runner-management access for the chosen scope.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundStyle(StatusTone.critical.text).textSelection(.enabled) }
            HStack {
                Button("Cancel") { token = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(connecting)
                Spacer()
                if connecting { ProgressView().controlSize(.small) }
                Button(connecting ? "Connecting…" : "Connect") {
                    let submittedServer = server, submittedToken = token
                    connecting = true
                    Task {
                        let success = await model.connectForgejo(server: submittedServer, token: submittedToken)
                        if success { token = ""; dismiss() }
                        else { message = model.errorMessage ?? "Connection failed" }
                        connecting = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(connecting || server.isEmpty)
            }
        }.padding(28).frame(width: 520)
            .onAppear { server = model.demoMode ? "https://forge.example.com" : model.defaultForgejoServer }
            .interactiveDismissDisabled(connecting)
    }
}
