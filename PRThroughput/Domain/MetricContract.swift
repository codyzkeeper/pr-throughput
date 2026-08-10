import CryptoKit
import Foundation

enum MetricContract {
    static let schemaVersion = 3
    static let metricContractVersion = "3"
    static let primaryRange = CohortRange.days7

    static func snapshot(from source: AppSnapshot, asOf: Date) throws -> CanonicalMetricSnapshot {
        let rangeSnapshots = CohortRange.allCases.map { range in
            let cohort = CohortMetrics.cohort(
                pullRequests: source.pullRequests,
                viewerID: source.viewer.id,
                range: range,
                asOf: asOf
            ).sorted { $0.id < $1.id }
            let openIDs = cohort.filter { pull in
                let merged = pull.mergedAt.map { $0 <= asOf } ?? false
                let closed = pull.mergedAt == nil
                    && pull.state == .closed
                    && (pull.closedAt.map { $0 <= asOf } ?? true)
                return !merged && !closed
            }.map(\.id)
            return MetricRangeSnapshot(
                range: range,
                cohortStartedAt: asOf.addingTimeInterval(-range.duration),
                cohortPullRequestIDs: cohort.map(\.id),
                openPullRequestIDs: openIDs,
                activity: source.activity(range: range, asOf: asOf),
                metrics: CohortMetrics.calculate(
                    pullRequests: source.pullRequests,
                    handoffs: source.handoffs,
                    viewerID: source.viewer.id,
                    range: range,
                    asOf: asOf
                )
            )
        }
        return CanonicalMetricSnapshot(
            schemaVersion: schemaVersion,
            metricContractVersion: metricContractVersion,
            primaryRange: primaryRange,
            asOf: asOf,
            viewerID: source.viewer.id,
            viewerLogin: source.viewer.login,
            sourceDigest: try sourceDigest(source),
            ranges: rangeSnapshots
        )
    }

    private static func sourceDigest(_ source: AppSnapshot) throws -> String {
        let facts = MetricSourceFacts(
            viewerID: source.viewer.id,
            pullRequests: source.pullRequests.sorted { $0.id < $1.id },
            events: source.events.sorted { lhs, rhs in
                lhs.at == rhs.at ? lhs.id < rhs.id : lhs.at < rhs.at
            },
            handoffs: source.handoffs.sorted { $0.id < $1.id }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(facts))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct CanonicalMetricSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let metricContractVersion: String
    let primaryRange: CohortRange
    let asOf: Date
    let viewerID: String
    let viewerLogin: String
    let sourceDigest: String
    let ranges: [MetricRangeSnapshot]

    func metrics(for range: CohortRange) -> CohortMetrics? {
        ranges.first { $0.range == range }?.metrics
    }

    func activity(for range: CohortRange) -> WindowActivityMetrics? {
        ranges.first { $0.range == range }?.activity
    }
}

struct MetricRangeSnapshot: Codable, Equatable, Sendable {
    let range: CohortRange
    let cohortStartedAt: Date
    let cohortPullRequestIDs: [String]
    let openPullRequestIDs: [String]
    let activity: WindowActivityMetrics
    let metrics: CohortMetrics
}

private struct MetricSourceFacts: Codable {
    let viewerID: String
    let pullRequests: [PullRequestSnapshot]
    let events: [TimelineEvent]
    let handoffs: [Handoff]
}
