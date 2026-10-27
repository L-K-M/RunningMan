import SwiftUI
import RunningManCore

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let recentJobs = model.recentJobs
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                fleetSummary
                LapLanes()
                MetricRow {
                    MetricTile(title: "Runners online", value: "\(model.runningCount)", footnote: "of \(model.runners.count) installed", symbol: "play.circle", tint: StatusTone.positive.text)
                    MetricTile(title: "Busy runners", value: "\(model.busyCount)", footnote: "with at least one active job", symbol: "bolt.fill", tint: StatusTone.active.text)
                    MetricTile(title: "Jobs recorded", value: "\(model.jobs.count)", footnote: "from local runner logs", symbol: "clock.arrow.circlepath", tint: RunningManStyle.accentText)
                    MetricTile(title: "Success rate", value: model.successRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", footnote: "of completed jobs", symbol: "checkmark.seal", tint: StatusTone.positive.text)
                }
                if !model.warnings.isEmpty {
                    Surface(padding: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StatusTone.warning.text)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("A little attention needed").font(.system(size: 12, weight: .semibold))
                                ForEach(Array(model.warnings.prefix(3).enumerated()), id: \.offset) { _, warning in
                                    Text(warning).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                if model.warnings.count > 3 { Text("\(model.warnings.count - 3) more in exported diagnostics").font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                            Spacer()
                        }
                    }
                }
                VStack(spacing: 13) {
                    SectionHeading(title: "Your fleet") {
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
                            TimelineView(.everyMinute) { _ in
                                let now = Date()
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(recentJobs.enumerated()), id: \.element.id) { index, job in
                                        JobRow(job: job, timestamp: .relative(now: now))
                                        if index < recentJobs.count - 1 { Divider() }
                                    }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity)
                    Surface {
                        SectionHeading(title: "Activity", subtitle: "Changes across your workspace") { EmptyView() }.padding(.bottom, 15)
                        if model.events.isEmpty {
                            EmptyPanel(symbol: "waveform.path", title: "All quiet", message: "Runner changes and local actions will appear here.").frame(height: 150)
                        } else {
                            TimelineView(.everyMinute) { _ in
                                let now = Date()
                                VStack(alignment: .leading, spacing: 17) {
                                    ForEach(model.events.prefix(5)) { event in activityRow(event, now: now) }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity)
                }
            }.padding(28).frame(maxWidth: 1400, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    /// The page's headline: live counts instead of a slogan, since the toolbar already
    /// names the page.
    private var fleetSummary: some View {
        let total = model.runners.count, online = model.runningCount, busy = model.busyCount
        let headline = total == 0 ? "No runners on this Mac yet"
            : "\(online) of \(total) \(total == 1 ? "runner" : "runners") online" + (busy > 0 ? ", \(busy) busy" : "")
        let attention = model.runners.filter { $0.status == .attention || $0.status == .unknown }.count
        let draining = model.drainingRunnerIDs.count
        let queue = model.fleetQueue
        var details: [String] = []
        if attention > 0 { details.append("\(attention) \(attention == 1 ? "needs" : "need") attention") }
        if draining > 0 { details.append("\(draining) \(draining == 1 ? "runner" : "runners") stopping when idle") }
        if queue.hasQueueEvidence, queue.queuedCount > 0 {
            details.append("\(queue.queuedCount)\(queue.isIncomplete ? "+" : "") compatible \(queue.queuedCount == 1 ? "job" : "jobs") queued")
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(headline).font(.system(size: 22, weight: .semibold, design: .rounded))
                .contentTransition(.numericText()).animation(reduceMotion ? nil : .snappy, value: headline)
            if !details.isEmpty {
                Text(details.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }

    private func activityRow(_ event: ActivityEvent, now: Date) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(event.kind == .failure ? StatusTone.critical.fill : event.kind == .warning ? StatusTone.warning.fill
                          : event.kind == .success ? StatusTone.positive.fill : RunningManStyle.accent)
                .frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
                if let detail = event.detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 4)
            Text(RelativeTime.text(for: event.date, now: now)).font(.system(size: 10)).foregroundStyle(.secondary)
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
                HStack(alignment: .top, spacing: 6) {
                    RunnerGlyph(runner: snapshot.runner, status: snapshot.status, size: 36)
                    Spacer()
                    if snapshot.runner.serviceDomain == .system { SystemServiceBadge() }
                    StatusBadge(status: snapshot.status, compact: true)
                }
                Text(snapshot.runner.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).padding(.top, 12)
                Text(snapshot.runner.repository).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2)
                Text("\(snapshot.runner.provider.title) · \(snapshot.runner.capacity) \(snapshot.runner.capacity == 1 ? "slot" : "slots")")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 3)
                Divider().padding(.vertical, 10)
                HStack(spacing: 6) {
                    if let job = snapshot.currentJob {
                        Image(systemName: "bolt.fill").foregroundStyle(StatusTone.active.text)
                        Text(job.name).lineLimit(1)
                    } else if model.drainingRunnerIDs.contains(snapshot.id) {
                        Image(systemName: "moon.zzz").foregroundStyle(StatusTone.warning.text)
                        Text("Stopping when idle")
                    } else {
                        Image(systemName: snapshot.startsAtLogin ? "power" : "hand.tap")
                        Text(snapshot.startsAtLogin ? "Starts at login" : "Started manually")
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain).contextMenu { RunnerActionsMenu(snapshot: snapshot) }
            .accessibilityLabel("\(snapshot.runner.name), \(snapshot.status.title), \(snapshot.runner.provider.title), \(snapshot.runner.repository)"
                                + (snapshot.runner.serviceDomain == .system ? ", system service, read-only" : ""))
    }
}
