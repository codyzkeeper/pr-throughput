import Foundation

/// Independent GitHub events whose effective timestamps fall in a rolling window.
/// These values are activity counts, not stages of a partitioning funnel.
struct WindowActivityMetrics: Codable, Equatable, Sendable {
    let opened: Int
    let handoffs: Int
    let merged: Int
    let approved: Int
    let changesRequested: Int
    let awaiting: Int

    var decisions: Int { approved + changesRequested }

    static let empty = WindowActivityMetrics(
        opened: 0,
        handoffs: 0,
        merged: 0,
        approved: 0,
        changesRequested: 0,
        awaiting: 0
    )

    static func calculate(
        pullRequests: [PullRequestSnapshot],
        events: [TimelineEvent],
        handoffs: [Handoff],
        viewerID: String,
        range: CohortRange,
        asOf: Date
    ) -> WindowActivityMetrics {
        let start = asOf.addingTimeInterval(-range.duration)
        let authored = pullRequests.filter { $0.authorID == viewerID && $0.eligibleAt != nil }
        let authoredIDs = Set(authored.map(\.id))
        let eligibilityByPullRequest = Dictionary(
            authored.compactMap { pull in pull.eligibleAt.map { (pull.id, $0) } },
            uniquingKeysWith: min
        )
        let isInWindow: (Date) -> Bool = { $0 >= start && $0 <= asOf }

        let opened = authored.filter { pull in
            pull.eligibleAt.map(isInWindow) ?? false
        }.count
        let merged = authored.filter { pull in
            guard let eligibleAt = pull.eligibleAt, let mergedAt = pull.mergedAt else { return false }
            return mergedAt >= eligibleAt && isInWindow(mergedAt)
        }.count

        var approved = 0
        var changesRequested = 0
        for event in events where authoredIDs.contains(event.pullRequestID) && isInWindow(event.at) {
            guard let eligibleAt = eligibilityByPullRequest[event.pullRequestID], event.at >= eligibleAt,
                  case let .reviewed(reviewer, state) = event.kind,
                  reviewer.kind == .user, reviewer.id != viewerID else { continue }
            switch state {
            case .approved: approved += 1
            case .changesRequested: changesRequested += 1
            case .commented, .dismissed, .pending: continue
            }
        }

        let windowHandoffs = handoffs.filter { handoff in
            guard let eligibleAt = eligibilityByPullRequest[handoff.pullRequestID],
                  handoff.at >= eligibleAt, isInWindow(handoff.at) else { return false }
            if case let .withdrawn(at, _) = handoff.outcome, at <= asOf { return false }
            return true
        }
        let awaiting = windowHandoffs.filter { handoff in
            switch handoff.outcome {
            case .pending: return true
            case let .approved(at, _), let .changesRequested(at, _), let .withdrawn(at, _):
                return at > asOf
            }
        }.count

        return WindowActivityMetrics(
            opened: opened,
            handoffs: windowHandoffs.count,
            merged: merged,
            approved: approved,
            changesRequested: changesRequested,
            awaiting: awaiting
        )
    }
}
