import AppKit
import SwiftUI
import RunningManCore

struct RunnersView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = RunnerStatusFilter.all
    private var runners: [RunnerSnapshot] {
        model.filteredRunners.filter { filter.matches($0.status) }.sorted { $0.runner.name.localizedStandardCompare($1.runner.name) == .orderedAscending }
    }
    @State private var availableWidth: CGFloat = 0
    private static let minimumListWidth: CGFloat = 300
    private static let preferredListWidth: CGFloat = 340
    private static let minimumDetailWidth: CGFloat = 440

    /// Gives the detail its minimum before the list grows past its own.
    /// The window's 1000 pt minimum leaves room for both beside a full sidebar.
    private static func listWidth(in totalWidth: CGFloat) -> CGFloat {
        max(minimumListWidth, min(preferredListWidth, totalWidth - minimumDetailWidth - 1))
    }

    var body: some View {
        // Not an HSplitView: nested in the NavigationSplitView detail, it asked
        // for more width than the window had near its minimum size, so the
        // column grew past the window edge and clipped the runner details.
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeading(eyebrow: "The fleet", title: "Runners", subtitle: "\(model.runners.count) installed on this Mac")
                    Picker("Show runners", selection: $filter) {
                        ForEach(RunnerStatusFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                }.padding(22)
                Divider()
                if runners.isEmpty {
                    EmptyPanel(symbol: "terminal", title: model.runners.isEmpty ? "No runners yet" : "No matching runners", message: model.runners.isEmpty ? "Register a new runner or import an existing installation." : "Try a different filter or search.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(runners) { runner in runnerRow(runner) }
                        }.padding(12)
                    }
                }
                Divider()
                HStack {
                    Button { model.importRunner() } label: { Label("Import…", systemImage: "folder.badge.plus") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.showingNewRunner = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).help("Create a runner")
                }.padding(16)
            }.frame(width: Self.listWidth(in: availableWidth))
            Divider()
            Group {
                if let snapshot = model.selectedRunner {
                    RunnerDetailView(snapshot: snapshot).id(snapshot.id)
                } else {
                    EmptyPanel(symbol: "cursorarrow.click.2", title: "Choose a runner", message: "See its live status, manage the service and follow its work.")
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Both bounds make the frame take the column's width rather than
        // passing the content's minimum up to the NavigationSplitView.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private func runnerRow(_ snapshot: RunnerSnapshot) -> some View {
        let selected = model.selectedRunnerID == snapshot.id
        return Button { model.selectedRunnerID = snapshot.id } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    Image(systemName: "terminal").font(.system(size: 17)).foregroundStyle(selected ? .indigo : snapshot.status.color)
                        .frame(width: 33, height: 33).background(snapshot.status.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.runner.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("\(snapshot.runner.provider.title) · \(snapshot.runner.repository)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.busyRunnerIDs.contains(snapshot.id) { ProgressView().controlSize(.mini) }
                }
                HStack {
                    StatusBadge(status: snapshot.status, compact: true)
                    Spacer()
                    if model.drainingRunnerIDs.contains(snapshot.id) {
                        Image(systemName: "moon.zzz").foregroundStyle(.orange).help("Stops when its current job finishes")
                    }
                    if snapshot.startsAtLogin { Image(systemName: "power").help("Starts automatically at login") }
                    if let version = snapshot.runner.version { Text("v\(version)").lineLimit(1) }
                }.font(.system(size: 9)).foregroundStyle(.tertiary)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? RunningManStyle.accent.opacity(0.075) : RunningManStyle.surface, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? RunningManStyle.accent.opacity(0.35) : RunningManStyle.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).contextMenu { RunnerActionsMenu(snapshot: snapshot) }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct RunnerDetailView: View {
    @Environment(AppModel.self) private var model
    let snapshot: RunnerSnapshot
    @State private var tab = "Overview"
    @State private var logSearch = ""
    @State private var followLog = true
    private var runner: InstalledRunner { snapshot.runner }
    private var isActing: Bool { model.busyRunnerIDs.contains(snapshot.id) }
    /// System LaunchDaemons are shown read-only; their detail text explains why.
    private var isControllable: Bool { runner.serviceDomain == .user }
    private var visibleLog: String {
        guard !logSearch.isEmpty else { return model.logText }
        return model.logText.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(logSearch) }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Image(systemName: "terminal.fill").foregroundStyle(snapshot.status.color)
                            Text(runner.name).font(.system(size: 23, weight: .bold, design: .rounded)).lineLimit(1)
                        }
                        Text(runner.provider.title + (runner.remoteURL?.host.map { " · " + $0 } ?? ""))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Button { model.openGitHub(runner) } label: {
                            Label(runner.repository, systemImage: "arrow.up.right.square").font(.system(size: 11))
                        }.buttonStyle(.link).disabled(runner.githubURL == nil)
                    }
                    Spacer()
                    Menu { RunnerActionsMenu(snapshot: snapshot) } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).frame(width: 25).help("Runner actions")
                }
                HStack {
                    StatusBadge(status: snapshot.status)
                    if model.drainingRunnerIDs.contains(snapshot.id) {
                        Label("Stopping when idle", systemImage: "moon.zzz").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    Spacer()
                    if isActing { ProgressView().controlSize(.small) }
                    if isControllable {
                        if snapshot.status.isRunning || snapshot.processID != nil {
                            Button("Stop", systemImage: "stop.fill") { model.perform(.stop, on: snapshot) }
                                .controlSize(.small).disabled(isActing)
                        } else {
                            Button("Start runner", systemImage: "play.fill") { model.perform(.start, on: snapshot) }
                                .buttonStyle(.borderedProminent).controlSize(.small).disabled(isActing || !snapshot.isEnabled)
                        }
                    }
                }
                Picker("Runner details", selection: $tab) {
                    Text("Overview").tag("Overview")
                    Text("Job log").tag("Job log")
                    Text("Live log").tag("Live log")
                    Text("Jobs (\(model.jobCount(for: snapshot.id)))").tag("Jobs")
                }.pickerStyle(.segmented).labelsHidden()
            }.padding(24)
            Divider()
            switch tab {
            case "Job log": JobLogView(snapshot: snapshot)
            case "Live log": logView
            case "Jobs": jobsView
            default: overview
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let job = snapshot.currentJob {
                    Surface {
                        Label("WORKING NOW", systemImage: "bolt.fill").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.indigo)
                        Text(job.name).font(.system(size: 16, weight: .semibold)).padding(.top, 8)
                        HStack {
                            Text(job.repository ?? runner.repository).lineLimit(1)
                            Spacer()
                            if job.outcome == .running {
                                Text(job.startedAt, style: .timer).monospacedDigit()
                            } else {
                                Text(formattedDuration(for: job)).monospacedDigit()
                                    .help(job.finishedAt == nil ? "No completion result in local logs" : "Recorded job duration")
                            }
                        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 3)
                        if let step = model.stepLogs[snapshot.id].flatMap({ $0.jobID == job.id ? $0.steps.last { $0.outcome == .running } : nil }) {
                            Button { tab = "Job log" } label: {
                                Label("Current step: \(step.name)", systemImage: "list.bullet.rectangle").lineLimit(1)
                            }.buttonStyle(.link).font(.system(size: 11)).padding(.top, 6).help("Show the job log")
                        }
                        if isControllable {
                            Button(model.drainingRunnerIDs.contains(snapshot.id) ? "Cancel stop when idle" : "Stop when idle", systemImage: "moon.zzz") { model.perform(.drain, on: snapshot) }
                                .controlSize(.small).padding(.top, 11)
                                .disabled(isActing)
                                .help("Stop after this job finishes. Keep RunningMan open until the runner stops.")
                        }
                    }
                }
                if let detail = snapshot.detail, !detail.isEmpty {
                    Label { Text(detail).textSelection(.enabled) } icon: { Image(systemName: snapshot.status == .attention ? "exclamationmark.triangle" : "info.circle") }
                        .font(.system(size: 11)).foregroundStyle(snapshot.status == .attention ? Color.orange : .secondary)
                }
                if isControllable { serviceControls }
                Surface {
                    SectionHeading(title: "Workload", subtitle: "Compatible queue and recent usage") {
                        Button("View fleet") { model.section = .workload }.buttonStyle(.link).font(.system(size: 11))
                    }.padding(.bottom, 4)
                    RunnerWorkloadRow(snapshot: snapshot)
                }
                Surface {
                    SectionHeading(title: "Release cleanup", subtitle: "Reported by this runner’s release workflow") {
                        Button("View reports") { model.section = .cleanup }.buttonStyle(.link).font(.system(size: 11))
                    }
                    if let report = model.latestCleanup(for: snapshot.id) {
                        CleanupResultSummary(report: report).padding(.top, 12)
                    } else {
                        Text("No cleanup reports yet. A release using the new cleanup workflow will report here after its upload attempts.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
                    }
                }
                Surface {
                    Text("Installation").font(.system(size: 13, weight: .semibold)).padding(.bottom, 13)
                    detailRow("Platform", value: runner.provider.title)
                    Divider().padding(.vertical, 9)
                    detailRow("Job slots", value: String(runner.capacity))
                    Divider().padding(.vertical, 9)
                    detailRow("Version", value: runner.version.map { "v\($0)" } ?? "Not reported")
                    Divider().padding(.vertical, 9)
                    detailRow("Process ID", value: snapshot.processID.map(String.init) ?? "Not running")
                    Divider().padding(.vertical, 9)
                    detailRow("Service", value: runner.serviceLabel.map { runner.serviceDomain == .system ? $0 + " (system)" : $0 } ?? "No user service installed")
                    Divider().padding(.vertical, 9)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Folder").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(runner.directory.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                        Button("Show in Finder", systemImage: "folder") { model.revealRunner(runner) }.buttonStyle(.link).font(.system(size: 11))
                    }
                    if !runner.labels.isEmpty {
                        Divider().padding(.vertical, 9)
                        detailRow("Labels", value: runner.labels.joined(separator: ", "))
                    }
                }
                let recent = Array(model.jobs(for: snapshot.id).prefix(3))
                if !recent.isEmpty {
                    Surface {
                        SectionHeading(title: "Recent work") { Button("View jobs") { tab = "Jobs" }.buttonStyle(.link).font(.system(size: 11)) }
                        TimelineView(.everyMinute) { _ in
                            let now = Date()
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(recent) { JobRow(job: $0, timestamp: .relative(now: now)) }
                            }
                        }
                    }
                }
            }.padding(22)
        }
    }

    private var serviceControls: some View {
        Surface {
            Text("Service controls").font(.system(size: 13, weight: .semibold)).padding(.bottom, 15)
            Toggle(isOn: Binding(get: { snapshot.isEnabled }, set: { model.perform($0 ? .enable : .disable, on: snapshot) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Runner enabled").font(.system(size: 12, weight: .medium))
                    Text("Allow this runner service to be started. Disabling stops it.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch).controlSize(.small).disabled(isActing)
            Divider().padding(.vertical, 13)
            Toggle(isOn: Binding(get: { snapshot.startsAtLogin }, set: { model.setStartup($0, for: snapshot) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start automatically at login").font(.system(size: 12, weight: .medium))
                    Text("Launch when you sign in to your macOS account. This does not start or stop it now.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.switch).controlSize(.small).disabled(isActing)
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 65, alignment: .leading)
            Text(value).font(.system(size: 10, weight: .medium, design: title == "Service" ? .monospaced : .default))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .trailing).lineLimit(3)
        }
    }

    private var logView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter log lines", text: $logSearch).textFieldStyle(.plain).font(.system(size: 11))
                if !logSearch.isEmpty {
                    Button { logSearch = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Divider().frame(height: 16)
                Toggle("Follow", isOn: $followLog).toggleStyle(.checkbox).font(.system(size: 10))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(visibleLog, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy the visible redacted log")
            }.padding(13)
            Divider()
            if model.logText.isEmpty {
                EmptyPanel(symbol: "text.alignleft", title: "No log output yet", message: "The most recent runner diagnostic output will appear here. Secrets are redacted before display.")
            } else if visibleLog.isEmpty {
                EmptyPanel(symbol: "magnifyingglass", title: "No matching lines", message: "Try another search term.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(visibleLog).font(.system(size: 10, design: .monospaced)).lineSpacing(4)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("log-end")
                        }.padding(16)
                    }.background(.primary.opacity(0.02))
                        .onChange(of: model.logText) { _, _ in if followLog { proxy.scrollTo("log-end", anchor: .bottom) } }
                        .onAppear { if followLog { proxy.scrollTo("log-end", anchor: .bottom) } }
                }
            }
            Divider()
            HStack {
                Label("Redacted diagnostic tail", systemImage: "lock.shield").foregroundStyle(.secondary)
                Spacer()
                Text("\(visibleLog.split(separator: "\n").count) lines").foregroundStyle(.tertiary)
            }.font(.system(size: 9)).padding(.horizontal, 13).padding(.vertical, 9)
        }
    }

    private var jobsView: some View {
        let jobs = model.jobs(for: snapshot.id)
        return Group {
            if jobs.isEmpty {
                EmptyPanel(symbol: "clock.arrow.circlepath", title: "No recorded jobs", message: "Completed and active jobs are collected from this runner’s local logs.")
            } else {
                ScrollView {
                    TimelineView(.everyMinute) { _ in
                        let now = Date()
                        LazyVStack(spacing: 0) {
                            ForEach(jobs) { job in
                                HStack(spacing: 10) { JobRow(job: job, timestamp: .relative(now: now)); OutcomeBadge(outcome: job.outcome) }
                                Divider()
                            }
                        }.padding(.horizontal, 22)
                    }
                }
            }
        }
    }
}
