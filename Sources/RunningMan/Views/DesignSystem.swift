import AppKit
import SwiftUI
import RunningManCore

/// A color with separate light and dark values. AppKit resolves it per view, so it
/// follows the window's appearance without any observation.
struct AdaptiveColor {
    let light: NSColor
    let dark: NSColor

    init(light: NSColor, dark: NSColor) {
        self.light = light
        self.dark = dark
    }

    /// sRGB components from 0 to 1.
    init(light: (Double, Double, Double), dark: (Double, Double, Double)) {
        self.init(light: NSColor(srgbRed: light.0, green: light.1, blue: light.2, alpha: 1),
                  dark: NSColor(srgbRed: dark.0, green: dark.1, blue: dark.2, alpha: 1))
    }

    func resolved(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }

    /// Build once and keep it: two dynamic colors built separately never compare equal,
    /// so a color made during a render would look like a style change to SwiftUI.
    func makeColor() -> Color {
        let palette = self
        return Color(nsColor: NSColor(name: nil) { palette.resolved(for: $0) })
    }
}

enum RunningManStyle {
    /// Interactive tint: prominent buttons, switches, selection and links.
    static let accent = Color.indigo
    /// The accent for small text and symbols; lighter than system indigo in dark mode,
    /// where indigo on a dark surface is below 4.5:1.
    static let accentText = Palette.accentText.makeColor()
    static let canvas = Palette.canvas.makeColor()
    static let surface = Palette.surface.makeColor()
    /// Selected or floating cards; matches `surface` in light mode.
    static let surfaceRaised = Palette.surfaceRaised.makeColor()
    static let line = Palette.line.makeColor()
    /// Light mode only; dark cards stand off the canvas by tone alone.
    static let cardShadow = Palette.cardShadow.makeColor()

    /// Raw values, kept apart from the SwiftUI colors so tests can check contrast.
    enum Palette {
        static let canvas = AdaptiveColor(light: (0.953, 0.957, 0.965), dark: (0.086, 0.086, 0.094))
        static let surface = AdaptiveColor(light: (1, 1, 1), dark: (0.133, 0.133, 0.145))
        static let surfaceRaised = AdaptiveColor(light: (1, 1, 1), dark: (0.165, 0.165, 0.180))
        static let line = AdaptiveColor(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.09))
        static let cardShadow = AdaptiveColor(light: NSColor.black.withAlphaComponent(0.05), dark: .clear)
        static let accentText = AdaptiveColor(light: (0.31, 0.29, 0.79), dark: (0.62, 0.60, 1.0))
    }
}

/// What a state means, whatever it describes. Runner statuses, job outcomes and cleanup
/// results map onto these, so one color always means one thing.
enum StatusTone: CaseIterable {
    /// Idle runners and successful jobs or cleanups.
    case positive
    /// Busy runners and running jobs; kept distinct from the indigo accent.
    case active
    /// Needs attention, partial results, queued work.
    case warning
    /// Failed jobs and failed cleanups.
    case critical
    /// Stopped, disabled, cancelled and skipped.
    case neutral
    /// Unknown state. It blocks interruption, so it must not look like stopped.
    case uncertain

    /// The opacity of the tone's tinted backgrounds; `text` keeps 4.5:1 on top of it.
    static let tintOpacity = 0.12

    /// Text, symbols and thin strokes: at least 4.5:1 on surfaces, on the canvas and
    /// on this tone's tint over either.
    var text: Color { Self.colors[self]?.text ?? palette.text.makeColor() }
    /// Bars, dots and tinted backgrounds.
    var fill: Color { Self.colors[self]?.fill ?? palette.fill.makeColor() }

    var palette: (text: AdaptiveColor, fill: AdaptiveColor) {
        switch self {
        case .positive:
            return (AdaptiveColor(light: (0.02, 0.43, 0.41), dark: (0.30, 0.78, 0.74)),
                    AdaptiveColor(light: (0.10, 0.60, 0.57), dark: (0.25, 0.72, 0.68)))
        case .active:
            return (AdaptiveColor(light: (0.00, 0.40, 0.69), dark: (0.38, 0.73, 1.00)),
                    AdaptiveColor(light: (0.04, 0.53, 0.86), dark: (0.30, 0.66, 1.00)))
        case .warning:
            return (AdaptiveColor(light: (0.64, 0.30, 0.00), dark: (1.00, 0.64, 0.26)),
                    AdaptiveColor(light: (0.96, 0.52, 0.00), dark: (1.00, 0.60, 0.12)))
        case .critical:
            return (AdaptiveColor(light: (0.76, 0.10, 0.10), dark: (1.00, 0.50, 0.47)),
                    AdaptiveColor(light: (0.90, 0.20, 0.18), dark: (1.00, 0.36, 0.33)))
        case .neutral:
            return (AdaptiveColor(light: (0.38, 0.38, 0.41), dark: (0.65, 0.65, 0.69)),
                    AdaptiveColor(light: (0.55, 0.55, 0.58), dark: (0.52, 0.52, 0.56)))
        case .uncertain:
            return (AdaptiveColor(light: (0.46, 0.38, 0.00), dark: (0.88, 0.76, 0.30)),
                    AdaptiveColor(light: (0.78, 0.62, 0.04), dark: (0.82, 0.68, 0.18)))
        }
    }

