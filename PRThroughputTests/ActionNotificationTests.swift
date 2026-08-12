import XCTest
@testable import PRThroughput

final class ActionNotificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testConfigurationRejectsUnsafeInputsAndBuildsQuotedSearches() throws {
        var configuration = ActionNotificationConfiguration.blank
        configuration.organization = "Example-Organization"
        configuration.rules[0].labelName = "owner: decide"
        configuration.rules[0].isEnabled = true

        XCTAssertNoThrow(try configuration.validated())
        XCTAssertEqual(
            try configuration.searchQuery(for: configuration.rules[0]),
            #"org:Example-Organization is:pr is:open label:\"owner: decide\""#
        )

        configuration.organization = "Bad Organization\norg:other"
        XCTAssertThrowsError(try configuration.validated())
    }

    func testConfigurationPersistsAtomicallyAndRevisionIsCanonical() throws {
        let suiteName = "ActionNotificationTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let value = configured()
        var reordered = value
        reordered.rules.reverse()

        try value.save(defaults: suite)

        XCTAssertEqual(ActionNotificationConfiguration.load(defaults: suite), try value.validated())
        XCTAssertEqual(reordered.revision, value.revision)
        XCTAssertTrue(ActionNotificationConfiguration.blank.organization.isEmpty)
        XCTAssertTrue(ActionNotificationConfiguration.blank.rules.allSatisfy { !$0.isEnabled && $0.labelName.isEmpty })
    }

    func testActionRowsAggregateApplicationsAndPrioritizeUnseenColor() {
        let green = application(rule: .assignReviewer, event: "green", color: "0E8A16")
        let yellow = application(rule: .invokeR2, event: "yellow", color: "FBCA04")
        let red = application(rule: .decide, event: "red", color: "B60205")
        let item = AttentionItem.action(
            pullRequestID: "PR_1",
            title: "A pull request",
            repository: "org/repo",
            number: 27,
            url: URL(string: "https://github.com/org/repo/pull/27")!,
            applications: [green, yellow, red]
        )

        XCTAssertEqual(item.applications.count, 3)
        XCTAssertEqual(item.highestPriorityUnseenApplication?.labelEventID, "red")
        XCTAssertEqual(item.highestPriorityUnseenApplication?.colorHex, "B60205")
        XCTAssertTrue(item.isActive)
        XCTAssertTrue(item.isUnseen)
    }

    func testPresentationStateOnlyCarriesAcrossIdenticalEventIDs() {
        var old = application(rule: .assignReviewer, event: "old", color: "0E8A16")
        old.seenAt = now
        old.dismissedAt = now
        old.deliveredAt = now
        let reapplied = application(rule: .assignReviewer, event: "new", color: "0E8A16")

        let merged = ActionAttentionMerger.mergePresentation(
            incoming: [reapplied],
            previous: [old]
        )

        XCTAssertNil(merged[0].seenAt)
        XCTAssertNil(merged[0].dismissedAt)
        XCTAssertNil(merged[0].deliveredAt)
    }

    func testRemovingOneLabelDoesNotRedeliverAnExistingApplication() {
        var retained = application(rule: .assignReviewer, event: "green", color: "0E8A16")
        retained.deliveredAt = now
        var removed = application(rule: .decide, event: "red", color: "B60205")
        removed.deliveredAt = now

        let merged = ActionAttentionMerger.mergePresentation(
            incoming: [application(rule: .assignReviewer, event: "green", color: "0E8A16")],
            previous: [retained, removed]
        )
        let item = AttentionItem.action(
            pullRequestID: "PR_1", title: "PR", repository: "org/repo", number: 1,
            url: URL(string: "https://github.com/org/repo/pull/1")!, applications: merged
        )

        XCTAssertFalse(item.hasUndeliveredApplication)
    }

    func testNewApplicationDeliversEvenWhenExistingLabelWasAlreadyDelivered() {
        var existing = application(rule: .decide, event: "red", color: "B60205")
        existing.deliveredAt = now
        let new = application(rule: .assignReviewer, event: "green", color: "0E8A16")
        let item = AttentionItem.action(
            pullRequestID: "PR_1", title: "PR", repository: "org/repo", number: 1,
            url: URL(string: "https://github.com/org/repo/pull/1")!, applications: [existing, new]
        )

        XCTAssertEqual(item.highestPriorityUndeliveredApplication?.labelEventID, "green")
        XCTAssertTrue(item.markingUndeliveredApplicationsDelivered(at: now)
            .applications.allSatisfy { $0.deliveredAt != nil })
    }

    func testFastActionCandidatesIncludePriorAssignedAndOnlyTwentyMostRecentAuthoredPRs() {
        var snapshot = emptySnapshot(actionItems: [])
        snapshot.assignedPullRequestIDs = ["assigned"]
        snapshot.pullRequests = (0..<25).map { index in
            PullRequestSnapshot(
                id: "authored-\(index)", repository: "Org/repo", number: index + 1,
                title: "PR \(index)", url: URL(string: "https://github.com/Org/repo/pull/\(index + 1)")!,
                authorID: "me", eligibleAt: now.addingTimeInterval(-1_000),
                updatedAt: now.addingTimeInterval(TimeInterval(-index)), isDraft: false,
                state: .open, mergedAt: nil, closedAt: nil
            )
        }

        let candidates = SyncCoordinator.actionCandidateIDs(
            snapshot: snapshot,
            priorItems: [actionItem()]
        )

        XCTAssertTrue(candidates.contains("assigned"))
        XCTAssertTrue(candidates.contains("PR_1"))
        XCTAssertTrue(candidates.contains("authored-0"))
        XCTAssertTrue(candidates.contains("authored-19"))
        XCTAssertFalse(candidates.contains("authored-20"))
        XCTAssertEqual(candidates.count, 22)
    }

    func testSystemNotificationIdentifierIsStableAccountScopedAndOpaque() {
        let first = ActionNotificationIdentifier.value(accountID: "account-a", pullRequestID: "PR_1")
        XCTAssertEqual(first, ActionNotificationIdentifier.value(accountID: "account-a", pullRequestID: "PR_1"))
        XCTAssertNotEqual(first, ActionNotificationIdentifier.value(accountID: "account-b", pullRequestID: "PR_1"))
        XCTAssertTrue(first.hasPrefix("pr-throughput.action."))
        XCTAssertFalse(first.contains("account-a"))
        XCTAssertFalse(first.contains("PR_1"))
    }

    func testViewingActionRowMarksItSeenButKeepsItActiveWhileLabelExists() {
        let item = AttentionItem.action(
            pullRequestID: "PR_1", title: "PR", repository: "org/repo", number: 1,
            url: URL(string: "https://github.com/org/repo/pull/1")!,
            applications: [application(rule: .decide, event: "one", color: "B60205")]
        )

        let result = item.markingSeen(revision: item.revisionID!, at: now)

        XCTAssertTrue(result.didMutate)
        XCTAssertTrue(result.item.isActive)
        XCTAssertFalse(result.item.isUnseen)
        XCTAssertEqual(result.item.applications.count, 1)
    }

    func testLegacyDismissedApplicationRemainsVisibleButSeen() {
        var legacy = application(rule: .decide, event: "one", color: "B60205")
        legacy.seenAt = now
        legacy.dismissedAt = now
        let item = AttentionItem.action(
            pullRequestID: "PR_1", title: "PR", repository: "org/repo", number: 1,
            url: URL(string: "https://github.com/org/repo/pull/1")!, applications: [legacy]
        )

        XCTAssertTrue(item.isActive)
        XCTAssertFalse(item.isUnseen)
        XCTAssertEqual(item.highestPriorityActiveApplication?.labelEventID, "one")
    }

    func testStaleRevisionCannotMarkNewApplicationSeen() {
        let first = AttentionItem.action(
            pullRequestID: "PR_1", title: "PR", repository: "org/repo", number: 1,
            url: URL(string: "https://github.com/org/repo/pull/1")!,
            applications: [application(rule: .assignReviewer, event: "one", color: "0E8A16")]
        )
        let second = AttentionItem.action(
            pullRequestID: "PR_1", title: "PR", repository: "org/repo", number: 1,
            url: URL(string: "https://github.com/org/repo/pull/1")!,
            applications: first.applications + [application(rule: .decide, event: "two", color: "B60205")]
        )

        XCTAssertNotEqual(first.revisionID, second.revisionID)
        XCTAssertFalse(second.markingSeen(revision: first.revisionID!, at: now).didMutate)
        XCTAssertTrue(second.markingSeen(revision: second.revisionID!, at: now).didMutate)
    }

    func testReconcilerRejectsDuplicateApplicationIDsAndBadColors() {
        let duplicate = application(rule: .decide, event: "same", color: "NOTHEX")
        let item = AttentionItem.action(
            pullRequestID: "PR_1", title: "PR", repository: "org/repo", number: 1,
            url: URL(string: "https://github.com/org/repo/pull/1")!,
            applications: [duplicate, duplicate]
        )
        let snapshot = AppSnapshot(
            viewer: GitHubUser(id: "me", login: "me", kind: .user),
            pullRequests: [], events: [], handoffs: [], assignedPullRequestIDs: [],
            attentionItems: [item], metadata: .empty
        )

        let issues = SnapshotReconciler.validate(snapshot).issues.joined(separator: " ")
        XCTAssertTrue(issues.contains("duplicate action-label application"))
        XCTAssertTrue(issues.contains("invalid label color"))
    }

    func testReconcilerRejectsApplicationsOutsideActiveConfiguration() {
        let item = AttentionItem.action(
            pullRequestID: "PR_1", title: "PR", repository: "org/repo", number: 1,
            url: URL(string: "https://github.com/org/repo/pull/1")!,
            applications: [application(rule: .decide, event: "event", color: "B60205")]
        )
        var snapshot = emptySnapshot(actionItems: [item])
        let configuration = configured()
        snapshot.metadata.actionAuthorityVersion = 1
        snapshot.metadata.actionConfigurationRevision = configuration.revision

        let issues = SnapshotReconciler.validate(
            snapshot,
            actionConfiguration: configuration
        ).issues.joined(separator: " ")

        XCTAssertTrue(issues.contains("does not match the active configuration"))
    }

    func testFailedActionDiscoveryPreservesPriorVerifiedFacts() async throws {
        let configuration = configured()
        var previous = emptySnapshot(actionItems: [actionItem()])
        previous.metadata.actionAuthorityVersion = 1
        previous.metadata.actionConfigurationRevision = configuration.revision
        previous.metadata.lastSuccessfulActionLabelSync = now
        var request = 0
        StubURLProtocol.handler = { urlRequest in
            request += 1
            if request == 1 {
                return Self.graphQLResponse(urlRequest, #"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#)
            }
            return (
                HTTPURLResponse(url: urlRequest.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data(#"{"message":"temporary"}"#.utf8)
            )
        }
        let coordinator = SyncCoordinator(api: GitHubAPI(token: "test", session: stubSession()))

        let result = try await coordinator.refreshAssigned(previous: previous, now: now, configuration: configuration)

        XCTAssertEqual(result.snapshot.attentionItems.map(\.id), ["action:PR_1"])
        XCTAssertEqual(result.snapshot.metadata.lastSuccessfulActionLabelSync, now)
        XCTAssertNotNil(result.snapshot.metadata.lastActionLabelError)
    }

    func testSuccessfulEmptyDirectStateRemovesPriorFacts() async throws {
        let configuration = configured()
        var previous = emptySnapshot(actionItems: [actionItem()])
        previous.metadata.actionAuthorityVersion = 1
        previous.metadata.actionConfigurationRevision = configuration.revision
        previous.metadata.lastSuccessfulActionLabelSync = now.addingTimeInterval(-60)
        var request = 0
        StubURLProtocol.handler = { urlRequest in
            request += 1
            switch request {
            case 1, 2:
                return Self.graphQLResponse(urlRequest, #"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#)
            default:
                return Self.graphQLResponse(urlRequest, #"{"data":{"nodes":[{"id":"PR_1","number":1,"title":"PR","url":"https://github.com/Org/repo/pull/1","updatedAt":"2027-01-15T08:00:00Z","state":"OPEN","isDraft":false,"repository":{"nameWithOwner":"Org/repo"},"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null,"hasPreviousPage":false,"startCursor":null},"nodes":[]},"timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null,"hasPreviousPage":false,"startCursor":null},"nodes":[]}}]}}"#)
            }
        }
        let coordinator = SyncCoordinator(api: GitHubAPI(token: "test", session: stubSession()))

        let result = try await coordinator.refreshAssigned(previous: previous, now: now, configuration: configuration)

        XCTAssertTrue(result.snapshot.attentionItems.isEmpty)
        XCTAssertEqual(result.snapshot.metadata.lastSuccessfulActionLabelSync, now)
        XCTAssertNil(result.snapshot.metadata.lastActionLabelError)
    }

    func testAssignedRefreshCanPreserveIndependentActionAuthority() async throws {
        let configuration = configured()
        var previous = emptySnapshot(actionItems: [actionItem()])
        previous.metadata.actionAuthorityVersion = 1
        previous.metadata.actionConfigurationRevision = configuration.revision
        previous.metadata.lastSuccessfulActionLabelSync = now
        var requestCount = 0
        StubURLProtocol.handler = { request in
            requestCount += 1
            return Self.graphQLResponse(
                request,
                #"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#
            )
        }
        let coordinator = SyncCoordinator(api: GitHubAPI(token: "test", session: stubSession()))

        let result = try await coordinator.refreshAssigned(
            previous: previous,
            now: now.addingTimeInterval(15),
            configuration: configuration,
            includeActionAuthority: false
        )

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(result.snapshot.attentionItems.map(\.id), ["action:PR_1"])
        XCTAssertEqual(result.snapshot.metadata.lastSuccessfulActionLabelSync, now)
    }

    func testIndependentActionRefreshRemovesStaleLabelFacts() async throws {
        let configuration = configured()
        var previous = emptySnapshot(actionItems: [actionItem()])
        previous.metadata.actionAuthorityVersion = 1
        previous.metadata.actionConfigurationRevision = configuration.revision
        previous.metadata.lastSuccessfulActionLabelSync = now.addingTimeInterval(-60)
        var requestCount = 0
        StubURLProtocol.handler = { request in
            requestCount += 1
            let payload = requestCount == 1
                ? #"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#
                : #"{"data":{"nodes":[{"id":"PR_1","number":1,"title":"PR","url":"https://github.com/Org/repo/pull/1","updatedAt":"2027-01-15T08:00:00Z","state":"OPEN","isDraft":false,"repository":{"nameWithOwner":"Org/repo"},"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null,"hasPreviousPage":false,"startCursor":null},"nodes":[]},"timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null,"hasPreviousPage":false,"startCursor":null},"nodes":[]}}]}}"#
            return Self.graphQLResponse(request, payload)
        }
        let coordinator = SyncCoordinator(api: GitHubAPI(token: "test", session: stubSession()))
        let refreshedAt = now.addingTimeInterval(15)

        let result = try await coordinator.refreshActions(
            previous: previous,
            configuration: configuration,
            now: refreshedAt
        )

        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(result.attentionItems.isEmpty)
        XCTAssertEqual(result.metadata.lastSuccessfulActionLabelSync, refreshedAt)
    }

    private func application(
        rule: ActionRuleID,
        event: String,
        color: String,
        labelName: String? = nil
    ) -> ActionLabelApplication {
        ActionLabelApplication(
            pullRequestID: "PR_1", ruleID: rule, labelID: "label-\(rule.rawValue)",
            labelEventID: event, labelName: labelName ?? rule.rawValue, colorHex: color,
            appliedAt: now, seenAt: nil, dismissedAt: nil
        )
    }

    private func configured() -> ActionNotificationConfiguration {
        ActionNotificationConfiguration(
            schemaVersion: 1, organization: "Org",
            rules: [
                ActionRuleConfiguration(id: .decide, labelName: "action needed", isEnabled: true),
                ActionRuleConfiguration(id: .invokeR2, labelName: "", isEnabled: false),
                ActionRuleConfiguration(id: .assignReviewer, labelName: "", isEnabled: false)
            ]
        )
    }

    private func actionItem() -> AttentionItem {
        AttentionItem.action(
            pullRequestID: "PR_1", title: "PR", repository: "Org/repo", number: 1,
            url: URL(string: "https://github.com/Org/repo/pull/1")!,
            applications: [application(
                rule: .decide, event: "event", color: "B60205", labelName: "action needed"
            )]
        )
    }

    private func emptySnapshot(actionItems: [AttentionItem]) -> AppSnapshot {
        AppSnapshot(
            viewer: GitHubUser(id: "me", login: "me", kind: .user),
            pullRequests: [], events: [], handoffs: [], assignedPullRequestIDs: [],
            attentionItems: actionItems,
            metadata: SyncMetadata(
                lastSuccessfulSync: now, lastNotificationSync: nil, lastError: nil,
                rateState: GitHubRateState(remaining: nil, resetAt: nil), baselineEstablished: true
            )
        )
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func graphQLResponse(_ request: URLRequest, _ payload: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
    }
}
