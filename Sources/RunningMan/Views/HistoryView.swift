import SwiftUI
import RunningManCore

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var outcome: JobOutcome?
    @State private var runnerFilter = "all"
    private var jobs: [RunnerJob] {
        model.filteredJobs.filter { (outcome == nil || $0.outcome == outcome) && (runnerFilter == "all" || $0.runnerID == runnerFilter) }
            .sorted { $0.startedAt > $1.startedAt }
    }
    private var grouped: [(date: Date, jobs: [RunnerJob])] {
        Dictionary(grouping: jobs) { Calendar.current.startOfDay(for: $0.startedAt) }
            .map { (date: $0.key, jobs: $0.value) }.sorted { $0.date > $1.date }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    PageHeading(eyebrow: "The paper trail", title: "Job history", subtitle: "A local record of the work behind your releases.")
                    Spacer()
                    Button("Export diagnostics…", systemImage: "square.and.arrow.up") { model.exportDiagnostics() }
                        .controlSize(.small).padding(.top, 5)
                }
                HStack(spacing: 7) {
                    outcomeChip(nil, title: "All jobs")
                    outcomeChip(.running, title: "Running")
                    outcomeChip(.success, title: "Success")
                    outcomeChip(.failure, title: "Failed")
                    outcomeChip(.cancelled, title: "Cancelled")
                    Spacer()
                    Picker("Runner", selection: $runnerFilter) {
                        Text("All runners").tag("all")
                        ForEach(model.runners) { Text($0.runner.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 190).controlSize(.small)
                }
            }.padding(28)
            Divider()
            if jobs.isEmpty {
                EmptyPanel(symbol: model.jobs.isEmpty ? "clock.arrow.circlepath" : "line.3.horizontal.decrease.circle", title: model.jobs.isEmpty ? "Your next run starts the story" : "No matching jobs", message: model.jobs.isEmpty ? "RunningMan collects job history from installed runners. New work will appear here automatically." : "Try another outcome, runner or search term.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(grouped, id: \.date) { group in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text(dayTitle(group.date)).font(.system(size: 11, weight: .semibold))
                                    Text("\(group.jobs.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                }.padding(.leading, 3)
                                Surface(padding: 0) {
                                    VStack(spacing: 0) {
                                        ForEach(Array(group.jobs.enumerated()), id: \.element.id) { index, job in
                                            HStack(spacing: 16) {
                                                JobRow(job: job, showRunner: true)
                                                OutcomeBadge(outcome: job.outcome).frame(width: 95, alignment: .trailing)
                                            }.padding(.horizontal, 18)
                                            if index < group.jobs.count - 1 { Divider().padding(.leading, 53) }
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(28)
                }
            }
            Divider()
            HStack {
                Text("\(jobs.count) \(jobs.count == 1 ? "job" : "jobs") shown").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Label("History stays on this Mac", systemImage: "internaldrive").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 28).padding(.vertical, 12)
        }
    }

    private func outcomeChip(_ value: JobOutcome?, title: String) -> some View {
        let selected = outcome == value
        return Button { outcome = value } label: {
            HStack(spacing: 5) {
                if let value { Image(systemName: value.symbol).foregroundStyle(value.color) }
                Text(title)
            }.font(.system(size: 10, weight: selected ? .semibold : .medium))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .foregroundStyle(selected ? RunningManStyle.accent : .secondary)
                .background(selected ? RunningManStyle.accent.opacity(0.10) : .primary.opacity(0.035), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? RunningManStyle.accent.opacity(0.2) : .clear))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
