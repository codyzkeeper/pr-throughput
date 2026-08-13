import XCTest
@testable import PRThroughput

final class WindowMetricsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)

    func testLedgerReconcilesNewReenteredAndEveryExit() {
        let start = now.addingTimeInterval(-WindowRange.days7.duration)
        let pulls = [
            pull("baseline", eligible: start.addingTimeInterval(-1_000), state: .open),
            pull("new-merged", eligible: start.addingTimeInterval(100), state: .merged,
                 mergedAt: start.addingTimeInterval(200)),
            pull("reopened", eligible: start.addingTimeInterval(-2_000), state: .open),
            pull("drafted", eligible: start.addingTimeInterval(-3_000), isDraft: true, state: .open),
            pull("closed", eligible: start.addingTimeInterval(-4_000), state: .closed,
                 closedAt: start.addingTimeInterval(500))
        ]
        let events = [
            event("merge", "new-merged", .merged, start.addingTimeInterval(200)),
            event("old-close", "reopened", .closed, start.addingTimeInterval(-500)),
            event("reopen", "reopened", .reopened, start.addingTimeInterval(300)),
            event("draft", "drafted", .convertedToDraft, start.addingTimeInterval(400)),
            event("close", "closed", .closed, start.addingTimeInterval(500))
        ]

        let metrics = snapshot(pulls: pulls, events: events).windowMetrics(range: .days7, asOf: now)

        XCTAssertEqual(metrics.openAtStart, 3)
        XCTAssertEqual(metrics.new, 1)
        XCTAssertEqual(metrics.reentered, 1)
        XCTAssertEqual(metrics.merged, 1)
        XCTAssertEqual(metrics.closed, 1)
        XCTAssertEqual(metrics.drafted, 1)
        XCTAssertEqual(metrics.openNow, 2)
        XCTAssertEqual(metrics.openAtStart + metrics.new + metrics.reentered
                       - metrics.merged - metrics.closed - metrics.drafted, metrics.openNow)
        XCTAssertEqual(metrics.netChange, -1)
    }

    func testEventAtStartBelongsToWindowAndNotOpeningBalance() {
        let start = now.addingTimeInterval(-WindowRange.hours48.duration)
        let pull = pull("boundary", eligible: start, state: .open)

        let metrics = snapshot(pulls: [pull], events: []).windowMetrics(range: .hours48, asOf: now)

        XCTAssertEqual(metrics.openAtStart, 0)
        XCTAssertEqual(metrics.new, 1)
        XCTAssertEqual(metrics.openNow, 1)
    }

    func testCloseAndMergeAtSameInstantCountOnlyMerged() {
        let start = now.addingTimeInterval(-WindowRange.hours48.duration)
        let pull = pull("terminal", eligible: start.addingTimeInterval(-100), state: .merged,
                        mergedAt: start.addingTimeInterval(100), closedAt: start.addingTimeInterval(100))
        let at = start.addingTimeInterval(100)
        let events = [event("close", "terminal", .closed, at), event("merge", "terminal", .merged, at)]

        let metrics = snapshot(pulls: [pull], events: events).windowMetrics(range: .hours48, asOf: now)

        XCTAssertEqual(metrics.merged, 1)
        XCTAssertEqual(metrics.closed, 0)
        XCTAssertEqual(metrics.openNow, 0)
    }

    func testReviewAcceptanceUsesOnlyDecisionEventsInWindow() {
        let start = now.addingTimeInterval(-WindowRange.days7.duration)
        let reviewer = GitHubUser(id: "reviewer", login: "reviewer", kind: .user)
        let pull = pull("old", eligible: start.addingTimeInterval(-10_000), state: .open)
        let events = [
            event("approved", "old", .reviewed(reviewer: reviewer, state: .approved), start.addingTimeInterval(10)),
            event("changes", "old", .reviewed(reviewer: reviewer, state: .changesRequested), start.addingTimeInterval(20)),
            event("self", "old", .reviewed(reviewer: viewer, state: .approved), start.addingTimeInterval(30)),
            event("old-review", "old", .reviewed(reviewer: reviewer, state: .changesRequested), start.addingTimeInterval(-1))
        ]

        let metrics = snapshot(pulls: [pull], events: events).windowMetrics(range: .days7, asOf: now)

        XCTAssertEqual(metrics.approved, 1)
        XCTAssertEqual(metrics.changesRequested, 1)
        XCTAssertEqual(metrics.decisions, 2)
        XCTAssertEqual(metrics.acceptanceRate, 0.5)
        XCTAssertEqual(metrics.reworkRate, 0.5)
    }

    func testRepeatedDraftAndReopenCyclesRemainAReconciledLedger() {
        let start = now.addingTimeInterval(-WindowRange.days7.duration)
        let pull = pull("cycles", eligible: start.addingTimeInterval(-100), state: .open)
        let events = [
            event("draft-1", pull.id, .convertedToDraft, start.addingTimeInterval(10)),
            event("ready-1", pull.id, .readyForReview, start.addingTimeInterval(20)),
            event("close-1", pull.id, .closed, start.addingTimeInterval(30)),
            event("reopen-1", pull.id, .reopened, start.addingTimeInterval(40)),
            event("draft-2", pull.id, .convertedToDraft, start.addingTimeInterval(50)),
            event("ready-2", pull.id, .readyForReview, start.addingTimeInterval(60))
        ]

        let metrics = snapshot(pulls: [pull], events: events).windowMetrics(range: .days7, asOf: now)

        XCTAssertEqual(metrics.openAtStart, 1)
        XCTAssertEqual(metrics.reentered, 3)
        XCTAssertEqual(metrics.closed, 1)
        XCTAssertEqual(metrics.drafted, 2)
        XCTAssertEqual(metrics.openNow, 1)
        XCTAssertEqual(
            metrics.openAtStart + metrics.new + metrics.reentered
                - metrics.merged - metrics.closed - metrics.drafted,
            metrics.openNow
        )
    }

    func testCanonicalDecodingRejectsTamperedDerivedRate() throws {
        let start = now.addingTimeInterval(-WindowRange.days7.duration)
        let reviewer = GitHubUser(id: "reviewer", login: "reviewer", kind: .user)
        let metrics = snapshot(
            pulls: [pull("reviews", eligible: start.addingTimeInterval(-100), state: .open)],
            events: [event(
                "approval", "reviews", .reviewed(reviewer: reviewer, state: .approved),
                start.addingTimeInterval(10)
            )]
        ).windowMetrics(range: .days7, asOf: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(metrics)) as? [String: Any]
        )
        object["acceptanceRate"] = 0.0
        let tampered = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertThrowsError(try decoder.decode(WindowMetrics.self, from: tampered))
    }

    func testAwaitingNowIncludesOldPendingButHandoffsRemainWindowScoped() {
        let start = now.addingTimeInterval(-WindowRange.days7.duration)
        let pull = pull("old", eligible: start.addingTimeInterval(-10_000), state: .open)
        let handoffs = [
            Handoff(id: "old-pending", pullRequestID: "old", reviewerID: "a",
                    at: start.addingTimeInterval(-100), outcome: .pending),
            Handoff(id: "new-pending", pullRequestID: "old", reviewerID: "b",
                    at: start.addingTimeInterval(100), outcome: .pending),
            Handoff(id: "withdrawn", pullRequestID: "old", reviewerID: "c",
                    at: start.addingTimeInterval(200),
                    outcome: .withdrawn(at: start.addingTimeInterval(300), reason: "removed"))
        ]

        let metrics = snapshot(pulls: [pull], handoffs: handoffs).windowMetrics(range: .days7, asOf: now)

        XCTAssertEqual(metrics.handoffs, 1)
        XCTAssertEqual(metrics.awaitingNow, 2)
    }

    private func snapshot(
        pulls: [PullRequestSnapshot],
        events: [TimelineEvent] = [],
        handoffs: [Handoff] = []
    ) -> AppSnapshot {
        AppSnapshot(viewer: viewer, pullRequests: pulls, events: events, handoffs: handoffs,
                    assignedPullRequestIDs: [], attentionItems: [], metadata: .empty)
    }

    private func pull(
        _ id: String,
        eligible: Date,
        isDraft: Bool = false,
        state: PullRequestState,
        mergedAt: Date? = nil,
        closedAt: Date? = nil
    ) -> PullRequestSnapshot {
        PullRequestSnapshot(
            id: id, repository: "o/r", number: id.hashValue, title: id,
            url: URL(string: "https://github.com/o/r/pull/1")!, authorID: viewer.id,
            eligibleAt: eligible, isDraft: isDraft, state: state,
            mergedAt: mergedAt, closedAt: closedAt
        )
    }

    private func event(_ id: String, _ pull: String, _ kind: TimelineEventKind, _ at: Date) -> TimelineEvent {
        TimelineEvent(id: id, pullRequestID: pull, kind: kind, at: at)
    }
}
