import AppKit
import Observation
import RunningManCore
import SwiftUI

/// What the menu bar item says about the fleet.
struct MenuBarStatus: Equatable {
    enum Figure: Equatable {
        /// Nothing installed, or every runner stopped or disabled.
        case standing
        /// Runners are online and none reports a job.
        case ready
        /// At least one runner is running a job.
        case running
        /// A runner needs attention. It outranks busy: a busy runner looks after itself.
        case fallen
    }

    var online = 0
    var busy = 0
    var attention = 0

    init(online: Int = 0, busy: Int = 0, attention: Int = 0) {
        self.online = online
        self.busy = busy
        self.attention = attention
    }

    init(runners: [RunnerSnapshot]) {
        online = runners.filter(\.isOnline).count
        busy = runners.filter { $0.status == .busy }.count
        attention = runners.filter(\.needsAttention).count
    }

    var figure: Figure {
        if attention > 0 { return .fallen }
        if busy > 0 { return .running }
        return online > 0 ? .ready : .standing
    }

    var accessibilityLabel: String {
        switch figure {
        case .fallen:
            return "RunningMan, \(attention) \(attention == 1 ? "runner needs" : "runners need") attention" + (busy > 0 ? ", \(busy) busy" : "")
        case .running:
            return "RunningMan, \(busy) \(busy == 1 ? "runner" : "runners") busy"
        case .ready:
            // Not "none busy": a Forgejo runner's activity can be unverified rather than idle.
            return "RunningMan, \(online) \(online == 1 ? "runner" : "runners") online, no jobs reported"
        case .standing:
            return "RunningMan, no runners online"
        }
    }
}

/// Draws the menu bar figure and runs it while jobs are active.
///
/// It is a separate observable from `AppModel`, so frame ticks invalidate only the menu
/// bar label and never the views that observe the model. The ticker exists only while a
/// runner is busy and motion is allowed; otherwise no timer runs at all.
@MainActor @Observable
final class MenuBarAnimator {
    enum Motion {
        case animated
        /// Snapshot captures stay still so they are reproducible.
        case still
    }

    private(set) var image: NSImage
    private(set) var status = MenuBarStatus()

    @ObservationIgnored private let motion: Motion
    @ObservationIgnored private let reduceMotion: () -> Bool
    @ObservationIgnored private var frames: [NSImage]
    @ObservationIgnored private(set) var frameIndex = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var tickerRate: Double?
    @ObservationIgnored private var reduceMotionObserver: NotificationObserver?

    init(motion: Motion, reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.motion = motion
        self.reduceMotion = reduceMotion
        frames = Self.frames(for: .standing).map { Self.described($0, as: MenuBarStatus().accessibilityLabel) }
        image = frames[0]
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTicker() }
        }
        reduceMotionObserver = NotificationObserver(center: center, token: token)
    }

    /// The frame rate in use, or nil when the figure is still and no timer runs. A test seam.
    var frameRate: Double? { tickerRate }

    /// Follows the model's runners for as long as both exist.
    func follow(_ model: AppModel) {
        let next = withObservationTracking {
            MenuBarStatus(runners: model.runners)
        } onChange: { [weak self, weak model] in
            // Called before the change is stored; read the new value on the next turn.
            Task { @MainActor in
                guard let self, let model else { return }
                self.follow(model)
            }
        }
        show(next)
    }

    func show(_ next: MenuBarStatus) {
        guard next != status else { return }
        if next.figure != status.figure { frameIndex = 0 }
        status = next
        // The status item takes its VoiceOver title from the image description and reads
        // it again only when the image changes, so every status gets described copies.
        frames = Self.frames(for: next.figure).map { Self.described($0, as: next.accessibilityLabel) }
        image = frames[frameIndex]
        updateTicker()
    }

    /// A jog for one busy runner, a run for two, a sprint for three or more. Nil when no
    /// runner is busy, so no timer exists.
    nonisolated static func framesPerSecond(busyRunners: Int) -> Double? {
        switch busyRunners {
        case ...0: return nil
        case 1: return 3.5
        case 2: return 4.5
        default: return 6
        }
    }

    private func updateTicker() {
        let animates = motion == .animated && status.figure == .running && !reduceMotion()
        let rate = animates ? Self.framesPerSecond(busyRunners: status.busy) : nil
        guard rate != tickerRate else { return }
        ticker?.cancel()
        ticker = nil
        tickerRate = rate
        guard let rate else {
            // Without a ticker the first frame stays. For a busy fleet under Reduce Motion
            // or in a still capture, its motion lines still set busy apart from idle.
            frameIndex = 0
            image = frames[0]
            return
        }
        let interval = 1 / rate
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval / 10))
                guard !Task.isCancelled, let self else { return }
                self.advance()
            }
        }
    }

    private func advance() {
        frameIndex = (frameIndex + 1) % frames.count
        image = frames[frameIndex]
    }
}

