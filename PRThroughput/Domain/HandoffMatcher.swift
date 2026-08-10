import Foundation

enum HandoffMatcher {
    static let matchingWindow: TimeInterval = 300

    private struct Candidate: Comparable {
        let unassignment: TimelineEvent
        let assignment: TimelineEvent
        let request: TimelineEvent
        let reviewer: GitHubUser
        let span: TimeInterval

        static func < (lhs: Candidate, rhs: Candidate) -> Bool {
            if lhs.span != rhs.span { return lhs.span < rhs.span }
            let lhsEnd = max(lhs.unassignment.at, lhs.assignment.at, lhs.request.at)
            let rhsEnd = max(rhs.unassignment.at, rhs.assignment.at, rhs.request.at)
            if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
            return lhs.stableKey < rhs.stableKey
        }

        var stableKey: String {
            [unassignment.id, assignment.id, request.id].sorted().joined(separator: "|")
        }
    }

    static func match(events: some Sequence<TimelineEvent>, viewerID: String) -> [Handoff] {
        let unique = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        let byPullRequest = Dictionary(grouping: unique, by: \.pullRequestID)
        var result: [Handoff] = []

        for (pullRequestID, pullEvents) in byPullRequest {
            let unassignments = pullEvents.filter {
                guard case let .unassigned(user) = $0.kind else { return false }
                return user.id == viewerID
            }.sorted(by: eventOrder)
            let assignments = pullEvents.compactMap { event -> (TimelineEvent, GitHubUser)? in
                guard case let .assigned(user) = event.kind,
                      user.kind == .user,
                      user.id != viewerID else { return nil }
                return (event, user)
            }.sorted { eventOrder($0.0, $1.0) }
            let requests = pullEvents.compactMap { event -> (TimelineEvent, GitHubUser)? in
                guard case let .reviewRequested(user) = event.kind,
                      user.kind == .user,
                      user.id != viewerID else { return nil }
                return (event, user)
            }.sorted { eventOrder($0.0, $1.0) }

            var candidates: [Candidate] = []
            let requestsByReviewer = Dictionary(grouping: requests, by: { $0.1.id })
            for (assignment, assignee) in assignments {
                guard let reviewerRequests = requestsByReviewer[assignee.id] else { continue }
                let requestStart = lowerBound(reviewerRequests, at: assignment.at.addingTimeInterval(-matchingWindow))
                var requestIndex = requestStart
                while requestIndex < reviewerRequests.count {
                    let (request, reviewer) = reviewerRequests[requestIndex]
                    guard request.at <= assignment.at.addingTimeInterval(matchingWindow) else { break }
                    let lower = max(assignment.at, request.at).addingTimeInterval(-matchingWindow)
                    let upper = min(assignment.at, request.at).addingTimeInterval(matchingWindow)
                    var unassignmentIndex = lowerBound(unassignments, at: lower)
                    while unassignmentIndex < unassignments.count {
                        let unassignment = unassignments[unassignmentIndex]
                        guard unassignment.at <= upper else { break }
                        let earliest = min(unassignment.at, min(assignment.at, request.at))
                        let latest = max(unassignment.at, max(assignment.at, request.at))
                        let span = latest.timeIntervalSince(earliest)
                        candidates.append(Candidate(
                            unassignment: unassignment,
                            assignment: assignment,
                            request: request,
                            reviewer: reviewer,
                            span: span
                        ))
                        unassignmentIndex += 1
                    }
                    requestIndex += 1
                }
            }

            var usedAssignments = Set<String>()
            var usedRequests = Set<String>()
            for candidate in candidates.sorted() {
                guard usedAssignments.insert(candidate.assignment.id).inserted,
                      usedRequests.insert(candidate.request.id).inserted else { continue }
                let id = [pullRequestID, candidate.reviewer.id, candidate.assignment.id, candidate.request.id]
                    .joined(separator: ":")
                result.append(Handoff(
                    id: id,
                    pullRequestID: pullRequestID,
                    reviewerID: candidate.reviewer.id,
                    at: max(candidate.unassignment.at, candidate.assignment.at, candidate.request.at),
                    outcome: .pending
                ))
            }
        }

        return result.sorted { $0.id < $1.id }
    }

    private static func eventOrder(_ lhs: TimelineEvent, _ rhs: TimelineEvent) -> Bool {
        lhs.at == rhs.at ? lhs.id < rhs.id : lhs.at < rhs.at
    }

    private static func lowerBound(_ events: [TimelineEvent], at date: Date) -> Int {
        var lower = 0
        var upper = events.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if events[middle].at < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func lowerBound(_ events: [(TimelineEvent, GitHubUser)], at date: Date) -> Int {
        var lower = 0
        var upper = events.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if events[middle].0.at < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}
