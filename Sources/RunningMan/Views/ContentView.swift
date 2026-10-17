import SwiftUI
import RunningManCore

struct ContentView: View {
    static let sidebarWidth = (min: CGFloat(190), ideal: CGFloat(210), max: CGFloat(250))
    /// The widest sidebar beside the runner list and detail at their minimums: 841 by 500 pt.
    /// That fits a quarter tile of a 1920 by 1080 pt display (half its width and half its
    /// height, 960 by 540 pt, less the menu bar), and so also a half tile.
    static let minimumSize = CGSize(width: sidebarWidth.max + RunnersView.minimumWidth, height: 500)
    @Environment(AppModel.self) private var model
    @Environment(AppUpdateChecker.self) private var updates
    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: Self.sidebarWidth.min, ideal: Self.sidebarWidth.ideal, max: Self.sidebarWidth.max)
        } detail: {
            VStack(spacing: 0) {
                if updates.showsBanner, let release = updates.available {
                    AppUpdateBanner(updates: updates, release: release)
                }
                Group {
                    switch model.section {
                    case .overview: OverviewView()
                    case .runners: RunnersView()
                    case .workload: WorkloadView()
                    case .history: HistoryView()
                    case .cleanup: CleanupView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(RunningManStyle.canvas)
            .navigationTitle(model.section.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Always the same button, so the toolbar never changes width or flickers;
                    // background polls do not show progress here.
                    Button { Task { await model.refreshNow() } } label: { RefreshSymbol(isActive: model.isManualRefreshing) }
                        .disabled(model.isManualRefreshing)
                        .help(model.isManualRefreshing ? "Refreshing runner state" : "Refresh runner state (⌘R)").keyboardShortcut("r")
                    Menu {
                        Button("Import existing runner…", systemImage: "folder.badge.plus") { model.importRunner() }
                        Button("Export diagnostics…", systemImage: "square.and.arrow.up") { model.exportDiagnostics() }
                        Divider()
                        Button("Start all enabled runners", systemImage: "play.fill") { model.startAll() }
                        Button("Stop all when idle", systemImage: "moon.zzz") { model.stopAllWhenIdle() }
                    } label: { Label("Fleet actions", systemImage: "ellipsis") }
                        .menuIndicator(.hidden).tint(.primary).help("Fleet actions")
                    Button { model.showingNewRunner = true } label: { Label("New runner", systemImage: "plus") }
                        .keyboardShortcut("n").help("Register a new GitHub or Forgejo runner (⌘N)")
                }
            }
            .searchable(text: $model.searchText, placement: .toolbar,
                        prompt: model.section == .history ? "Search job history" : model.section == .workload ? "Search queues or scopes" : model.section == .cleanup ? "Search cleanup reports" : "Find a runner")
        }
        .tint(RunningManStyle.accent)
        // The runner list and detail, the metric rows and the filters adapt to the narrower space.
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        // A sheet does not inherit the tint above, so each presented root sets its own.
        .sheet(isPresented: $model.showingNewRunner) { NewRunnerSheet().environment(model).tint(RunningManStyle.accent) }
        .sheet(isPresented: $model.showingForgejoConnection) { ForgejoConnectionSheet().environment(model).tint(RunningManStyle.accent) }
        .onChange(of: model.selectedRunnerID) { _, _ in model.selectionChanged() }
        .alert("RunningMan", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog(model.confirmation?.title ?? "Confirm action", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.cancelPendingAction() } }), titleVisibility: .visible) {
            Button(model.confirmation?.buttonTitle ?? "Continue", role: .destructive) { model.confirmPendingAction() }
            Button("Cancel", role: .cancel) { model.cancelPendingAction() }
        } message: { Text(model.confirmation?.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WORKSPACE").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 9)
            ForEach(AppSection.allCases) { section in
                Button {
                    model.section = section
                    model.searchText = ""
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage).font(.system(size: 14)).frame(width: 19)
                        Text(section.title).font(.system(size: 12, weight: model.section == section ? .semibold : .medium))
                        Spacer()
                        if section == .runners {
                            Text("\(model.runners.count)").font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }.foregroundStyle(model.section == section ? RunningManStyle.accentText : Color.primary.opacity(0.8))
                        .padding(.horizontal, 11).padding(.vertical, 10)
                        .background(model.section == section ? RunningManStyle.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 3)
                    .accessibilityAddTraits(model.section == section ? .isSelected : [])
            }
            Spacer()
            if model.demoMode {
                Label("Preview workspace", systemImage: "sparkles").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RunningManStyle.accentText).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RunningManStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 7) {
                    Circle().fill(model.runningCount > 0 ? StatusTone.positive.fill : StatusTone.neutral.fill).frame(width: 6, height: 6)
                    Text("\(model.runningCount) of \(model.runners.count) online").font(.system(size: 11, weight: .medium))
                }
                if let lastUpdated = model.lastUpdated {
                    Text("Checked \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle").font(.system(size: 22)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.githubAccount ?? "GitHub CLI").font(.system(size: 11, weight: .medium)).lineLimit(1)
                            .help("Check your GitHub CLI account in Settings")
                        Text("This Mac · \(model.demoMode ? "demo" : ProcessInfo.processInfo.userName)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    SettingsLink { Image(systemName: "gearshape").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Settings")
                }
            }.padding(16)
        }.frame(maxHeight: .infinity).background(.thinMaterial)
    }
}

/// Spins while a manual refresh runs on macOS 15 and later, unless Reduce Motion is on.
/// On macOS 14 the disabled button alone shows that a refresh is in progress.
private struct RefreshSymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isActive: Bool
    var body: some View {
        if #available(macOS 15, *) {
            Image(systemName: "arrow.clockwise").symbolEffect(.rotate, isActive: isActive && !reduceMotion)
        } else {
            Image(systemName: "arrow.clockwise")
        }
    }
}
