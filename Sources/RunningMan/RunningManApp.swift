import AppKit
import ScreenCaptureKit
import SwiftUI
import RunningManWidgetViews

@main
struct RunningManApp: App {
    @State private var model: AppModel
    @State private var updates: AppUpdateChecker
    @State private var backgroundMode: BackgroundMode
    /// Follows the model from outside it, so frame ticks re-render only the menu bar label.
    @State private var menuBarAnimator: MenuBarAnimator
    @NSApplicationDelegateAdaptor(RunningManAppDelegate.self) private var delegate

    init() {
        let model = AppModel()
        // Before SwiftUI creates a window, so AppKit has saved nothing yet.
        if model.demoMode { DemoLayoutPreferences.record() }
        // Demo data and snapshot captures stay offline and banner-free.
        let updates = AppUpdateChecker(mode: model.demoMode || SnapshotCapture.destination != nil ? .offline : .live)
        let backgroundMode = BackgroundMode(mode: model.demoMode || SnapshotCapture.destination != nil ? .preview : .live)
        let animator = MenuBarAnimator(motion: SnapshotCapture.destination == nil ? .animated : .still)
        animator.follow(model)
        _model = State(initialValue: model)
        _updates = State(initialValue: updates)
        _backgroundMode = State(initialValue: backgroundMode)
        _menuBarAnimator = State(initialValue: animator)
        // The delegate starts monitoring and update checks at launch, whether or not
        // the main window appears, and applies background mode to the Dock icon.
        delegate.model = model
        delegate.updates = updates
        delegate.backgroundMode = backgroundMode
    }

    var body: some Scene {
        Window("RunningMan", id: "main") {
            MainWindowScene(updates: updates, delegate: delegate).environment(model)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            AppUpdateCommands(updates: updates)
            CommandGroup(replacing: .newItem) {
                Button("New Runner…") { model.showingNewRunner = true }.keyboardShortcut("n")
                Button("Import Existing Runner…") { model.importRunner() }.keyboardShortcut("o")
            }
            CommandMenu("Runners") {
                Button("Refresh") { Task { await model.refreshNow() } }.keyboardShortcut("r")
                Divider()
                Button("Start All Enabled Runners") { model.startAll() }
                Button("Stop All When Idle") { model.stopAllWhenIdle() }
                Divider()
                Button("Export Diagnostics…") { model.exportDiagnostics() }
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element.id) { index, section in
                    Button(section.title) {
                        model.section = section
                        model.showMainWindow?()
                    }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
            }
        }
        Settings {
            SettingsView().environment(model).environment(updates).environment(backgroundMode).tint(RunningManStyle.accent)
        }
        MenuBarExtra {
            MenuPanelScene(delegate: delegate).environment(model)
        } label: {
            MenuBarLabelScene(animator: menuBarAnimator, delegate: delegate)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MainWindowScene: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let updates: AppUpdateChecker
    let delegate: RunningManAppDelegate
    @State private var snapshotTaskStarted = false
    var body: some View {
        ContentView()
            .environment(updates)
            .background(WindowIdentity())
            .onAppear {
                delegate.sceneAppeared(openWindow: openWindow)
                delegate.mainWindowAppeared()
                // Occlusion notifications refine this; the first one can arrive
                // before WindowIdentity has tagged the window, so read the window
                // itself once it exists (a window restored minimised is not visible).
                model.mainWindowVisible = true
                DispatchQueue.main.async {
                    if let window = NSApp.windows.first(where: { $0.identifier == RunningManAppDelegate.mainWindowIdentifier }) {
                        model.mainWindowVisible = window.occlusionState.contains(.visible)
                    }
                }
                // The preview workspace races scripted runs in real time; captures stay still.
                model.startDemoRace()
                if !snapshotTaskStarted, let directory = SnapshotCapture.destination {
                    snapshotTaskStarted = true
                    Task { await SnapshotCapture.run(model: model, directory: directory) }
                }
            }
            .onDisappear { model.mainWindowVisible = false }
    }
}

/// The menu bar panel's content. It reports when the panel is open (polling
/// cadence) and hands over openWindow, so alerts can reach the main window
/// even when it never appeared at launch.
private struct MenuPanelScene: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let delegate: RunningManAppDelegate
    var body: some View {
        RunnerMenuView()
            .onAppear {
                delegate.sceneAppeared(openWindow: openWindow)
                model.menuPanelVisible = true
            }
            .onDisappear { model.menuPanelVisible = false }
    }
}

/// The menu bar icon is drawn from launch, so it hands over openWindow even when no
/// window appears (a login item launch) and the menu bar panel has not been opened.
/// Without it, a notification click or an alert could not open the main window.
private struct MenuBarLabelScene: View {
    @Environment(\.openWindow) private var openWindow
    let animator: MenuBarAnimator
    let delegate: RunningManAppDelegate
    var body: some View {
        MenuBarLabel(animator: animator).onAppear { delegate.sceneAppeared(openWindow: openWindow) }
    }
}

private struct WindowIdentity: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = RunningManAppDelegate.mainWindowIdentifier
            if let window { DemoLayoutPreferences.windowDidAppear(window) }
        }
    }
    func makeNSView(context: Context) -> View { View(frame: .zero) }
    func updateNSView(_ nsView: View, context: Context) {}
}