extension MenuBarAnimator {
    /// Every frame has this size, so the menu bar item never changes width.
    nonisolated static let canvas = NSSize(width: 22, height: 18)
    private static let standingFrame = stillFrame("figure.stand")
    private static let readyFrame = stillFrame("figure.run")
    private static let fallenFrame = stillFrame("figure.fall")
    private static let runningFrames = (0..<4).map(runningFrame)

    /// Template images: AppKit tints them for the menu bar's appearance, so one set
    /// serves light, dark and tinted menu bars.
    static func frames(for figure: MenuBarStatus.Figure) -> [NSImage] {
        switch figure {
        case .standing: return [standingFrame]
        case .ready: return [readyFrame]
        case .running: return runningFrames
        case .fallen: return [fallenFrame]
        }
    }

    /// SwiftUI does not pass an accessibility label on a menu bar label to the status
    /// item, which reads the image description instead.
    private static func described(_ frame: NSImage, as label: String) -> NSImage {
        let copy = (frame.copy() as? NSImage) ?? frame
        copy.accessibilityDescription = label
        return copy
    }

    nonisolated private static func symbol(_ name: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
    }

    nonisolated private static func stillFrame(_ name: String) -> NSImage {
        let figure = symbol(name)
        return template { rect in
            // Whole points keep the figure crisp on 1x displays.
            let origin = NSPoint(x: ((rect.width - figure.size.width) / 2).rounded(.down), y: ((rect.height - figure.size.height) / 2).rounded(.down))
            figure.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// The runner moves to the right edge with a 1 pt bob every other frame; three motion
    /// lines behind it slide back and fade, staggered so two or three always show. Offsets
    /// are in half points so the lines stay sharp on Retina displays.
    nonisolated private static func runningFrame(_ index: Int) -> NSImage {
        let figure = symbol("figure.run")
        return template { rect in
            let origin = NSPoint(x: rect.width - figure.size.width, y: ((rect.height - figure.size.height) / 2).rounded(.down) + CGFloat(index % 2))
            figure.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            let length: CGFloat = 3, thickness: CGFloat = 1.5
            let heights: [CGFloat] = [11.5, 8.5, 5.5]
            for (row, height) in heights.enumerated() {
                let step = (index + row * 3) % 4
                let dash = NSRect(x: origin.x - length - CGFloat(step), y: origin.y + height, width: length, height: thickness)
                NSColor.black.withAlphaComponent(1 - CGFloat(step) * 0.25).setFill()
                NSBezierPath(roundedRect: dash, xRadius: thickness / 2, yRadius: thickness / 2).fill()
            }
        }
    }

    nonisolated private static func template(_ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Removes a block-based observer when its owner goes away, without the owner's
/// isolated state being touched from `deinit`.
private final class NotificationObserver {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit { center.removeObserver(token) }
}

/// The menu bar item. It reads only the animator, so frame ticks re-render this label
/// and nothing else. Its VoiceOver title comes from the image; see `described(_:as:)`.
struct MenuBarLabel: View {
    let animator: MenuBarAnimator

    var body: some View {
        Image(nsImage: animator.image)
    }
}
