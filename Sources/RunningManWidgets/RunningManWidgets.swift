import RunningManCore
import RunningManWidgetViews
import SwiftUI
import WidgetKit

@main
struct RunningManWidgets: WidgetBundle {
    var body: some Widget {
        FleetWidget()
        JobResultsWidget()
    }
}

private struct FleetWidget: Widget {
    var body: some WidgetConfiguration { statsConfiguration(for: .fleet) }
}

private struct JobResultsWidget: Widget {
    var body: some WidgetConfiguration { statsConfiguration(for: .jobs) }
}

@MainActor private func statsConfiguration(for kind: RunnerWidgetKind) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind.identifier, provider: StatsProvider()) { entry in
        StatsContent(kind: kind, entry: entry)
    }
    .configurationDisplayName(Text(kind.title))
    .description(Text(kind == .fleet
        ? "Online, busy and stopped runners on this Mac, from RunningMan’s latest snapshot."
        : "Recorded job outcomes and success rate from available local history."))
    .supportedFamilies([.systemSmall, .systemMedium])
}

private struct StatsContent: View {
    @Environment(\.widgetFamily) private var family
    let kind: RunnerWidgetKind
    let entry: StatsEntry

    var body: some View {
        RunnerWidgetView(kind: kind, snapshot: entry.snapshot, date: entry.date, family: family)
            .containerBackground(.background, for: .widget)
    }
}

private struct StatsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

private struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry {
        let date = Date()
        return StatsEntry(date: date, snapshot: .example(at: date))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { completion(StatsEntry(date: Date(), snapshot: await load())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        Task {
            let snapshot = await load()
            let now = Date()
            var entries = [StatsEntry(date: now, snapshot: snapshot)]
            // Mark cached counts stale even if the host quits and never invalidates us.
            if let snapshot, !snapshot.isStale(at: now) {
                entries.append(StatsEntry(date: snapshot.updatedAt.addingTimeInterval(WidgetSnapshot.staleInterval), snapshot: snapshot))
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(WidgetSnapshot.staleInterval))))
        }
    }

    private func load() async -> WidgetSnapshot? {
        guard let home = WidgetAccount.homeDirectory else { return nil }
        return try? await WidgetSnapshotStore(fileURL: WidgetSnapshotStore.fileURL(homeDirectory: home)).load()
    }
}
