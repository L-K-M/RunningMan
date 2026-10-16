import AppKit
import SwiftUI

@main
struct RunningManApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(RunningManAppDelegate.self) private var delegate

    var body: some Scene {
        Window("RunningMan", id: "main") {
            MainWindowScene().environment(model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
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
        Settings { SettingsView().environment(model) }
        MenuBarExtra {
            RunnerMenuView().environment(model)
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
    @State private var snapshotTaskStarted = false
    var body: some View {
        ContentView()
            .background(WindowIdentity())
            .onAppear {
                let action = openWindow
                model.showMainWindow = {
                    action(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.identifier?.rawValue == "RunningManMain" }?.makeKeyAndOrderFront(nil)
                }
                model.startMonitoring()
                if !snapshotTaskStarted, let directory = SnapshotCapture.destination {
                    snapshotTaskStarted = true
                    Task { await SnapshotCapture.run(model: model, directory: directory) }
                }
            }
    }
}

private struct WindowIdentity: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = NSUserInterfaceItemIdentifier("RunningManMain")
        }
    }
    func makeNSView(context: Context) -> View { View(frame: .zero) }
    func updateNSView(_ nsView: View, context: Context) {}
}

@MainActor final class RunningManAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
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