/// Demo mode must not modify the real preferences, but AppKit saves window and
/// sidebar frames by itself, some of them while the window is still being set
/// up. Demo mode records those entries before any window exists, stops the
/// main window's saves once it appears, and puts the recorded values back.
/// Outside demo mode nothing is recorded and every call does nothing.
@MainActor private enum DemoLayoutPreferences {
    private static var recorded: [String: Any]?

    static func record() { recorded = entries() }

    static func windowDidAppear(_ window: NSWindow) {
        guard recorded != nil else { return }
        window.setFrameAutosaveName("")
        // SwiftUI installs the split view after this view joins the window.
        DispatchQueue.main.async { [weak window] in
            if let root = window?.contentView { splitViews(in: root).forEach { $0.autosaveName = nil } }
            restore()
        }
    }

    /// Also covers windows that keep autosaving, such as Settings.
    static func restore() {
        guard let recorded else { return }
        for key in Set(recorded.keys).union(entries().keys) {
            UserDefaults.standard.set(recorded[key], forKey: key)
        }
    }

    /// Only the app's own persistent domain: restoring a key seen in the
    /// global or argument domain would copy it into the app's preferences.
    private static func entries() -> [String: Any] {
        guard let domain = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:)) else { return [:] }
        return domain.filter { $0.key.hasPrefix("NSWindow Frame ") || $0.key.hasPrefix("NSSplitView Subview Frames ") }
    }

    private static func splitViews(in view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews(in:))
    }
}

@MainActor final class RunningManAppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("RunningManMain")
    weak var model: AppModel?
    weak var updates: AppUpdateChecker?
    weak var backgroundMode: BackgroundMode?
    /// From the latest scene to appear (main window, menu bar panel or menu bar icon);
    /// it can reopen the main window after it was closed.
    private var openWindow: OpenWindowAction?
    private var pendingWidgetOpen = false
    /// From the main window's appearance until it closes; a minimised window is open.
    private var mainWindowOpen = false

    /// Monitoring and update checks start here rather than in the main window's
    /// onAppear: the window is not always presented at launch (state restoration,
    /// a bare launch argument, a login item launch), and the menu bar, widgets and
    /// stop-after-job need them anyway.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else { return }
        model.showMainWindow = { [weak self] in self?.showMainWindow() }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged(_:)), name: name, object: nil)
        }
        backgroundMode?.changed = { [weak self] in self?.updateDockIcon() }
        updateDockIcon()
        model.startMonitoring()
        updates?.startAutomatic()
    }

    func mainWindowAppeared() {
        mainWindowOpen = true
        updateDockIcon()
    }

    /// Background mode keeps RunningMan out of the Dock while its main window is closed.
    private func updateDockIcon() {
        guard let backgroundMode else { return }
        let policy = BackgroundMode.activationPolicy(enabled: backgroundMode.isEnabled, mainWindowOpen: mainWindowOpen)
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// Picks up a login item changed in System Settings; a change updates the Dock icon.
    func applicationDidBecomeActive(_ notification: Notification) {
        backgroundMode?.refresh()
    }

    func sceneAppeared(openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        if pendingWidgetOpen {
            pendingWidgetOpen = false
            showMainWindow()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where model?.openWidget(url) == true {
            pendingWidgetOpen = openWindow == nil
            showMainWindow()
        }
    }

    /// Before any scene has handed over openWindow, this still brings an existing
    /// main window forward.
    func showMainWindow() {
        openWindow?(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier == Self.mainWindowIdentifier }?.makeKeyAndOrderFront(nil)
    }

    /// Minimising, hiding the app, switching Spaces, covering the window or the
    /// display sleeping all change occlusion; closing posts willClose first.
    @objc private func windowVisibilityChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.identifier == Self.mainWindowIdentifier else { return }
        let closing = notification.name == NSWindow.willCloseNotification
        model?.mainWindowVisible = !closing && window.occlusionState.contains(.visible)
        if closing {
            mainWindowOpen = false
            updateDockIcon()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        model?.stopMonitoring()
        DemoLayoutPreferences.restore()
    }

    /// Stop-after-job requests survive a relaunch, but nothing acts on them while RunningMan is closed,
    /// and quitting would cut off a creation or runner action in progress, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SnapshotCapture.destination == nil, !isSessionEnding, let warning = model?.quitWarning else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.title
        alert.informativeText = warning.message
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// macOS asks every app to quit when you log out, restart or shut down. A prompt then would cancel
    /// that, and the requests are persisted anyway.
    private var isSessionEnding: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown].contains(reason)
    }
}

