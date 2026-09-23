import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("notification.approved.enabled") private var approved = true
    @AppStorage("notification.merged.enabled") private var merged = true
    @State private var actionDraft: ActionNotificationConfiguration
    @State private var actionError: String?
    @State private var labelSearch = ""

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
                Text("Choose labels from accessible Keeper-Dating repositories and set how each one notifies you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Search GitHub labels", text: $labelSearch)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await model.refreshLabelCatalog(force: true) }
                    } label: {
                        if model.isLoadingLabelCatalog {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh labels from GitHub")
                }
                if let error = model.labelCatalogError {
                    Text("Label catalog unavailable: \(error)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if actionDraft.rules.isEmpty {
                    Text("No labels selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(actionDraft.rules) { rule in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(color(for: rule))
                                .frame(width: 10, height: 10)
                            Text(rule.labelName)
                                .lineLimit(1)
                            if !isAvailable(rule) {
                                Text("Unavailable")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Picker("Notification", selection: binding(for: rule.id).notificationLevel) {
                                ForEach(NotificationLevel.allCases, id: \.self) { level in
                                    Text(level.displayName).tag(level)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            Button { remove(rule.id) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove label")
                        }
                    }
                }
                let available = filteredCatalog
                if !available.isEmpty {
                    Text("Available labels")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(available) { entry in
                        Button { addOrRemove(entry) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected(entry) ? "checkmark.square.fill" : "square")
                                Circle().fill(color(for: entry)).frame(width: 10, height: 10)
                                Text(entry.name).lineLimit(1)
                                Spacer()
                                Text("\(entry.repositoryCount) repos")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } else if model.labelCatalog.isEmpty && !model.isLoadingLabelCatalog {
                    Text("No labels loaded yet. Refresh after signing in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .frame(width: 560, height: 700)
        .task { await model.refreshLabelCatalog() }
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

    private var filteredCatalog: [GitHubLabelCatalogEntry] {
        let query = labelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.labelCatalog.filter { query.isEmpty || $0.name.lowercased().contains(query) }
    }

    private func isSelected(_ entry: GitHubLabelCatalogEntry) -> Bool {
        actionDraft.rules.contains { $0.id == entry.key }
    }

    private func isAvailable(_ rule: ActionLabelRuleConfiguration) -> Bool {
        model.labelCatalog.contains { $0.key == rule.id }
    }

    private func binding(for id: String) -> Binding<ActionLabelRuleConfiguration> {
        Binding(
            get: { actionDraft.rules.first(where: { $0.id == id }) ?? ActionLabelRuleConfiguration(labelName: "", notificationLevel: .persistent) },
            set: { updated in
                guard let index = actionDraft.rules.firstIndex(where: { $0.id == id }) else { return }
                actionDraft.rules[index] = updated
            }
        )
    }

    private func addOrRemove(_ entry: GitHubLabelCatalogEntry) {
        if let index = actionDraft.rules.firstIndex(where: { $0.id == entry.key }) {
            actionDraft.rules.remove(at: index)
        } else {
            actionDraft.rules.append(ActionLabelRuleConfiguration(labelName: entry.name))
            actionDraft.rules.sort { $0.id < $1.id }
        }
    }

    private func remove(_ id: String) {
        actionDraft.rules.removeAll { $0.id == id }
    }

    private func color(for rule: ActionLabelRuleConfiguration) -> Color {
        color(for: model.labelCatalog.first { $0.key == rule.id }?.colorHex)
    }

    private func color(for entry: GitHubLabelCatalogEntry) -> Color {
        color(for: entry.colorHex)
    }

    private func color(for hex: String?) -> Color {
        guard let hex, let value = Int(hex, radix: 16) else { return .secondary }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
