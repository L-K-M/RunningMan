import SwiftUI
import RunningManCore

/// The slim banner the main window shows while a newer release is known.
struct AppUpdateBanner: View {
    @Bindable var updates: AppUpdateChecker
    var release: AppRelease

    var body: some View {
        HStack(spacing: 10) {
            Label("Update", systemImage: "arrow.down.circle.fill").font(.callout.weight(.semibold))
            Text("RunningMan \(release.version) is available").font(.callout).lineLimit(1)
            Spacer()
            Button("View Release") { NSWorkspace.shared.open(release.releasePage) }.controlSize(.small)
            Button("Skip This Version") { updates.skip(release) }.controlSize(.small)
            Button("Later") { updates.bannerDismissed = true }.controlSize(.small)
        }.padding(.horizontal, 12).padding(.vertical, 7)
            .background(RunningManStyle.surface).overlay(alignment: .bottom) { Divider() }
    }
}
