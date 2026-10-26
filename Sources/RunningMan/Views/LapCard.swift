import AppKit
import RunningManCore
import SwiftUI

/// The running job of one runner, raced against its ghost: the runner detail's main card.
struct LapCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: RunnerSnapshot
    let job: RunnerJob
    var isControllable = true
    var isActing = false
    /// Opens the job log, scrolled to a step when one is given.
    var openJobLog: (Int?) -> Void = { _ in }

    @State private var selected: Int?
    @State private var hovered: Int?
    @State private var trackWidth: CGFloat = 0
    @FocusState private var trackFocused: Bool

    private var log: JobStepLog? { model.stepLogs[snapshot.id].flatMap { $0.jobID == job.id ? $0 : nil } }
    private var steps: [JobStep] { log?.steps ?? [] }
    private var isFinished: Bool { log?.isFinished ?? (job.finishedAt != nil) }

    var body: some View {
        let reference = model.lapReference(for: job)
        Surface {
            HStack(alignment: .center) {
                Label(isFinished ? "FINISHED" : "WORKING NOW", systemImage: isFinished ? "flag.checkered" : "bolt.fill")
                    .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(StatusTone.active.text)
                Spacer()
                if let reference { paceMenu(reference) }
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name).font(.system(size: 16, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text([job.repository ?? snapshot.runner.repository, job.workflow].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                TimelineView(.lapSeconds) { context in
                    LapReadout(progress: progress(reference, at: context.date), job: job)
                }
            }.padding(.top, 8)
            track(reference).padding(.top, 10)
            TimelineView(.lapSeconds) { context in
                LapCaption(progress: progress(reference, at: context.date), now: context.date)
            }.padding(.top, 2)
            HStack(spacing: 10) {
                if isControllable, !isFinished {
                    Button(model.drainingRunnerIDs.contains(snapshot.id) ? "Cancel stop when idle" : "Stop when idle", systemImage: "moon.zzz") {
                        model.perform(.drain, on: snapshot)
                    }
                    .controlSize(.small).disabled(isActing)
                    .help("Stop after this job finishes. Keep RunningMan open until the runner stops.")
                }
                Spacer()
                if snapshot.runner.provider == .github {
                    Button("Job log", systemImage: "list.bullet.rectangle") { openJobLog(nil) }
                        .buttonStyle(.link).font(.system(size: 11)).help("Show the steps and output of this job")
                }
            }.padding(.top, 11)
        }
    }

    private func progress(_ reference: LapReference?, at now: Date) -> LapProgress {
        LapTrack.progress(job: job, steps: steps, isFinished: isFinished, reference: reference, now: now)
    }

    private func track(_ reference: LapReference?) -> some View {
        // A selection stays until Escape or a second click on it, wherever focus goes.
        let highlighted = hovered ?? selected
        return LapTrack(job: job, steps: steps, isFinished: isFinished, reference: reference, style: .full,
                        selectedSector: highlighted, onEvent: play)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = $0 }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location): hovered = sector(at: location.x, reference: reference)
                case .ended: hovered = nil
                }
            }
            // One click selects a step and keeps its details up; a double click opens it in the job log.
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                guard let index = sector(at: location.x, reference: reference) else { return }
                openJobLog(progress(reference, at: Date()).sectors.first { $0.id == index }?.stepID)
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { location in
                let index = sector(at: location.x, reference: reference)
                selected = index == selected ? nil : index
                trackFocused = true
            }
            .overlay(alignment: .topLeading) {
                if let shown = hovered ?? selected { inspector(shown, reference: reference) }
            }
            // Keyboard-driven like a text field: a click focuses it and still selects.
            .focusable(interactions: .edit)
            .focused($trackFocused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { moveSelection(-1, reference: reference) }
            .onKeyPress(.rightArrow) { moveSelection(1, reference: reference) }
            .onKeyPress(.escape) {
                guard selected != nil else { return .ignored }
                selected = nil
                return .handled
            }
            .onKeyPress(.return) {
                openJobLog(selected.flatMap { index in progress(reference, at: Date()).sectors.first { $0.id == index }?.stepID })
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "gG")) { _ in
                model.ghostPace = model.ghostPace.next
                return .handled
            }
            .onChange(of: job.id) { _, _ in selected = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Lap against \(reference?.pace.title.lowercased() ?? "no earlier run")")
            .accessibilityValue(accessibilityValue(progress(reference, at: Date())))
            .accessibilityHint("Adjust to step through the job's steps. Press Return to open the selected step in the job log.")
            .accessibilityAdjustableAction { direction in
                _ = moveSelection(direction == .increment ? 1 : -1, reference: reference)
            }
    }

    private func sector(at x: CGFloat, reference: LapReference?) -> Int? {
        guard trackWidth > 0 else { return nil }
        let current = progress(reference, at: Date())
        return LapTrack.layout(progress: current, width: trackWidth, style: .full).sector(at: x)
    }

    private func moveSelection(_ step: Int, reference: LapReference?) -> KeyPress.Result {
        let sectors = progress(reference, at: Date()).sectors
        guard !sectors.isEmpty else { return .ignored }
        let start = selected ?? (step > 0 ? -1 : sectors.count)
        selected = min(max(start + step, 0), sectors.count - 1)
        return .handled
    }

    private func play(_ event: LapEvent) {
        guard model.lapSoundsEnabled, NSApp.isActive, SnapshotCapture.destination == nil else { return }
        LapSounds.shared.play(event)
    }

    private func paceMenu(_ reference: LapReference) -> some View {
        Menu {
            ForEach(GhostPace.allCases, id: \.self) { pace in
                Button {
                    model.ghostPace = pace
                } label: {
                    let total = model.lapReference(for: job, pace: pace)?.total
                    Text(pace.title + (total.map { " · " + LapProgress.clock($0) } ?? ""))
                }
            }
        } label: {
            Label("vs \(reference.pace.title)", systemImage: "figure.run").labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).foregroundStyle(.secondary)
        .help("The ghost replays \(reference.pace.title.lowercased()) of \(reference.runs) recorded \(reference.runs == 1 ? "run" : "runs"). Press G on the track to switch.")
    }

    private func inspector(_ index: Int, reference: LapReference?) -> some View {
        let current = progress(reference, at: Date())
        let layout = LapTrack.layout(progress: current, width: trackWidth, style: .full)
        return Group {
            if let sector = current.sectors.first(where: { $0.id == index }), let span = layout.spans.first(where: { $0.id == index }) {
                let width: CGFloat = 236
                let x = min(max(span.x + span.width / 2 - width / 2, 0), max(0, trackWidth - width))
                SectorInspector(sector: sector, isRunning: current.currentSector == index)
                    .frame(width: width)
                    .offset(x: x, y: -64)
                    .allowsHitTesting(false)
            }
        }
    }

    private func accessibilityValue(_ progress: LapProgress) -> String {
        var parts: [String] = []
        switch progress.outcome {
        case .running:
            if progress.reference != nil { parts.append(LapProgress.describeLead(progress.lead)) }
            if let current = progress.currentSector, let sector = progress.sectors.first(where: { $0.id == current }) {
                parts.append("Step \(current + 1) of \(progress.sectors.count), \(sector.name), \(LapProgress.clock(sector.actual ?? 0))"
                             + (sector.reference > 0 ? " of usually \(LapProgress.clock(sector.reference))" : ""))
            }
            if let remaining = progress.remaining {
                parts.append("Done about \(Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened))")
            }
        case .success: parts.append("Finished in \(LapProgress.clock(progress.elapsed)), \(LapProgress.describeLead(progress.lead))")
        case .failure: parts.append("Failed after \(LapProgress.clock(progress.elapsed))")
        case .cancelled: parts.append("Cancelled after \(LapProgress.clock(progress.elapsed))")
        }
        if let selected, let sector = progress.sectors.first(where: { $0.id == selected }) {
            parts.append("Selected: \(SectorInspector.summary(sector))")
        }
        return parts.joined(separator: ". ")
    }
}

