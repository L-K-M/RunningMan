import SwiftUI

/// "RunningMan → Check for Updates…", right below About, the macOS-standard spot.
struct AppUpdateCommands: Commands {
    private let updates: AppUpdateChecker

    init(updates: AppUpdateChecker) {
        self.updates = updates
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(updates.checking ? "Checking for Updates…" : "Check for Updates…") {
                updates.checkNow()
            }
            .disabled(updates.checking)
        }
    }
}
