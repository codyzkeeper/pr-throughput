import XCTest
@testable import PRThroughput

final class SyncCoordinatorTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testRefreshCadenceRunsAssignedEveryFifteenSecondsAndFullEveryFiveMinutes() {
        XCTAssertEqual(AppModel.scheduledRefresh(atTick: 1), .assignedOnly)
        XCTAssertEqual(AppModel.scheduledRefresh(atTick: 19), .assignedOnly)
        XCTAssertEqual(AppModel.scheduledRefresh(atTick: 20), .full)
        XCTAssertEqual(AppModel.scheduledRefresh(atTick: 40), .full)
    }

    func testOnlyUnauthorizedFailuresInvalidateTheSession() {
        XCTAssertTrue(AppModel.shouldDisconnect(after: GitHubAPIError.unauthorized))
        XCTAssertFalse(AppModel.shouldDisconnect(after: GitHubAPIError.rateLimited(resetAt: nil)))
        XCTAssertFalse(AppModel.shouldDisconnect(after: URLError(.notConnectedToInternet)))
    }

    func testTimelineCacheRequiresCurrentSchemaAndUnchangedPullRequest() {
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(SyncCoordinator.canReuseTimeline(
            schemaVersion: nil,
            cachedUpdatedAt: updatedAt,
            currentUpdatedAt: updatedAt
        ))
        XCTAssertFalse(SyncCoordinator.canReuseTimeline(
            schemaVersion: TimelineEvent.sourceSchemaVersion,
            cachedUpdatedAt: updatedAt.addingTimeInterval(-1),
            currentUpdatedAt: updatedAt
        ))
        XCTAssertTrue(SyncCoordinator.canReuseTimeline(
            schemaVersion: TimelineEvent.sourceSchemaVersion,
            cachedUpdatedAt: updatedAt,
            currentUpdatedAt: updatedAt
        ))
    }

    func testTimelineNotificationDeltaExcludesKnownAndStaleEvents() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let known = TimelineEvent(id: "known", pullRequestID: "pr", kind: .merged, at: now)
        let stale = TimelineEvent(id: "stale", pullRequestID: "pr", kind: .merged, at: now.addingTimeInterval(-3_600))
        let recent = TimelineEvent(id: "recent", pullRequestID: "pr", kind: .merged, at: now.addingTimeInterval(-60))
        var metadata = SyncMetadata.empty
        metadata.baselineEstablished = true
        metadata.lastSuccessfulSync = now
        let previous = AppSnapshot(
            viewer: viewer,
            pullRequests: [],
            events: [known],
            handoffs: [],
            assignedPullRequestIDs: [],
            attentionItems: [],
            metadata: metadata
        )

        let delta = SyncCoordinator.timelineNotificationDelta(
            events: [known, stale, recent],
            previous: previous
        )

        XCTAssertEqual(delta.map(\.id), ["recent"])
    }

    func testAssignmentRefreshDoesNotAdvanceFullSyncFreshness() async throws {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data(#"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#.utf8)
            return (response, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "test", session: URLSession(configuration: configuration))
        let coordinator = SyncCoordinator(api: api)
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let fullSyncAt = Date(timeIntervalSince1970: 1_700_000_000)
        var metadata = SyncMetadata.empty
        metadata.lastSuccessfulSync = fullSyncAt
        let previous = AppSnapshot(
            viewer: viewer,
            pullRequests: [],
            events: [],
            handoffs: [],
            assignedPullRequestIDs: ["old"],
            attentionItems: [],
            metadata: metadata
        )

        let result = try await coordinator.refreshAssigned(previous: previous)

        XCTAssertEqual(result.snapshot.metadata.lastSuccessfulSync, fullSyncAt)
        XCTAssertTrue(result.snapshot.assignedPullRequestIDs.isEmpty)
    }

    func testAssignmentRemovalImmediatelyCreatesAndContinuesWatchingHandoff() async throws {
        let now = Date(timeIntervalSince1970: 1_786_032_000)
        let formatter = ISO8601DateFormatter()
        let unassignedAt = formatter.string(from: now.addingTimeInterval(-30))
        let assignedAt = formatter.string(from: now.addingTimeInterval(-20))
        let requestedAt = formatter.string(from: now.addingTimeInterval(-10))
        let reviewedAt = formatter.string(from: now.addingTimeInterval(5))
        var includeDecision = false
        var timelineRequestCount = 0
        StubURLProtocol.handler = { request in
            let body = try XCTUnwrap(request.httpBody ?? Self.readBodyStream(request.httpBodyStream))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let query = try XCTUnwrap(object["query"] as? String)
            let payload: String
            if query.contains("SearchPullRequests") {
                payload = #"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#
            } else {
                XCTAssertTrue(query.contains("PullRequestRecentTimeline"))
                timelineRequestCount += 1
                let review = includeDecision
                    ? #",{"__typename":"PullRequestReview","id":"review","submittedAt":"\#(reviewedAt)","state":"CHANGES_REQUESTED","author":{"__typename":"User","id":"reviewer","login":"alice"}}"#
                    : ""
                payload = #"{"data":{"node":{"updatedAt":"\#(requestedAt)","isDraft":false,"state":"OPEN","mergedAt":null,"closedAt":null,"timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"__typename":"UnassignedEvent","id":"unassigned","createdAt":"\#(unassignedAt)","assignee":{"__typename":"User","id":"viewer","login":"me"}},{"__typename":"AssignedEvent","id":"assigned","createdAt":"\#(assignedAt)","assignee":{"__typename":"User","id":"reviewer","login":"alice"}},{"__typename":"ReviewRequestedEvent","id":"requested","createdAt":"\#(requestedAt)","requestedReviewer":{"__typename":"User","id":"reviewer","login":"alice"}}\#(review)]}}}}"#
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "test", session: URLSession(configuration: configuration))
        let coordinator = SyncCoordinator(api: api)
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let pull = PullRequestSnapshot(
            id: "pr", repository: "o/r", number: 7, title: "Ship it",
            url: URL(string: "https://github.com/o/r/pull/7")!, authorID: viewer.id,
            eligibleAt: now.addingTimeInterval(-3_600), updatedAt: now,
            isDraft: false, state: .open
        )
        var metadata = SyncMetadata.empty
        metadata.baselineEstablished = true
        metadata.lastSuccessfulSync = now.addingTimeInterval(-60)
        let previous = AppSnapshot(
            viewer: viewer, pullRequests: [pull], events: [], handoffs: [],
            assignedPullRequestIDs: [pull.id], attentionItems: [], metadata: metadata
        )

        let handedOff = try await coordinator.refreshAssigned(previous: previous, now: now)

        XCTAssertTrue(handedOff.snapshot.assignedPullRequestIDs.isEmpty)
        XCTAssertEqual(handedOff.snapshot.handoffs.count, 1)
        guard case .pending = handedOff.snapshot.handoffs[0].outcome else {
            return XCTFail("Expected the new handoff to be pending")
        }

        includeDecision = true
        // The initial handoff watch has expired here. The pending-review cadence
        // still finds the decision and must start a fresh post-decision watch.
        let decided = try await coordinator.refreshAssigned(previous: handedOff.snapshot, now: now.addingTimeInterval(400))

        guard case .changesRequested = decided.snapshot.handoffs[0].outcome else {
            return XCTFail("Expected the watched handoff to pick up the review decision")
        }
        XCTAssertTrue(decided.snapshot.attentionItems.isEmpty, "Review decisions are metrics, not direct-tag inbox items")

        _ = try await coordinator.refreshAssigned(previous: decided.snapshot, now: now.addingTimeInterval(415))
        XCTAssertEqual(timelineRequestCount, 3, "A decided PR should remain on the targeted watch for a prompt merge update")
    }

    func testTimelineNotificationDeltaIsEmptyBeforeBaseline() {
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let event = TimelineEvent(id: "event", pullRequestID: "pr", kind: .merged, at: Date())
        let previous = AppSnapshot(
            viewer: viewer,
            pullRequests: [],
            events: [],
            handoffs: [],
            assignedPullRequestIDs: [],
            attentionItems: [],
            metadata: .empty
        )

        XCTAssertTrue(SyncCoordinator.timelineNotificationDelta(events: [event], previous: previous).isEmpty)
    }

    func testAttentionNormalizationKeepsNewestVerifiedMentionRevisionPerThread() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://github.com/o/r/pull/7")!
        let oldMention = AttentionItem(
            id: "thread:7", kind: .mention, level: .loud,
            title: "Old title", repository: "o/r", url: url,
            createdAt: now.addingTimeInterval(-120), revisionID: "comment:1:1",
            verificationVersion: AttentionItem.directMentionVerificationVersion,
            seenRevisionID: "comment:1:1"
        )
        let latestMention = AttentionItem(
            id: "thread:7", kind: .mention, level: .loud,
            title: "Current title", repository: "o/r", url: url,
            createdAt: now.addingTimeInterval(-60), revisionID: "comment:2:1",
            verificationVersion: AttentionItem.directMentionVerificationVersion,
            seenRevisionID: "comment:1:1"
        )
        let legacyAssignment = AttentionItem(
            id: "legacy", kind: .assigned, level: .persistent,
            title: "Current title", repository: "o/r", url: url, createdAt: now
        )

        let normalized = SyncCoordinator.normalizeAttention(
            [oldMention, latestMention, legacyAssignment],
            now: now
        )

        XCTAssertEqual(normalized.map(\.id), ["thread:7"])
        XCTAssertEqual(normalized[0].revisionID, "comment:2:1")
        XCTAssertEqual(normalized[0].seenRevisionID, "comment:1:1")
        XCTAssertTrue(normalized[0].isUnseen)
    }

    func testAttentionNormalizationDoesNotResurrectAcknowledgedRevision() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(string: "https://github.com/o/r/pull/7")!
        let acknowledged = AttentionItem(
            id: "thread:7", kind: .mention, level: .loud,
            title: "Mention", repository: "o/r", url: url,
            createdAt: now, revisionID: "comment:2:1",
            verificationVersion: AttentionItem.directMentionVerificationVersion,
            seenRevisionID: "comment:2:1", acknowledgedRevisionID: "comment:2:1"
        )

        let normalized = SyncCoordinator.normalizeAttention([acknowledged], now: now)

        XCTAssertEqual(normalized.count, 1)
        XCTAssertFalse(normalized[0].isActive)
        XCTAssertFalse(normalized[0].isUnseen)
    }

    func testAttentionNormalizationExpiresActiveItemsOutsideBackfillWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = AttentionItem(
            id: "thread:7", kind: .mention, level: .loud,
            title: "Expired", repository: "o/r",
            url: URL(string: "https://github.com/o/r/pull/7")!,
            createdAt: now.addingTimeInterval(-31 * 24 * 3_600),
            revisionID: "issueComment:1:1",
            verificationVersion: AttentionItem.directMentionVerificationVersion
        )

        XCTAssertTrue(SyncCoordinator.normalizeAttention([expired], now: now).isEmpty)
    }

    func testDirectMentionMatcherRejectsQuotedCodeAndUsernamePrefixes() {
        XCTAssertTrue(DirectMentionMatcher.containsDirectMention(in: "Please decide, @OctoCat.", login: "octocat"))
        XCTAssertFalse(DirectMentionMatcher.containsDirectMention(in: "`@octocat`", login: "octocat"))
        XCTAssertFalse(DirectMentionMatcher.containsDirectMention(in: "> @octocat said this", login: "octocat"))
        XCTAssertFalse(DirectMentionMatcher.containsDirectMention(in: "@octocat-old", login: "octocat"))
        XCTAssertFalse(DirectMentionMatcher.containsDirectMention(in: "```\n@octocat\n```", login: "octocat"))
        XCTAssertTrue(DirectMentionMatcher.containsDirectMention(in: "```ignored```\n@octocat", login: "octocat"))
        XCTAssertFalse(DirectMentionMatcher.containsDirectMention(in: "``@octocat with ` inside``", login: "octocat"))
        XCTAssertFalse(DirectMentionMatcher.containsDirectMention(in: "<code>@octocat</code>", login: "octocat"))
        XCTAssertFalse(DirectMentionMatcher.containsDirectMention(in: "<pre>\n@octocat\n</pre>", login: "octocat"))
        XCTAssertFalse(DirectMentionMatcher.containsDirectMention(in: "<!-- @octocat -->", login: "octocat"))
        XCTAssertFalse(DirectMentionMatcher.containsDirectMention(in: "- > @octocat quoted", login: "octocat"))
        XCTAssertTrue(DirectMentionMatcher.containsDirectMention(in: "``ignored`` and @octocat", login: "octocat"))
    }

    func testNotificationPollCreatesOnlyUnreadVerifiedDirectMention() async throws {
        StubURLProtocol.handler = { request in
            let path = request.url!.path
            let payload: String
            switch path {
            case "/notifications":
                payload = #"[{"id":"27","unread":true,"reason":"mention","updated_at":"2026-08-06T18:00:00Z","subject":{"title":"Needs a decision","url":"https://api.github.com/repos/o/r/pulls/27","latest_comment_url":"https://api.github.com/repos/o/r/issues/comments/99","type":"PullRequest"},"repository":{"full_name":"o/r","html_url":"https://github.com/o/r"}},{"id":"28","unread":true,"reason":"assign","updated_at":"2026-08-06T18:00:00Z","subject":{"title":"Assigned only","url":"https://api.github.com/repos/o/r/pulls/28","latest_comment_url":null,"type":"PullRequest"},"repository":{"full_name":"o/r","html_url":"https://github.com/o/r"}},{"id":"29","unread":false,"reason":"mention","updated_at":"2026-08-06T18:00:00Z","subject":{"title":"Already read","url":"https://api.github.com/repos/o/r/pulls/29","latest_comment_url":null,"type":"PullRequest"},"repository":{"full_name":"o/r","html_url":"https://github.com/o/r"}}]"#
            case "/repos/o/r/issues/comments/99":
                payload = #"{"id":99,"body":"@me please decide","user":{"login":"alice"},"created_at":"2026-08-06T18:00:00Z","updated_at":"2026-08-06T18:00:00Z","submitted_at":null}"#
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "test", session: URLSession(configuration: configuration))
        let coordinator = SyncCoordinator(api: api)
        var metadata = SyncMetadata.empty
        metadata.baselineEstablished = true
        metadata.lastNotificationSync = Date(timeIntervalSince1970: 1_786_000_000)
        let previous = AppSnapshot(
            viewer: GitHubUser(id: "viewer", login: "me", kind: .user),
            pullRequests: [], events: [], handoffs: [], assignedPullRequestIDs: [],
            attentionItems: [], metadata: metadata
        )

        let (updated, newItems) = try await coordinator.pollNotifications(previous: previous)

        XCTAssertEqual(updated.attentionItems.map(\.id), ["thread:27"])
        XCTAssertEqual(newItems.map(\.id), ["thread:27"])
        XCTAssertTrue(updated.attentionItems[0].isUnseen)
        XCTAssertTrue(updated.attentionItems[0].revisionID?.hasPrefix("issueComment:99:") == true)
    }

    func testNotificationPollDoesNotUseUnrelatedCommentToVerifyLatestSource() async throws {
        var requestedPaths: [String] = []
        StubURLProtocol.handler = { request in
            let path = request.url!.path
            requestedPaths.append(path)
            let payload: String
            switch path {
            case "/notifications":
                payload = #"[{"id":"27","unread":true,"reason":"mention","updated_at":"2026-08-06T18:00:00Z","subject":{"title":"No current tag","url":"https://api.github.com/repos/o/r/pulls/27","latest_comment_url":"https://api.github.com/repos/o/r/issues/comments/99","type":"PullRequest"},"repository":{"full_name":"o/r","html_url":"https://github.com/o/r"}}]"#
            case "/repos/o/r/issues/comments/99":
                payload = #"{"id":99,"body":"No direct tag here","user":{"login":"alice"},"created_at":"2026-08-06T18:00:00Z","updated_at":"2026-08-06T18:00:00Z","submitted_at":null}"#
            case "/repos/o/r/issues/27/comments":
                payload = #"[{"id":98,"body":"@me this older comment must not qualify","user":{"login":"bob"},"created_at":"2026-08-06T17:59:00Z","updated_at":"2026-08-06T17:59:00Z","submitted_at":null}]"#
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "test", session: URLSession(configuration: configuration))
        let coordinator = SyncCoordinator(api: api)
        var metadata = SyncMetadata.empty
        metadata.baselineEstablished = true
        metadata.lastNotificationSync = Date(timeIntervalSince1970: 1_786_000_000)
        let previous = AppSnapshot(
            viewer: GitHubUser(id: "viewer", login: "me", kind: .user),
            pullRequests: [], events: [], handoffs: [], assignedPullRequestIDs: [],
            attentionItems: [], metadata: metadata
        )

        let (updated, newItems) = try await coordinator.pollNotifications(previous: previous)

        XCTAssertTrue(updated.attentionItems.isEmpty)
        XCTAssertTrue(newItems.isEmpty)
        XCTAssertEqual(requestedPaths, ["/notifications", "/repos/o/r/issues/comments/99"])
    }

    func testNotificationPollRemovesActiveItemWhenGitHubThreadIsRead() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/notifications")
            let payload = #"[{"id":"27","unread":false,"reason":"mention","updated_at":"2026-08-06T18:00:00Z","subject":{"title":"Handled elsewhere","url":"https://api.github.com/repos/o/r/pulls/27","latest_comment_url":"https://api.github.com/repos/o/r/issues/comments/99","type":"PullRequest"},"repository":{"full_name":"o/r","html_url":"https://github.com/o/r"}}]"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "test", session: URLSession(configuration: configuration))
        let coordinator = SyncCoordinator(api: api)
        var metadata = SyncMetadata.empty
        metadata.baselineEstablished = true
        metadata.lastNotificationSync = Date(timeIntervalSince1970: 1_786_000_000)
        let existing = AttentionItem(
            id: "thread:27", kind: .mention, level: .loud,
            title: "Handled elsewhere", repository: "o/r",
            url: URL(string: "https://github.com/o/r/pull/27")!,
            createdAt: Date(), revisionID: "issueComment:99:1",
            verificationVersion: AttentionItem.directMentionVerificationVersion
        )
        let previous = AppSnapshot(
            viewer: GitHubUser(id: "viewer", login: "me", kind: .user),
            pullRequests: [], events: [], handoffs: [], assignedPullRequestIDs: [],
            attentionItems: [existing], metadata: metadata
        )

        let (updated, newItems) = try await coordinator.pollNotifications(previous: previous)

        XCTAssertTrue(updated.attentionItems.isEmpty)
        XCTAssertTrue(newItems.isEmpty)
    }

    func testNotificationVerificationFailureDoesNotAdvanceCursor() async throws {
        let cursor = Date(timeIntervalSince1970: 1_786_000_000)
        StubURLProtocol.handler = { request in
            if request.url?.path == "/notifications" {
                let payload = #"[{"id":"27","unread":true,"reason":"mention","updated_at":"2026-08-06T18:00:00Z","subject":{"title":"Cannot verify","url":"https://api.github.com/repos/o/r/pulls/27","latest_comment_url":"https://api.github.com/repos/o/r/issues/comments/99","type":"PullRequest"},"repository":{"full_name":"o/r","html_url":"https://github.com/o/r"}},{"id":"28","unread":true,"reason":"mention","updated_at":"2026-08-06T18:00:00Z","subject":{"title":"Can verify","url":"https://api.github.com/repos/o/r/pulls/28","latest_comment_url":"https://api.github.com/repos/o/r/comments/100","type":"PullRequest"},"repository":{"full_name":"o/r","html_url":"https://github.com/o/r"}}]"#
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
            }
            if request.url?.path == "/repos/o/r/comments/100" {
                let payload = #"{"id":100,"body":"@me decide","user":{"login":"alice"},"created_at":"2026-08-06T18:00:00Z","updated_at":"2026-08-06T18:00:00Z","submitted_at":null}"#
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
            }
            let payload = #"{"message":"temporary failure"}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "test", session: URLSession(configuration: configuration))
        let coordinator = SyncCoordinator(api: api)
        var metadata = SyncMetadata.empty
        metadata.baselineEstablished = true
        metadata.lastNotificationSync = cursor
        let previous = AppSnapshot(
            viewer: GitHubUser(id: "viewer", login: "me", kind: .user),
            pullRequests: [], events: [], handoffs: [], assignedPullRequestIDs: [],
            attentionItems: [], metadata: metadata
        )

        let (updated, newItems) = try await coordinator.pollNotifications(previous: previous)

        XCTAssertEqual(updated.metadata.lastNotificationSync, cursor)
        XCTAssertNotNil(updated.metadata.lastError)
        XCTAssertEqual(updated.attentionItems.map(\.id), ["thread:28"])
        XCTAssertEqual(newItems.map(\.id), ["thread:28"])
    }

    func testEligibilityUsesFirstNonDraftMoment() {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let converted = TimelineEvent(id: "draft", pullRequestID: "pr", kind: .convertedToDraft, at: createdAt.addingTimeInterval(60))
        let ready = TimelineEvent(id: "ready", pullRequestID: "pr", kind: .readyForReview, at: createdAt.addingTimeInterval(120))

        XCTAssertEqual(
            SyncCoordinator.eligibleAt(createdAt: createdAt, currentIsDraft: false, events: [converted, ready]),
            createdAt
        )
        XCTAssertEqual(
            SyncCoordinator.eligibleAt(createdAt: createdAt, currentIsDraft: false, events: [ready]),
            ready.at
        )
        XCTAssertNil(SyncCoordinator.eligibleAt(createdAt: createdAt, currentIsDraft: true, events: []))

        let tiedReady = TimelineEvent(id: "tied-ready", pullRequestID: "pr", kind: .readyForReview, at: ready.at)
        let tiedDraft = TimelineEvent(id: "tied-draft", pullRequestID: "pr", kind: .convertedToDraft, at: ready.at)
        XCTAssertEqual(
            SyncCoordinator.eligibleAt(createdAt: createdAt, currentIsDraft: false, events: [tiedReady, tiedDraft]),
            createdAt
        )
        XCTAssertEqual(
            SyncCoordinator.eligibleAt(createdAt: createdAt, currentIsDraft: true, events: [tiedDraft, tiedReady]),
            ready.at
        )
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
