import RunningManCore
import SwiftUI
import WidgetKit

/// Shared with the isolated screenshot gallery, so smoke tests render the shipped views.
public struct RunnerWidgetView: View {
    private let family: WidgetFamily
    private let kind: RunnerWidgetKind
    private let snapshot: WidgetSnapshot?
    private let date: Date

    public init(kind: RunnerWidgetKind, snapshot: WidgetSnapshot?, date: Date, family: WidgetFamily) {
        self.kind = kind
        self.snapshot = snapshot
        self.date = date
        self.family = family
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(kind.title, systemImage: kind == .fleet ? "server.rack" : "checkmark.seal")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            if let snapshot {
                stats(snapshot)
                footer(snapshot)
            } else {
                Spacer(minLength: 0)
                Text("Stats unavailable").font(.headline)
                Text("Open RunningMan to refresh.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .widgetURL(kind.url)
    }

    @ViewBuilder private func stats(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                if kind == .fleet {
                    Text(snapshot.fleet.online, format: .number)
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                    Text("of \(snapshot.fleet.total) online").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(snapshot.jobs.successRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                    Text("Success rate").font(.caption).foregroundStyle(.secondary)
                    if family == .systemMedium {
                        Text("\(snapshot.jobs.completed) completed").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)

            if family == .systemMedium {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    if kind == .fleet {
                        metric("Busy", count: snapshot.fleet.busy, symbol: "bolt.fill")
                        metric("Attention", count: snapshot.fleet.attention, symbol: "exclamationmark.triangle")
                        metric("Stopped", count: snapshot.fleet.stopped, symbol: "stop.circle")
                        metric("Disabled", count: snapshot.fleet.disabled, symbol: "pause.circle")
                    } else {
                        metric("Succeeded", count: snapshot.jobs.succeeded, symbol: "checkmark.circle")
                        metric("Failed", count: snapshot.jobs.failed, symbol: "xmark.circle")
                        metric("Cancelled", count: snapshot.jobs.cancelled, symbol: "minus.circle")
                        metric("Unknown", count: snapshot.jobs.unknown, symbol: "questionmark.circle")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)

        if kind == .fleet {
            if family == .systemSmall {
                Text("\(snapshot.fleet.busy) busy · \(snapshot.fleet.attention) attention")
                    .font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.7)
            }
            if snapshot.fleet.unverified > 0 {
                Text("\(snapshot.fleet.unverified) activity unverified").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } else {
            Text("\(snapshot.jobs.total) jobs recorded locally").font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func metric(_ title: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 12)
            Text(title)
            Spacer(minLength: 2)
            Text(count, format: .number).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }

    private func footer(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text(snapshot.isStale(at: date) ? "Last snapshot · " : "Updated · ") + Text(snapshot.updatedAt, style: .time))
            if snapshot.isStale(at: date) { Text("Open app to refresh") }
        }
        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
    }
}

/// Fictional, in-process previews. No widget cache or installed runner is touched.
public struct WidgetPreviewGallery: View {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Desktop widgets").font(.title2.bold())
            Text("Fictional preview · Small and medium").font(.caption).foregroundStyle(.secondary)
            ForEach(RunnerWidgetKind.allCases, id: \.rawValue) { kind in
                HStack(spacing: 16) {
                    card(kind: kind, snapshot: .example(at: date), family: .systemSmall)
                    card(kind: kind, snapshot: .example(at: date), family: .systemMedium)
                }
            }
            HStack(spacing: 16) {
                card(kind: .fleet, snapshot: nil, family: .systemSmall)
                card(kind: .jobs, snapshot: .example(at: date.addingTimeInterval(-WidgetSnapshot.staleInterval)), family: .systemMedium)
            }
        }
        .padding(24).background(.quaternary.opacity(0.4))
    }

    private func card(kind: RunnerWidgetKind, snapshot: WidgetSnapshot?, family: WidgetFamily) -> some View {
        RunnerWidgetView(kind: kind, snapshot: snapshot, date: date, family: family)
            .padding(16)
            .frame(width: family == .systemSmall ? 170 : 360, height: 170)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }
}
