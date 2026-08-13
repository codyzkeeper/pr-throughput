import XCTest
@testable import PRThroughput

final class ActivitySeriesTests: XCTestCase {
    func testBuildsCompleteChronologicalSeries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let asOf = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 12)))
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let firstEligible = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: 15)))
        let secondEligible = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 10)))
        let mergedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 8)))
        let handedOffAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 11)))
        let pulls = [
            PullRequestSnapshot(id: "one", repository: "o/r", number: 1, title: "One", url: URL(string: "https://github.com/o/r/pull/1")!, authorID: viewer.id, eligibleAt: firstEligible, isDraft: false, state: .merged, mergedAt: mergedAt),
            PullRequestSnapshot(id: "two", repository: "o/r", number: 2, title: "Two", url: URL(string: "https://github.com/o/r/pull/2")!, authorID: viewer.id, eligibleAt: secondEligible, isDraft: false, state: .open)
        ]
        let handoffs = [
            Handoff(id: "handoff", pullRequestID: "two", reviewerID: "reviewer", at: handedOffAt, outcome: .pending)
        ]
        let snapshot = AppSnapshot(viewer: viewer, pullRequests: pulls, events: [], handoffs: handoffs, assignedPullRequestIDs: [], attentionItems: [], metadata: .empty)

        let points = ActivitySeriesBuilder.points(snapshot: snapshot, range: .days7, asOf: asOf, calendar: calendar)
        let opened = points.filter { $0.series == "New" }
        let handoffsSeries = points.filter { $0.series == "Handoffs" }
        let merged = points.filter { $0.series == "Merged" }

        XCTAssertEqual(opened.count, 8)
        XCTAssertEqual(handoffsSeries.count, 8)
        XCTAssertEqual(merged.count, 8)
        XCTAssertEqual(opened.map(\.date), opened.map(\.date).sorted())
        XCTAssertEqual(handoffsSeries.map(\.date), handoffsSeries.map(\.date).sorted())
        XCTAssertEqual(merged.map(\.date), merged.map(\.date).sorted())
        XCTAssertEqual(opened.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(handoffsSeries.reduce(0) { $0 + $1.count }, 1)
        XCTAssertEqual(merged.reduce(0) { $0 + $1.count }, 1)
        let metrics = snapshot.windowMetrics(range: .days7, asOf: asOf)
        XCTAssertEqual(opened.reduce(0) { $0 + $1.count }, metrics.new)
        XCTAssertEqual(handoffsSeries.reduce(0) { $0 + $1.count }, metrics.handoffs)
        XCTAssertEqual(merged.reduce(0) { $0 + $1.count }, metrics.merged)
    }

    func testDoesNotPlotFutureMerge() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let asOf = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 12)))
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let pull = PullRequestSnapshot(
            id: "future",
            repository: "o/r",
            number: 1,
            title: "Future",
            url: URL(string: "https://github.com/o/r/pull/1")!,
            authorID: viewer.id,
            eligibleAt: asOf.addingTimeInterval(-3_600),
            isDraft: false,
            state: .merged,
            mergedAt: asOf.addingTimeInterval(3_600)
        )
        let snapshot = AppSnapshot(viewer: viewer, pullRequests: [pull], events: [], handoffs: [], assignedPullRequestIDs: [], attentionItems: [], metadata: .empty)

        let points = ActivitySeriesBuilder.points(snapshot: snapshot, range: .hours48, asOf: asOf, calendar: calendar)

        XCTAssertEqual(points.filter { $0.series == "Merged" }.reduce(0) { $0 + $1.count }, 0)
    }

    func testPlotsMergeInWindowForPullRequestOpenedBeforeWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let asOf = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 12)))
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let pull = PullRequestSnapshot(
            id: "old", repository: "o/r", number: 1, title: "Old",
            url: URL(string: "https://github.com/o/r/pull/1")!, authorID: viewer.id,
            eligibleAt: asOf.addingTimeInterval(-40 * 86_400), isDraft: false,
            state: .merged, mergedAt: asOf.addingTimeInterval(-3_600)
        )
        let snapshot = AppSnapshot(viewer: viewer, pullRequests: [pull], events: [], handoffs: [], assignedPullRequestIDs: [], attentionItems: [], metadata: .empty)

        let points = ActivitySeriesBuilder.points(snapshot: snapshot, range: .days7, asOf: asOf, calendar: calendar)

        XCTAssertEqual(points.filter { $0.series == "New" }.reduce(0) { $0 + $1.count }, 0)
        XCTAssertEqual(points.filter { $0.series == "Merged" }.reduce(0) { $0 + $1.count }, 1)
    }

    func testUsesHourlyBucketsFor48Hours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let asOf = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 12, minute: 30)))
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let snapshot = AppSnapshot(viewer: viewer, pullRequests: [], events: [], handoffs: [], assignedPullRequestIDs: [], attentionItems: [], metadata: .empty)

        let points = ActivitySeriesBuilder.points(snapshot: snapshot, range: .hours48, asOf: asOf, calendar: calendar)
        let opened = points.filter { $0.series == "New" }

        XCTAssertEqual(opened.count, 49)
        XCTAssertTrue(opened.allSatisfy { calendar.component(.minute, from: $0.date) == 0 })
    }

    func testHandoffSeriesUsesTheSameNonWithdrawnWindowDefinitionAsMetrics() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let asOf = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 12)))
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let pull = PullRequestSnapshot(
            id: "pull", repository: "o/r", number: 1, title: "Pull",
            url: URL(string: "https://github.com/o/r/pull/1")!, authorID: viewer.id,
            eligibleAt: asOf.addingTimeInterval(-10 * 86_400), isDraft: false, state: .open
        )
        let handoffs = [
            Handoff(id: "included", pullRequestID: pull.id, reviewerID: "alice",
                    at: asOf.addingTimeInterval(-3_600), outcome: .pending),
            Handoff(id: "withdrawn", pullRequestID: pull.id, reviewerID: "bob",
                    at: asOf.addingTimeInterval(-2_000),
                    outcome: .withdrawn(at: asOf.addingTimeInterval(-1_000), reason: "removed")),
            Handoff(id: "outside", pullRequestID: pull.id, reviewerID: "carol",
                    at: asOf.addingTimeInterval(-8 * 86_400), outcome: .pending)
        ]
        let snapshot = AppSnapshot(
            viewer: viewer, pullRequests: [pull], events: [], handoffs: handoffs,
            assignedPullRequestIDs: [], attentionItems: [], metadata: .empty
        )

        let points = ActivitySeriesBuilder.points(snapshot: snapshot, range: .days7, asOf: asOf, calendar: calendar)

        XCTAssertEqual(points.filter { $0.series == "Handoffs" }.reduce(0) { $0 + $1.count }, 1)
        XCTAssertEqual(snapshot.windowMetrics(range: .days7, asOf: asOf).handoffs, 1)
    }

    func testAllSeriesReconcileAtExactWindowBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let asOf = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 12)))
        let start = asOf.addingTimeInterval(-WindowRange.hours48.duration)
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let reviewer = GitHubUser(id: "reviewer", login: "alice", kind: .user)
        let pull = PullRequestSnapshot(
            id: "boundary", repository: "o/r", number: 1, title: "Boundary",
            url: URL(string: "https://github.com/o/r/pull/1")!, authorID: viewer.id,
            eligibleAt: start, isDraft: false, state: .merged, mergedAt: asOf
        )
        let events = [
            TimelineEvent(id: "approved", pullRequestID: pull.id,
                          kind: .reviewed(reviewer: reviewer, state: .approved), at: asOf)
        ]
        let handoffs = [
            Handoff(id: "at-start", pullRequestID: pull.id, reviewerID: reviewer.id,
                    at: start, outcome: .approved(at: asOf, reviewID: "approved")),
            Handoff(id: "before-start", pullRequestID: pull.id, reviewerID: "other",
                    at: start.addingTimeInterval(-0.001), outcome: .pending),
            Handoff(id: "after-end", pullRequestID: pull.id, reviewerID: "future",
                    at: asOf.addingTimeInterval(0.001), outcome: .pending)
        ]
        let snapshot = AppSnapshot(
            viewer: viewer, pullRequests: [pull], events: events, handoffs: handoffs,
            assignedPullRequestIDs: [], attentionItems: [], metadata: .empty
        )

        let points = ActivitySeriesBuilder.points(snapshot: snapshot, range: .hours48, asOf: asOf, calendar: calendar)
        let metrics = snapshot.windowMetrics(range: .hours48, asOf: asOf)

        XCTAssertEqual(points.filter { $0.series == "New" }.reduce(0) { $0 + $1.count }, metrics.new)
        XCTAssertEqual(points.filter { $0.series == "Handoffs" }.reduce(0) { $0 + $1.count }, metrics.handoffs)
        XCTAssertEqual(points.filter { $0.series == "Merged" }.reduce(0) { $0 + $1.count }, metrics.merged)
        XCTAssertEqual(metrics.new, 1)
        XCTAssertEqual(metrics.handoffs, 1)
        XCTAssertEqual(metrics.merged, 1)
    }
}
