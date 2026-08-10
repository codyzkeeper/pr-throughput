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
        let pulls = [
            PullRequestSnapshot(id: "one", repository: "o/r", number: 1, title: "One", url: URL(string: "https://github.com/o/r/pull/1")!, authorID: viewer.id, eligibleAt: firstEligible, isDraft: false, state: .merged, mergedAt: mergedAt),
            PullRequestSnapshot(id: "two", repository: "o/r", number: 2, title: "Two", url: URL(string: "https://github.com/o/r/pull/2")!, authorID: viewer.id, eligibleAt: secondEligible, isDraft: false, state: .open)
        ]
        let snapshot = AppSnapshot(viewer: viewer, pullRequests: pulls, events: [], handoffs: [], assignedPullRequestIDs: [], attentionItems: [], metadata: .empty)

        let points = ActivitySeriesBuilder.points(snapshot: snapshot, range: .days7, asOf: asOf, calendar: calendar)
        let opened = points.filter { $0.series == "Opened" }
        let merged = points.filter { $0.series == "Merged" }

        XCTAssertEqual(opened.count, 8)
        XCTAssertEqual(merged.count, 8)
        XCTAssertEqual(opened.map(\.date), opened.map(\.date).sorted())
        XCTAssertEqual(merged.map(\.date), merged.map(\.date).sorted())
        XCTAssertEqual(opened.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(merged.reduce(0) { $0 + $1.count }, 1)
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

        XCTAssertEqual(points.filter { $0.series == "Opened" }.reduce(0) { $0 + $1.count }, 0)
        XCTAssertEqual(points.filter { $0.series == "Merged" }.reduce(0) { $0 + $1.count }, 1)
    }

    func testUsesHourlyBucketsFor48Hours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let asOf = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 12, minute: 30)))
        let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
        let snapshot = AppSnapshot(viewer: viewer, pullRequests: [], events: [], handoffs: [], assignedPullRequestIDs: [], attentionItems: [], metadata: .empty)

        let points = ActivitySeriesBuilder.points(snapshot: snapshot, range: .hours48, asOf: asOf, calendar: calendar)
        let opened = points.filter { $0.series == "Opened" }

        XCTAssertEqual(opened.count, 49)
        XCTAssertTrue(opened.allSatisfy { calendar.component(.minute, from: $0.date) == 0 })
    }
}
