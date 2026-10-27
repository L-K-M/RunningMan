import AppKit
import RunningManCore
import SwiftUI

// The lap track: the running job's steps as sectors on a lane, sized by how long each step usually
// takes. A translucent ghost replays the usual run at constant speed; the live runner holds its pace
// inside a running step and surges to the boundary when the step finishes. Finished sectors are
// painted by their split, so a slow cache restore or a record build reads at a glance.

enum LapPalette {
    static let rail = AdaptiveColor(light: (0.875, 0.882, 0.898), dark: (0.205, 0.205, 0.225)).makeColor()
    static let railShade = AdaptiveColor(light: NSColor.black.withAlphaComponent(0.10), dark: NSColor.black.withAlphaComponent(0.35)).makeColor()
    static let railLight = AdaptiveColor(light: NSColor.white.withAlphaComponent(0.85), dark: NSColor.white.withAlphaComponent(0.06)).makeColor()
    static let laneLine = AdaptiveColor(light: NSColor.white.withAlphaComponent(0.95), dark: NSColor.white.withAlphaComponent(0.22)).makeColor()
    /// Timing screens paint a personal best purple; it is distinct from every status tone.
    static let personalBest = AdaptiveColor(light: (0.53, 0.25, 0.88), dark: (0.72, 0.52, 1.0)).makeColor()
    static let ghost = AdaptiveColor(light: (0.32, 0.34, 0.40), dark: (0.80, 0.82, 0.90)).makeColor()
    static let checker = AdaptiveColor(light: (0.13, 0.13, 0.15), dark: (0.92, 0.92, 0.95)).makeColor()
}

/// Positions on a track of a given width. Sectors are proportional to their reference time, but
/// each keeps a minimum width so a one-second step stays visible and clickable.
struct LapLayout {
    struct Span { let id: Int; let x: CGFloat; let width: CGFloat }

    let spans: [Span]
    let x0: CGFloat
    let x1: CGFloat
    private let starts: [Double]
    private let lengths: [Double]
    private let hasReference: Bool

    init(progress: LapProgress, width: CGFloat, startInset: CGFloat, endInset: CGFloat, minimumSector: CGFloat) {
        x0 = startInset
        x1 = max(startInset + 1, width - endInset)
        let hasReference = progress.total > 0
        self.hasReference = hasReference
        let sectors = progress.sectors
        // Without a reference every step gets the same share.
        let lengths = sectors.map { hasReference ? $0.reference : 1 }
        self.lengths = lengths
        var cumulative = 0.0
        starts = lengths.map { length in defer { cumulative += length }; return cumulative }
        let available = x1 - x0
        var widths = Array(repeating: CGFloat(0), count: sectors.count)
        if !sectors.isEmpty {
            // Give small sectors the minimum, then share the rest by reference time.
            var fixed = Set<Int>()
            // Each round fixes at least one more sector or stops, so this ends within count rounds.
            for _ in 0...sectors.count {
                let free = available - CGFloat(fixed.count) * minimumSector
                let freeLength = lengths.enumerated().filter { !fixed.contains($0.offset) }.reduce(0) { $0 + $1.element }
                var changed = false
                for index in sectors.indices where !fixed.contains(index) {
                    let width = freeLength > 0 ? free * CGFloat(lengths[index] / freeLength) : free / CGFloat(max(1, sectors.count - fixed.count))
                    if width < minimumSector { fixed.insert(index); changed = true }
                    widths[index] = width
                }
                for index in fixed { widths[index] = minimumSector }
                if !changed { break }
            }
            let sum = widths.reduce(0, +)
            if sum > 0 { widths = widths.map { $0 * available / sum } }
        }
        var cursor = x0
        spans = sectors.indices.map { index in
            defer { cursor += widths[index] }
            return Span(id: sectors[index].id, x: cursor, width: widths[index])
        }
    }