extension TimelineSchedule where Self == PeriodicTimelineSchedule {
    /// Every lap readout ticks on the same whole second, so the window updates once a second
    /// however many readouts are showing; each update lays out the whole window.
    static var lapSeconds: PeriodicTimelineSchedule { .periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 1) }
}

/// The lead in large digits, or the result once the job has finished.
struct LapReadout: View {
    let progress: LapProgress
    let job: RunnerJob
    var compact = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.system(size: compact ? 13 : 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tone).contentTransition(.numericText(value: progress.lead)).lineLimit(1)
            if !compact {
                Text(caption).font(.system(size: 10, weight: .medium)).foregroundStyle(captionTone).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var value: String {
        switch progress.outcome {
        case .running:
            guard let reference = progress.reference else { return LapProgress.clock(progress.elapsed).replacingOccurrences(of: " s", with: "s") }
            // A job paced as a whole has no lead until it finishes or runs long; show what is left.
            if reference.isWholeJob, progress.lead <= 0, let remaining = progress.remaining { return Self.minutes(remaining) + (compact ? " left" : "") }
            return Self.signed(progress.lead)
        case .success: return Self.minutes(progress.elapsed)
        case .failure: return compact ? "Failed" : Self.minutes(progress.elapsed)
        case .cancelled: return compact ? "Stopped" : Self.minutes(progress.elapsed)
        }
    }

    private var caption: String {
        switch progress.outcome {
        case .running:
            guard let reference = progress.reference else { return "first recorded run" }
            if reference.isWholeJob, progress.lead <= 0 { return "left, usually" }
            let lead = Int(progress.lead.rounded())
            return lead == 0 ? "level" : lead < 0 ? "ahead" : "behind"
        case .success:
            guard let reference = progress.reference else { return "finished" }
            if let best = reference.bestTotal, progress.elapsed < best { return "personal best" }
            return LapProgress.describeLead(progress.lead).replacingOccurrences(of: "ahead", with: "faster").replacingOccurrences(of: "behind", with: "slower")
        case .failure: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private var tone: Color {
        switch progress.outcome {
        case .running:
            guard let reference = progress.reference else { return .primary }
            if reference.isWholeJob, progress.lead <= 0 { return .primary }
            let lead = Int(progress.lead.rounded())
            return lead < 0 ? StatusTone.positive.text : lead > 0 ? StatusTone.warning.text : .primary
        case .success:
            if let best = progress.reference?.bestTotal, progress.elapsed < best { return LapPalette.personalBest }
            return StatusTone.positive.text
        case .failure: return StatusTone.critical.text
        case .cancelled: return StatusTone.neutral.text
        }
    }

    private var captionTone: Color {
        if progress.outcome == .success, let best = progress.reference?.bestTotal, progress.elapsed < best { return LapPalette.personalBest }
        return .secondary
    }

    /// "−0:07", "+1:15", "±0:00".
    static func signed(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        let sign = rounded < 0 ? "−" : rounded > 0 ? "+" : "±"
        return sign + minutes(Double(abs(rounded)))
    }

    static func minutes(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The line under the track: the running step against its usual time and the finish estimate.
struct LapCaption: View {
    let progress: LapProgress
    let now: Date

    var body: some View {
        // In a narrow detail the step comes first; the finish estimate gives way.
        ViewThatFits(in: .horizontal) {
            line(showsEstimate: true)
            line(showsEstimate: false)
        }
        .font(.system(size: 11)).lineLimit(1)
    }

    private func line(showsEstimate: Bool) -> some View {
        HStack(spacing: 6) {
            switch progress.outcome {
            case .running:
                if let index = progress.currentSector, let sector = progress.sectors.first(where: { $0.id == index }) {
                    if sector.isOverrun {
                        Label(stepText(sector), systemImage: "tortoise.fill").foregroundStyle(StatusTone.warning.text)
                    } else {
                        Text(stepText(sector)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if showsEstimate, let remaining = progress.remaining {
                    Text("Done about \(now.addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            case .success:
                Text(finishText).foregroundStyle(.secondary)
                Spacer()
            case .failure, .cancelled:
                if let index = progress.failedSector, let sector = progress.sectors.first(where: { $0.id == index }) {
                    Label("Failed in \(sector.name) after \(LapProgress.clock(progress.elapsed))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(StatusTone.critical.text)
                } else {
                    Text(progress.outcome == .cancelled ? "Cancelled after \(LapProgress.clock(progress.elapsed))" : "Failed").foregroundStyle(.secondary)
                }
                Spacer()
                if showsEstimate, let total = progress.reference?.total {
                    Text("usually done by \(LapProgress.clock(total))").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stepText(_ sector: LapProgress.Sector) -> String {
        let actual = LapProgress.clock(sector.actual ?? 0)
        guard sector.reference > 0 else { return "\(sector.name) · \(actual)" + (progress.reference == nil ? "" : " · new step") }
        return sector.isOverrun
            ? "\(sector.name) · usually \(LapProgress.clock(sector.reference)) · \(actual) now"
            : "\(sector.name) · \(actual) of usually \(LapProgress.clock(sector.reference))"
    }

    private var finishText: String {
        guard let reference = progress.reference else { return "First recorded run of this job" }
        let all = reference.totals + [progress.elapsed]
        let rank = all.filter { $0 < progress.elapsed }.count + 1
        let ordinal = rank == 1 ? "fastest" : rank == 2 ? "2nd fastest" : rank == 3 ? "3rd fastest" : "\(rank)th fastest"
        return "Finished in \(LapProgress.clock(progress.elapsed)) · \(ordinal) of \(all.count) runs"
    }
}

/// Details of one step, shown while the pointer rests on its sector.
struct SectorInspector: View {
    let sector: LapProgress.Sector
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(sector.name.isEmpty ? "Whole job" : sector.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(Self.summary(sector)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if !sector.history.isEmpty { HistoryStrip(history: sector.history, current: sector.actual, reference: sector.reference) }
        }
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(RunningManStyle.line))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    static func summary(_ sector: LapProgress.Sector) -> String {
        var parts: [String] = []
        if let actual = sector.actual { parts.append("this run \(LapProgress.clock(actual))") }
        if sector.reference > 0 { parts.append("usually \(LapProgress.clock(sector.reference))") }
        if let best = sector.history.min() { parts.append("best \(LapProgress.clock(best))") }
        if sector.isPersonalBest { parts.append("personal best") }
        return parts.isEmpty ? "Not reached yet" : parts.joined(separator: " · ")
    }
}

/// The step's recent durations as small bars, this run in the accent color.
struct HistoryStrip: View {
    let history: [Double]
    let current: Double?
    let reference: Double

    var body: some View {
        let values = Array(history.suffix(19)) + (current.map { [$0] } ?? [])
        let top = max(values.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                let isCurrent = current != nil && index == values.count - 1
                RoundedRectangle(cornerRadius: 1)
                    .fill(isCurrent ? RunningManStyle.accent : Color.secondary.opacity(0.45))
                    .frame(width: 4, height: max(2, 18 * CGFloat(value / top)))
            }
        }
        .frame(height: 18, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Every runner with a job on the track, as compact lanes on the Overview.
struct LapLanes: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let racing = model.runners.compactMap { snapshot in model.lapJob(for: snapshot.id).map { (snapshot, $0) } }
        if !racing.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "Running now") { EmptyView() }
                Surface(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(racing.enumerated()), id: \.element.0.id) { index, item in
                            if index > 0 { Divider().padding(.leading, 16) }
                            LapLaneRow(snapshot: item.0, job: item.1)
                        }
                    }
                }
            }
        }
    }
}

struct LapLaneRow: View {
    @Environment(AppModel.self) private var model
    let snapshot: RunnerSnapshot
    let job: RunnerJob

    var body: some View {
        let log = model.stepLogs[snapshot.id].flatMap { $0.jobID == job.id ? $0 : nil }
        let steps = log?.steps ?? []
        let finished = log?.isFinished ?? (job.finishedAt != nil)
        let reference = model.lapReference(for: job)
        Button {
            model.selectedRunnerID = snapshot.id
            model.section = .runners
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.runner.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(job.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(width: 160, alignment: .leading)
                LapTrack(job: job, steps: steps, isFinished: finished, reference: reference, style: .lane)
                TimelineView(.lapSeconds) { context in
                    LapReadout(progress: LapTrack.progress(job: job, steps: steps, isFinished: finished, reference: reference, now: context.date),
                               job: job, compact: true)
                }.frame(width: 76, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(snapshot.runner.name), \(job.name)")
        .accessibilityValue(laneValue(reference: reference, steps: steps, finished: finished))
        .accessibilityHint("Shows this runner")
    }

    private func laneValue(reference: LapReference?, steps: [JobStep], finished: Bool) -> String {
        let progress = LapTrack.progress(job: job, steps: steps, isFinished: finished, reference: reference, now: Date())
        switch progress.outcome {
        case .running: return reference == nil ? "Running for \(LapProgress.clock(progress.elapsed))" : LapProgress.describeLead(progress.lead)
        case .success: return "Finished in \(LapProgress.clock(progress.elapsed))"
        case .failure: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}
