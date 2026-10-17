import AppKit
import SwiftUI

@main
struct RunningManApp: App {
    @State private var model: AppModel
    @State private var updates: AppUpdateChecker
    @NSApplicationDelegateAdaptor(RunningManAppDelegate.self) private var delegate

    init() {
        let model = AppModel()
        // Demo data and snapshot captures stay offline and banner-free.
        let updates = AppUpdateChecker(mode: model.demoMode || SnapshotCapture.destination != nil ? .offline : .live)
        _model = State(initialValue: model)
        _updates = State(initialValue: updates)
        // The delegate starts both at launch, whether or not the main window appears.
        delegate.model = model
        delegate.updates = updates
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
                Button("Refresh") { Task { await model.refresh() } }.keyboardShortcut("r")
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
        Settings { SettingsView().environment(model).environment(updates) }
        MenuBarExtra {
            MenuPanelScene(delegate: delegate).environment(model)
        } label: {
            Label {
                Text(model.busyCount > 0 ? "\(model.busyCount) building" : "RunningMan")
            } icon: {
                Image(systemName: model.busyCount > 0 ? "figure.run.circle.fill" : "figure.run")
            }
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
                // Occlusion notifications refine this; the first one can arrive
                // before WindowIdentity has tagged the window.
                model.mainWindowVisible = true
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

private struct WindowIdentity: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = RunningManAppDelegate.mainWindowIdentifier
        }
    }
    func makeNSView(context: Context) -> View { View(frame: .zero) }
    func updateNSView(_ nsView: View, context: Context) {}
}

@MainActor final class RunningManAppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("RunningManMain")
    weak var model: AppModel?
    weak var updates: AppUpdateChecker?
    /// From the latest scene to appear (main window or menu bar panel); it can
    /// reopen the main window after it was closed.
    private var openWindow: OpenWindowAction?

    /// Monitoring and update checks start here rather than in the main window's
    /// onAppear: the window is not always presented at launch (state restoration,
    /// a bare launch argument), and the menu bar and stop-after-job need them anyway.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else { return }
        model.showMainWindow = { [weak self] in self?.showMainWindow() }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged(_:)), name: name, object: nil)
        }
        model.startMonitoring()
        updates?.startAutomatic()
    }

    func sceneAppeared(openWindow: OpenWindowAction) {
        self.openWindow = openWindow
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
        model?.mainWindowVisible = notification.name != NSWindow.willCloseNotification && window.occlusionState.contains(.visible)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.stopMonitoring() }
}

@MainActor private enum SnapshotCapture {
    static var destination: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-dir"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
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
                try capture(name: section.rawValue, directory: directory)
            }
            model.section = .overview
            NSApp.appearance = NSAppearance(named: .darkAqua)
            try await Task.sleep(for: .milliseconds(650))
            try capture(name: "overview-dark", directory: directory)
            model.section = .workload
            try await Task.sleep(for: .milliseconds(650))
            try capture(name: "workload-dark", directory: directory)
            model.section = .cleanup
            try await Task.sleep(for: .milliseconds(650))
            try capture(name: "cleanup-dark", directory: directory)
            NSApp.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("Snapshot failed: \(error.localizedDescription)\n".utf8))
            model.stopMonitoring()
            exit(EXIT_FAILURE)
        }
    }
    private static func capture(name: String, directory: URL) throws {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "RunningManMain" }),
              let content = window.contentView?.superview,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw NSError(domain: "RunningMan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Main window is unavailable."])
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "RunningMan", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode screenshot."])
        }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