    /// The x of a track position in reference seconds; inside a sector it moves linearly.
    func x(for position: Double) -> CGFloat {
        guard let last = spans.last else { return x0 }
        for (index, span) in spans.enumerated() {
            let start = starts[index], length = lengths[index]
            if position < start + length || index == spans.count - 1 {
                guard length > 0 else { return span.x }
                let fraction = min(max((position - start) / length, 0), 1)
                return span.x + span.width * CGFloat(fraction)
            }
        }
        return last.x + last.width
    }

    /// The x of a position measured in sectors (index plus fraction), used without a reference.
    func x(sector index: Int, fraction: Double) -> CGFloat {
        guard spans.indices.contains(index) else { return spans.last.map { $0.x + $0.width } ?? x0 }
        return spans[index].x + spans[index].width * CGFloat(min(max(fraction, 0), 1))
    }

    func sector(at x: CGFloat) -> Int? {
        spans.first { x >= $0.x && x < $0.x + $0.width }?.id
    }
}

/// Something the user may want to hear or see called out.
enum LapEvent: Equatable {
    case split(seconds: Double, personalBest: Bool)
    case overtake
    case finished(LapProgress.Outcome)
}

/// Per-track animation state. It lives outside SwiftUI state because it changes every frame.
final class LapMotion {
    struct Particle { var x, y, vx, vy, spin: Double; let color: Int; let born: Date }

    private(set) var jobID: String?
    private(set) var shownLive: Double = 0
    private var velocity: Double = 0
    private var lastTarget: Double = 0
    private var lastFrame: Date?
    /// Set while the runner is clearly behind the ghost; a pass needs it first, so one pass is
    /// called out once however slowly the spring then glides past.
    private var wasBehind = false
    private var referenceID: String?
    private var finishedSectors: Set<Int> = []
    private var outcome: LapProgress.Outcome = .running
    private(set) var passedAt: Date?
    private(set) var passX: CGFloat = 0
    private(set) var finishedAt: Date?
    private(set) var surgingUntil: Date?
    private(set) var particles: [Particle] = []

    /// Advances the springs to `now` and reports what changed since the last frame. The first
    /// frame for a job only records where things stand, so opening a window mid-race is quiet.
    func update(_ progress: LapProgress, jobID: String, now: Date, reduceMotion: Bool, layout: LapLayout) -> [LapEvent] {
        let target = progress.total > 0 ? progress.live : 0
        guard self.jobID == jobID else {
            self.jobID = jobID
            shownLive = target; velocity = 0; lastFrame = now
            seed(progress)
            outcome = progress.outcome
            passedAt = nil; finishedAt = progress.isFinished ? .distantPast : nil; surgingUntil = nil; particles = []
            return []
        }
        // Another ghost moves every sector and the gap at once; the spring carries the runner to
        // its new place, but nothing it passes on the way happened in the race.
        if Self.identity(of: progress.reference) != referenceID { seed(progress) }
        // Frames can be an eighth of a second apart, so the spring runs in small steps to stay stable.
        var remaining = min(max(now.timeIntervalSince(lastFrame ?? now), 0), 0.5)
        lastFrame = now
        lastTarget = target
        if reduceMotion {
            shownLive = target; velocity = 0
        } else {
            // A spring with a 0.5 s response and slight overshoot carries the surge after a step.
            let stiffness = 158.0, damping = 20.0
            while remaining > 0 {
                let dt = min(remaining, 1.0 / 120)
                remaining -= dt
                let acceleration = stiffness * (target - shownLive) - damping * velocity
                velocity += acceleration * dt
                shownLive += velocity * dt
            }
            if abs(target - shownLive) < 0.001 && abs(velocity) < 0.01 { shownLive = target; velocity = 0 }
        }
        var events: [LapEvent] = []
        for sector in progress.sectors where !finishedSectors.contains(sector.id) {
            guard case .finished(let stepOutcome) = sector.state else { continue }
            finishedSectors.insert(sector.id)
            if stepOutcome == .success, let split = sector.split {
                events.append(.split(seconds: split, personalBest: sector.isPersonalBest))
                if split < -LapProgress.splitThreshold { surgingUntil = now.addingTimeInterval(0.7) }
            }
        }
        // Judged on the race, not the spring, so overshoot cannot fake a pass and a slow glide
        // cannot miss one. A ghost waiting at the line is caught, not passed.
        if progress.total > 0, progress.outcome == .running || progress.outcome == .success {
            if progress.ghost - progress.live > Self.behind {
                wasBehind = true
            } else if wasBehind, progress.live >= progress.ghost, progress.ghost < progress.total {
                wasBehind = false
                events.append(.overtake)
                passedAt = now
                passX = layout.x(for: progress.ghost)
            }
        }
        if outcome == .running, progress.outcome != .running {
            events.append(.finished(progress.outcome))
            finishedAt = now
            if progress.outcome == .success, !reduceMotion { burst(at: Double(layout.x1), now: now, seed: jobID.hashValue) }
        }
        outcome = progress.outcome
        particles = particles.filter { now.timeIntervalSince($0.born) < 1.4 }
        return events
    }

