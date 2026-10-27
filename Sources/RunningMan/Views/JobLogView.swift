import AppKit
import RunningManCore
import SwiftUI

/// The steps and output of a runner's most recent job, laid out like GitHub's job log.
struct JobLogView: View {
    @Environment(AppModel.self) private var model
    let snapshot: RunnerSnapshot
    /// A step to open and scroll to, for example one chosen on the lap track.
    var focusStep: Int?
    /// Steps the user opened or closed; others follow the default (open while running or failed).
    @State private var stepExpansion: [Int: Bool] = [:]
    @State private var openGroups: Set<Int> = []
    @State private var followOutput = true

    private var log: JobStepLog? { model.stepLogs[snapshot.id] }

    var body: some View {
        if snapshot.runner.provider == .forgejo {
            EmptyPanel(symbol: "text.page.slash", title: "Job log not available",
                       message: "Forgejo runners send step output straight to the server and keep no local copy. Open the job on your Forgejo server to read it.")
        } else if let log {
            content(log)
                .onChange(of: log.jobID) { _, _ in stepExpansion = [:]; openGroups = [] }
        } else {
            EmptyPanel(symbol: "list.bullet.rectangle", title: "No job yet",
                       message: "When this runner starts a job, its steps and output appear here while the job runs.")
        }
    }

