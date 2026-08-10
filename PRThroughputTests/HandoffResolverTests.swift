import XCTest
@testable import PRThroughput

final class HandoffResolverTests: XCTestCase {
    func testDecisionResolvesLatestPendingCycleOnce() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let reviewer = GitHubUser(id: "reviewer", login: "alice", kind: .user)
        let handoffs = [
            Handoff(id: "h1", pullRequestID: "pr", reviewerID: reviewer.id, at: base, outcome: .pending),
            Handoff(id: "h2", pullRequestID: "pr", reviewerID: reviewer.id, at: base.addingTimeInterval(100), outcome: .pending)
        ]
        let events = [
            TimelineEvent(id: "review", pullRequestID: "pr", kind: .reviewed(reviewer: reviewer, state: .changesRequested), at: base.addingTimeInterval(200)),
            TimelineEvent(id: "approval-without-rehandoff", pullRequestID: "pr", kind: .reviewed(reviewer: reviewer, state: .approved), at: base.addingTimeInterval(300))
        ]

        let resolved = HandoffResolver.resolve(handoffs: handoffs, events: events)

        XCTAssertEqual(resolved.first(where: { $0.id == "h1" })?.outcome, .withdrawn(at: base.addingTimeInterval(100), reason: "superseded-by-new-handoff"))
        XCTAssertEqual(resolved.first(where: { $0.id == "h2" })?.outcome, .changesRequested(at: base.addingTimeInterval(200), reviewID: "review"))
    }

    func testRemovedRequestWithdrawsAndMergeEndsRemainingCycles() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let alice = GitHubUser(id: "alice", login: "alice", kind: .user)
        let bob = GitHubUser(id: "bob", login: "bob", kind: .user)
        let handoffs = [
            Handoff(id: "a", pullRequestID: "pr", reviewerID: alice.id, at: base, outcome: .pending),
            Handoff(id: "b", pullRequestID: "pr", reviewerID: bob.id, at: base, outcome: .pending)
        ]
        let events = [
            TimelineEvent(id: "removed", pullRequestID: "pr", kind: .reviewRequestRemoved(alice), at: base.addingTimeInterval(20)),
            TimelineEvent(id: "merged", pullRequestID: "pr", kind: .merged, at: base.addingTimeInterval(30))
        ]

        let resolved = HandoffResolver.resolve(handoffs: handoffs, events: events)
        guard case let .withdrawn(_, aliceReason)? = resolved.first(where: { $0.id == "a" })?.outcome else {
            return XCTFail("Alice should be withdrawn")
        }
        guard case let .withdrawn(_, bobReason)? = resolved.first(where: { $0.id == "b" })?.outcome else {
            return XCTFail("Bob should be withdrawn")
        }
        XCTAssertEqual(aliceReason, "review-request-removed")
        XCTAssertEqual(bobReason, "pull-request-ended")
    }

    func testDecisionBeforeLaterHandoffRemainsAttachedToEarlierCycle() {
        let start = Date(timeIntervalSince1970: 1_000)
        let reviewer = GitHubUser(id: "reviewer", login: "alice", kind: .user)
        let handoffs = [
            Handoff(id: "first", pullRequestID: "pr", reviewerID: reviewer.id, at: start, outcome: .pending),
            Handoff(id: "second", pullRequestID: "pr", reviewerID: reviewer.id, at: start.addingTimeInterval(120), outcome: .pending)
        ]
        let approval = TimelineEvent(
            id: "approval",
            pullRequestID: "pr",
            kind: .reviewed(reviewer: reviewer, state: .approved),
            at: start.addingTimeInterval(60)
        )

        let resolved = HandoffResolver.resolve(handoffs: handoffs, events: [approval])

        guard case .approved = resolved.first(where: { $0.id == "first" })?.outcome else {
            return XCTFail("The first review decision should remain accepted")
        }
        guard case .pending = resolved.first(where: { $0.id == "second" })?.outcome else {
            return XCTFail("The later handoff should still await a decision")
        }
    }

    func testActualReviewResolvesAWithdrawnRequest() {
        let start = Date(timeIntervalSince1970: 1_000)
        let reviewer = GitHubUser(id: "reviewer", login: "alice", kind: .user)
        let handoff = Handoff(
            id: "handoff",
            pullRequestID: "pr",
            reviewerID: reviewer.id,
            at: start,
            outcome: .pending
        )
        let events = [
            TimelineEvent(id: "removed", pullRequestID: "pr", kind: .reviewRequestRemoved(reviewer), at: start.addingTimeInterval(30)),
            TimelineEvent(id: "review", pullRequestID: "pr", kind: .reviewed(reviewer: reviewer, state: .approved), at: start.addingTimeInterval(60))
        ]

        let resolved = HandoffResolver.resolve(handoffs: [handoff], events: events)

        XCTAssertEqual(resolved.first?.outcome, .approved(at: start.addingTimeInterval(60), reviewID: "review"))
    }

    func testLongTimelineResolvesInSinglePass() {
        let start = Date(timeIntervalSince1970: 1_000)
        let reviewer = GitHubUser(id: "reviewer", login: "alice", kind: .user)
        var handoffs: [Handoff] = []
        var events: [TimelineEvent] = []
        for index in 0..<300 {
            let handoffAt = start.addingTimeInterval(TimeInterval(index * 10))
            handoffs.append(Handoff(id: "h-\(index)", pullRequestID: "pr", reviewerID: reviewer.id, at: handoffAt, outcome: .pending))
            events.append(TimelineEvent(id: "r-\(index)", pullRequestID: "pr", kind: .reviewed(reviewer: reviewer, state: .approved), at: handoffAt.addingTimeInterval(5)))
        }

        let started = ContinuousClock.now
        let resolved = HandoffResolver.resolve(handoffs: handoffs, events: events)
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(resolved.count, 300)
        XCTAssertTrue(resolved.allSatisfy { if case .approved = $0.outcome { return true }; return false })
        XCTAssertLessThan(elapsed, .seconds(2))
    }
}