    private func burst(at x: Double, now: Date, seed: Int) {
        var generator = SplitMix(seed: UInt64(bitPattern: Int64(seed)))
        particles = (0..<22).map { index in
            let angle = Double.pi * (0.55 + 0.9 * generator.unit())
            let speed = 70 + 110 * generator.unit()
            return Particle(x: x, y: 0, vx: cos(angle) * speed, vy: -sin(angle) * speed, spin: (generator.unit() - 0.5) * 14,
                            color: index % 4, born: now)
        }
    }

    /// How far behind the ghost counts as behind, in reference seconds.
    private static let behind = 0.4

    /// Takes the race as it stands without calling anything out.
    private func seed(_ progress: LapProgress) {
        referenceID = Self.identity(of: progress.reference)
        wasBehind = progress.total > 0 && progress.ghost - progress.live > Self.behind
        finishedSectors = Set(progress.sectors.filter { if case .finished = $0.state { return true } else { return false } }.map(\.id))
    }

    private static func identity(of reference: LapReference?) -> String? {
        reference.map { "\($0.pace.rawValue) \($0.runs) \($0.total) \($0.sectors.count)" }
    }

    func surging(at now: Date) -> Bool { surgingUntil.map { now < $0 } ?? false }

    /// A finished race whose finish has played out draws the same frame from then on.
    func isSettled(at now: Date) -> Bool {
        outcome != .running && particles.isEmpty && shownLive == lastTarget && !wantsSmoothFrames(at: now)
    }

    /// Smooth frames are needed only while something moves quickly: the surge spring, the
    /// overtake glint, the finish. Otherwise the track ticks like the menu bar figure.
    func wantsSmoothFrames(at now: Date) -> Bool {
        // In a running step the target creeps at the ghost's speed and the spring follows it
        // closely; only a real jump, such as the surge after a step, needs smooth frames.
        if abs(lastTarget - shownLive) > 0.5 { return true }
        if let passedAt, now.timeIntervalSince(passedAt) < 0.7 { return true }
        if let finishedAt, now.timeIntervalSince(finishedAt) < 1.5 { return true }
        return surging(at: now)
    }
}

/// A small deterministic generator, so a finish looks the same each time it is replayed.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

struct LapTrack: View {
    enum Style { case full, lane }

    let job: RunnerJob
    let steps: [JobStep]
    let isFinished: Bool
    let reference: LapReference?
    var style: Style = .full
    var selectedSector: Int?
    var onEvent: ((LapEvent) -> Void)?

    @State private var motion = LapMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var colorScheme

    static func height(for style: Style) -> CGFloat { style == .full ? 62 : 26 }

