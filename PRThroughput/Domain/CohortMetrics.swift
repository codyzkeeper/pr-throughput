import Foundation

enum CohortRange: String, CaseIterable, Codable, Identifiable, Sendable {
    case hours48 = "48h"
    case days7 = "7d"
    case days30 = "30d"

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .hours48: 48 * 3_600
        case .days7: 7 * 24 * 3_600
        case .days30: 30 * 24 * 3_600
        }
    }
}

struct CohortMetrics: Codable, Equatable, Sendable {
    let opened: Int
    let handedOff: Int
    let merged: Int
    let open: Int
    let closedUnmerged: Int
    let decisions: Int
    let approved: Int
    let changesRequested: Int
    let pending: Int
    let mergeCompletionRate: Double?
    let acceptanceRate: Double?
    let reworkRate: Double?
    let medianOpenAge: TimeInterval?
    let medianTimeToMerge: TimeInterval?

    static let empty = CohortMetrics(
        opened: 0, handedOff: 0, merged: 0, open: 0, closedUnmerged: 0,
        decisions: 0, approved: 0, changesRequested: 0,
        pending: 0, mergeCompletionRate: nil, acceptanceRate: nil,
        reworkRate: nil, medianOpenAge: nil, medianTimeToMerge: nil
    )

    static func calculate(
        pullRequests: [PullRequestSnapshot],
        handoffs: [Handoff],
        viewerID: String,
        range: CohortRange,
        asOf: Date
    ) -> CohortMetrics {
        let cohort = cohort(
            pullRequests: pullRequests,
            viewerID: viewerID,
            range: range,
            asOf: asOf
        )
        let cohortIDs = Set(cohort.map(\.id))
        let eligibilityByPullRequest = Dictionary(
            cohort.compactMap { pull in pull.eligibleAt.map { (pull.id, $0) } },
            uniquingKeysWith: min
        )
        let cohortHandoffs = handoffs.filter { handoff in
            guard cohortIDs.contains(handoff.pullRequestID),
                  let eligibleAt = eligibilityByPullRequest[handoff.pullRequestID] else { return false }
            return handoff.at >= eligibleAt && handoff.at <= asOf
        }
        let approved = cohortHandoffs.filter {
            if case let .approved(at, _) = $0.outcome { return at <= asOf }
            return false
        }.count
        let changes = cohortHandoffs.filter {
            if case let .changesRequested(at, _) = $0.outcome { return at <= asOf }
            return false
        }.count
        let pending = cohortHandoffs.filter {
            switch $0.outcome {
            case .pending: return true
            case let .approved(at, _), let .changesRequested(at, _), let .withdrawn(at, _): return at > asOf
            }
        }.count
        let handedOff = Set(cohortHandoffs.compactMap { handoff -> String? in
            if case let .withdrawn(at, _) = handoff.outcome, at <= asOf { return nil }
            return handoff.pullRequestID
        }).count
        let merged = cohort.filter { $0.mergedAt.map { $0 <= asOf } ?? false }.count
        let closed = cohort.filter {
            $0.mergedAt == nil && $0.state == .closed && ($0.closedAt.map { $0 <= asOf } ?? true)
        }.count
        let open = cohort.count - merged - closed
        let openAges = cohort.compactMap { pull -> TimeInterval? in
            let isMerged = pull.mergedAt.map { $0 <= asOf } ?? false
            let isClosed = pull.mergedAt == nil
                && pull.state == .closed
                && (pull.closedAt.map { $0 <= asOf } ?? true)
            guard !isMerged, !isClosed, let eligibleAt = pull.eligibleAt else { return nil }
            return max(0, asOf.timeIntervalSince(eligibleAt))
        }.sorted()
        let decisions = approved + changes
        let mergeDurations = cohort.compactMap { pull -> TimeInterval? in
            guard let eligibleAt = pull.eligibleAt,
                  let mergedAt = pull.mergedAt,
                  mergedAt <= asOf else { return nil }
            return max(0, mergedAt.timeIntervalSince(eligibleAt))
        }.sorted()

        return CohortMetrics(
            opened: cohort.count,
            handedOff: handedOff,
            merged: merged,
            open: open,
            closedUnmerged: closed,
            decisions: decisions,
            approved: approved,
            changesRequested: changes,
            pending: pending,
            mergeCompletionRate: ratio(merged, cohort.count),
            acceptanceRate: ratio(approved, decisions),
            reworkRate: ratio(changes, decisions),
            medianOpenAge: median(openAges),
            medianTimeToMerge: median(mergeDurations)
        )
    }

    static func cohort(
        pullRequests: [PullRequestSnapshot],
        viewerID: String,
        range: CohortRange,
        asOf: Date
    ) -> [PullRequestSnapshot] {
        let start = asOf.addingTimeInterval(-range.duration)
        return pullRequests.filter {
            guard $0.authorID == viewerID, let eligibleAt = $0.eligibleAt else { return false }
            return eligibleAt >= start && eligibleAt <= asOf
        }
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double? {
        denominator == 0 ? nil : Double(numerator) / Double(denominator)
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}