    private static let colors: [StatusTone: (text: Color, fill: Color)] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, ($0.palette.text.makeColor(), $0.palette.fill.makeColor())) })
}

extension RunnerStatus {
    var tone: StatusTone {
        switch self {
        case .idle: return .positive
        case .busy: return .active
        case .stopped, .disabled: return .neutral
        case .attention: return .warning
        case .unknown: return .uncertain
        }
    }
    /// Safe for small text; see `StatusTone.text`.
    var color: Color { tone.text }
    var symbol: String {
        switch self {
        case .idle: return "checkmark.circle.fill"
        case .busy: return "arrow.triangle.2.circlepath"
        case .stopped: return "stop.circle.fill"
        case .disabled: return "pause.circle"
        case .attention: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

extension JobOutcome {
    var tone: StatusTone {
        switch self {
        case .running: return .active
        case .success: return .positive
        case .failure: return .critical
        case .cancelled: return .neutral
        case .unknown: return .uncertain
        }
    }
    /// Safe for small text; see `StatusTone.text`.
    var color: Color { tone.text }
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

extension RunnerProvider {
    /// A typographic mark, not a logo.
    var monogram: String { self == .github ? "GH" : "FJ" }
}

/// A runner's tile: provider monogram tinted by status, with a lock for system
/// services, which RunningMan only observes.
struct RunnerGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let runner: InstalledRunner
    let status: RunnerStatus
    var size: CGFloat = 34

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Text(runner.provider.monogram)
            .font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
            .foregroundStyle(status.color)
            .frame(width: size, height: size)
            .background(status.tone.fill.opacity(0.14), in: shape)
            .overlay(shape.strokeBorder(status.tone.fill.opacity(0.22)))
            .overlay(alignment: .bottomTrailing) {
                if runner.serviceDomain == .system { lockBadge }
            }
            .animation(reduceMotion ? nil : .snappy, value: status)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(runner.provider.title + (runner.serviceDomain == .system ? " runner, system service, read-only" : " runner"))
    }

    private var lockBadge: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: max(7, size * 0.22), weight: .bold))
            .foregroundStyle(StatusTone.neutral.text)
            .frame(width: size * 0.44, height: size * 0.44)
            .background(Circle().fill(RunningManStyle.surfaceRaised))
            .overlay(Circle().strokeBorder(RunningManStyle.line))
            .offset(x: size * 0.14, y: size * 0.14)
            .help(SystemServiceBadge.explanation)
    }
}

/// Marks a runner supervised by a system LaunchDaemon.
struct SystemServiceBadge: View {
    static let explanation = "System service, monitored read-only"
    var body: some View {
        Text("System")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(StatusTone.neutral.text)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill(StatusTone.neutral.fill.opacity(0.10)))
            .overlay(Capsule().strokeBorder(RunningManStyle.line))
            .help(Self.explanation)
            .accessibilityLabel(Self.explanation)
    }
}

/// One headline figure with its explanation. Put tiles in an HStack with
/// `.fixedSize(horizontal: false, vertical: true)` so a row shares one height.
struct MetricTile: View {
    let title: String
    let value: String
    let footnote: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 3)
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint)
            }
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .numericValueTransition(value).padding(.top, 8)
            Text(footnote).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

/// The title block of a sheet.
struct SheetHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(RunningManStyle.accentText)
                .frame(width: 44, height: 44)
                .background(RunningManStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// The card treatment: surface fill, hairline, and a faint shadow in light mode.
    /// A selected card is raised and outlined in the accent.
    func cardStyle(cornerRadius: CGFloat = 14, isSelected: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            // The shadow belongs to the shape only, so text inside never casts one.
            shape.fill(isSelected ? RunningManStyle.surfaceRaised : RunningManStyle.surface)
                .shadow(color: RunningManStyle.cardShadow, radius: 2, y: 1)
        }
        .overlay(shape.strokeBorder(isSelected ? RunningManStyle.accent : RunningManStyle.line, lineWidth: isSelected ? 1.5 : 1))
    }

    /// Bounces a symbol once when its busy state changes, and stays still with Reduce Motion.
    /// A repeating effect kept the window redrawing for as long as a job ran: about 20% of a
    /// core with two busy runners in a release build, against 3% without it.
    func busySymbolEffect(_ isBusy: Bool) -> some View {
        modifier(BusySymbolEffect(isBusy: isBusy))
    }

    /// Rolls changed digits instead of swapping the whole figure.
    func numericValueTransition<Value: Equatable>(_ value: Value) -> some View {
        modifier(NumericValueTransition(value: value))
    }
}

private struct BusySymbolEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isBusy: Bool
    func body(content: Content) -> some View {
        content.symbolEffect(.bounce, value: isBusy).symbolEffectsRemoved(reduceMotion)
    }
}

private struct NumericValueTransition<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    func body(content: Content) -> some View {
        content.contentTransition(.numericText()).animation(reduceMotion ? nil : .snappy, value: value)
    }
}
