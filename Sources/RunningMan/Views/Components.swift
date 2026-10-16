import SwiftUI
import RunningManCore

enum RunningManStyle {
    static let accent = Color.indigo
    static let teal = Color(red: 0.10, green: 0.57, blue: 0.56)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let line = Color.primary.opacity(0.07)
}

extension RunnerStatus {
    var color: Color {
        switch self {
        case .idle: return RunningManStyle.teal
        case .busy: return .indigo
        case .stopped: return .secondary
        case .disabled: return .secondary
        case .attention: return .orange
        case .unknown: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .idle: return "checkmark.circle.fill"
        case .busy: return "arrow.triangle.2.circlepath"
        case .stopped: return "stop.circle"
        case .disabled: return "pause.circle"
        case .attention: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

extension JobOutcome {
    var color: Color {
        switch self {
        case .running: return .indigo
        case .success: return RunningManStyle.teal
        case .failure: return .red
        case .cancelled: return .orange
        case .unknown: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct StatusBadge: View {
    let status: RunnerStatus
    var compact = false
    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.system(size: compact ? 10 : 11, weight: .semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(status.color.opacity(0.10), in: Capsule())
            .accessibilityLabel("Status: \(status.title)")
    }
}

struct OutcomeBadge: View {
    let outcome: JobOutcome
    var body: some View {
        Label(outcome.title, systemImage: outcome.symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(outcome.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(outcome.color.opacity(0.09), in: Capsule())
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
            .background(RunningManStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(RunningManStyle.line))
    }
}

struct PageHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.8).foregroundStyle(RunningManStyle.accent)
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-0.7)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
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
        if snapshot.status.isRunning || snapshot.processID != nil {
            Button(model.drainingRunnerIDs.contains(snapshot.id) ? "Cancel stop when idle" : "Stop when idle", systemImage: "moon.zzz") { model.perform(.drain, on: snapshot) }
                .help("Stop after this job finishes. Keep RunningMan open until the runner stops.")
            Button("Stop runner", systemImage: "stop.fill") { model.perform(.stop, on: snapshot) }
        } else {
            Button("Start runner", systemImage: "play.fill") { model.perform(.start, on: snapshot) }
                .disabled(!snapshot.isEnabled)
        }
        Divider()
        Button(snapshot.isEnabled ? "Disable runner" : "Enable runner", systemImage: snapshot.isEnabled ? "pause.circle" : "checkmark.circle") {
            model.perform(snapshot.isEnabled ? .disable : .enable, on: snapshot)
        }
        Button(snapshot.startsAtLogin ? "Turn off start at login" : "Start at login", systemImage: "power") {
            model.setStartup(!snapshot.startsAtLogin, for: snapshot)
        }
        Divider()
        Button("Show in Finder", systemImage: "folder") { model.revealRunner(snapshot.runner) }
        Button("Open on \(snapshot.runner.provider.title)", systemImage: "arrow.up.right.square") { model.openGitHub(snapshot.runner) }
            .disabled(snapshot.runner.githubURL == nil)
        Divider()
        Button("Delete runner…", systemImage: "trash", role: .destructive) { model.perform(.delete, on: snapshot) }
    }
}

func formattedDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
    if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds)s"
}

func formattedDuration(for job: RunnerJob) -> String {
    guard job.outcome == .running || job.finishedAt != nil else { return "—" }
    return formattedDuration(job.duration)
}

struct JobRow: View {
    @Environment(AppModel.self) private var model
    let job: RunnerJob
    var showRunner = false
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: job.outcome.symbol).font(.system(size: 16)).foregroundStyle(job.outcome.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if let repository = job.repository { Text(repository).lineLimit(1) }
                    if let workflow = job.workflow {
                        if job.repository != nil { Text("·") }
                        Text(workflow).lineLimit(1)
                    }
                    if job.repository == nil && job.workflow == nil { Text("Recorded from local runner logs") }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if showRunner, let runner = model.runners.first(where: { $0.id == job.runnerID }) {
                    Text(runner.runner.name).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(formattedDuration(for: job)).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .help(job.outcome != .running && job.finishedAt == nil ? "No completion result in local logs" : "Recorded job duration")
                Text(job.startedAt, style: .relative).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if job.runURL != nil {
                Button { model.openJob(job) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open this run on its server")
            }
        }.padding(.vertical, 12)
    }
}
