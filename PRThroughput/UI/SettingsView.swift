import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("notification.approved.enabled") private var approved = true
    @AppStorage("notification.merged.enabled") private var merged = true
    @State private var actionDraft: ActionNotificationConfiguration
    @State private var actionError: String?

    init(model: AppModel) {
        self.model = model
        _actionDraft = State(initialValue: model.actionConfiguration)
    }

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("PR approved — quiet", isOn: $approved)
                Toggle("PR merged — quiet", isOn: $merged)
            }
            Section("Action labels") {
                TextField("GitHub organization", text: $actionDraft.organization)
                    .textFieldStyle(.roundedBorder)
                Text("An open pull request appears in Needs attention while it has an enabled label.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(actionDraft.rules.indices, id: \.self) { index in
                    HStack {
                        Toggle(actionDraft.rules[index].id.displayName, isOn: $actionDraft.rules[index].isEnabled)
                            .frame(width: 155, alignment: .leading)
                        TextField("GitHub label", text: $actionDraft.rules[index].labelName)
                            .textFieldStyle(.roundedBorder)
                    }
                    .help("Priority \(index + 1). The menu-bar dot uses this label's color from GitHub.")
                }
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Revert") {
                        actionDraft = model.actionConfiguration
                        actionError = nil
                    }
                    Button("Save") {
                        do {
                            try model.saveActionConfiguration(actionDraft)
                            actionDraft = model.actionConfiguration
                            actionError = nil
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(actionDraft == model.actionConfiguration)
                }
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
                diagnostic("Action-label state", value: actionState)
                diagnostic("macOS notification permission", value: model.notificationAuthorizationStatus)
                diagnostic("Action PRs", value: String(model.snapshot?.attentionItems.count ?? 0))
                diagnostic("Action label facts", value: String(model.snapshot?.attentionItems.flatMap(\.applications).count ?? 0))
                diagnostic("Search/direct disagreements", value: model.snapshot?.metadata.actionSearchDisagreementCount.map(String.init) ?? "Unknown")
                if let error = model.snapshot?.metadata.lastActionLabelError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 650)
    }

    private var actionState: String {
        guard model.actionConfiguration.isConfigured else { return "Unconfigured" }
        if model.isSyncing { return "Refreshing" }
        if model.snapshot?.metadata.lastActionLabelError != nil { return "Error — previous verified state preserved" }
        guard let date = model.snapshot?.metadata.lastSuccessfulActionLabelSync else { return "Waiting for first sync" }
        return Date().timeIntervalSince(date) > 60 ? "Stale — \(date.formatted())" : "Fresh — \(date.formatted())"
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
