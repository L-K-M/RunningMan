import SwiftUI

struct NewRunnerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var githubURL = ""
    @State private var name = ""
    @State private var labels = "local-mac-release"
    @State private var startsAtLogin = true
    @State private var attempted = false
    @FocusState private var urlFocused: Bool

    private var validURL: Bool {
        guard let url = URL(string: githubURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return (1...2).contains(url.path.split(separator: "/").count)
    }
    private var validName: Bool { name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "plus.rectangle.on.folder.fill").font(.system(size: 27)).foregroundStyle(.indigo)
                    .frame(width: 52, height: 52).background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Give your next release a home.").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Register a GitHub Actions runner on this Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(26)
            Divider()
            Form {
                Section {
                    TextField("GitHub URL", text: $githubURL, prompt: Text("https://github.com/owner/repository"))
                        .focused($urlFocused).disabled(model.isCreating)
                    if attempted && !validURL {
                        Text("Enter an HTTPS github.com repository or organization URL.").font(.system(size: 10)).foregroundStyle(.red)
                    } else {
                        Text("Use a repository URL, or an organization URL if you have organization owner access.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    TextField("Runner name", text: $name, prompt: Text("macbook-releases")).disabled(model.isCreating)
                    if attempted && !validName {
                        Text("Start with a letter or number. Use up to 64 letters, numbers, periods, hyphens or underscores.")
                            .font(.system(size: 10)).foregroundStyle(.red)
                    }
                    TextField("Custom labels", text: $labels, prompt: Text("local-mac-release, swift")).disabled(model.isCreating)
                    Text("Separate labels with commas. The default self-hosted, macOS and architecture labels are added automatically.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } header: { Text("Registration") }
                Section {
                    Toggle("Start automatically when I log in", isOn: $startsAtLogin).disabled(model.isCreating)
                    Label("The runner starts as your macOS account and can run repository workflows with your account’s permissions.", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Installed in your personal Application Support folder").font(.system(size: 11))
                            Text("RunningMan/Runners/\(name.isEmpty ? "runner-name" : name)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("On this Mac") }
                Section {
                    HStack {
                        Image(systemName: model.githubAccount == nil ? "person.crop.circle.badge.questionmark" : "checkmark.circle.fill")
                            .foregroundStyle(model.githubAccount == nil ? Color.secondary : RunningManStyle.teal)
                        Text(model.githubAccount.map { "Connected as \($0)" } ?? "Requires GitHub CLI authentication")
                            .font(.system(size: 11))
                        Spacer()
                        Button("Check connection") { Task { await model.checkGitHub() } }.controlSize(.small).disabled(model.isCreating)
                    }
                    Text("RunningMan uses your signed-in GitHub CLI to request a short-lived registration token. You need admin permission for the selected repository.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            if model.isCreating || !model.creationProgress.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    if model.isCreating { ProgressView().controlSize(.small) }
                    Text(model.creationProgress).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(4).textSelection(.enabled)
                }.padding(.horizontal, 26).padding(.bottom, 15)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isCreating)
                Spacer()
                Button(model.isCreating ? "Creating runner…" : "Create & start runner") {
                    attempted = true
                    guard validURL, validName else { return }
                    Task {
                        if await model.createRunner(githubURL: githubURL, name: name, labels: labels, startsAtLogin: startsAtLogin) { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.isCreating)
            }.padding(20)
        }.frame(width: 600, height: 690).onAppear { urlFocused = true }
            .interactiveDismissDisabled(model.isCreating)
    }
}
