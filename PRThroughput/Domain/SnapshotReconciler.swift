import Foundation

struct ReconciliationReport: Equatable, Sendable {
    let issues: [String]

    var isValid: Bool { issues.isEmpty }
}

struct DataIntegrityError: LocalizedError, Equatable {
    let issues: [String]

    var errorDescription: String? {
        "Data reconciliation failed: \(issues.joined(separator: " ")) The previous verified totals were preserved."
    }
}

enum SnapshotReconciler {
    static func validate(
        _ snapshot: AppSnapshot,
        asOf: Date = Date(),
        actionConfiguration: ActionNotificationConfiguration? = nil
    ) -> ReconciliationReport {
        var issues: [String] = []
        if snapshot.metadata.timelineSchemaVersion != TimelineEvent.sourceSchemaVersion {
            issues.append("Timeline cache schema is stale and must be refreshed before window metrics can be verified.")
        }
        let configuredRules = actionConfiguration.flatMap { try? $0.validated() }.map {
            Dictionary(uniqueKeysWithValues: $0.enabledRules.map { ($0.id, $0.labelName.lowercased()) })
        }

        appendDuplicateIssue(snapshot.pullRequests.map(\.id), label: "pull request", to: &issues)
        appendDuplicateIssue(snapshot.events.map(\.id), label: "timeline event", to: &issues)
        appendDuplicateIssue(snapshot.handoffs.map(\.id), label: "handoff", to: &issues)
        appendDuplicateIssue(snapshot.attentionItems.map(\.id), label: "attention row", to: &issues)
        appendDuplicateIssue(
            snapshot.attentionItems.flatMap(\.applications).map(\.labelEventID),
            label: "action-label application",
            to: &issues
        )

        for item in snapshot.attentionItems {
            if item.url.scheme != "https" || item.url.host?.lowercased() != "github.com"
                || !item.url.path.contains("/pull/") {
                issues.append("Attention inbox contains an invalid PR URL.")
            }
            switch item.kind {
            case .actionLabels:
                guard let pullRequestID = item.pullRequestID, !item.applications.isEmpty else {
                    issues.append("Action-label row is missing its PR identity or applications.")
                    continue
                }
                if item.revisionID != AttentionItem.actionRevision(item.applications) {
                    issues.append("Action-label row revision does not match its applications.")
                }
                appendDuplicateIssue(item.applications.map { $0.ruleID.rawValue }, label: "action rule in one PR row", to: &issues)
                for application in item.applications {
                    if application.pullRequestID != pullRequestID {
                        issues.append("Action-label application references a different PR.")
                    }
                    if application.normalizedColorHex == nil {
                        issues.append("Action-label application has an invalid label color.")
                    }
                    if let configuredRules,
                       configuredRules[application.ruleID] != application.labelName.lowercased() {
                        issues.append("Action-label application does not match the active configuration.")
                    }
                }
            default:
                if snapshot.metadata.actionAuthorityVersion == 1 {
                    issues.append("Action-label authority contains active legacy attention data.")
                } else if !item.isVerifiedDirectMention {
                    issues.append("Direct-mention inbox contains unverified legacy data.")
                }
            }
        }
        if snapshot.metadata.actionAuthorityVersion == 1,
           !snapshot.attentionItems.isEmpty,
           snapshot.metadata.actionConfigurationRevision == nil {
            issues.append("Action-label facts are missing their configuration revision.")
        }
        if let actionConfiguration,
           snapshot.metadata.actionConfigurationRevision != actionConfiguration.revision {
            issues.append("Action-label facts use a stale configuration revision.")
        }

        let pullIDs = Set(snapshot.pullRequests.map(\.id))
        let orphanEvents = snapshot.events.filter { !pullIDs.contains($0.pullRequestID) }.map(\.id)
        if !orphanEvents.isEmpty {
            issues.append("\(orphanEvents.count) timeline event(s) reference an unknown PR.")
        }
        let orphanHandoffs = snapshot.handoffs.filter { !pullIDs.contains($0.pullRequestID) }.map(\.id)
        if !orphanHandoffs.isEmpty {
            issues.append("\(orphanHandoffs.count) handoff(s) reference an unknown PR.")
        }

        for pull in snapshot.pullRequests {
            switch pull.state {
            case .merged:
                if pull.mergedAt == nil { issues.append("Merged PR \(pull.repository)#\(pull.number) has no merge time.") }
            case .closed:
                if pull.mergedAt != nil { issues.append("Closed PR \(pull.repository)#\(pull.number) also has a merge time.") }
            case .open:
                if pull.mergedAt != nil || pull.closedAt != nil {
                    issues.append("Open PR \(pull.repository)#\(pull.number) has terminal timestamps.")
                }
            }
            if pull.mergedAt != nil, pull.state != .merged {
                issues.append("PR \(pull.repository)#\(pull.number) has a merge time but is not merged.")
            }
        }

        let derived = HandoffResolver.resolve(
            handoffs: HandoffMatcher.match(events: snapshot.events, viewerID: snapshot.viewer.id),
            events: snapshot.events
        )
        if Set(derived) != Set(snapshot.handoffs) {
            issues.append("Stored handoffs do not match the timeline-derived handoffs.")
        }

        for range in WindowRange.allCases {
            validate(snapshot.windowMetrics(range: range, asOf: asOf), range: range, issues: &issues)
        }
        let expectedOpenNow = Set(snapshot.pullRequests.lazy.filter {
            $0.authorID == snapshot.viewer.id && $0.eligibleAt != nil
                && $0.state == .open && !$0.isDraft
        }.map(\.id))
        let reducedOpenNow = Set(snapshot.windowMetrics(range: .days30, asOf: asOf).openAtEndIDs)
        if expectedOpenNow != reducedOpenNow {
            issues.append("Lifecycle reducer closing state does not match GitHub's current authored backlog.")
        }
        return ReconciliationReport(issues: issues)
    }

