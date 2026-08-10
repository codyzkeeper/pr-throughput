import XCTest
@testable import PRThroughput

final class CohortMetricsTests: XCTestCase {
    func testSeparatesShippingCountsFromReviewCycles() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let viewerID = "viewer"
        let pulls = [
            PullRequestSnapshot(id: "1", repository: "org/a", number: 1, title: "One", url: URL(string: "https://github.com/org/a/pull/1")!, authorID: viewerID, eligibleAt: now.addingTimeInterval(-3_600), isDraft: false, state: .merged, mergedAt: now.addingTimeInterval(-600)),
            PullRequestSnapshot(id: "2", repository: "org/a", number: 2, title: "Two", url: URL(string: "https://github.com/org/a/pull/2")!, authorID: viewerID, eligibleAt: now.addingTimeInterval(-7_200), isDraft: false, state: .open)
        ]
        let handoffs = [
            Handoff(id: "h1", pullRequestID: "1", reviewerID: "a", at: now.addingTimeInterval(-3_000), outcome: .approved(at: now.addingTimeInterval(-2_000), reviewID: "d1")),
            Handoff(id: "h2", pullRequestID: "1", reviewerID: "a", at: now.addingTimeInterval(-1_900), outcome: .changesRequested(at: now.addingTimeInterval(-1_000), reviewID: "d2")),
            Handoff(id: "h3", pullRequestID: "2", reviewerID: "b", at: now.addingTimeInterval(-900), outcome: .pending),
            Handoff(id: "h4", pullRequestID: "2", reviewerID: "c", at: now.addingTimeInterval(-800), outcome: .withdrawn(at: now.addingTimeInterval(-700), reason: "superseded"))
        ]

        let metrics = CohortMetrics.calculate(pullRequests: pulls, handoffs: handoffs, viewerID: viewerID, range: .hours48, asOf: now)

