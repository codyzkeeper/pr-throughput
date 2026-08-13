import Foundation

enum HandoffResolver {
    private struct ReviewKey: Hashable {
        let pullRequestID: String
        let reviewerID: String
    }

    static func resolve(handoffs: [Handoff], events: [TimelineEvent]) -> [Handoff] {
        var result = handoffs.sorted { lhs, rhs in
            lhs.at == rhs.at ? lhs.id < rhs.id : lhs.at < rhs.at
        }
        let orderedEvents = events.sorted(by: eventOrder)
        var nextHandoff = 0
        var latestByReviewer: [ReviewKey: Int] = [:]
        var pendingByPullRequest: [String: Set<Int>] = [:]

        func removePending(_ index: Int) {
            pendingByPullRequest[result[index].pullRequestID]?.remove(index)
        }

        func activateHandoffs(through cutoff: Date) {
            while nextHandoff < result.count, result[nextHandoff].at <= cutoff {
                let index = nextHandoff
                let handoff = result[index]
                let key = ReviewKey(pullRequestID: handoff.pullRequestID, reviewerID: handoff.reviewerID)
                if let previous = latestByReviewer[key], case .pending = result[previous].outcome {
                    result[previous].outcome = .withdrawn(at: handoff.at, reason: "superseded-by-new-handoff")
                    removePending(previous)
                }
                latestByReviewer[key] = index
                if case .pending = handoff.outcome {
                    pendingByPullRequest[handoff.pullRequestID, default: []].insert(index)
                }
                nextHandoff += 1
            }
        }

        for event in orderedEvents {
            activateHandoffs(through: event.at)
            switch event.kind {
            case let .reviewed(reviewer, state):
                guard state == .approved || state == .changesRequested else { continue }
                let key = ReviewKey(pullRequestID: event.pullRequestID, reviewerID: reviewer.id)
                guard let index = latestByReviewer[key] else { continue }
                switch result[index].outcome {
                case .pending, .withdrawn:
                    result[index].outcome = state == .approved
                        ? .approved(at: event.at, reviewID: event.id)
                        : .changesRequested(at: event.at, reviewID: event.id)
                    removePending(index)
                case .approved, .changesRequested:
                    continue
                }
            case let .reviewRequestRemoved(reviewer):
                let key = ReviewKey(pullRequestID: event.pullRequestID, reviewerID: reviewer.id)
                guard let index = latestByReviewer[key], case .pending = result[index].outcome else { continue }
                result[index].outcome = .withdrawn(at: event.at, reason: "review-request-removed")
                removePending(index)
            case .merged, .closed:
                let pending = pendingByPullRequest.removeValue(forKey: event.pullRequestID) ?? []
                for index in pending {
                    result[index].outcome = .withdrawn(at: event.at, reason: "pull-request-ended")
                }
            default:
                continue
            }
        }

        activateHandoffs(through: .distantFuture)
        return result.sorted { $0.id < $1.id }
    }

    private static func eventOrder(_ lhs: TimelineEvent, _ rhs: TimelineEvent) -> Bool {
        if lhs.at != rhs.at { return lhs.at < rhs.at }
        if lhs.pullRequestID != rhs.pullRequestID { return lhs.pullRequestID < rhs.pullRequestID }
        if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
        return lhs.id < rhs.id
    }
}
