import XCTest
@testable import PRThroughput

final class MetricContractTests: XCTestCase {
    func testCanonicalSnapshotMatchesDirectMetricsForEveryRange() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = snapshot(now: now)
        let canonical = try source.canonicalMetrics(asOf: now)

        XCTAssertEqual(canonical.schemaVersion, 3)
        XCTAssertEqual(canonical.metricContractVersion, "3")
        XCTAssertEqual(canonical.primaryRange, .days7)
        XCTAssertEqual(canonical.ranges.map(\.range), CohortRange.allCases)
        for range in CohortRange.allCases {
            XCTAssertEqual(canonical.metrics(for: range), source.metrics(range: range, asOf: now))
            XCTAssertEqual(canonical.activity(for: range), source.activity(range: range, asOf: now))
        }
    }

    func testSourceDigestIsStableAcrossCollectionOrderingAndChangesWithFacts() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = snapshot(now: now)
        var reordered = source
        reordered.pullRequests.reverse()
        reordered.events.reverse()
        reordered.handoffs.reverse()
        XCTAssertEqual(
            try source.canonicalMetrics(asOf: now).sourceDigest,
            try reordered.canonicalMetrics(asOf: now).sourceDigest
        )

        reordered.pullRequests[0].mergedAt = now
        XCTAssertNotEqual(
            try source.canonicalMetrics(asOf: now).sourceDigest,
            try reordered.canonicalMetrics(asOf: now).sourceDigest
        )
    }

    func testCanonicalSnapshotRoundTripsAsVersionedJSON() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let canonical = try snapshot(now: now).canonicalMetrics(asOf: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(CanonicalMetricSnapshot.self, from: encoder.encode(canonical)), canonical)
    }

    func testCanonicalOpenIDsRespectHistoricalAsOf() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var source = snapshot(now: now)
        source.pullRequests[0] = PullRequestSnapshot(
            id: "open",
            repository: "o/r",
            number: 1,
            title: "Open",
            url: URL(string: "https://github.com/o/r/pull/1")!,
            authorID: "viewer",
            eligibleAt: now.addingTimeInterval(-3_600),
            isDraft: false,
            state: .closed,
            closedAt: now.addingTimeInterval(60)
        )

        let range = try XCTUnwrap(source.canonicalMetrics(asOf: now).ranges.first { $0.range == .days7 })
        XCTAssertEqual(range.openPullRequestIDs, ["open"])
        XCTAssertEqual(range.metrics.open, 1)
    }

    private func snapshot(now: Date) -> AppSnapshot {
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let pulls = [
            PullRequestSnapshot(id: "open", repository: "o/r", number: 1, title: "Open", url: URL(string: "https://github.com/o/r/pull/1")!, authorID: viewer.id, eligibleAt: now.addingTimeInterval(-3_600), isDraft: false, state: .open),
            PullRequestSnapshot(id: "merged", repository: "o/r", number: 2, title: "Merged", url: URL(string: "https://github.com/o/r/pull/2")!, authorID: viewer.id, eligibleAt: now.addingTimeInterval(-7_200), isDraft: false, state: .merged, mergedAt: now.addingTimeInterval(-60))
        ]
        let reviewer = GitHubUser(id: "reviewer", login: "reviewer", kind: .user)
        let events = [
            TimelineEvent(id: "assignment", pullRequestID: "merged", kind: .assigned(reviewer), at: now.addingTimeInterval(-1_000)),
            TimelineEvent(id: "review", pullRequestID: "merged", kind: .reviewed(reviewer: reviewer, state: .approved), at: now.addingTimeInterval(-500))
        ]
        let handoffs = [
            Handoff(id: "handoff", pullRequestID: "merged", reviewerID: reviewer.id, at: now.addingTimeInterval(-900), outcome: .approved(at: now.addingTimeInterval(-500), reviewID: "review"))
        ]
        return AppSnapshot(viewer: viewer, pullRequests: pulls, events: events, handoffs: handoffs, assignedPullRequestIDs: ["open"], attentionItems: [], metadata: .empty)
    }
}
