import XCTest
@testable import PRThroughput

final class SnapshotReconcilerTests: XCTestCase {
    func testValidSnapshotReconcilesSourceFactsAndEveryMetricRange() throws {
        let snapshot = makeSnapshot()

        let report = snapshot.reconciliation(asOf: now)

        XCTAssertTrue(report.isValid, report.issues.joined(separator: "\n"))
        XCTAssertNoThrow(try SnapshotReconciler.requireValid(snapshot, asOf: now))
        for range in CohortRange.allCases {
            let metrics = snapshot.metrics(range: range, asOf: now)
            XCTAssertEqual(metrics.opened, metrics.open + metrics.merged + metrics.closedUnmerged)
            XCTAssertEqual(metrics.decisions, metrics.approved + metrics.changesRequested)
        }
    }

    func testRejectsStoredHandoffThatCannotBeDerivedFromTimeline() {
        var snapshot = makeSnapshot()
        snapshot.handoffs[0].outcome = .approved(at: now, reviewID: "missing-review")

        let report = snapshot.reconciliation(asOf: now)

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains { $0.contains("timeline-derived") })
        XCTAssertThrowsError(try SnapshotReconciler.requireValid(snapshot, asOf: now))
    }

    func testRejectsDuplicateAndOrphanSourceFacts() {
        var snapshot = makeSnapshot()
        snapshot.events.append(snapshot.events[0])
        snapshot.events.append(TimelineEvent(id: "orphan", pullRequestID: "unknown", kind: .merged, at: now))

        let report = snapshot.reconciliation(asOf: now)

        XCTAssertTrue(report.issues.contains { $0.contains("duplicate timeline event") })
        XCTAssertTrue(report.issues.contains { $0.contains("unknown PR") })
    }

    func testRejectsContradictoryPullRequestState() {
        var snapshot = makeSnapshot()
        let pull = snapshot.pullRequests[0]
        snapshot.pullRequests[0] = PullRequestSnapshot(
            id: pull.id, repository: pull.repository, number: pull.number,
            title: pull.title, url: pull.url, authorID: pull.authorID,
            eligibleAt: pull.eligibleAt, updatedAt: pull.updatedAt,
            isDraft: false, state: .open, mergedAt: now
        )

        let report = snapshot.reconciliation(asOf: now)

        XCTAssertTrue(report.issues.contains { $0.contains("terminal timestamps") })
        XCTAssertTrue(report.issues.contains { $0.contains("not merged") })
    }

    private let now = Date(timeIntervalSince1970: 1_786_032_000)

    private func makeSnapshot() -> AppSnapshot {
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let reviewer = GitHubUser(id: "reviewer", login: "alice", kind: .user)
        let pull = PullRequestSnapshot(
            id: "pr", repository: "o/r", number: 7, title: "Ship it",
            url: URL(string: "https://github.com/o/r/pull/7")!, authorID: viewer.id,
            eligibleAt: now.addingTimeInterval(-3_600), updatedAt: now,
            isDraft: false, state: .open
        )
        let events = [
            TimelineEvent(id: "unassigned", pullRequestID: pull.id, kind: .unassigned(viewer), at: now.addingTimeInterval(-30)),
            TimelineEvent(id: "assigned", pullRequestID: pull.id, kind: .assigned(reviewer), at: now.addingTimeInterval(-20)),
            TimelineEvent(id: "requested", pullRequestID: pull.id, kind: .reviewRequested(reviewer), at: now.addingTimeInterval(-10)),
            TimelineEvent(id: "review", pullRequestID: pull.id, kind: .reviewed(reviewer: reviewer, state: .approved), at: now)
        ]
        let handoffs = HandoffResolver.resolve(
            handoffs: HandoffMatcher.match(events: events, viewerID: viewer.id),
            events: events
        )
        var metadata = SyncMetadata.empty
        metadata.baselineEstablished = true
        metadata.lastSuccessfulSync = now
        return AppSnapshot(
            viewer: viewer, pullRequests: [pull], events: events, handoffs: handoffs,
            assignedPullRequestIDs: [], attentionItems: [], metadata: metadata
        )
    }
}
