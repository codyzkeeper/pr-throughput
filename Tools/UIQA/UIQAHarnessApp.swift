import SwiftUI

@main
struct UIQAHarnessApp: App {
    @StateObject private var model: AppModel

    init() {
        // Prevent the production view's task from reading Keychain or starting network work.
        setenv("XCTestConfigurationFilePath", "PRThroughputUIQA", 1)
        let actionConfiguration = ActionNotificationConfiguration(
            schemaVersion: ActionNotificationConfiguration.schemaVersion,
            organization: "Example-Organization",
            rules: [
                ActionRuleConfiguration(id: .decide, labelName: "owner: decide", isEnabled: true),
                ActionRuleConfiguration(id: .invokeR2, labelName: "owner: invoke R2", isEnabled: true),
                ActionRuleConfiguration(id: .assignReviewer, labelName: "owner: assign reviewer", isEnabled: true),
                ActionRuleConfiguration(id: .mergeable, labelName: "owner: mergeable", isEnabled: true)
            ]
        )
        let model = AppModel(
            snapshotStore: try? SnapshotStore(inMemory: true),
            actionConfiguration: actionConfiguration
        )
        model.connectionState = .connected
#if UIQA_INITIAL_SYNC
        model.isSyncing = true
#else
        if CommandLine.arguments.contains("--initial-sync") {
            model.isSyncing = true
        } else {
            model.snapshot = Self.fixture(configurationRevision: actionConfiguration.revision)
        }
#endif
        model.setPopoverPresented(true)
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup("PR Throughput UI QA") {
            MenuPopoverView(model: model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model)
        }
    }

    private static func fixture(configurationRevision: String, now: Date = Date()) -> AppSnapshot {
        let viewer = GitHubUser(id: "viewer", login: "ui-qa", kind: .user)
        let pulls = [
            pull("pr-1", number: 101, eligibleAt: now.addingTimeInterval(-24 * 3_600), state: .merged,
                 mergedAt: now.addingTimeInterval(-10 * 3_600)),
            pull("pr-2", number: 102, eligibleAt: now.addingTimeInterval(-30 * 3_600), state: .open),
            pull("pr-3", number: 103, eligibleAt: now.addingTimeInterval(-5 * 86_400), state: .closed,
                 closedAt: now.addingTimeInterval(-4 * 86_400)),
            pull("pr-4", number: 104, eligibleAt: now.addingTimeInterval(-2 * 86_400), isDraft: true, state: .open),
            pull("pr-5", number: 105, eligibleAt: now.addingTimeInterval(-10 * 86_400), state: .merged,
                 mergedAt: now.addingTimeInterval(-9 * 86_400))
        ]
        let handoffs = [
            Handoff(id: "handoff-1", pullRequestID: "pr-1", reviewerID: "reviewer-a",
                    at: now.addingTimeInterval(-20 * 3_600),
                    outcome: .approved(at: now.addingTimeInterval(-12 * 3_600), reviewID: "review-1")),
            Handoff(id: "handoff-2", pullRequestID: "pr-2", reviewerID: "reviewer-b",
                    at: now.addingTimeInterval(-25 * 3_600),
                    outcome: .changesRequested(at: now.addingTimeInterval(-23 * 3_600), reviewID: "review-2")),
            Handoff(id: "handoff-3", pullRequestID: "pr-2", reviewerID: "reviewer-b",
                    at: now.addingTimeInterval(-2 * 3_600), outcome: .pending),
            Handoff(id: "handoff-4", pullRequestID: "pr-5", reviewerID: "reviewer-c",
                    at: now.addingTimeInterval(-9.5 * 86_400),
                    outcome: .approved(at: now.addingTimeInterval(-9 * 86_400), reviewID: "review-3"))
        ]
        let reviewerA = GitHubUser(id: "reviewer-a", login: "alice", kind: .user)
        let reviewerB = GitHubUser(id: "reviewer-b", login: "bob", kind: .user)
        let events = [
            TimelineEvent(id: "review-1", pullRequestID: "pr-1",
                          kind: .reviewed(reviewer: reviewerA, state: .approved),
                          at: now.addingTimeInterval(-12 * 3_600)),
            TimelineEvent(id: "review-2", pullRequestID: "pr-2",
                          kind: .reviewed(reviewer: reviewerB, state: .changesRequested),
                          at: now.addingTimeInterval(-23 * 3_600)),
            TimelineEvent(id: "draft-4", pullRequestID: "pr-4", kind: .convertedToDraft,
                          at: now.addingTimeInterval(-24 * 3_600))
        ]
        return AppSnapshot(
            viewer: viewer,
            pullRequests: pulls,
            events: events,
            handoffs: handoffs,
            assignedPullRequestIDs: ["pr-2"],
            attentionItems: [
                AttentionItem.action(
                    pullRequestID: "pr-action", title: "Choose the rollout approach",
                    repository: "example/repository", number: 106,
                    url: URL(string: "https://github.com/example/repository/pull/106")!,
                    applications: [
                        ActionLabelApplication(
                            pullRequestID: "pr-action", ruleID: .decide, labelID: "label-red",
                            labelEventID: "event-red", labelName: "decision needed", colorHex: "B60205",
                            appliedAt: now, seenAt: nil, dismissedAt: nil
                        ),
                        ActionLabelApplication(
                            pullRequestID: "pr-action", ruleID: .assignReviewer, labelID: "label-green",
                            labelEventID: "event-green", labelName: "assign reviewer", colorHex: "0E8A16",
                            appliedAt: now.addingTimeInterval(-60), seenAt: now, dismissedAt: nil
                        )
                    ]
                ),
                AttentionItem.action(
                    pullRequestID: "pr-mergeable", title: "Ship the verified release",
                    repository: "example/automation", number: 107,
                    url: URL(string: "https://github.com/example/automation/pull/107")!,
                    applications: [ActionLabelApplication(
                        pullRequestID: "pr-mergeable", ruleID: .mergeable, labelID: "label-blue",
                        labelEventID: "event-blue", labelName: "ready to merge", colorHex: "0052CC",
                        appliedAt: now.addingTimeInterval(-30), seenAt: nil, dismissedAt: nil
                    )]
                )
            ],
            metadata: SyncMetadata(
                lastSuccessfulSync: now,
                lastNotificationSync: now,
                lastError: nil,
                rateState: GitHubRateState(remaining: 4_999, resetAt: nil),
                baselineEstablished: true,
                actionAuthorityVersion: 1,
                actionConfigurationRevision: configurationRevision,
                lastSuccessfulActionLabelSync: now,
                actionSearchDisagreementCount: 0
            )
        )
    }

    private static func pull(
        _ id: String,
        number: Int,
        eligibleAt: Date,
        isDraft: Bool = false,
        state: PullRequestState,
        mergedAt: Date? = nil,
        closedAt: Date? = nil
    ) -> PullRequestSnapshot {
        PullRequestSnapshot(
            id: id,
            repository: "example/repository",
            number: number,
            title: "UI QA pull request \(number)",
            url: URL(string: "https://github.com/example/repository/pull/\(number)")!,
            authorID: "viewer",
            eligibleAt: eligibleAt,
            updatedAt: eligibleAt,
            isDraft: isDraft,
            state: state,
            mergedAt: mergedAt,
            closedAt: closedAt
        )
    }
}
