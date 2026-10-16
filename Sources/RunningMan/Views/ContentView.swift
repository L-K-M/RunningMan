import SwiftUI
import RunningManCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppUpdateChecker.self) private var updates
    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
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
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(RunningManStyle.canvas)
            .navigationTitle(model.section.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small).frame(width: 22).help("Refreshing runner state")
                    } else {
                        Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                            .help("Refresh runner state (⌘R)").keyboardShortcut("r")
                    }
                    Menu {
                        Button("Import existing runner…", systemImage: "folder.badge.plus") { model.importRunner() }
                        Button("Export diagnostics…", systemImage: "square.and.arrow.up") { model.exportDiagnostics() }
                        Divider()
                        Button("Start all enabled runners", systemImage: "play.fill") { model.startAll() }
                        Button("Stop all when idle", systemImage: "moon.zzz") { model.stopAllWhenIdle() }
                    } label: { Image(systemName: "ellipsis.circle") }.help("Fleet actions")
                    Button { model.showingNewRunner = true } label: { Label("New runner", systemImage: "plus") }
                        .keyboardShortcut("n").help("Register a new GitHub or Forgejo runner (⌘N)")
                }
            }
            .searchable(text: $model.searchText, placement: .toolbar,
                        prompt: model.section == .history ? "Search job history" : model.section == .workload ? "Search queues or scopes" : "Find a runner")
        }
        .tint(RunningManStyle.accent)
        .frame(minWidth: 1000, minHeight: 650)
        .sheet(isPresented: $model.showingNewRunner) { NewRunnerSheet().environment(model) }
        .sheet(isPresented: $model.showingForgejoConnection) { ForgejoConnectionSheet().environment(model) }
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
            HStack(spacing: 11) {
                Image(systemName: "figure.run.circle.fill")
                    .font(.system(size: 34)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, RunningManStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("RunningMan").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("YOUR LOCAL RUNNER HQ").font(.system(size: 8, weight: .semibold)).tracking(1.05).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 17).padding(.top, 22).padding(.bottom, 28)

            Text("WORKSPACE").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.tertiary)
                .padding(.horizontal, 20).padding(.bottom, 9)
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
                    }.foregroundStyle(model.section == section ? RunningManStyle.accent : Color.primary.opacity(0.8))
                        .padding(.horizontal, 11).padding(.vertical, 10)
                        .background(model.section == section ? RunningManStyle.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 3)
                    .accessibilityAddTraits(model.section == section ? .isSelected : [])
            }
            Spacer()
            if model.demoMode {
                Label("Preview workspace", systemImage: "sparkles").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.indigo).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 7) {
                    Circle().fill(model.runningCount > 0 ? RunningManStyle.teal : Color.secondary).frame(width: 6, height: 6)
                    Text("\(model.runningCount) of \(model.runners.count) running").font(.system(size: 11, weight: .medium))
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
                        Text("This Mac · \(model.demoMode ? "demo" : ProcessInfo.processInfo.userName)").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    SettingsLink { Image(systemName: "gearshape").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Settings")
                }
            }.padding(16)
        }.frame(maxHeight: .infinity).background(.thinMaterial)
    }
}
