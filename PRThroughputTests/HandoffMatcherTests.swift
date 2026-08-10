import XCTest
@testable import PRThroughput

final class HandoffMatcherTests: XCTestCase {
    private let viewer = GitHubUser(id: "viewer", login: "me", kind: .user)
    private let reviewer = GitHubUser(id: "reviewer", login: "alice", kind: .user)

    func testMatchesAtExactlyFiveMinutesButNotBeyond() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let boundary = events(base: base, reviewOffset: 300)
        let outside = events(base: base, reviewOffset: 300.001)

        XCTAssertEqual(HandoffMatcher.match(events: boundary, viewerID: viewer.id).count, 1)
        XCTAssertEqual(HandoffMatcher.match(events: outside, viewerID: viewer.id).count, 0)
    }

    func testIgnoresTeamsBotsAndIncompleteTriples() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let team = GitHubUser(id: "team", login: "platform", kind: .team)
        let bot = GitHubUser(id: "bot", login: "automation", kind: .bot)
        let shared = [
            TimelineEvent(id: "u", pullRequestID: "pr", kind: .unassigned(viewer), at: base),
            TimelineEvent(id: "a-team", pullRequestID: "pr", kind: .assigned(team), at: base),
            TimelineEvent(id: "r-team", pullRequestID: "pr", kind: .reviewRequested(team), at: base),
            TimelineEvent(id: "a-bot", pullRequestID: "pr", kind: .assigned(bot), at: base),
            TimelineEvent(id: "r-bot", pullRequestID: "pr", kind: .reviewRequested(bot), at: base),
            TimelineEvent(id: "a-only", pullRequestID: "pr", kind: .assigned(reviewer), at: base)
        ]

        XCTAssertTrue(HandoffMatcher.match(events: shared, viewerID: viewer.id).isEmpty)
    }

    func testMatchingIsStableAcrossDeliveryOrderAndDuplicateInput() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let source = events(base: base, reviewOffset: 30)
        let first = HandoffMatcher.match(events: source, viewerID: viewer.id)
        let second = HandoffMatcher.match(events: Array(source.reversed()) + source, viewerID: viewer.id)

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(second.map(\.id)).count, second.count)
    }

    func testMatchesGitHubMutationEventsRegardlessOfTimestampOrder() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            TimelineEvent(id: "a", pullRequestID: "pr", kind: .assigned(reviewer), at: base),
            TimelineEvent(id: "r", pullRequestID: "pr", kind: .reviewRequested(reviewer), at: base.addingTimeInterval(10)),
            TimelineEvent(id: "u", pullRequestID: "pr", kind: .unassigned(viewer), at: base.addingTimeInterval(20))
        ]

        XCTAssertEqual(HandoffMatcher.match(events: events, viewerID: viewer.id).count, 1)
    }

    func testRejectsSelfAssignmentAndSelfReviewRequest() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [
            TimelineEvent(id: "u", pullRequestID: "pr", kind: .unassigned(viewer), at: base),
            TimelineEvent(id: "a", pullRequestID: "pr", kind: .assigned(viewer), at: base.addingTimeInterval(10)),
            TimelineEvent(id: "r", pullRequestID: "pr", kind: .reviewRequested(viewer), at: base.addingTimeInterval(20))
        ]

        XCTAssertTrue(HandoffMatcher.match(events: events, viewerID: viewer.id).isEmpty)
    }

    func testLongTimelineRemainsWindowBounded() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var timeline: [TimelineEvent] = []
        for index in 0..<300 {
            let reviewer = GitHubUser(id: "reviewer-\(index)", login: "reviewer-\(index)", kind: .user)
            let start = base.addingTimeInterval(TimeInterval(index * 1_000))
            timeline.append(TimelineEvent(id: "u-\(index)", pullRequestID: "pr", kind: .unassigned(viewer), at: start))
            timeline.append(TimelineEvent(id: "a-\(index)", pullRequestID: "pr", kind: .assigned(reviewer), at: start.addingTimeInterval(10)))
            timeline.append(TimelineEvent(id: "r-\(index)", pullRequestID: "pr", kind: .reviewRequested(reviewer), at: start.addingTimeInterval(20)))
        }

        let started = ContinuousClock.now
        let matches = HandoffMatcher.match(events: timeline, viewerID: viewer.id)
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(matches.count, 300)
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    private func events(base: Date, reviewOffset: TimeInterval) -> [TimelineEvent] {
        [
            TimelineEvent(id: "u", pullRequestID: "pr", kind: .unassigned(viewer), at: base),
            TimelineEvent(id: "a", pullRequestID: "pr", kind: .assigned(reviewer), at: base.addingTimeInterval(10)),
            TimelineEvent(id: "r", pullRequestID: "pr", kind: .reviewRequested(reviewer), at: base.addingTimeInterval(reviewOffset))
        ]
    }
}
