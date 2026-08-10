import XCTest
@testable import PRThroughput

final class WindowActivityMetricsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
    private let reviewer = GitHubUser(id: "reviewer", login: "alice", kind: .user)

    func testCountsEventsInWindowRegardlessOfPullRequestVintage() {
        let old = pull(id: "old", eligibleAt: now.addingTimeInterval(-40 * 86_400), state: .merged,
                       mergedAt: now.addingTimeInterval(-3_600))
        let recent = pull(id: "recent", eligibleAt: now.addingTimeInterval(-3_600), state: .open)
        let events = [
            TimelineEvent(id: "approved", pullRequestID: old.id,
                          kind: .reviewed(reviewer: reviewer, state: .approved),
                          at: now.addingTimeInterval(-2_000)),
            TimelineEvent(id: "changes", pullRequestID: old.id,
                          kind: .reviewed(reviewer: reviewer, state: .changesRequested),
                          at: now.addingTimeInterval(-1_000))
        ]

        let metrics = WindowActivityMetrics.calculate(
            pullRequests: [old, recent], events: events, handoffs: [],
            viewerID: viewer.id, range: .days7, asOf: now
        )

        XCTAssertEqual(metrics.opened, 1)
        XCTAssertEqual(metrics.merged, 1)
        XCTAssertEqual(metrics.approved, 1)
        XCTAssertEqual(metrics.changesRequested, 1)
        XCTAssertEqual(metrics.decisions, 2)
    }

    func testCountsRepeatedHandoffsAndExcludesWithdrawnCycles() {
        let pull = pull(id: "old", eligibleAt: now.addingTimeInterval(-40 * 86_400), state: .open)
        let handoffs = [
            Handoff(id: "approved", pullRequestID: pull.id, reviewerID: reviewer.id,
                    at: now.addingTimeInterval(-5_000),
                    outcome: .approved(at: now.addingTimeInterval(-4_000), reviewID: "r1")),
            Handoff(id: "pending", pullRequestID: pull.id, reviewerID: reviewer.id,
                    at: now.addingTimeInterval(-3_000), outcome: .pending),
            Handoff(id: "withdrawn", pullRequestID: pull.id, reviewerID: reviewer.id,
                    at: now.addingTimeInterval(-2_000),
                    outcome: .withdrawn(at: now.addingTimeInterval(-1_000), reason: "removed")),
            Handoff(id: "outside", pullRequestID: pull.id, reviewerID: reviewer.id,
                    at: now.addingTimeInterval(-8 * 86_400), outcome: .pending)
        ]

        let metrics = WindowActivityMetrics.calculate(
            pullRequests: [pull], events: [], handoffs: handoffs,
            viewerID: viewer.id, range: .days7, asOf: now
        )

        XCTAssertEqual(metrics.handoffs, 2)
        XCTAssertEqual(metrics.awaiting, 1)
    }

    func testIgnoresOtherAuthorsNonDecisiveReviewsAndFutureFacts() {
        let mine = pull(id: "mine", eligibleAt: now.addingTimeInterval(-3_600), state: .open)
        let theirs = PullRequestSnapshot(
            id: "theirs", repository: "o/r", number: 2, title: "Theirs",
            url: URL(string: "https://github.com/o/r/pull/2")!, authorID: "someone-else",
            eligibleAt: now.addingTimeInterval(-3_600), isDraft: false, state: .open
        )
        let events = [
            TimelineEvent(id: "comment", pullRequestID: mine.id,
                          kind: .reviewed(reviewer: reviewer, state: .commented),
                          at: now.addingTimeInterval(-100)),
            TimelineEvent(id: "future", pullRequestID: mine.id,
                          kind: .reviewed(reviewer: reviewer, state: .approved),
                          at: now.addingTimeInterval(1)),
            TimelineEvent(id: "theirs-review", pullRequestID: theirs.id,
                          kind: .reviewed(reviewer: reviewer, state: .approved),
                          at: now.addingTimeInterval(-100))
        ]

        let metrics = WindowActivityMetrics.calculate(
            pullRequests: [mine, theirs], events: events, handoffs: [],
            viewerID: viewer.id, range: .hours48, asOf: now
        )

        XCTAssertEqual(metrics.opened, 1)
        XCTAssertEqual(metrics.decisions, 0)
    }

    func testOnlyCountsNamedExternalReviewersAfterEligibility() {
        let eligibleAt = now.addingTimeInterval(-3_600)
        let mine = pull(id: "mine", eligibleAt: eligibleAt, state: .open)
        let bot = GitHubUser(id: "bot", login: "ci-bot", kind: .bot)
        let events = [
            TimelineEvent(id: "bot", pullRequestID: mine.id,
                          kind: .reviewed(reviewer: bot, state: .approved),
                          at: now.addingTimeInterval(-100)),
            TimelineEvent(id: "self", pullRequestID: mine.id,
                          kind: .reviewed(reviewer: viewer, state: .approved),
                          at: now.addingTimeInterval(-100)),
            TimelineEvent(id: "before-eligible", pullRequestID: mine.id,
                          kind: .reviewed(reviewer: reviewer, state: .changesRequested),
                          at: eligibleAt.addingTimeInterval(-1)),
            TimelineEvent(id: "human", pullRequestID: mine.id,
                          kind: .reviewed(reviewer: reviewer, state: .approved),
                          at: now.addingTimeInterval(-100))
        ]

        let metrics = WindowActivityMetrics.calculate(
            pullRequests: [mine], events: events, handoffs: [],
            viewerID: viewer.id, range: .hours48, asOf: now
        )

        XCTAssertEqual(metrics.approved, 1)
        XCTAssertEqual(metrics.changesRequested, 0)
    }

    func testCohortMembershipPersistsAfterPullRequestReturnsToDraft() {
        let redrafted = PullRequestSnapshot(
            id: "redrafted", repository: "o/r", number: 1, title: "Redrafted",
            url: URL(string: "https://github.com/o/r/pull/1")!, authorID: viewer.id,
            eligibleAt: now.addingTimeInterval(-3_600), isDraft: true, state: .open
        )

        let activity = WindowActivityMetrics.calculate(
            pullRequests: [redrafted], events: [], handoffs: [],
            viewerID: viewer.id, range: .hours48, asOf: now
        )
        let cohort = CohortMetrics.calculate(
            pullRequests: [redrafted], handoffs: [], viewerID: viewer.id,
            range: .hours48, asOf: now
        )

        XCTAssertEqual(activity.opened, 1)
        XCTAssertEqual(cohort.opened, 1)
    }

    private func pull(
        id: String,
        eligibleAt: Date,
        state: PullRequestState,
        mergedAt: Date? = nil
    ) -> PullRequestSnapshot {
        PullRequestSnapshot(
            id: id, repository: "o/r", number: 1, title: id,
            url: URL(string: "https://github.com/o/r/pull/1")!, authorID: viewer.id,
            eligibleAt: eligibleAt, isDraft: false, state: state, mergedAt: mergedAt
        )
    }
}
