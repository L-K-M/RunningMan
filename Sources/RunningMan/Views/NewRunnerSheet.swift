import SwiftUI
import RunningManCore
import RunningManServices

struct NewRunnerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var provider: RunnerProvider = .github
    @State private var githubURL = ""
    @State private var forgejoServer = ""
    @State private var forgejoScope: ForgejoRunnerScope = .repository
    @State private var scopeName = ""
    @State private var token = ""
    @State private var name = ""
    @State private var labels = "local-mac-release"
    @State private var capacity = 1
    @State private var startsAtLogin = true
    @State private var attempted = false
    @State private var checkingConnection = false
    @State private var submitting = false
    @State private var connectionMessage = ""

    private var validURL: Bool {
        if provider == .forgejo {
            guard let url = URL(string: forgejoServer.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return (try? ForgejoConnectionStore.origin(for: url)) != nil
        }
        guard let url = URL(string: githubURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return (1...2).contains(url.path.split(separator: "/").count)
    }
    private var validName: Bool { name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil }
    private var validScope: Bool {
        provider == .github || ((forgejoScope == .user || forgejoScope == .instance) ? scopeName.isEmpty
            : scopeName.range(of: forgejoScope == .repository ? #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"# : #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil)
    }
    private var nativeLabel: String {
        #if arch(arm64)
        return "macos-arm64:host"
        #else
        return "macos-x64:host"
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "plus.rectangle.on.folder.fill").font(.system(size: 27)).foregroundStyle(.indigo)
                    .frame(width: 52, height: 52).background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Give your next release a home.").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Register a GitHub or Forgejo runner on this Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(24)
            Divider()
            Form {
                Section {
                    Picker("Platform", selection: $provider) {
                        Text("GitHub").tag(RunnerProvider.github)
                        Text("Forgejo").tag(RunnerProvider.forgejo)
                    }.pickerStyle(.segmented).disabled(model.isCreating)
                    if provider == .github { githubFields } else { forgejoFields }
                } header: { Text("Connection") }
                Section {
                    TextField("Runner name", text: $name, prompt: Text("macbook-releases")).disabled(model.isCreating)
                    if attempted && !validName {
                        Text("Start with a letter or number. Use up to 64 letters, numbers, periods, hyphens or underscores.")
                            .font(.system(size: 10)).foregroundStyle(.red)
                    }
                    TextField("Labels", text: $labels, prompt: Text(provider == .github ? "local-mac-release, swift" : nativeLabel)).disabled(model.isCreating)
                    Text(provider == .github
                        ? "Separate labels with commas. GitHub adds self-hosted, macOS and architecture labels."
                        : "Separate labels with commas. Native Mac jobs use host labels, for example \(nativeLabel). Use the label before :host in runs-on.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if provider == .forgejo {
                        Stepper("Concurrent job slots: \(capacity)", value: $capacity, in: 1...8).disabled(model.isCreating)
                        Text("One slot runs one job. Start with one for Xcode builds; more slots share this Mac’s CPU and memory.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } header: { Text("Runner") }
                Section {
                    Toggle("Start automatically when I log in", isOn: $startsAtLogin).disabled(model.isCreating)
                    Label("Jobs run as your macOS account, with that account’s permissions.", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Installed in RunningMan/Runners/\(name.isEmpty ? "runner-name" : name) inside your Application Support folder.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if provider == .forgejo {
                        Text("Setup installs the official Homebrew forgejo-runner package if needed, then creates a dedicated login service. Existing services are kept separate.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("JavaScript actions such as checkout also require a compatible Node.js installation on this Mac.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } header: { Text("On this Mac") }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
                .disabled(model.isCreating || checkingConnection || submitting)
            if model.isCreating || !model.creationProgress.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    if model.isCreating { ProgressView().controlSize(.small) }
                    Text(model.creationProgress).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(4).textSelection(.enabled)
                }.padding(.horizontal, 24).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Button("Cancel") { token = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isCreating || checkingConnection || submitting)
                Spacer()
                Button(model.isCreating || submitting ? "Creating runner…" : "Create & start runner") { create() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.isCreating || checkingConnection || submitting)
            }.padding(20)
        }.frame(width: 640, height: 760)
            .onAppear { forgejoServer = model.demoMode ? "https://forge.example.com" : model.defaultForgejoServer }
            .onChange(of: provider) { _, platform in
                if labels == "local-mac-release" || labels == nativeLabel { labels = platform == .forgejo ? nativeLabel : "local-mac-release" }
                connectionMessage = ""
            }
            .onChange(of: forgejoScope) { _, value in
                if value == .user || value == .instance { scopeName = "" }
            }
            .interactiveDismissDisabled(model.isCreating || checkingConnection || submitting)
    }

    @ViewBuilder private var githubFields: some View {
        TextField("GitHub URL", text: $githubURL, prompt: Text("https://github.com/owner/repository")).disabled(model.isCreating)
        Text(attempted && !validURL ? "Enter an HTTPS github.com repository or organization URL." : "Use a repository URL, or an organization URL if you have owner access.")
            .font(.system(size: 10)).foregroundStyle(attempted && !validURL ? Color.red : .secondary)
        HStack {
            Text(model.githubAccount.map { "Connected as \($0)" } ?? "Uses your signed-in GitHub CLI").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Check connection") { Task { await model.checkGitHub() } }.controlSize(.small).disabled(model.isCreating)
        }
    }

    @ViewBuilder private var forgejoFields: some View {
        TextField("Forgejo server", text: $forgejoServer, prompt: Text("https://forge.example.com")).disabled(model.isCreating || checkingConnection || submitting)
        if attempted && !validURL { Text("Enter the HTTPS server URL.").font(.system(size: 10)).foregroundStyle(.red) }
        Picker("Registration scope", selection: $forgejoScope) {
            Text("Repository").tag(ForgejoRunnerScope.repository)
            Text("Organization").tag(ForgejoRunnerScope.organization)
            Text("My account").tag(ForgejoRunnerScope.user)
            Text("Entire instance").tag(ForgejoRunnerScope.instance)
        }.disabled(model.isCreating)
        if forgejoScope == .repository || forgejoScope == .organization {
            TextField(forgejoScope == .repository ? "Repository" : "Organization", text: $scopeName,
                      prompt: Text(forgejoScope == .repository ? "owner/repository" : "organization")).disabled(model.isCreating)
        }
        if attempted && !validScope { Text("Enter the repository as owner/name, or the organization name.").font(.system(size: 10)).foregroundStyle(.red) }
        SecureField("Access token", text: $token, prompt: Text("Leave empty to use the saved connection")).disabled(model.isCreating || checkingConnection || submitting)
        Text("Saved in your login Keychain. Creating or removing runners requires runner-management permission for the selected scope. Queue monitoring needs access to its Actions jobs.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        HStack {
            if checkingConnection { ProgressView().controlSize(.small) }
            Text(connectionMessage.isEmpty ? "Forgejo 15 or later with runner-management API support" : connectionMessage)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
            Spacer()
            Button("Connect") {
                checkingConnection = true
                Task {
                    let connected = await model.connectForgejo(server: forgejoServer, token: token)
                    connectionMessage = connected ? "Connected as \(model.forgejoAccount ?? "your Forgejo account")" : (model.errorMessage ?? "Connection failed")
                    if connected { token = "" }
                    checkingConnection = false
                }
            }.controlSize(.small).disabled(!validURL || model.isCreating || checkingConnection)
        }
    }

    private func create() {
        attempted = true
        guard validURL, validName, validScope, !submitting, !checkingConnection, !model.isCreating else { return }
        // Credential checking can suspend before the model begins installation.
        // Hold the sheet for the entire submission, and use exactly the values
        // the user submitted even if SwiftUI later updates this view's state.
        let submitted = (provider: provider, githubURL: githubURL, server: forgejoServer,
                         scope: forgejoScope, scopeName: scopeName, token: token, name: name,
                         labels: labels, capacity: capacity, startsAtLogin: startsAtLogin)
        submitting = true
        Task {
            defer { submitting = false }
            let created: Bool
            if submitted.provider == .github {
                created = await model.createRunner(githubURL: submitted.githubURL, name: submitted.name,
                    labels: submitted.labels, startsAtLogin: submitted.startsAtLogin)
            } else {
                if !submitted.token.isEmpty {
                    guard await model.connectForgejo(server: submitted.server, token: submitted.token) else { return }
                    token = ""
                }
                created = await model.createForgejoRunner(server: submitted.server, scope: submitted.scope,
                    scopeName: submitted.scopeName, name: submitted.name, labels: submitted.labels,
                    capacity: submitted.capacity, startsAtLogin: submitted.startsAtLogin)
            }
            if created { dismiss() }
        }
    }
}
