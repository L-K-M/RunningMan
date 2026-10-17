import AppKit
import Foundation
import RunningManCore

/// App-level update state: restores the last announced release, runs the daily
/// check when due and answers Check for Updates. All state is observed through
/// this one object (the banner, the settings pane and the menu read it).
@Observable @MainActor
final class AppUpdateChecker {
    enum Mode {
        /// Restores the last announced release, fetches the manifest and saves results.
        case live
        /// The preview workspace and snapshot captures: no stored banner, no network
        /// and no reads or writes of update preferences.
        case offline
    }

    let mode: Mode
    private(set) var available: AppRelease?
    private(set) var checking = false
    private(set) var lastCheck: Date?
    /// Set by the banner's Later button for this run only.
    var bannerDismissed = false

    var showsBanner: Bool { available != nil && !bannerDismissed }

    /// The skipped version, kept across runs so a skipped release stays silent.
    private(set) var skippedVersion: String? {
        didSet {
            guard mode == .live else { return }
            if let skippedVersion { defaults.set(skippedVersion, forKey: Self.skippedKey) }
            else { defaults.removeObject(forKey: Self.skippedKey) }
        }
    }

    static let lastCheckKey = "appUpdate.lastSuccessfulCheck"
    static let manifestKey = "appUpdate.latestManifest"
    static let skippedKey = "appUpdate.skippedVersion"
    static let automaticKey = "appUpdate.automaticChecks"
    /// How often the automatic schedule asks whether the daily check is due.
    private static let evaluationInterval: Duration = .seconds(60 * 60)
    /// The network usually needs a moment after wake; a failed check retries hourly.
    private static let wakeDelay: Duration = .seconds(60)

    private let defaults: UserDefaults
    private let appVersion: String
    private let fetch: (String) async throws -> Data
    private let presentMessage: @MainActor (_ title: String, _ message: String) -> Void
    private var task: Task<Void, Never>?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    /// `isReleaseBuild` false keeps dev and snapshot builds quiet: only builds
    /// carrying a plain X.Y.Z version ask the manifest anything.
    var isReleaseBuild: Bool { AppUpdateCheck.isReleaseVersion(appVersion) }

    /// `presentMessage` shows a titled message; tests replace the modal alert.
    init(mode: Mode = .live,
         defaults: UserDefaults = .standard,
         appVersion: String? = nil,
         fetch: @escaping (String) async throws -> Data = { try await AppUpdateCheck.fetch(appVersion: $0) },
         presentMessage: @escaping @MainActor (_ title: String, _ message: String) -> Void = AppUpdateChecker.presentAlert) {
        self.mode = mode
        self.defaults = defaults
        self.appVersion = appVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        self.fetch = fetch
        self.presentMessage = presentMessage
        guard mode == .live else { return }
        lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
        skippedVersion = defaults.string(forKey: Self.skippedKey)
        // A stored manifest already announces its release while the network is away.
        if let data = defaults.data(forKey: Self.manifestKey),
           let release = try? AppUpdateCheck.release(from: data),
           case .available = AppUpdateCheck.status(of: release, runningVersion: self.appVersion, skippedVersion: skippedVersion) {
            available = release
        }
    }

    /// Called at launch; later calls do nothing. Checks now if due, then asks again
    /// every hour and shortly after the Mac wakes, so a menu bar session that runs
    /// for days still checks daily.
    func startAutomatic() {
        guard mode == .live, schedule == nil else { return }
        checkIfDue()
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.evaluationInterval, tolerance: .seconds(5 * 60))
                guard let self else { return }
                checkIfDue()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.wakeDelay)
                self?.checkIfDue()
            }
        }
    }

    /// Checks only when automatic checks are on (default; read each time, so the
    /// Settings toggle applies at once), the build is a release build and a check is due.
    func checkIfDue(now: Date = Date()) {
        guard mode == .live, isReleaseBuild, defaults.object(forKey: Self.automaticKey) as? Bool ?? true,
              AppUpdateCheck.isDue(lastSuccess: lastCheck, now: now) else { return }
        run(manual: false)
    }

    /// Menu command: always fetches and reports the outcome, good or bad.
    func checkNow() {
        guard mode == .live else {
            alert(title: "Update checks are off in the preview workspace",
                  message: "Open RunningMan normally to check for updates.")
            return
        }
        run(manual: true)
    }

    func skip(_ release: AppRelease) {
        skippedVersion = release.version
        if available == release { available = nil }
    }

    private func run(manual: Bool) {
        guard !checking else { return }
        if manual, !isReleaseBuild {
            alert(title: "Update checks are off in this build",
                  message: "Update checks run in released versions of RunningMan. This build is \(appVersion.isEmpty ? "a development build" : appVersion).")
            return
        }
        checking = true
        let version = appVersion
        let fetch = self.fetch
        task = Task { @MainActor [weak self] in
            defer { self?.checking = false }
            do {
                let data = try await fetch(version)
                let release = try AppUpdateCheck.release(from: data)
                self?.defaults.set(data, forKey: Self.manifestKey)
                self?.defaults.set(Date(), forKey: Self.lastCheckKey)
                self?.lastCheck = Date()
                let status = AppUpdateCheck.status(of: release, runningVersion: version, skippedVersion: self?.skippedVersion)
                switch status {
                case .available(let release):
                    self?.available = release
                    self?.bannerDismissed = false
                    if manual { self?.alertUpdate(release) }
                case .skipped(let release):
                    self?.available = nil
                    if manual { self?.alert(title: "Version \(release.version) is skipped", message: "RunningMan \(release.version) is available, but you chose to skip it.") }
                case .upToDate(let newest):
                    self?.available = nil
                    if manual { self?.alert(title: "You're up to date", message: "RunningMan \(version) is the latest version (newest release: \(newest.version)).") }
                }
            } catch {
                if manual {
                    self?.alert(title: "Could not check for updates", message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }

    private func alertUpdate(_ release: AppRelease) {
        let alert = NSAlert()
        alert.messageText = "RunningMan \(release.version) is available"
        alert.informativeText = "You are running \(appVersion). Download the new version from the release page and replace the app."
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(release.releasePage)
        case .alertSecondButtonReturn: skip(release)
        default: break
        }
    }

    private func alert(title: String, message: String) { presentMessage(title, message) }

    static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