    private func content(_ log: JobStepLog) -> some View {
        let job = model.jobs(for: snapshot.id).first { $0.id == log.jobID }
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job?.name ?? "Most recent job").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(log.isFinished ? "Finished" : "Running").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if let job, job.runURL != nil {
                    Button("Open on GitHub", systemImage: "arrow.up.right.square") { model.openJob(job) }
                        .buttonStyle(.link).font(.system(size: 11))
                }
                Divider().frame(height: 16)
                Toggle("Follow", isOn: $followOutput).toggleStyle(.checkbox).font(.system(size: 10))
                    .help("Keep the newest output of the running step in view")
                Button { copy(log.steps) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help("Copy the redacted output of all steps")
            }.padding(13)
            Divider()
            if !log.hasOutput {
                notice("The runner uploaded this job’s output to GitHub before RunningMan could read it. Open the run on GitHub to see it.")
            } else if log.isTruncated {
                notice("Some output is not shown: earlier lines were trimmed to save memory, or the runner uploaded them before RunningMan read them.")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(log.steps) { step in
                            Section {
                                if isExpanded(step) { stepOutput(step) }
                            } header: { stepHeader(step) }
                        }
                    }.padding(.bottom, 12)
                }
                .background(.primary.opacity(0.02))
                .onChange(of: log.revision) { _, _ in scrollToNewest(log, proxy: proxy) }
                .onAppear {
                    guard let focusStep, log.steps.contains(where: { $0.id == focusStep }) else { scrollToNewest(log, proxy: proxy); return }
                    followOutput = false
                    stepExpansion[focusStep] = true
                    DispatchQueue.main.async { proxy.scrollTo("step-\(focusStep)", anchor: .top) }
                }
            }
            Divider()
            HStack {
                Label("Read from the runner’s local files · secrets redacted", systemImage: "lock.shield").foregroundStyle(.secondary)
                Spacer()
                Text("\(log.steps.count) steps").foregroundStyle(.tertiary)
            }.font(.system(size: 9)).padding(.horizontal, 13).padding(.vertical, 9)
        }
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).padding(.vertical, 9)
            .background(.primary.opacity(0.03))
    }

    private func stepHeader(_ step: JobStep) -> some View {
        Button {
            stepExpansion[step.id] = !isExpanded(step)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isExpanded(step) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
                Image(systemName: step.outcome.symbol).foregroundStyle(step.outcome.color).frame(width: 16)
                Text(step.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                stepDuration(step).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
        .id(stepAnchor(step))
        .contextMenu {
            Button("Copy Step Output") { copy([step]) }.disabled(step.lines.isEmpty)
        }
        .accessibilityLabel("\(step.name), \(step.outcome.title)")
    }

    @ViewBuilder
    private func stepDuration(_ step: JobStep) -> some View {
        switch step.outcome {
        case .skipped: Text("Skipped")
        case .running where step.finishedAt == nil: Text(step.startedAt, style: .timer).monospacedDigit()
        default:
            if let finished = step.finishedAt { Text(formattedDuration(finished.timeIntervalSince(step.startedAt))) }
        }
    }

    @ViewBuilder
    private func stepOutput(_ step: JobStep) -> some View {
        let lines = visibleLines(step)
        if lines.isEmpty {
            Text(step.outcome == .skipped ? "This step was skipped." : "No output was read for this step.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 52).padding(.vertical, 8)
        }
        ForEach(lines, id: \.line.id) { number, line in
            lineRow(number: number, line: line).id(lineAnchor(line))
        }
    }

    private func lineRow(number: Int, line: JobStepLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").foregroundStyle(.tertiary).frame(width: 40, alignment: .trailing)
            if line.kind == .groupHeader {
                Button {
                    if openGroups.contains(line.id) { openGroups.remove(line.id) } else { openGroups.insert(line.id) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: openGroups.contains(line.id) ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                        Text(line.text).fontWeight(.semibold)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                Text(line.text).foregroundStyle(line.kind.color).italic(line.kind == .omission)
                    .padding(.leading, line.isGrouped ? 13 : 0)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 16).padding(.vertical, 1)
        .background(line.kind.background)
    }

    /// Lines of the step with collapsed groups hidden, numbered like GitHub (from 1 within each step).
    private func visibleLines(_ step: JobStep) -> [(number: Int, line: JobStepLine)] {
        var result: [(number: Int, line: JobStepLine)] = []
        var groupOpen = true
        for (index, line) in step.lines.enumerated() {
            if line.kind == .groupHeader { groupOpen = openGroups.contains(line.id) }
            else if !line.isGrouped { groupOpen = true }
            if line.kind == .groupHeader || !line.isGrouped || groupOpen { result.append((index + 1, line)) }
        }
        return result
    }

    private func isExpanded(_ step: JobStep) -> Bool {
        stepExpansion[step.id] ?? (step.outcome == .running || step.outcome == .failure)
    }

    private func scrollToNewest(_ log: JobStepLog, proxy: ScrollViewProxy) {
        guard followOutput, let step = log.steps.last(where: { $0.outcome == .running }) else { return }
        if isExpanded(step), let line = visibleLines(step).last?.line {
            proxy.scrollTo(lineAnchor(line), anchor: .bottom)
        } else {
            proxy.scrollTo(stepAnchor(step), anchor: .top)
        }
    }

    private func stepAnchor(_ step: JobStep) -> String { "step-\(step.id)" }
    private func lineAnchor(_ line: JobStepLine) -> String { "line-\(line.id)" }

    private func copy(_ steps: [JobStep]) {
        let text = steps.map { step in
            ([step.name] + step.lines.map { ($0.isGrouped ? "  " : "") + $0.text }).joined(separator: "\n")
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension JobStepOutcome {
    var title: String {
        switch self {
        case .running: "Running"
        case .success: "Succeeded"
        case .failure: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .unknown: "Result unknown"
        }
    }
    var symbol: String {
        switch self {
        case .running: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .cancelled: "stop.circle"
        case .skipped: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .cancelled: .orange
        case .running: .indigo
        case .skipped, .unknown: .secondary
        }
    }
}

private extension JobStepLine.Kind {
    var color: Color {
        switch self {
        case .command: .blue
        case .error: .red
        case .warning: .orange
        case .notice: .teal
        case .debug, .section, .omission: .secondary
        case .output, .groupHeader: .primary
        }
    }
    var background: Color {
        switch self {
        case .error: .red.opacity(0.08)
        case .warning: .orange.opacity(0.08)
        default: .clear
        }
    }
}