    var body: some View {
        let frame = LapFrame(job: job, steps: steps, isFinished: isFinished, reference: reference, style: style,
                             selectedSector: selectedSector, onEvent: onEvent, motion: motion,
                             reduceMotion: reduceMotion, colorScheme: colorScheme)
        // Eight frames a second like a sprite, smooth only during a surge, a pass or a finish;
        // slower while the window is in the background, and once a second with Reduce Motion.
        let calm: Double = reduceMotion ? 1 : (activeState == .inactive ? 0.5 : 1.0 / 8)
        LapFrameHost(frame: frame, calm: calm, smooth: !reduceMotion && activeState != .inactive)
            .frame(height: Self.height(for: style))
            .accessibilityHidden(true)
    }

    static func progress(job: RunnerJob, steps: [JobStep], isFinished: Bool, reference: LapReference?, now: Date) -> LapProgress {
        LapProgress.make(steps: steps, reference: reference, jobStarted: steps.first?.startedAt ?? job.startedAt, isFinished: isFinished,
                         jobOutcome: job.outcome, now: now)
    }

    static func layout(progress: LapProgress, width: CGFloat, style: Style) -> LapLayout {
        style == .full
            ? LapLayout(progress: progress, width: width, startInset: 12, endInset: 22, minimumSector: 5)
            : LapLayout(progress: progress, width: width, startInset: 8, endInset: 12, minimumSector: 3)
    }
}

/// Puts the track's frames in an AppKit view with its own timer. Driven by a SwiftUI timeline,
/// every frame laid out the whole window: about a fifth of a core at eight frames a second.
private struct LapFrameHost: NSViewRepresentable {
    let frame: LapFrame
    let calm: TimeInterval
    let smooth: Bool

    func makeNSView(context: Context) -> LapFrameView { LapFrameView() }

    func updateNSView(_ view: LapFrameView, context: Context) {
        view.template = frame
        view.calm = calm
        view.smooth = smooth
        view.needsDisplay = true
    }
}

