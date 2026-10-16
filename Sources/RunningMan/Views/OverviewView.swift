import SwiftUI
import RunningManCore

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    private var recentJobs: [RunnerJob] { Array(model.jobs.sorted { $0.startedAt > $1.startedAt }.prefix(4)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    PageHeading(eyebrow: "Mission control", title: "A clear view of your runners.", subtitle: "Every service, every job, right here on your Mac.")
                    Spacer(minLength: 12)
                    if let updated = model.lastUpdated {
                        Label("Updated \(updated.formatted(date: .omitted, time: .shortened))", systemImage: "waveform.path")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.primary.opacity(0.035), in: Capsule()).padding(.top, 4)
                    }
                }
                HStack(spacing: 12) {
                    metric("Runners running", value: "\(model.runningCount)", footnote: "of \(model.runners.count) installed", icon: "play.circle", color: RunningManStyle.teal)
                    metric("Working now", value: "\(model.busyCount)", footnote: model.busyCount == 1 ? "job in progress" : "jobs in progress", icon: "bolt.fill", color: .indigo)
                    metric("Jobs recorded", value: "\(model.jobs.count)", footnote: "from local runner logs", icon: "clock.arrow.circlepath", color: .purple)
                    metric("Success rate", value: model.successRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", footnote: "of completed jobs", icon: "checkmark.seal", color: RunningManStyle.teal)
                }
                if !model.warnings.isEmpty {
                    Surface(padding: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("A little attention needed").font(.system(size: 12, weight: .semibold))
                                ForEach(Array(model.warnings.prefix(3).enumerated()), id: \.offset) { _, warning in
                                    Text(warning).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                if model.warnings.count > 3 { Text("\(model.warnings.count - 3) more in exported diagnostics").font(.system(size: 10)).foregroundStyle(.secondary) }
                            }
                            Spacer()
                        }
                    }
                }
                VStack(spacing: 13) {
                    SectionHeading(title: "Your fleet", subtitle: "Local state, refreshed automatically") {
                        Button("View all", systemImage: "arrow.right") { model.section = .runners }.buttonStyle(.link).font(.system(size: 11))
                    }
                    if model.runners.isEmpty {
                        Surface {
                            VStack(spacing: 14) {
                                EmptyPanel(symbol: "desktopcomputer.and.arrow.down", title: "Meet your new runner headquarters", message: "RunningMan finds runner installations on this Mac. Import a folder or register your first runner to get started.")
                                HStack {
                                    Button("Import existing…") { model.importRunner() }
                                    Button("Create a runner", systemImage: "plus") { model.showingNewRunner = true }.buttonStyle(.borderedProminent)
                                }.padding(.bottom, 15)
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                            ForEach(model.filteredRunners.prefix(6)) { snapshot in RunnerCard(snapshot: snapshot) }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    Surface {
                        SectionHeading(title: "Recent jobs", subtitle: "The latest work your Mac has done") {
                            Button { model.section = .history } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }.padding(.bottom, 6)
                        if recentJobs.isEmpty {
                            EmptyPanel(symbol: "clock", title: "Ready for the first run", message: "Job history appears when your runners pick up work.").frame(height: 150)
                        } else {
                            ForEach(Array(recentJobs.enumerated()), id: \.element.id) { index, job in
                                JobRow(job: job)
                                if index < recentJobs.count - 1 { Divider() }
                            }
                        }
                    }.frame(maxWidth: .infinity)
                    Surface {
                        SectionHeading(title: "Activity", subtitle: "Changes across your workspace") { EmptyView() }.padding(.bottom, 15)
                        if model.events.isEmpty {
                            EmptyPanel(symbol: "waveform.path", title: "All quiet", message: "Runner changes and local actions will appear here.").frame(height: 150)
                        } else {
                            VStack(alignment: .leading, spacing: 17) {
                                ForEach(model.events.prefix(5)) { event in activityRow(event) }
                            }
                        }
                    }.frame(maxWidth: .infinity)
                }
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").foregroundStyle(RunningManStyle.teal)
                    Text("Built for your Mac. Runner discovery and log history stay local.")
                }.font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 4)
            }.padding(28).frame(maxWidth: 1400, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func metric(_ title: String, value: String, footnote: String, icon: String, color: Color) -> some View {
        Surface(padding: 16) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 3)
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color)
            }
            Text(value).font(.system(size: 33, weight: .semibold, design: .rounded)).monospacedDigit().padding(.top, 8)
            Text(footnote).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 1)
        }
    }

    private func activityRow(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(event.kind == .failure ? Color.red : event.kind == .warning ? .orange : event.kind == .success ? RunningManStyle.teal : .indigo)
                .frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
                if let detail = event.detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 4)
            Text(event.date, style: .relative).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

struct RunnerCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: RunnerSnapshot
    var body: some View {
        Button {
            model.selectedRunnerID = snapshot.id
            model.section = .runners
        } label: {
            Surface(padding: 17) {
                HStack(alignment: .top) {
                    Image(systemName: "terminal").font(.system(size: 17, weight: .medium))
                        .foregroundStyle(snapshot.status.color)
                        .frame(width: 36, height: 36)
                        .background(snapshot.status.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    Spacer()
                    StatusBadge(status: snapshot.status, compact: true)
                }
                Text(snapshot.runner.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).padding(.top, 12)
                Text(snapshot.runner.repository).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2)
                Divider().padding(.vertical, 10)
                HStack(spacing: 6) {
                    if let job = snapshot.currentJob {
                        Image(systemName: "bolt.fill").foregroundStyle(.indigo)
                        Text(job.name).lineLimit(1)
                    } else if model.drainingRunnerIDs.contains(snapshot.id) {
                        Image(systemName: "moon.zzz").foregroundStyle(.orange)
                        Text("Stopping when idle")
                    } else {
                        Image(systemName: snapshot.startsAtLogin ? "power" : "hand.tap")
                        Text(snapshot.startsAtLogin ? "Starts at login" : "Started manually")
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain).contextMenu { RunnerActionsMenu(snapshot: snapshot) }
            .accessibilityLabel("\(snapshot.runner.name), \(snapshot.status.title), \(snapshot.runner.repository)")
    }
}