        XCTAssertEqual(metrics.opened, 2)
        XCTAssertEqual(metrics.handedOff, 2)
        XCTAssertEqual(metrics.merged, 1)
        XCTAssertEqual(metrics.mergeCompletionRate, 0.5)
        XCTAssertEqual(metrics.medianOpenAge, 7_200)
        XCTAssertEqual(metrics.decisions, 2)
        XCTAssertEqual(metrics.pending, 1)
        XCTAssertEqual(metrics.acceptanceRate, 0.5)
        XCTAssertNotNil(metrics.reworkRate)
        XCTAssertEqual(metrics.reworkRate!, 0.5, accuracy: 0.0001)
        XCTAssertEqual(metrics.acceptanceRate! + metrics.reworkRate!, 1.0, accuracy: 0.0001)
    }

    func testPendingAndWithdrawnCyclesDoNotEnterReviewDenominator() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pull = PullRequestSnapshot(
            id: "1",
            repository: "org/repo",
            number: 1,
            title: "One",
            url: URL(string: "https://github.com/org/repo/pull/1")!,
            authorID: "viewer",
            eligibleAt: now.addingTimeInterval(-3_600),
            isDraft: false,
            state: .open
        )
        let handoffs = [
            Handoff(id: "pending", pullRequestID: "1", reviewerID: "a", at: now.addingTimeInterval(-2_000), outcome: .pending),
            Handoff(id: "withdrawn", pullRequestID: "1", reviewerID: "b", at: now.addingTimeInterval(-1_000), outcome: .withdrawn(at: now.addingTimeInterval(-500), reason: "removed"))
        ]

        let metrics = CohortMetrics.calculate(
            pullRequests: [pull],
            handoffs: handoffs,
            viewerID: "viewer",
            range: .hours48,
            asOf: now
        )

        XCTAssertEqual(metrics.decisions, 0)
        XCTAssertEqual(metrics.handedOff, 1)
        XCTAssertEqual(metrics.pending, 1)
        XCTAssertNil(metrics.acceptanceRate)
        XCTAssertNil(metrics.reworkRate)
        XCTAssertEqual(metrics.mergeCompletionRate, 0)
        XCTAssertEqual(metrics.medianOpenAge, 3_600)
    }

    func testUsesNilForZeroDenominators() {
        let metrics = CohortMetrics.calculate(pullRequests: [], handoffs: [], viewerID: "viewer", range: .days7, asOf: Date())
        XCTAssertNil(metrics.acceptanceRate)
        XCTAssertNil(metrics.reworkRate)
        XCTAssertNil(metrics.mergeCompletionRate)
        XCTAssertNil(metrics.medianOpenAge)
    }

    func testShippingHandoffsCountUniquePRsAndExcludeWithdrawnOnlyCycles() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pulls = ["reviewed", "pending", "withdrawn"].enumerated().map { index, id in
            PullRequestSnapshot(
                id: id,
                repository: "org/repo",
                number: index + 1,
                title: id,
                url: URL(string: "https://github.com/org/repo/pull/\(index + 1)")!,
                authorID: "viewer",
                eligibleAt: now.addingTimeInterval(-3_600),
                isDraft: false,
                state: .open
            )
        }
        let handoffs = [
            Handoff(id: "reviewed-1", pullRequestID: "reviewed", reviewerID: "a", at: now.addingTimeInterval(-3_000), outcome: .changesRequested(at: now.addingTimeInterval(-2_500), reviewID: "r1")),
            Handoff(id: "reviewed-2", pullRequestID: "reviewed", reviewerID: "a", at: now.addingTimeInterval(-2_000), outcome: .approved(at: now.addingTimeInterval(-1_500), reviewID: "r2")),
            Handoff(id: "pending", pullRequestID: "pending", reviewerID: "b", at: now.addingTimeInterval(-1_000), outcome: .pending),
            Handoff(id: "withdrawn", pullRequestID: "withdrawn", reviewerID: "c", at: now.addingTimeInterval(-900), outcome: .withdrawn(at: now.addingTimeInterval(-800), reason: "removed"))
        ]

        let metrics = CohortMetrics.calculate(
            pullRequests: pulls,
            handoffs: handoffs,
            viewerID: "viewer",
            range: .hours48,
            asOf: now
        )

        XCTAssertEqual(metrics.handedOff, 2)
        XCTAssertEqual(metrics.decisions, 2)
        XCTAssertEqual(metrics.pending, 1)
    }

    func testExcludesDraftAndOutsideCohort() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pulls = [
            PullRequestSnapshot(id: "draft", repository: "o/r", number: 1, title: "Draft", url: URL(string: "https://example.com/1")!, authorID: "viewer", eligibleAt: nil, isDraft: true, state: .open),
            PullRequestSnapshot(id: "redrafted", repository: "o/r", number: 3, title: "Redrafted", url: URL(string: "https://example.com/3")!, authorID: "viewer", eligibleAt: now.addingTimeInterval(-3_600), isDraft: true, state: .open),
            PullRequestSnapshot(id: "old", repository: "o/r", number: 2, title: "Old", url: URL(string: "https://example.com/2")!, authorID: "viewer", eligibleAt: now.addingTimeInterval(-49 * 3_600), isDraft: false, state: .open)
        ]

        let metrics = CohortMetrics.calculate(pullRequests: pulls, handoffs: [], viewerID: "viewer", range: .hours48, asOf: now)
        XCTAssertEqual(metrics.opened, 1)
    }

    func testReviewCycleMustStartAfterEligibilityAndBeforeAsOf() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let eligibleAt = now.addingTimeInterval(-3_600)
        let pull = PullRequestSnapshot(
            id: "pr",
            repository: "o/r",
            number: 1,
            title: "PR",
            url: URL(string: "https://github.com/o/r/pull/1")!,
            authorID: "viewer",
            eligibleAt: eligibleAt,
            isDraft: false,
            state: .merged,
            mergedAt: now.addingTimeInterval(60)
        )
        let handoffs = [
            Handoff(id: "before", pullRequestID: "pr", reviewerID: "a", at: eligibleAt.addingTimeInterval(-1), outcome: .approved(at: eligibleAt, reviewID: "r1")),
            Handoff(id: "inside", pullRequestID: "pr", reviewerID: "b", at: eligibleAt, outcome: .approved(at: now.addingTimeInterval(-1), reviewID: "r2")),
            Handoff(id: "future", pullRequestID: "pr", reviewerID: "c", at: now.addingTimeInterval(1), outcome: .changesRequested(at: now.addingTimeInterval(2), reviewID: "r3"))
        ]

        let metrics = CohortMetrics.calculate(
            pullRequests: [pull],
            handoffs: handoffs,
            viewerID: "viewer",
            range: .hours48,
            asOf: now
        )

        XCTAssertEqual(metrics.decisions, 1)
        XCTAssertEqual(metrics.approved, 1)
        XCTAssertEqual(metrics.changesRequested, 0)
        XCTAssertEqual(metrics.merged, 0)
        XCTAssertEqual(metrics.open, 1)
        XCTAssertEqual(metrics.mergeCompletionRate, 0)
        XCTAssertEqual(metrics.medianOpenAge, 3_600)
        XCTAssertNil(metrics.medianTimeToMerge)
    }

    func testMedianOpenAgeUsesOnlyPRsOpenAtAsOf() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pulls = [
            PullRequestSnapshot(id: "young", repository: "o/r", number: 1, title: "Young", url: URL(string: "https://github.com/o/r/pull/1")!, authorID: "viewer", eligibleAt: now.addingTimeInterval(-3_600), isDraft: false, state: .open),
            PullRequestSnapshot(id: "old", repository: "o/r", number: 2, title: "Old", url: URL(string: "https://github.com/o/r/pull/2")!, authorID: "viewer", eligibleAt: now.addingTimeInterval(-10_800), isDraft: false, state: .open),
            PullRequestSnapshot(id: "merged", repository: "o/r", number: 3, title: "Merged", url: URL(string: "https://github.com/o/r/pull/3")!, authorID: "viewer", eligibleAt: now.addingTimeInterval(-20_000), isDraft: false, state: .merged, mergedAt: now.addingTimeInterval(-100)),
            PullRequestSnapshot(id: "closed", repository: "o/r", number: 4, title: "Closed", url: URL(string: "https://github.com/o/r/pull/4")!, authorID: "viewer", eligibleAt: now.addingTimeInterval(-30_000), isDraft: false, state: .closed, closedAt: now.addingTimeInterval(-50))
        ]

        let metrics = CohortMetrics.calculate(
            pullRequests: pulls,
            handoffs: [],
            viewerID: "viewer",
            range: .hours48,
            asOf: now
        )

        XCTAssertEqual(metrics.mergeCompletionRate, 0.25)
        XCTAssertEqual(metrics.medianOpenAge, 7_200)
    }
}
