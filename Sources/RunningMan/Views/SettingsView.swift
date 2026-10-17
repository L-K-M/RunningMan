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
                Toggle("Notify when a job fails", isOn: $model.notificationPreferences.jobFailures)
                Toggle("Notify when a job succeeds", isOn: $model.notificationPreferences.jobSuccesses)
                Toggle("Notify when a runner stops unexpectedly", isOn: $model.notificationPreferences.unexpectedStops)
                Text("Covers jobs that finish while RunningMan is open; cancelled jobs count as failures. A stop is unexpected when you did not start, stop or change that runner in RunningMan during the previous 30 seconds.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                notificationStatus
            } header: { Text("Notifications") }
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
                    .font(.system(size: 10)).foregroundStyle(.secondary)
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
                    Image(systemName: "figure.run.circle.fill").font(.system(size: 32)).foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RunningMan").font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text("A little clarity for the runners behind your releases.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }.formStyle(.grouped).frame(width: 560, height: 660)
        // Permission can change in System Settings while this window stays open.
        .task { await model.refreshNotificationAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshNotificationAuthorization() }
        }
    }

    @ViewBuilder private var notificationStatus: some View {
        switch model.notificationAuthorization {
        case .authorized, .checking:
            EmptyView()
        case .notDetermined:
            Text("macOS asks for permission the first time you turn one on.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .denied:
            HStack {
                Label("Notifications are off in System Settings.", systemImage: "bell.slash")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                Spacer()
                Button("Open System Settings") { model.openNotificationSettings() }.controlSize(.small)
            }
        case .unavailable:
            Text(model.demoMode ? "This preview workspace never sends notifications." : "Notifications are available when RunningMan runs as an installed app.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct RunnerMenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "figure.run.circle.fill").font(.system(size: 24)).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 3) {
                    Text("RunningMan").font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("\(model.runningCount) running · \(model.busyCount) working").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh")
            }.padding(16)
            Divider()
            if model.runners.isEmpty {
                Text("No runners discovered yet").font(.system(size: 11)).foregroundStyle(.secondary).padding(18)
            } else {
                ForEach(model.runners.prefix(8)) { snapshot in
                    HStack(spacing: 10) {
                        Circle().fill(snapshot.status.color).frame(width: 7, height: 7)
                        Button {
                            model.selectedRunnerID = snapshot.id
                            model.section = .runners
                            openWindow(id: "main")
                            NSApp.activate(ignoringOtherApps: true)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.runner.name).font(.system(size: 11, weight: .medium))
                                Text(snapshot.currentJob?.name ?? snapshot.status.title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu { RunnerActionsMenu(snapshot: snapshot) } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).frame(width: 20)
                    }.padding(.horizontal, 17).padding(.vertical, 9)
                }
            }
            Divider()
            HStack {
                Button("Open RunningMan") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Menu {
                    Button("Start all enabled runners") { model.startAll() }
                    Button("Stop all when idle") { model.stopAllWhenIdle() }
                    Divider()
                    Button("Quit RunningMan") { NSApp.terminate(nil) }
                } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).frame(width: 20)
            }.buttonStyle(.plain).font(.system(size: 10)).padding(16)
        }.frame(width: 310).tint(.indigo)
    }
}
