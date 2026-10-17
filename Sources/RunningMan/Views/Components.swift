import SwiftUI
import RunningManCore

struct StatusBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: RunnerStatus
    var compact = false
    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.system(size: compact ? 10 : 11, weight: .semibold))
            .foregroundStyle(status.color)
            .contentTransition(.symbolEffect(.replace))
            .busySymbolEffect(status == .busy)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                // Disabled reads as hollow, so it differs from stopped at a glance.
                if status == .disabled {
                    Capsule().strokeBorder(status.tone.fill.opacity(0.45))
                } else {
                    Capsule().fill(status.tone.fill.opacity(StatusTone.tintOpacity))
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: status)
            .accessibilityLabel("Status: \(status.title)")
    }
}

struct OutcomeBadge: View {
    let outcome: JobOutcome
    var compact = false
    var body: some View {
        Label(outcome.title, systemImage: outcome.symbol)
            .font(.system(size: compact ? 10 : 11, weight: compact ? .semibold : .medium))
            .foregroundStyle(outcome.color)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 5)
            .background(outcome.tone.fill.opacity(StatusTone.tintOpacity), in: Capsule())
            .accessibilityLabel("Outcome: \(outcome.title)")
    }
}

struct Surface<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content
    var body: some View {
        // A ViewBuilder can return several sibling views. Give them one layout
        // container before applying card modifiers, so a card remains one view
        // when its caller is an HStack, grid or another result builder.
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
    }
}

struct SectionHeading<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing()
        }
    }
}

struct EmptyPanel: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 11) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                .padding(.bottom, 3)
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 330)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

struct RunnerActionsMenu: View {
    @Environment(AppModel.self) private var model
    let snapshot: RunnerSnapshot
    var body: some View {
        let controllable = snapshot.runner.serviceDomain == .user
        if !controllable {
            Text("Managed by a system service")
        } else if snapshot.status.isRunning || snapshot.processID != nil {
            Button(model.drainingRunnerIDs.contains(snapshot.id) ? "Cancel stop when idle" : "Stop when idle", systemImage: "moon.zzz") { model.perform(.drain, on: snapshot) }
                .help("Stop after this job finishes. Keep RunningMan open until the runner stops.")
            Button("Stop runner", systemImage: "stop.fill") { model.perform(.stop, on: snapshot) }
        } else {
            Button("Start runner", systemImage: "play.fill") { model.perform(.start, on: snapshot) }
                .disabled(!snapshot.isEnabled)
        }
        if controllable {
            Divider()
            Button(snapshot.isEnabled ? "Disable runner" : "Enable runner", systemImage: snapshot.isEnabled ? "pause.circle" : "checkmark.circle") {
                model.perform(snapshot.isEnabled ? .disable : .enable, on: snapshot)
            }
            Button(snapshot.startsAtLogin ? "Turn off start at login" : "Start at login", systemImage: "power") {
                model.setStartup(!snapshot.startsAtLogin, for: snapshot)
            }
        }
        Divider()
        Button("Show in Finder", systemImage: "folder") { model.revealRunner(snapshot.runner) }
        Button("Open on \(snapshot.runner.provider.title)", systemImage: "arrow.up.right.square") { model.openGitHub(snapshot.runner) }
            .disabled(snapshot.runner.githubURL == nil)
        if controllable {
            Divider()
            Button("Delete runner…", systemImage: "trash", role: .destructive) { model.perform(.delete, on: snapshot) }
        }
    }
}

/// "45s", "3m", "3m 4s", "2h", "2h 5m": zero trailing components are omitted.
func formattedDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds >= 3600 {
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(seconds / 3600)h" : "\(seconds / 3600)h \(minutes)m"
    }
    if seconds >= 60 { return seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds)s"
}

func formattedDuration(for job: RunnerJob) -> String {
    guard job.outcome == .running || job.finishedAt != nil else { return "—" }
    return formattedDuration(job.duration)
}

/// Minute-granular relative time ("now", "5 min. ago"). Render it inside a
/// `TimelineView(.everyMinute)` instead of a relative text style that updates every
/// second, and pass the current date: the schedule's context date is the start of the
/// minute, up to 59 seconds behind on the first render.
@MainActor enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .short
        return formatter
    }()

    static func text(for date: Date, now: Date) -> String {
        let minutes = max(0, (now.timeIntervalSince(date) / 60).rounded(.down))
        return formatter.localizedString(fromTimeInterval: -minutes * 60)
    }
}

struct JobRow: View {
    /// History rows are grouped by day, so they show the start time; other lists
    /// show how long ago the job started, relative to a minute-granular `now`.
    enum Timestamp {
        case startTime
        case relative(now: Date)
    }

    @Environment(AppModel.self) private var model
    let job: RunnerJob
    var showRunner = false
    /// Adds a badge after the name for every outcome except success, so failures,
    /// cancellations and unknown results stand out in long lists.
    var showsOutcomeBadge = false
    let timestamp: Timestamp
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: job.outcome.symbol).font(.system(size: 16)).foregroundStyle(job.outcome.color)
                .busySymbolEffect(job.outcome == .running)
                .frame(width: 22)
                .help(job.outcome.title)
                .accessibilityLabel("Outcome: \(job.outcome.title)")
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(job.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if showsOutcomeBadge && job.outcome != .success { OutcomeBadge(outcome: job.outcome, compact: true) }
                }
                HStack(spacing: 5) {
                    if let repository = job.repository { Text(repository).lineLimit(1) }
                    if let workflow = job.workflow {
                        if job.repository != nil { Text("·") }
                        Text(workflow).lineLimit(1)
                    }
                    if job.repository == nil && job.workflow == nil { Text("Recorded from local runner logs") }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                if showRunner, let name = model.runnerNames[job.runnerID] {
                    Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Group {
                    if job.outcome == .running {
                        Text(job.startedAt, style: .timer).help("Time since the job started")
                    } else {
                        Text(formattedDuration(for: job))
                            .help(job.finishedAt == nil ? "No completion result in local logs" : "Recorded job duration")
                    }
                }.font(.system(size: 11, weight: .medium, design: .monospaced))
                Group {
                    switch timestamp {
                    case .startTime: Text(job.startedAt.formatted(date: .omitted, time: .shortened))
                    case .relative(let now): Text(RelativeTime.text(for: job.startedAt, now: now))
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if job.runURL != nil {
                Button { model.openJob(job) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open this run on its server")
            }
        }.padding(.vertical, 12)
    }
}
