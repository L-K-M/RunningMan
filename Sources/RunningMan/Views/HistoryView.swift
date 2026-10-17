import SwiftUI
import RunningManCore

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var outcome: JobOutcome?
    @State private var runnerFilter = "all"
    /// Newest first, because `filteredJobs` is.
    private var visibleJobs: [RunnerJob] {
        model.filteredJobs.filter { (outcome == nil || $0.outcome == outcome) && (runnerFilter == "all" || $0.runnerID == runnerFilter) }
    }
    var body: some View {
        // Filter and group once per render; everything below reads these locals.
        let jobs = visibleJobs
        let groups = Self.dayGroups(jobs)
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
                    // Rows are direct children of the lazy stack, so only visible ones are
                    // built; each row draws its own slice of the day's card.
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(Array(group.jobs.enumerated()), id: \.element.id) { index, job in
                                    VStack(spacing: 0) {
                                        HStack(spacing: 16) {
                                            JobRow(job: job, showRunner: true, timestamp: .startTime)
                                            OutcomeBadge(outcome: job.outcome).frame(width: 95, alignment: .trailing)
                                        }.padding(.horizontal, 18)
                                        if index < group.jobs.count - 1 { Divider().padding(.leading, 53) }
                                    }.modifier(CardSlice(isFirst: index == 0, isLast: index == group.jobs.count - 1))
                                }
                            } header: {
                                // The top inset keeps a pinned header clear of the divider above; the
                                // stack padding and footer are 8 pt smaller, so resting spacing is unchanged.
                                HStack {
                                    Text(dayTitle(group.date)).font(.system(size: 11, weight: .semibold))
                                    Text("\(group.jobs.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                }.padding(.leading, 3).padding(.top, 8).padding(.bottom, 9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RunningManStyle.canvas)
                            } footer: {
                                if group.id != groups.last?.id { Color.clear.frame(height: 12) }
                            }
                        }
                    }.padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 28)
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

    struct DayGroup: Identifiable {
        var date: Date
        var jobs: [RunnerJob]
        var id: Date { date }
    }

    /// Groups jobs by the calendar day they started, newest day first, keeping the
    /// input order within a day. Sorted input needs one calendar lookup per day.
    static func dayGroups(_ jobs: [RunnerJob], calendar: Calendar = .current) -> [DayGroup] {
        var groups: [DayGroup] = []
        var indexByDay: [Date: Int] = [:]
        var current: (day: DateInterval, index: Int)?
        for job in jobs {
            if let current, job.startedAt >= current.day.start, job.startedAt < current.day.end {
                groups[current.index].jobs.append(job)
                continue
            }
            // Days are 23 or 25 hours long when daylight saving time changes.
            let day = calendar.dateInterval(of: .day, for: job.startedAt) ?? {
                let start = calendar.startOfDay(for: job.startedAt)
                return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
            }()
            let index: Int
            if let existing = indexByDay[day.start] {
                index = existing
            } else {
                index = groups.count
                indexByDay[day.start] = index
                groups.append(DayGroup(date: day.start, jobs: []))
            }
            groups[index].jobs.append(job)
            current = (day, index)
        }
        return groups.sorted { $0.date > $1.date }
    }
}

/// One row's share of a rounded card, so a lazy list of rows reads as one card: only
/// the first and last rows round their corners, and the outline's horizontal edges
/// appear only at the ends of the card.
private struct CardSlice: ViewModifier {
    let isFirst: Bool
    let isLast: Bool
    func body(content: Content) -> some View {
        let radius: CGFloat = 14
        let shape = UnevenRoundedRectangle(topLeadingRadius: isFirst ? radius : 0, bottomLeadingRadius: isLast ? radius : 0,
                                           bottomTrailingRadius: isLast ? radius : 0, topTrailingRadius: isFirst ? radius : 0)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RunningManStyle.surface, in: shape)
            .overlay {
                // Extend the outline past interior edges and clip it, leaving only the sides there.
                shape.strokeBorder(RunningManStyle.line)
                    .padding(.top, isFirst ? 0 : -2).padding(.bottom, isLast ? 0 : -2)
            }
            .clipShape(Rectangle())
    }
}
