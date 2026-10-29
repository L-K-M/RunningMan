import AppKit
import ServiceManagement
import XCTest
@testable import RunningMan

final class BackgroundModeTests: XCTestCase {
    @MainActor func testTogglingRegistersTheLoginItemOnceAndReportsEachChange() {
        let loginItem = FakeLoginItem()
        let mode = BackgroundMode(mode: .live, loginItem: loginItem)
        var changes = 0
        mode.changed = { changes += 1 }
        XCTAssertFalse(mode.isEnabled)

        mode.setEnabled(true)
        XCTAssertTrue(mode.isEnabled)
        XCTAssertEqual(loginItem.calls, ["register"])
        XCTAssertEqual(changes, 1)

        mode.setEnabled(true)
        XCTAssertEqual(loginItem.calls, ["register"], "An unchanged choice must not register again")
        XCTAssertEqual(changes, 1)

        mode.setEnabled(false)
        XCTAssertFalse(mode.isEnabled)
        XCTAssertEqual(loginItem.calls, ["register", "unregister"])
        XCTAssertEqual(changes, 2)
    }

    @MainActor func testAFailedChangeShowsTheSystemStateAndWhy() {
        let loginItem = FakeLoginItem()
        loginItem.failure = FakeError()
        let mode = BackgroundMode(mode: .live, loginItem: loginItem)
        var changes = 0
        mode.changed = { changes += 1 }
        mode.setEnabled(true)
        XCTAssertFalse(mode.isEnabled, "The toggle must not claim a login item macOS refused")
        XCTAssertNotNil(mode.failure)
        XCTAssertEqual(changes, 0, "Nothing changed, so the Dock icon stays as it is")

        loginItem.failure = nil
        mode.setEnabled(true)
        XCTAssertTrue(mode.isEnabled)
        XCTAssertNil(mode.failure, "A successful change clears the earlier failure")
    }

    /// SMAppService documents that register() fails with "launch denied" when the user has
    /// not approved the item, which then awaits approval: the approval prompt must show.
    @MainActor func testAnErrorThatStillLeavesTheItemAwaitingApprovalShowsNoFailure() {
        let loginItem = FakeLoginItem()
        loginItem.failure = FakeError()
        loginItem.statusAfterFailure = .requiresApproval
        let mode = BackgroundMode(mode: .live, loginItem: loginItem)
        mode.setEnabled(true)
        XCTAssertTrue(mode.isEnabled)
        XCTAssertTrue(mode.needsApproval)
        XCTAssertNil(mode.failure, "A stale error would hide the Open Login Items button")
    }

    @MainActor func testAChangeInSystemSettingsClearsAnEarlierFailure() {
        let loginItem = FakeLoginItem()
        loginItem.failure = FakeError()
        let mode = BackgroundMode(mode: .live, loginItem: loginItem)
        mode.setEnabled(true)
        XCTAssertNotNil(mode.failure)

        loginItem.status = .enabled
        mode.refresh()
        XCTAssertTrue(mode.isEnabled)
        XCTAssertNil(mode.failure, "The error no longer describes the login item")
    }

    @MainActor func testALoginItemAwaitingApprovalStaysOnAndAsksForIt() {
        let loginItem = FakeLoginItem()
        loginItem.registeredStatus = .requiresApproval
        let mode = BackgroundMode(mode: .live, loginItem: loginItem)
        mode.setEnabled(true)
        XCTAssertTrue(mode.isEnabled)
        XCTAssertTrue(mode.needsApproval)
    }

    /// The login item is the only stored state, so removing RunningMan from Login Items
    /// in System Settings turns background mode off.
    @MainActor func testRefreshFollowsSystemSettingsAndReportsOnlyChanges() {
        let loginItem = FakeLoginItem()
        loginItem.status = .enabled
        let mode = BackgroundMode(mode: .live, loginItem: loginItem)
        var changes = 0
        mode.changed = { changes += 1 }
        XCTAssertTrue(mode.isEnabled)

        mode.refresh()
        XCTAssertEqual(changes, 0, "An unchanged login item must not touch the Dock icon")

        loginItem.status = .notRegistered
        mode.refresh()
        XCTAssertFalse(mode.isEnabled)
        XCTAssertEqual(changes, 1, "Removing RunningMan in System Settings must bring the Dock icon back")
        XCTAssertTrue(loginItem.calls.isEmpty, "Reading the state must never change it")
    }

    @MainActor func testThePreviewWorkspaceStartsOffAndKeepsTheChoiceForThisRun() {
        let mode = BackgroundMode(mode: .preview)
        XCTAssertFalse(mode.isEnabled)
        mode.setEnabled(true)
        XCTAssertTrue(mode.isEnabled)
        XCTAssertNil(mode.failure)
        mode.setEnabled(false)
        XCTAssertFalse(mode.isEnabled)
    }

    func testTheDockIconHidesOnlyWithTheModeOnAndTheWindowClosed() {
        XCTAssertEqual(BackgroundMode.activationPolicy(enabled: false, mainWindowOpen: false), .regular)
        XCTAssertEqual(BackgroundMode.activationPolicy(enabled: false, mainWindowOpen: true), .regular)
        XCTAssertEqual(BackgroundMode.activationPolicy(enabled: true, mainWindowOpen: true), .regular)
        XCTAssertEqual(BackgroundMode.activationPolicy(enabled: true, mainWindowOpen: false), .accessory)
    }
}

private struct FakeError: Error {}

private final class FakeLoginItem: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    /// What a successful register() leaves behind.
    var registeredStatus: SMAppService.Status = .enabled
    var failure: Error?
    /// What a failing call leaves behind, if it changes anything.
    var statusAfterFailure: SMAppService.Status?
    private(set) var calls: [String] = []

    func register() throws {
        calls.append("register")
        try failIfConfigured()
        status = registeredStatus
    }

    func unregister() throws {
        calls.append("unregister")
        try failIfConfigured()
        status = .notRegistered
    }

    private func failIfConfigured() throws {
        guard let failure else { return }
        if let statusAfterFailure { status = statusAfterFailure }
        throw failure
    }
}
