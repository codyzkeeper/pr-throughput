import XCTest
@testable import PRThroughput

@MainActor
final class PersistenceTests: XCTestCase {
    func testConnectedMenuWaitsForVerifiedSnapshotBeforeShowingMetrics() {
        XCTAssertEqual(
            MenuPresentationState.resolve(connectionState: .connected, hasSnapshot: false),
            .initialSync
        )
        XCTAssertEqual(
            MenuPresentationState.resolve(connectionState: .connected, hasSnapshot: true),
            .dashboard
        )
    }

    func testStatusItemNeverPresentsZeroAsFactBeforeFirstVerifiedSnapshot() {
        XCTAssertEqual(
            StatusItemPresentation.resolve(
                transient: nil,
                connectionState: .connected,
                hasVerifiedSnapshot: false
            ),
            .syncing
        )
        XCTAssertEqual(
            StatusItemPresentation.resolve(
                transient: nil,
                connectionState: .connected,
                hasVerifiedSnapshot: true
            ),
            .assignedCount
        )
    }

    func testSnapshotRoundTripsAndReplacementIsIdempotent() throws {
        let store = try SnapshotStore(inMemory: true)
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        var snapshot = AppSnapshot(
            viewer: viewer,
            pullRequests: [],
            events: [],
            handoffs: [],
            assignedPullRequestIDs: ["pr-1"],
            attentionItems: [],
            metadata: .empty
        )
        snapshot.attentionItems = [AttentionItem(
            id: "thread:7", kind: .mention, level: .loud,
            title: "Decide", repository: "o/r",
            url: URL(string: "https://github.com/o/r/pull/7")!, createdAt: Date(),
            revisionID: "issueComment:9:1",
            verificationVersion: AttentionItem.directMentionVerificationVersion,
            seenRevisionID: "issueComment:9:1"
        )]
        try store.save(snapshot)
        snapshot.assignedPullRequestIDs.insert("pr-2")
        try store.save(snapshot)

        let loaded = try XCTUnwrap(store.load(accountID: viewer.id))
        XCTAssertEqual(loaded.assignedPullRequestIDs, ["pr-1", "pr-2"])
        XCTAssertEqual(loaded.attentionItems.first?.seenRevisionID, "issueComment:9:1")
        XCTAssertFalse(try XCTUnwrap(loaded.attentionItems.first).isUnseen)
    }

    func testDeleteAllRemovesAccountData() throws {
        let store = try SnapshotStore(inMemory: true)
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        try store.save(AppSnapshot(viewer: viewer, pullRequests: [], events: [], handoffs: [], assignedPullRequestIDs: [], attentionItems: [], metadata: .empty))
        try store.deleteAll()
        XCTAssertNil(try store.load(accountID: viewer.id))
    }

    func testLegacyMetadataWithoutTimelineSchemaStillDecodes() throws {
        let data = Data(#"{"lastSuccessfulSync":null,"lastNotificationSync":null,"lastError":null,"rateState":{"remaining":null,"resetAt":null},"baselineEstablished":true}"#.utf8)
        let metadata = try JSONDecoder().decode(SyncMetadata.self, from: data)

        XCTAssertNil(metadata.timelineSchemaVersion)
        XCTAssertTrue(metadata.baselineEstablished)
    }

    func testLegacyTimelineEventWithoutSourceOrderStillDecodes() throws {
        let data = Data(#"{"id":"event","pullRequestID":"pr","kind":{"readyForReview":{}},"at":"2026-08-06T18:00:00Z"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let event = try decoder.decode(TimelineEvent.self, from: data)

        XCTAssertEqual(event.sourceOrder, 0)
    }

    func testLegacyAttentionItemDecodesAsUnverifiedAndInactive() throws {
        let data = Data(#"{"id":"legacy","kind":"assigned","level":"persistent","title":"Old","repository":"o/r","url":"https://github.com/o/r/pull/7","createdAt":"2026-08-06T18:00:00Z","acknowledgedAt":null}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let item = try decoder.decode(AttentionItem.self, from: data)

        XCTAssertFalse(item.isVerifiedDirectMention)
        XCTAssertFalse(item.isActive)
        XCTAssertFalse(item.isUnseen)
    }
}