/// Renders `LapFrame` into its layer and asks for the next frame only as soon as the motion
/// needs one. Clicks, hover and accessibility belong to the SwiftUI view around it.
private final class LapFrameView: NSView {
    var template: LapFrame?
    var calm: TimeInterval = 1.0 / 8
    var smooth = true
    private var renderer: ImageRenderer<LapFrame>?
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        if window != nil { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard var content = template, bounds.width > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let now = Date()
        content.now = now
        content.size = bounds.size
        if let renderer { renderer.content = content } else { renderer = ImageRenderer(content: content) }
        let scale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            renderer?.render(rasterizationScale: scale) { _, render in render(context) }
        }
        scheduleFrame(after: now)
    }

    private func scheduleFrame(after now: Date) {
        timer?.invalidate()
        timer = nil
        // A settled track redraws only when SwiftUI hands it something new.
        guard let window, template?.motion.isSettled(at: now) != true else { return }
        let fast = smooth && template?.motion.wantsSmoothFrames(at: now) == true
        let interval = !window.occlusionState.contains(.visible) ? 1 : fast ? 1.0 / 60 : calm
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// One frame of the track at `now`, drawn with Canvas.
private struct LapFrame: View {
    typealias Style = LapTrack.Style

    let job: RunnerJob
    let steps: [JobStep]
    let isFinished: Bool
    let reference: LapReference?
    let style: Style
    let selectedSector: Int?
    let onEvent: ((LapEvent) -> Void)?
    let motion: LapMotion
    let reduceMotion: Bool
    let colorScheme: ColorScheme
    var now = Date.distantPast
    var size = CGSize.zero

    private enum Symbol: Hashable { case run, ghost, stand, finish, fall }

    var body: some View {
        Canvas { context, size in
            let progress = LapTrack.progress(job: job, steps: steps, isFinished: isFinished, reference: reference, now: now)
            let layout = LapTrack.layout(progress: progress, width: size.width, style: style)
            let events = motion.update(progress, jobID: job.id, now: now, reduceMotion: reduceMotion, layout: layout)
            if !events.isEmpty, let onEvent { DispatchQueue.main.async { events.forEach(onEvent) } }
            draw(&context, size: size, progress: progress, layout: layout, now: now)
        } symbols: {
            let size: CGFloat = style == .full ? 23 : 13
            Image(systemName: "figure.run").font(.system(size: size, weight: .semibold)).foregroundStyle(RunningManStyle.accent).tag(Symbol.run)
            Image(systemName: "figure.run").font(.system(size: size, weight: .semibold)).foregroundStyle(LapPalette.ghost).tag(Symbol.ghost)
            Image(systemName: "figure.stand").font(.system(size: size, weight: .semibold)).foregroundStyle(RunningManStyle.accent).tag(Symbol.stand)
            Image(systemName: "figure.arms.open").font(.system(size: size, weight: .semibold)).foregroundStyle(StatusTone.positive.text).tag(Symbol.finish)
            Image(systemName: "figure.fall").font(.system(size: size, weight: .semibold)).foregroundStyle(StatusTone.critical.text).tag(Symbol.fall)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, colorScheme)
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize, progress: LapProgress, layout: LapLayout, now: Date) {
        let full = style == .full
        let railY: CGFloat = full ? 27 : 15
        let railHeight: CGFloat = full ? 12 : 6
        let rail = CGRect(x: layout.x0 - (full ? 6 : 4), y: railY, width: layout.x1 - layout.x0 + (full ? 6 : 4), height: railHeight)
        let shape = RoundedRectangle(cornerRadius: railHeight / 2, style: .continuous)

        // The lane: a recessed strip with a light lower lip.
        context.fill(shape.path(in: rail.offsetBy(dx: 0, dy: 1)), with: .color(LapPalette.railLight))
        context.fill(shape.path(in: rail), with: .color(LapPalette.rail))
        context.stroke(shape.path(in: rail.insetBy(dx: 0.5, dy: 0.5)), with: .color(LapPalette.railShade), lineWidth: 1)

        // Paint behind the runner: each finished sector by its split, the running one as it goes.
        var clipped = context
        clipped.clip(to: shape.path(in: rail))
        let liveX = progress.total > 0 ? layout.x(for: motion.shownLive) : noReferenceX(progress, layout: layout, now: now)
        for (sector, span) in zip(progress.sectors, layout.spans) {
            let band = CGRect(x: span.x, y: rail.minY, width: span.width, height: rail.height)
            switch sector.state {
            case .finished(let outcome):
                // A failed step is painted only as far as the run got.
                let painted = outcome == .failure ? CGRect(x: band.minX, y: band.minY, width: max(2, min(liveX, band.maxX) - band.minX), height: band.height) : band
                clipped.fill(Path(painted), with: .color(paint(for: sector, outcome: outcome)))
                if outcome == .failure { hatch(&clipped, painted, color: .white.opacity(0.45)) }
            case .running:
                let painted = CGRect(x: span.x, y: band.minY, width: max(0, min(liveX, span.x + span.width) - span.x), height: band.height)
                clipped.fill(Path(painted), with: .color(StatusTone.active.fill.opacity(0.55)))
                if sector.isOverrun {
                    hatch(&clipped, band, color: StatusTone.warning.fill.opacity(0.75))
                } else if !reduceMotion, painted.width > 6 {
                    // A soft sheen travels along the painted part of the running step.
                    let phase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    let sheenX = painted.minX + painted.width * CGFloat(phase)
                    let sheen = CGRect(x: sheenX - 14, y: band.minY, width: 28, height: band.height)
                    clipped.fill(Path(sheen), with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.35), .white.opacity(0)]),
                                                                     startPoint: CGPoint(x: sheen.minX, y: 0), endPoint: CGPoint(x: sheen.maxX, y: 0)))
                }
            case .upcoming:
                if full {
                    var dash = Path(); dash.move(to: CGPoint(x: span.x + 2, y: band.midY)); dash.addLine(to: CGPoint(x: span.x + span.width - 2, y: band.midY))
                    clipped.stroke(dash, with: .color(LapPalette.laneLine.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
            }
        }
        if progress.outcome != .running, progress.outcome != .success {
            // Beyond a failure the lane goes quiet.
            let stopX = liveX + 2
            clipped.fill(Path(CGRect(x: stopX, y: rail.minY, width: rail.maxX - stopX, height: rail.height)), with: .color(LapPalette.rail.opacity(0.55)))
        }

        // Step boundaries as painted lane marks.
        for span in layout.spans.dropFirst() {
            var mark = Path(); mark.move(to: CGPoint(x: span.x, y: rail.minY)); mark.addLine(to: CGPoint(x: span.x, y: rail.maxY))
            clipped.stroke(mark, with: .color(LapPalette.laneLine), lineWidth: full ? 1.5 : 1)
        }
        if let selectedSector, let span = layout.spans.first(where: { $0.id == selectedSector }) {
            let outline = CGRect(x: span.x, y: rail.minY - 2, width: span.width, height: rail.height + 4)
            context.stroke(RoundedRectangle(cornerRadius: 4).path(in: outline), with: .color(RunningManStyle.accent), lineWidth: 1.5)
        }

        drawFinish(&context, layout: layout, rail: rail, progress: progress, now: now)
        if full { drawSplits(&context, progress: progress, layout: layout, below: rail.maxY + 3) }
        drawGhost(&context, progress: progress, layout: layout, railTop: rail.minY, now: now)
        drawRunner(&context, progress: progress, x: liveX, railTop: rail.minY, now: now)
        drawPass(&context, railTop: rail.minY, now: now)
        drawParticles(&context, railTop: rail.minY, now: now)
    }

    /// Without a reference the runner moves sector by sector, easing into the running step.
    private func noReferenceX(_ progress: LapProgress, layout: LapLayout, now: Date) -> CGFloat {
        guard let current = progress.currentSector else {
            return progress.outcome == .success ? layout.x1 : layout.x(sector: progress.sectors.count, fraction: 0)
        }
        let inStep = progress.sectors[current].actual ?? 0
        return layout.x(sector: current, fraction: 0.85 * (1 - exp(-inStep / 40)))
    }

    private func paint(for sector: LapProgress.Sector, outcome: JobStepOutcome) -> Color {
        switch outcome {
        case .failure: return StatusTone.critical.fill
        case .cancelled, .skipped, .unknown, .running: return StatusTone.neutral.fill.opacity(0.35)
        case .success:
            // Done is green: on pace a soft green, faster a full one, slower orange, a best purple.
            if sector.isPersonalBest { return LapPalette.personalBest.opacity(0.85) }
            guard let split = sector.split else { return StatusTone.positive.fill.opacity(0.4) }
            if split < 0 { return StatusTone.positive.fill.opacity(0.9) }
            if split > 0 { return StatusTone.warning.fill.opacity(0.85) }
            return StatusTone.positive.fill.opacity(0.4)
        }
    }

    private func hatch(_ context: inout GraphicsContext, _ rect: CGRect, color: Color) {
        var lines = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            lines.move(to: CGPoint(x: x, y: rect.maxY)); lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 4
        }
        var local = context
        local.clip(to: Path(rect))
        local.stroke(lines, with: .color(color), lineWidth: 1.2)
    }

    private func drawFinish(_ context: inout GraphicsContext, layout: LapLayout, rail: CGRect, progress: LapProgress, now: Date) {
        let full = style == .full
        let square: CGFloat = full ? 4 : 3
        let columns = 2, rows = Int((rail.height / square).rounded(.down))
        let origin = CGPoint(x: layout.x1 + 2, y: rail.minY + (rail.height - CGFloat(rows) * square) / 2)
        for row in 0..<rows {
            for column in 0..<columns where (row + column).isMultiple(of: 2) {
                context.fill(Path(CGRect(x: origin.x + CGFloat(column) * square, y: origin.y + CGFloat(row) * square, width: square, height: square)),
                             with: .color(LapPalette.checker))
            }
        }
        context.stroke(Path(CGRect(x: origin.x, y: origin.y, width: square * CGFloat(columns), height: square * CGFloat(rows))),
                       with: .color(LapPalette.checker.opacity(0.5)), lineWidth: 0.5)
        guard full else { return }
        // The finish tape: intact while the job runs, snapped when it succeeds.
        let tapeX = layout.x1
        let top = rail.minY - 18, bottom = rail.minY
        let tape = StatusTone.positive.text
        if progress.outcome == .success, let finished = motion.finishedAt {
            let age = now.timeIntervalSince(finished)
            guard age < 0.9, !reduceMotion else { return }
            let t = age / 0.9
            let middle = (top + bottom) / 2
            for (anchor, end, turn) in [(top, middle, 1.0), (bottom, middle, -1.0)] {
                var piece = Path()
                let angle = turn * (.pi / 2.6) * t
                let length = abs(end - anchor)
                let direction = end > anchor ? 1.0 : -1.0
                piece.move(to: CGPoint(x: tapeX, y: anchor))
                piece.addLine(to: CGPoint(x: tapeX + CGFloat(sin(angle) * length), y: anchor + CGFloat(direction * cos(angle) * length) + CGFloat(20 * t * t)))
                context.stroke(piece, with: .color(tape.opacity(1 - t)), lineWidth: 1.5)
            }
        } else if progress.outcome == .running {
            var line = Path(); line.move(to: CGPoint(x: tapeX, y: top)); line.addLine(to: CGPoint(x: tapeX, y: bottom))
            context.stroke(line, with: .color(tape.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
        }
    }

    private func drawSplits(_ context: inout GraphicsContext, progress: LapProgress, layout: LapLayout, below y: CGFloat) {
        for (sector, span) in zip(progress.sectors, layout.spans) {
            guard case .finished(.success) = sector.state, let split = sector.split else { continue }
            let center = CGPoint(x: span.x + span.width / 2, y: y + 8)
            let color: Color = sector.isPersonalBest ? LapPalette.personalBest : split < 0 ? StatusTone.positive.text : split > 0 ? StatusTone.warning.text : .secondary
            let seconds = Int(abs(split).rounded())
            let label = sector.isPersonalBest ? "PB" : seconds == 0 ? "" : (split < 0 ? "−" : "+") + "\(seconds)s"
            if span.width >= 26, !label.isEmpty {
                context.draw(Text(label).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(color), at: center)
            } else if seconds != 0 || sector.isPersonalBest {
                context.fill(Path(ellipseIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)), with: .color(color))
            }
        }
    }

    private func figureOrigin(_ symbol: GraphicsContext.ResolvedSymbol, x: CGFloat, railTop: CGFloat) -> CGPoint {
        CGPoint(x: x, y: railTop + 1 - symbol.size.height / 2)
    }

    private func drawGhost(_ context: inout GraphicsContext, progress: LapProgress, layout: LapLayout, railTop: CGFloat, now: Date) {
        guard progress.total > 0, let ghost = context.resolveSymbol(id: Symbol.ghost) else { return }
        let x = layout.x(for: progress.ghost)
        let center = figureOrigin(ghost, x: x, railTop: railTop)
        let base = style == .full ? 0.34 : 0.4
        // Afterimages trail the ghost while it moves, unless the runner is beside it, where they
        // would read as the runner's own motion blur.
        let runnerX = layout.x(for: motion.shownLive)
        if progress.ghost < progress.total, !reduceMotion, abs(x - runnerX) > ghost.size.width * 1.2 {
            for (offset, opacity) in [(9.0, 0.06), (4.5, 0.13)] {
                var trail = context
                trail.opacity = opacity
                trail.draw(ghost, at: CGPoint(x: center.x - CGFloat(offset), y: center.y))
            }
        }
        var main = context
        main.opacity = base
        main.draw(ghost, at: CGPoint(x: center.x, y: center.y + bob(now, phaseShift: 0.125)))
    }

    private func drawRunner(_ context: inout GraphicsContext, progress: LapProgress, x: CGFloat, railTop: CGFloat, now: Date) {
        let symbolID: Symbol
        switch progress.outcome {
        case .running: symbolID = progress.sectors.isEmpty ? .stand : .run
        case .success: symbolID = .finish
        case .failure: symbolID = .fall
        case .cancelled: symbolID = .stand
        }
        guard let figure = context.resolveSymbol(id: symbolID) else { return }
        var center = figureOrigin(figure, x: x, railTop: railTop)
        var local = context
        if progress.outcome == .running {
            center.y += bob(now, phaseShift: 0)
            if motion.surging(at: now), !reduceMotion {
                // Speed lines behind a runner that just finished a step early.
                let length: CGFloat = style == .full ? 9 : 5
                for (row, height) in [0.25, 0.5, 0.72].enumerated() {
                    let y = center.y - figure.size.height / 2 + figure.size.height * CGFloat(height)
                    let start = center.x - figure.size.width / 2 - 2 - CGFloat(row % 2) * 3
                    var line = Path(); line.move(to: CGPoint(x: start - length, y: y)); line.addLine(to: CGPoint(x: start, y: y))
                    local.stroke(line, with: .color(RunningManStyle.accent.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
            if !reduceMotion {
                // Two stride poses, alternating four times a second.
                let tilt = stride(now) ? 0.06 : -0.03
                local.translateBy(x: center.x, y: center.y)
                local.rotate(by: .radians(tilt))
                local.translateBy(x: -center.x, y: -center.y)
            }
        } else if progress.outcome == .failure {
            local.translateBy(x: center.x, y: center.y)
            local.rotate(by: .degrees(-12))
            local.translateBy(x: -center.x, y: -center.y)
        }
        // A soft contact shadow under the feet, drawn as a shape: a blur filter per frame costs too much.
        let shadow = CGRect(x: center.x - figure.size.width * 0.32, y: railTop - 1.5, width: figure.size.width * 0.64, height: 3)
        context.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.14)))
        local.draw(figure, at: center)
    }

    /// Which of two stride poses to show; the ghost runs half a stride out of step.
    private func stride(_ now: Date, phaseShift: Double = 0) -> Bool {
        Int((now.timeIntervalSinceReferenceDate + phaseShift) * 8).isMultiple(of: 2)
    }

    private func bob(_ now: Date, phaseShift: Double) -> CGFloat {
        guard !reduceMotion else { return 0 }
        return stride(now, phaseShift: phaseShift) ? -(style == .full ? 1.5 : 1) : 0
    }

    private func drawPass(_ context: inout GraphicsContext, railTop: CGFloat, now: Date) {
        guard let passed = motion.passedAt, !reduceMotion else { return }
        let age = now.timeIntervalSince(passed)
        guard age < 0.6 else { return }
        let t = age / 0.6
        let center = CGPoint(x: motion.passX, y: railTop - (style == .full ? 12 : 7))
        let radius = CGFloat(4 + 10 * t)
        var rays = Path()
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4
            rays.move(to: CGPoint(x: center.x + CGFloat(cos(angle)) * radius * 0.45, y: center.y + CGFloat(sin(angle)) * radius * 0.45))
            rays.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius))
        }
        context.stroke(rays, with: .color(LapPalette.personalBest.opacity(1 - t)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    private func drawParticles(_ context: inout GraphicsContext, railTop: CGFloat, now: Date) {
        let colors: [Color] = [RunningManStyle.accent, StatusTone.positive.fill, LapPalette.personalBest, StatusTone.warning.fill]
        for particle in motion.particles {
            let age = now.timeIntervalSince(particle.born)
            let x = particle.x + particle.vx * age
            let y = Double(railTop) - 6 + particle.vy * age + 0.5 * 260 * age * age
            var local = context
            local.opacity = max(0, 1 - age / 1.4)
            local.translateBy(x: CGFloat(x), y: CGFloat(y))
            local.rotate(by: .radians(particle.spin * age))
            local.fill(Path(CGRect(x: -2, y: -1, width: 4, height: 2)), with: .color(colors[particle.color]))
        }
    }
}
