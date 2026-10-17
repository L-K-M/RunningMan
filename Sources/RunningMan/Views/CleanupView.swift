import SwiftUI
import RunningManCore

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var runnerFilter = "all"
    private var reports: [RunnerCleanupRecord] {
        model.filteredCleanupRecords.filter { runnerFilter == "all" || $0.runnerID == runnerFilter }
    }
    private var recent: [RunnerCleanupRecord] {
        reports.filter { ($0.finishedAt ?? $0.startedAt) >= Date().addingTimeInterval(-86_400) }
    }
    private var completed: [RunnerCleanupRecord] { recent.filter { $0.status == .success } }
    private var removedBytes: Int64 {
        completed.reduce(Int64(0)) { total, report in
            let sum = total.addingReportingOverflow(max(0, report.bytesRemoved))
            return sum.overflow ? Int64.max : sum.partialValue
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) {
                    Text("Cleanup reports from job-owned release workspaces.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 12)
                    Picker("Runner", selection: $runnerFilter) {
                        Text("All runners").tag("all")
                        ForEach(model.runners) { Text($0.runner.name).tag($0.id) }
                    }.frame(maxWidth: 200).controlSize(.small)
                }
                HStack(spacing: 12) {
                    MetricTile(title: "Build files removed", value: cleanupBytes(removedBytes),
                               footnote: "Reported file size · last 24 hours", symbol: "externaldrive.badge.checkmark", tint: StatusTone.positive.text)
                    MetricTile(title: "Completed cleanups", value: String(completed.count), footnote: "Last 24 hours", symbol: "checkmark.circle", tint: StatusTone.positive.text)
                    MetricTile(title: "Needs attention", value: String(recent.filter { $0.status == .failed || $0.status == .partial }.count),
                               footnote: "Unconfirmed or incomplete removal", symbol: "exclamationmark.triangle", tint: StatusTone.warning.text)
                    MetricTile(title: "Awaiting cleanup", value: String(reports.filter { $0.status == .pending }.count),
                               footnote: "No final report yet", symbol: "hourglass", tint: StatusTone.active.text)
                }.fixedSize(horizontal: false, vertical: true)
                Surface {
                    Label("Only that job’s build workspace", systemImage: "lock.shield").font(.system(size: 13, weight: .semibold))
                    Text("Release workflows build in a separate temporary copy, then remove it after upload attempts. Runner settings, diagnostic logs, cleanup reports, development checkouts and shared tool caches are kept outside that workspace.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 7)
                    Text("RunningMan reads these reports. It does not delete files or assume that an older release was cleaned up.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 9)
                }
                SectionHeading(title: "Cleanup history", subtitle: "Latest reports retained by each runner") { EmptyView() }
                if !model.cleanupWarnings.isEmpty {
                    Surface {
                        Label("Some reports could not be read", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(StatusTone.warning.text)
                        Text(model.cleanupWarnings.joined(separator: "\n")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 7)
                    }
                }
                if reports.isEmpty {
                    Surface {
                        EmptyPanel(symbol: "sparkles", title: "No cleanup reports yet",
                                   message: "Cut a release containing the new cleanup workflow. Its result will appear here automatically; older jobs have no cleanup evidence.")
                            .frame(minHeight: 150)
                    }
                } else {
                    ForEach(reports, id: \.cleanupUIIdentity) { report in
                        Surface {
                            // The summary below carries the status icon and title, so the
                            // header names the work only.
                            HStack(alignment: .top, spacing: 14) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(report.repository).font(.system(size: 13, weight: .semibold))
                                    Text("\(model.runnerName(for: report.runnerID)) · \(report.job) · Run #\(report.runID), attempt \(report.runAttempt)")
                                        .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                if let url = report.runURL {
                                    Button { model.openServerLink(url) } label: { Image(systemName: "arrow.up.right") }
                                        .buttonStyle(.plain).help("Open this workflow run")
                                }
                            }
                            CleanupResultSummary(report: report).padding(.top, 12)
                            if !report.paths.isEmpty {
                                DisclosureGroup("Reported workspace") {
                                    ForEach(Array(report.paths.enumerated()), id: \.offset) { _, path in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(path.path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                            Text(path.status.title).font(.system(size: 10)).foregroundStyle(path.status.cleanupColor)
                                            if let message = path.message { Text(message).font(.system(size: 10)).foregroundStyle(.secondary) }
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                                    }
                                }.font(.system(size: 10)).padding(.top, 12)
                            }
                        }
                    }
                }
                Text("Sizes are estimates from removed file contents, not measurements of free disk space. APFS snapshots and shared blocks can change the space actually recovered. A cancelled job normally still runs cleanup; a powered-off or force-killed runner can leave a pending report and its workspace behind.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(28).frame(maxWidth: 1400).frame(maxWidth: .infinity)
        }
    }
}

struct CleanupResultSummary: View {
    let report: RunnerCleanupRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(report.status.title, systemImage: report.status.cleanupSymbol)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(report.status.cleanupColor)
                Spacer()
                Text((report.finishedAt ?? report.startedAt).formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if report.status == .success || report.status == .partial {
                Text("\(cleanupBytes(report.bytesRemoved)) · \(report.filesRemoved.formatted()) files removed")
                    .font(.system(size: 12, weight: .medium))
                Text("Reported by the cleanup step; release upload success is tracked separately.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if report.status == .pending {
                Text("The job workspace was prepared, but cleanup has not been confirmed. The job may still be running or may have been interrupted.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let message = report.message, !message.isEmpty {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private func cleanupBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

private extension RunnerCleanupRecord {
    var cleanupUIIdentity: String { runnerID + ":" + id }
}

private extension RunnerCleanupStatus {
    var cleanupColor: Color {
        switch self {
        case .success: return StatusTone.positive.text
        case .partial: return StatusTone.warning.text
        case .failed: return StatusTone.critical.text
        case .pending: return StatusTone.active.text
        case .skipped: return StatusTone.neutral.text
        }
    }
    var cleanupSymbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .pending: return "hourglass"
        case .skipped: return "minus.circle"
        }
    }
}
