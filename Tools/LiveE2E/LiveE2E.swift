import Darwin
import Foundation

enum LiveE2EError: LocalizedError {
    case missingToken
    case invalidArguments(String)
    case invariant(String)

    var errorDescription: String? {
        switch self {
        case .missingToken: "A GitHub token must be provided on standard input."
        case let .invalidArguments(message): message
        case let .invariant(message): "Invariant failed: \(message)"
        }
    }
}

@main
struct LiveE2E {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("PRThroughputLiveE2E: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let value = String(data: input, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { throw LiveE2EError.missingToken }

        let api = GitHubAPI(token: value)
        let viewer = try await api.viewer()
        let actionConfiguration = try actionConfigurationFromEnvironment()
        if options.actionOnly {
            let candidateIDs = Set((ProcessInfo.processInfo.environment["PR_THROUGHPUT_ACTION_CANDIDATE_IDS"] ?? "")
                .split(separator: ",").map(String.init))
            let discovery = try await api.actionPullRequests(
                configuration: actionConfiguration,
                candidateIDs: candidateIDs
            )
            try validateActionRows(discovery.pullRequests, configuration: actionConfiguration)
            let summary: [String: Any] = [
                "account": viewer.login,
                "actionPullRequests": discovery.pullRequests.count,
                "actionLabelFacts": discovery.pullRequests.flatMap(\.applications).count,
                "actionSearchDisagreements": discovery.searchDisagreementCount,
                "rateRemaining": await api.rateState.remaining ?? -1
            ]
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        let assigned = try await api.searchPullRequests(
            query: "is:pr is:open assignee:\(viewer.login) draft:false"
        )
        guard Set(assigned.map(\.id)).count == assigned.count,
              assigned.allSatisfy({ !$0.isDraft && $0.state == "OPEN" }) else {
            throw LiveE2EError.invariant("assigned pull-request discovery")
        }

        let coordinator = SyncCoordinator(api: api)
        let first = try await coordinator.refresh(previous: nil, configuration: actionConfiguration)
        try validate(first.snapshot, viewer: viewer, configuration: actionConfiguration)

        let second = try await coordinator.refresh(previous: first.snapshot, configuration: actionConfiguration)
        try validate(second.snapshot, viewer: viewer, configuration: actionConfiguration)
        guard let asOf = second.snapshot.metadata.lastSuccessfulSync else {
            throw LiveE2EError.invariant("missing verified full-sync boundary")
        }

        if options.canonicalMetrics {
            let canonical = try second.snapshot.canonicalMetrics(asOf: asOf)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(canonical))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }

        let metrics = second.snapshot.windowMetrics(range: .days30, asOf: asOf)
        let authoredIDs = Set(second.snapshot.pullRequests.filter { $0.authorID == viewer.id }.map(\.id))
        let reviewEvents = second.snapshot.events.filter { event in
            guard authoredIDs.contains(event.pullRequestID),
                  event.at >= asOf.addingTimeInterval(-WindowRange.days30.duration), event.at <= asOf,
                  case let .reviewed(reviewer, state) = event.kind,
                  reviewer.id != viewer.id else { return false }
            return state == .approved || state == .changesRequested
        }
        let allOutcomes = Dictionary(grouping: second.snapshot.handoffs, by: { handoff in
            switch handoff.outcome {
            case .approved: "approved"
            case .changesRequested: "changesRequested"
            case .pending: "pending"
            case .withdrawn: "withdrawn"
            }
        }).mapValues(\.count)
        let summary: [String: Any] = [
            "account": viewer.login,
            "assigned": second.snapshot.assignedCount,
            "pullRequests": second.snapshot.pullRequests.count,
            "timelineEvents": second.snapshot.events.count,
            "reviewCycles": second.snapshot.handoffs.count,
            "reviewCycleOutcomes": allOutcomes,
            "reviewDecisionEvents30d": reviewEvents.count,
            "completedReviews30d": metrics.decisions,
            "awaitingReviewsNow": metrics.awaitingNow,
            "actionPullRequests": second.snapshot.attentionItems.count,
            "actionLabelFacts": second.snapshot.attentionItems.flatMap(\.applications).count,
            "actionSearchDisagreements": second.snapshot.metadata.actionSearchDisagreementCount ?? -1,
            "rateRemaining": second.snapshot.metadata.rateState.remaining ?? -1
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func validateActionRows(
        _ rows: [GitHubActionPullRequest],
        configuration: ActionNotificationConfiguration
    ) throws {
        try require(configuration.isConfigured, "action-only mode requires action-label configuration")
        try require(Set(rows.map(\.id)).count == rows.count, "duplicate action rows")
        try require(rows.allSatisfy {
            !$0.applications.isEmpty && $0.url.scheme == "https" && $0.url.host == "github.com"
        }, "invalid or unsafe action row")
        let applications = rows.flatMap(\.applications)
        try require(Set(applications.map(\.labelEventID)).count == applications.count, "duplicate label application IDs")
        try require(applications.allSatisfy { $0.normalizedColorHex != nil }, "invalid action label color")
    }

    private static func validate(
        _ snapshot: AppSnapshot,
        viewer: GitHubUser,
        configuration: ActionNotificationConfiguration
    ) throws {
        let asOf = Date()
        try require(snapshot.viewer == viewer, "viewer identity changed")
        try require(Set(snapshot.pullRequests.map(\.id)).count == snapshot.pullRequests.count, "duplicate pull requests")
        try require(Set(snapshot.events.map(\.id)).count == snapshot.events.count, "duplicate timeline events")
        try require(Set(snapshot.handoffs.map(\.id)).count == snapshot.handoffs.count, "duplicate review cycles")
        try require(snapshot.pullRequests.allSatisfy { $0.authorID == viewer.id }, "non-viewer authored PR")
        try require(Set(snapshot.attentionItems.map(\.id)).count == snapshot.attentionItems.count, "duplicate action rows")
        try require(snapshot.attentionItems.allSatisfy {
            $0.kind == .actionLabels && !$0.applications.isEmpty
                && $0.url.scheme == "https" && $0.url.host == "github.com"
        }, "invalid or unsafe action row")
        let applications = snapshot.attentionItems.flatMap(\.applications)
        try require(Set(applications.map(\.labelEventID)).count == applications.count, "duplicate label application IDs")
        try require(applications.allSatisfy { $0.normalizedColorHex != nil }, "invalid action label color")
        try require(snapshot.metadata.actionConfigurationRevision == configuration.revision, "action configuration revision")
        try require(snapshot.metadata.lastSuccessfulActionLabelSync != nil, "missing action-label sync timestamp")
        try require(snapshot.metadata.lastActionLabelError == nil, "action sync reported: \(snapshot.metadata.lastActionLabelError ?? "unknown error")")
        try require(snapshot.metadata.baselineEstablished, "baseline not established")
        try require(snapshot.metadata.lastSuccessfulSync != nil, "missing sync timestamp")
        try require(snapshot.metadata.lastError == nil, "sync reported: \(snapshot.metadata.lastError ?? "unknown error")")

        for range in WindowRange.allCases {
            let metrics = snapshot.windowMetrics(range: range, asOf: asOf)
            try require(metrics.openAtStart + metrics.new + metrics.reentered - metrics.merged
                        - metrics.closed - metrics.drafted == metrics.openNow,
                        "backlog ledger for \(range.rawValue)")
            try require(metrics.decisions == metrics.approved + metrics.changesRequested, "review partition for \(range.rawValue)")
            try require((metrics.medianOpenAge == nil) == (metrics.openNow == 0), "open-age availability for \(range.rawValue)")
            if let acceptance = metrics.acceptanceRate, let rework = metrics.reworkRate {
                try require(abs(acceptance + rework - 1) < 0.000_001, "review rates for \(range.rawValue)")
            } else {
                try require(metrics.decisions == 0, "missing rates with decisions for \(range.rawValue)")
            }
        }
    }

    private static func actionConfigurationFromEnvironment() throws -> ActionNotificationConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let organization = environment["PR_THROUGHPUT_ACTION_ORGANIZATION"] ?? ""
        let names = [
            environment["PR_THROUGHPUT_ACTION_LABEL_1"] ?? "",
            environment["PR_THROUGHPUT_ACTION_LABEL_2"] ?? "",
            environment["PR_THROUGHPUT_ACTION_LABEL_3"] ?? ""
        ]
        guard !organization.isEmpty else { return .blank }
        let rules = zip(ActionRuleID.allCases, names).map { id, name in
            ActionRuleConfiguration(id: id, labelName: name, isEnabled: !name.isEmpty)
        }
        return try ActionNotificationConfiguration(
            schemaVersion: 1, organization: organization, rules: rules
        ).validated()
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw LiveE2EError.invariant(message) }
    }

    private struct Options {
        let canonicalMetrics: Bool
        let actionOnly: Bool

        init(arguments: [String]) throws {
            var canonicalMetrics = false
            var actionOnly = false
            for argument in arguments {
                switch argument {
                case "--canonical-metrics":
                    canonicalMetrics = true
                case "--action-only":
                    actionOnly = true
                default:
                    throw LiveE2EError.invalidArguments("Unknown argument: \(argument)")
                }
            }
            guard !(canonicalMetrics && actionOnly) else {
                throw LiveE2EError.invalidArguments("Choose either --canonical-metrics or --action-only.")
            }
            self.canonicalMetrics = canonicalMetrics
            self.actionOnly = actionOnly
        }
    }
}