    private static func validate(_ metrics: WindowMetrics, range: WindowRange, issues: inout [String]) {
        let label = range.rawValue
        let expectedEnd = metrics.openAtStart + metrics.new + metrics.reentered
            - metrics.merged - metrics.closed - metrics.drafted
        if expectedEnd != metrics.openNow {
            issues.append("\(label): opening backlog plus entries minus exits does not equal authored open.")
        }
        if metrics.netChange != metrics.openNow - metrics.openAtStart {
            issues.append("\(label): net backlog change does not match its boundaries.")
        }
        if metrics.decisions != metrics.approved + metrics.changesRequested {
            issues.append("\(label): review decisions do not equal approved + changes requested.")
        }
        validateRate(metrics.acceptanceRate, numerator: metrics.approved, denominator: metrics.decisions,
                     name: "acceptance", range: label, issues: &issues)
        validateRate(metrics.reworkRate, numerator: metrics.changesRequested, denominator: metrics.decisions,
                     name: "rework", range: label, issues: &issues)
        if metrics.decisions > 0,
           let acceptance = metrics.acceptanceRate,
           let rework = metrics.reworkRate,
           abs(acceptance + rework - 1) > 0.000_000_1 {
            issues.append("\(label): acceptance + rework does not equal 100%.")
        }
        if (metrics.openNow == 0) != (metrics.medianOpenAge == nil) {
            issues.append("\(label): median open age does not reconcile with authored open.")
        }
        if (metrics.merged == 0) != (metrics.medianTimeToMerge == nil) {
            issues.append("\(label): median merge time does not reconcile with window merges.")
        }
        let transitionIDs = metrics.reenteredTransitions.map(\.id)
            + metrics.closedTransitions.map(\.id)
            + metrics.draftedTransitions.map(\.id)
        appendDuplicateIssue(transitionIDs, label: "window transition", to: &issues)
        appendDuplicateIssue(metrics.approvalEventIDs + metrics.changesRequestedEventIDs,
                             label: "window review event", to: &issues)
    }

    static func requireValid(
        _ snapshot: AppSnapshot,
        asOf: Date = Date(),
        actionConfiguration: ActionNotificationConfiguration? = nil
    ) throws {
        let report = validate(snapshot, asOf: asOf, actionConfiguration: actionConfiguration)
        guard report.isValid else { throw DataIntegrityError(issues: report.issues) }
    }

    private static func validateRate(
        _ actual: Double?,
        numerator: Int,
        denominator: Int,
        name: String,
        range: String,
        issues: inout [String]
    ) {
        let expected = denominator == 0 ? nil : Double(numerator) / Double(denominator)
        switch (actual, expected) {
        case (nil, nil): return
        case let (actual?, expected?) where abs(actual - expected) <= 0.000_000_1: return
        default: issues.append("\(range): \(name) rate does not match its numerator and denominator.")
        }
    }

    private static func appendDuplicateIssue(_ ids: [String], label: String, to issues: inout [String]) {
        let duplicateCount = ids.count - Set(ids).count
        if duplicateCount > 0 { issues.append("Found \(duplicateCount) duplicate \(label) ID(s).") }
    }
}
