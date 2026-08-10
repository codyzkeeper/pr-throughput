import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("notification.mention.enabled") private var mentions = true
    @AppStorage("notification.approved.enabled") private var approved = true
    @AppStorage("notification.merged.enabled") private var merged = true

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Direct mention alerts", isOn: $mentions)
                    .help("Play a time-sensitive system alert when someone directly tags your GitHub username. The in-app feed remains enabled.")
                Toggle("PR approved — quiet", isOn: $approved)
                Toggle("PR merged — quiet", isOn: $merged)
            }
            Section("GitHub") {
                LabeledContent("Account", value: accountValue)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("GitHub account")
                    .accessibilityValue(accountValue)
                TextField("OAuth client ID", text: $model.oauthClientID)
                Link("Manage OAuth authorization", destination: URL(string: "https://github.com/settings/applications")!)
                Button("Sign out", role: .destructive) { model.signOut() }
            }
            Section("Diagnostics") {
                diagnostic("Last full sync", value: model.snapshot?.metadata.lastSuccessfulSync?.formatted() ?? "Never")
                diagnostic("GitHub API quota remaining", value: model.snapshot?.metadata.rateState.remaining.map(String.init) ?? "Unknown")
                diagnostic("Tracked PR records", value: String(model.snapshot?.pullRequests.count ?? 0))
                diagnostic("Tracked timeline events", value: String(model.snapshot?.events.count ?? 0))
            }
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 430)
    }

    private var accountValue: String {
        model.snapshot.map { "@\($0.viewer.login)" } ?? "Not connected"
    }

    private func diagnostic(_ label: String, value: String) -> some View {
        LabeledContent(label, value: value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}
