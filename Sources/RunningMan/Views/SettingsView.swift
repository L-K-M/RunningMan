import AppKit
import SwiftUI
import RunningManCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppUpdateChecker.self) private var updates
    @AppStorage(AppUpdateChecker.automaticKey) private var checkAutomatically = true
    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Refresh runner status automatically", isOn: $model.refreshAutomatically)
                Text("Refreshes local service state and diagnostic logs every three seconds while RunningMan is open.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Keep this Mac awake while a job is running", isOn: $model.keepAwakeWhileBusy)
                Text("Prevents idle sleep during detected jobs. Closing your MacBook lid can still put it to sleep.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: { Text("Monitoring") }
            Section {
                LabeledContent("GitHub account") {
                    HStack {
                        Text(model.githubAccount ?? "Not checked").foregroundStyle(.secondary)
                        Button("Check connection") { Task { await model.checkGitHub() } }
                    }
                }
                Text("Connection uses your existing GitHub CLI sign-in. Runner discovery, logs and service controls also work offline.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: { Text("GitHub") }
            Section {
                Toggle("Read server queues automatically", isOn: $model.remoteMonitoringEnabled)
                Text("Reads compatible queued and active jobs about once a minute while monitoring. GitHub uses your CLI sign-in; Forgejo uses a token stored in Keychain. Coverage depends on server APIs, labels and repository access.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Connect a Forgejo server…", systemImage: "network") { model.showingForgejoConnection = true }
                ForEach(model.forgejoServers, id: \.absoluteString) { server in
                    HStack {
                        Text(server.host ?? server.absoluteString).font(.system(size: 11))
                        Spacer()
                        Button("Forget connection") { Task { await model.forgetForgejo(server) } }.controlSize(.small)
                    }
                }
                Text("Forgetting a connection removes RunningMan’s API token. Registered runners keep their own connection and continue running.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: { Text("Queues & Forgejo") }
            Section {
                LabeledContent("Installed runners", value: "\(model.runners.count)")
                LabeledContent("Start at login", value: "\(model.startsAtLoginCount) runners")
                Text("Set automatic startup separately for each runner in its Overview. Services start when you log in to this macOS account, after startup or restart.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Import an existing runner folder…", systemImage: "folder.badge.plus") { model.importRunner() }
            } header: { Text("Runner services") }
            Section {
                LabeledContent("Recorded jobs", value: "\(model.jobs.count)")
                Text("History is reconstructed from local diagnostic logs and saved on this Mac. Old or missing logs can limit the available history. Known secret patterns are redacted before display and export.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("Export diagnostics…", systemImage: "square.and.arrow.up") { model.exportDiagnostics() }
                    Spacer()
                    Button("Clear saved history…", role: .destructive) { model.clearHistory() }
                        .disabled(model.jobs.isEmpty)
                }
            } header: { Text("History & diagnostics") }
            Section {
                Toggle("Check for updates automatically", isOn: $checkAutomatically)
                Text("Checks once a day by downloading a small public file from GitHub. Nothing else is sent.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button(updates.checking ? "Checking…" : "Check Now") { updates.checkNow() }
                        .disabled(updates.checking)
                    if let last = updates.lastCheck {
                        Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Updates") }
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "figure.run.circle.fill").font(.system(size: 32)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, RunningManStyle.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RunningMan").font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text("A little clarity for the runners behind your releases.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }.formStyle(.grouped).frame(width: 560, height: 660)
    }
}

struct RunnerMenuView: View {
    /// More rows would make the panel taller than a small display.
    static let visibleRunnerLimit = 8

    /// A capsule in the summary under the header.
    struct SummaryItem: Equatable {
        let text: String
        let symbol: String
        let tone: StatusTone
    }

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let runners = model.menuBarRunners
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if runners.isEmpty {
                Text("No runners discovered yet").font(.system(size: 11)).foregroundStyle(.secondary).padding(18)
            } else {
                VStack(spacing: 0) {
                    ForEach(runners.prefix(Self.visibleRunnerLimit)) { snapshot in
                        MenuRunnerRow(snapshot: snapshot, isDraining: model.drainingRunnerIDs.contains(snapshot.id)) {
                            showRunners(selecting: snapshot.id)
                        }
                    }
                    if runners.count > Self.visibleRunnerLimit {
                        MenuOverflowRow(count: runners.count - Self.visibleRunnerLimit) { showRunners(selecting: nil) }
                    }
                }.padding(6)
            }
            Divider()
            footer
        }.frame(width: 320).tint(RunningManStyle.accent)
    }

    private var header: some View {
        let summary = Self.summaryItems(attention: model.attentionCount, draining: model.drainingRunnerIDs.count, queue: model.fleetQueue)
        let total = model.runners.count, busy = model.busyCount
        let subtitle = total == 0 ? "No runners yet" : "\(model.runningCount) of \(total) online" + (busy > 0 ? " · \(busy) busy" : "")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                    .frame(width: 26, height: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("RunningMan").font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refreshNow() } } label: { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.isManualRefreshing).help("Refresh")
            }
            if !summary.isEmpty {
                WrappingRow(spacing: 6) {
                    ForEach(summary, id: \.text) { item in
                        Label(item.text, systemImage: item.symbol)
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(item.tone.text)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(item.tone.fill.opacity(StatusTone.tintOpacity), in: Capsule())
                    }
                }.accessibilityElement(children: .combine)
            }
        }.padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Button("Open RunningMan") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Spacer()
            Menu {
                Button("Start all enabled runners") { model.startAll() }
                Button("Stop all when idle") { model.stopAllWhenIdle() }
                Divider()
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Button("Quit RunningMan") { NSApp.terminate(nil) }
            } label: { Label("More options", systemImage: "gearshape").labelStyle(.iconOnly) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.secondary).fixedSize().help("Fleet actions, settings and quit")
        }.buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func showRunners(selecting runnerID: String?) {
        if let runnerID { model.selectedRunnerID = runnerID }
        model.section = .runners
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Only facts worth acting on: a queue count appears when it is known and not zero,
    /// so an unknown queue never reads as an empty one.
    nonisolated static func summaryItems(attention: Int, draining: Int, queue: FleetQueueSummary) -> [SummaryItem] {
        var items: [SummaryItem] = []
        if attention > 0 {
            items.append(SummaryItem(text: "\(attention) \(attention == 1 ? "needs" : "need") attention", symbol: "exclamationmark.triangle.fill", tone: .warning))
        }
        if queue.hasQueueEvidence, queue.queuedCount > 0 {
            items.append(SummaryItem(text: "\(queue.queuedCount)\(queue.isIncomplete ? "+" : "") queued", symbol: "tray.full", tone: .warning))
        }
        if draining > 0 {
            items.append(SummaryItem(text: "\(draining) stopping when idle", symbol: "moon.zzz", tone: .warning))
        }
        return items
    }

    /// The second line of a runner row. "Online" means the process is alive and "busy"
    /// that it has a job.
    nonisolated static func runnerDetail(for snapshot: RunnerSnapshot) -> String {
        switch snapshot.status {
        case .busy: return snapshot.currentJob?.name ?? "Busy"
        case .unknown where !snapshot.needsAttention: return "Online, activity not verified"
        default: return snapshot.status.title
        }
    }
}

/// One runner in the menu bar panel. The row opens the runner; the trailing menu holds
/// its actions.
private struct MenuRunnerRow: View {
    let snapshot: RunnerSnapshot
    let isDraining: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 10) {
                    // The rows behind the "needs attention" capsule carry the same warning.
                    Image(systemName: snapshot.needsAttention ? "exclamationmark.triangle.fill" : snapshot.status.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(snapshot.needsAttention ? StatusTone.warning.text : snapshot.status.color)
                        .busySymbolEffect(snapshot.status == .busy)
                        .frame(width: 16)
                        .accessibilityLabel(snapshot.needsAttention ? "\(snapshot.status.title), needs attention" : snapshot.status.title)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(snapshot.runner.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if isDraining {
                                Image(systemName: "moon.zzz").font(.system(size: 10)).foregroundStyle(StatusTone.warning.text)
                                    .help("Stops when idle").accessibilityLabel("Stops when idle")
                            }
                        }
                        Text(RunnerMenuView.runnerDetail(for: snapshot)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if snapshot.status == .busy, let job = snapshot.currentJob {
                        Text(job.startedAt, style: .timer)
                            .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                            .help("Time since the job started")
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(snapshot.detail.map { "\(snapshot.status.title). \($0)" } ?? snapshot.status.title)
            .accessibilityHint("Shows this runner in RunningMan")
            Menu { RunnerActionsMenu(snapshot: snapshot) } label: {
                Label("Actions for \(snapshot.runner.name)", systemImage: "ellipsis").labelStyle(.iconOnly)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.secondary).fixedSize().help("Runner actions")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .modifier(MenuRowHighlight())
    }
}

private struct MenuOverflowRow: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                Text("\(count) more \(count == 1 ? "runner" : "runners")")
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(MenuRowHighlight())
        .accessibilityHint("Shows every runner in RunningMan")
    }
}

/// Places views left to right and starts a new line when the width runs out, so summary
/// capsules never truncate.
private struct WrappingRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(subviews, width: bounds.width).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (origins, CGSize(width: widest, height: y + lineHeight))
    }
}

/// The rounded highlight under the pointer, as in a menu.
private struct MenuRowHighlight: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isHovered ? Color.primary.opacity(0.07) : .clear))
            .onHover { isHovered = $0 }
    }
}
