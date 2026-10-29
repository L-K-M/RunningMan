import AppKit
import ServiceManagement

/// The parts of `SMAppService` background mode uses, so tests and the preview
/// workspace can stand in for the system's login items.
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// Background mode: RunningMan opens at login in the menu bar and shows a Dock icon
/// only while its main window is open. Monitoring starts either way, so with automatic
/// refresh on, the menu bar and desktop widgets stay current without a window.
///
/// RunningMan's own login item ("Open at Login" in System Settings → General → Login
/// Items) is the only stored state, so removing RunningMan there turns the mode off.
/// A login item launch opens no main window, so nothing here has to suppress one.
/// Runner services keep their own, separate login policy.
@Observable @MainActor
final class BackgroundMode {
    enum Mode {
        /// Registers RunningMan's login item with macOS.
        case live
        /// The preview workspace and snapshot captures: the choice lasts for this run
        /// and never reaches System Settings.
        case preview
    }

    let mode: Mode
    private let loginItem: LoginItemService
    private var status: SMAppService.Status
    /// Why the last change did not take effect; cleared when the status changes.
    private(set) var failure: String?
    /// Lets the app delegate update the Dock icon when the status changes, here or in
    /// System Settings.
    @ObservationIgnored var changed: (() -> Void)?

    init(mode: Mode, loginItem: LoginItemService? = nil) {
        self.mode = mode
        self.loginItem = loginItem ?? (mode == .live ? SMAppService.mainApp : PreviewLoginItem())
        status = self.loginItem.status
    }

    /// Registered, including while macOS waits for approval in System Settings.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    /// System Settings can change the login item while RunningMan runs.
    func refresh() {
        let current = loginItem.status
        guard current != status else { return }
        status = current
        failure = nil
        changed?()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        var error: Error?
        do {
            if enabled { try loginItem.register() } else { try loginItem.unregister() }
        } catch let caught {
            error = caught
        }
        refresh()
        // macOS can report an error and still reach the requested state, for example a
        // login item that now waits for approval; the status explains that better.
        failure = isEnabled == enabled ? nil : error?.localizedDescription
    }

    func openLoginItemsSettings() {
        guard mode == .live else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    /// A minimised main window still needs the Dock icon: it is restored from the Dock.
    nonisolated static func activationPolicy(enabled: Bool, mainWindowOpen: Bool) -> NSApplication.ActivationPolicy {
        enabled && !mainWindowOpen ? .accessory : .regular
    }
}

private final class PreviewLoginItem: LoginItemService {
    private(set) var status: SMAppService.Status = .notRegistered
    func register() { status = .enabled }
    func unregister() { status = .notRegistered }
}