/// Also read by AppModel, which keeps notifications off during captures.
@MainActor enum SnapshotCapture {
    /// scripts/smoke-test.sh sets this. The directory deliberately stays out of
    /// the command line: at launch, a bare argument that does not follow a
    /// `-key` stops SwiftUI from opening the main window. In
    /// `--demo --snapshot-dir <dir>`, `--demo` took `--snapshot-dir` as its
    /// value, the path was left bare, and the capture never started.
    static var destination: URL? {
        guard let path = ProcessInfo.processInfo.environment["RUNNINGMAN_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static func run(model: AppModel, directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await Task.sleep(for: .seconds(model.demoMode ? 1.5 : 4))
            NSApp.appearance = NSAppearance(named: .aqua)
            NSApp.activate(ignoringOtherApps: true)
            for section in AppSection.allCases {
                model.section = section
                try await Task.sleep(for: .milliseconds(650))
                try await capture(name: section.rawValue, directory: directory)
            }
            model.section = .overview
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try await Task.sleep(for: .milliseconds(650))
            try await capture(name: "overview-dark", directory: directory)
            model.section = .workload
            try await Task.sleep(for: .milliseconds(650))
            try await capture(name: "workload-dark", directory: directory)
            model.section = .cleanup
            try await Task.sleep(for: .milliseconds(650))
            try await capture(name: "cleanup-dark", directory: directory)
            try await captureWidgets(directory: directory)
            NSApp.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("Snapshot failed: \(error.localizedDescription)\n".utf8))
            model.stopMonitoring()
            exit(EXIT_FAILURE)
        }
    }
    private static func capture(name: String, directory: URL) async throws {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "RunningManMain" }) else {
            throw SnapshotError.windowUnavailable
        }
        try await capture(window: window, name: name, directory: directory)
    }

    private static func captureWidgets(directory: URL) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 594, height: 660),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "RunningMan widget previews"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for (name, appearance, scheme) in [("widgets", NSAppearance.Name.aqua, ColorScheme.light),
                                           ("widgets-dark", .darkAqua, .dark)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: WidgetPreviewGallery().preferredColorScheme(scheme))
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.center()
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(650))
            try await capture(window: window, name: name, directory: directory)
        }
    }

    private static func capture(window: NSWindow, name: String, directory: URL) async throws {
        let image = try await composited(window)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodingFailed
        }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    /// Captures the window as the window server composites it. Drawing the
    /// view tree with `cacheDisplay` misses layer content that AppKit does not
    /// draw itself: on macOS 26 the glass sidebar, toolbar and every section
    /// rooted in a `ScrollView` came out blank. `currentProcess` lists only
    /// this app's own windows, so the capture needs no Screen Recording
    /// permission and never shows other apps.
    private static func composited(_ window: NSWindow) async throws -> CGImage {
        guard #available(macOS 14.4, *) else { throw SnapshotError.unsupportedSystem }
        let content = try await SCShareableContent.currentProcess
        guard let shareable = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw SnapshotError.windowUnavailable
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(shareable.frame.width * window.backingScaleFactor)
        configuration.height = Int(shareable.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: shareable), configuration: configuration)
    }
}

private enum SnapshotError: LocalizedError {
    case windowUnavailable, encodingFailed, unsupportedSystem
    var errorDescription: String? {
        switch self {
        case .windowUnavailable: "Main window is unavailable."
        case .encodingFailed: "Could not encode screenshot."
        case .unsupportedSystem: "Preview captures need macOS 14.4 or later."
        }
    }
}
