import CryptoKit
import Foundation

enum MetricContract {
    static let schemaVersion = 4
    static let metricContractVersion = "4"
    static let primaryRange = WindowRange.days7

    static func snapshot(from source: AppSnapshot, asOf: Date) throws -> CanonicalMetricSnapshot {
        let ranges = WindowRange.allCases.map { range in
            MetricRangeSnapshot(
                range: range,
                windowStart: asOf.addingTimeInterval(-range.duration),
                metrics: source.windowMetrics(range: range, asOf: asOf)
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
            ranges: ranges
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
    let primaryRange: WindowRange
    let asOf: Date
    let viewerID: String
    let viewerLogin: String
    let sourceDigest: String
    let ranges: [MetricRangeSnapshot]

    func metrics(for range: WindowRange) -> WindowMetrics? {
        ranges.first { $0.range == range }?.metrics
    }
}

struct MetricRangeSnapshot: Codable, Equatable, Sendable {
    let range: WindowRange
    let windowStart: Date
    let metrics: WindowMetrics
}

private struct MetricSourceFacts: Codable {
    let viewerID: String
    let pullRequests: [PullRequestSnapshot]
    let events: [TimelineEvent]
    let handoffs: [Handoff]
}
