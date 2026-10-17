import AppKit
import XCTest
import RunningManCore
@testable import RunningMan

final class DesignSystemTests: XCTestCase {
    private enum Appearance: CaseIterable { case light, dark }

    /// Small status text sits on cards, on the canvas (detail headers) and inside its own
    /// tinted capsule over either, so it must reach WCAG AA (4.5:1) on all of them.
    func testStatusAndAccentTextReachSmallTextContrastEverywhereTheyAppear() {
        let palette = RunningManStyle.Palette.self
        var texts = StatusTone.allCases.map { ("\($0)", $0.palette.text, $0.palette.fill) }
        texts.append(("accentText", palette.accentText, palette.accentText))
        for appearance in Appearance.allCases {
            var backgrounds = [("surface", rgb(palette.surface, appearance)), ("canvas", rgb(palette.canvas, appearance))]
            if appearance == .dark { backgrounds.append(("raised", rgb(palette.surfaceRaised, appearance))) }
            for (name, text, fill) in texts {
                for (backgroundName, background) in backgrounds {
                    let tinted = blend(rgb(fill, appearance), over: background, opacity: StatusTone.tintOpacity)
                    for (label, behind) in [(backgroundName, background), (backgroundName + " + tint", tinted)] {
                        let ratio = contrast(rgb(text, appearance), behind)
                        XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) on \(label) in \(appearance) mode is \(ratio):1")
                    }
                }
            }
        }
    }

    func testCardsStandOffTheCanvasInBothAppearances() {
        let palette = RunningManStyle.Palette.self
        for appearance in Appearance.allCases {
            let canvas = rgb(palette.canvas, appearance), surface = rgb(palette.surface, appearance)
            XCTAssertGreaterThan(contrast(canvas, surface), 1.08, "Cards blend into the canvas in \(appearance) mode")
        }
    }

    func testAdaptiveColorFollowsTheAppearance() throws {
        let tone = StatusTone.active.palette.text
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua)), darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        XCTAssertEqual(tone.resolved(for: aqua), tone.light)
        XCTAssertEqual(tone.resolved(for: darkAqua), tone.dark)
        let vibrantDark = try XCTUnwrap(NSAppearance(named: .vibrantDark))
        XCTAssertEqual(tone.resolved(for: vibrantDark), tone.dark, "Dark variants such as vibrant dark resolve to the dark value")
        // Increase Contrast uses its own appearances; they must keep their light or dark side.
        let highContrastLight = try XCTUnwrap(NSAppearance(named: .accessibilityHighContrastAqua))
        let highContrastDark = try XCTUnwrap(NSAppearance(named: .accessibilityHighContrastDarkAqua))
        XCTAssertEqual(tone.resolved(for: highContrastLight), tone.light)
        XCTAssertEqual(tone.resolved(for: highContrastDark), tone.dark)
    }

    /// Unknown blocks interruption, so it must not look like a runner that is merely
    /// stopped; busy must not look like the accent used for selection.
    func testStatesThatMeanDifferentThingsLookDifferent() {
        XCTAssertEqual(RunnerStatus.unknown.tone, .uncertain)
        XCTAssertEqual(RunnerStatus.stopped.tone, .neutral)
        XCTAssertEqual(RunnerStatus.disabled.tone, .neutral)
        XCTAssertEqual(RunnerStatus.busy.tone, .active)
        XCTAssertEqual(RunnerStatus.idle.tone, .positive)
        XCTAssertEqual(RunnerStatus.attention.tone, .warning)
        XCTAssertEqual(JobOutcome.running.tone, .active)
        XCTAssertEqual(JobOutcome.success.tone, .positive)
        XCTAssertEqual(JobOutcome.failure.tone, .critical)
        XCTAssertEqual(JobOutcome.cancelled.tone, .neutral)
        XCTAssertEqual(JobOutcome.unknown.tone, .uncertain)
        XCTAssertNotEqual(RunnerStatus.stopped.symbol, RunnerStatus.disabled.symbol)
        XCTAssertNotEqual(RunnerStatus.unknown.symbol, RunnerStatus.stopped.symbol)

        let pairs: [(String, AdaptiveColor, AdaptiveColor)] = [
            ("uncertain/neutral", StatusTone.uncertain.palette.text, StatusTone.neutral.palette.text),
            ("uncertain/warning", StatusTone.uncertain.palette.text, StatusTone.warning.palette.text),
            ("active/accent", StatusTone.active.palette.text, RunningManStyle.Palette.accentText),
            ("active/positive", StatusTone.active.palette.text, StatusTone.positive.palette.text)
        ]
        for appearance in Appearance.allCases {
            for (name, first, second) in pairs {
                let distance = hueDistance(rgb(first, appearance), rgb(second, appearance))
                XCTAssertGreaterThan(distance, 15, "\(name) hues are only \(distance) degrees apart in \(appearance) mode")
            }
        }
    }

    // MARK: - Color math (sRGB, WCAG 2.x relative luminance)

    private typealias RGB = (r: Double, g: Double, b: Double)

    private func rgb(_ color: AdaptiveColor, _ appearance: Appearance) -> RGB {
        let resolved = (appearance == .dark ? color.dark : color.light).usingColorSpace(.sRGB)!
        // Translucent values (hairlines) are not text colors; tests only pass opaque ones.
        XCTAssertEqual(resolved.alphaComponent, 1, accuracy: 0.001)
        return (Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent))
    }

    private func blend(_ top: RGB, over bottom: RGB, opacity: Double) -> RGB {
        (top.r * opacity + bottom.r * (1 - opacity), top.g * opacity + bottom.g * (1 - opacity), top.b * opacity + bottom.b * (1 - opacity))
    }

    private func luminance(_ color: RGB) -> Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }

    private func contrast(_ first: RGB, _ second: RGB) -> Double {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func hueDistance(_ first: RGB, _ second: RGB) -> Double {
        func hue(_ color: RGB) -> Double {
            let high = max(color.r, color.g, color.b), low = min(color.r, color.g, color.b), delta = high - low
            guard delta > 0.02 else { return -1 }
            let sector: Double
            if high == color.r { sector = ((color.g - color.b) / delta).truncatingRemainder(dividingBy: 6) }
            else if high == color.g { sector = (color.b - color.r) / delta + 2 }
            else { sector = (color.r - color.g) / delta + 4 }
            return (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
        }
        let a = hue(first), b = hue(second)
        // A gray has no hue; any chromatic color counts as clearly different from it.
        if a < 0 || b < 0 { return a == b ? 0 : 180 }
        let difference = abs(a - b)
        return min(difference, 360 - difference)
    }
}
