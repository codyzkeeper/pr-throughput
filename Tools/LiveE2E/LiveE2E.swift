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
        let assigned = try await api.searchPullRequests(
            query: "is:pr is:open assignee:\(viewer.login) draft:false"
        )
        guard Set(assigned.map(\.id)).count == assigned.count,
              assigned.allSatisfy({ !$0.isDraft && $0.state == "OPEN" }) else {
            throw LiveE2EError.invariant("assigned pull-request discovery")
        }

        let notificationThreads = try await api.notifications(
            since: Date().addingTimeInterval(-30 * 24 * 3_600)
        )
        for thread in notificationThreads where
            thread.unread && thread.reason == "mention" && thread.subject.type == "PullRequest" {
            _ = try await api.mentionContents(thread: thread)
        }

        let coordinator = SyncCoordinator(api: api)
        let first = try await coordinator.refresh(previous: nil)
        try validate(first.snapshot, viewer: viewer)

        let second = try await coordinator.refresh(previous: first.snapshot)
        try validate(second.snapshot, viewer: viewer)
        let asOf = Date()

        if options.canonicalMetrics {
            let canonical = try second.snapshot.canonicalMetrics(asOf: asOf)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(canonical))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }

        let metrics = second.snapshot.metrics(range: .days30, asOf: asOf)
        let cohortIDs = Set(second.snapshot.pullRequests.filter {
            guard $0.authorID == viewer.id, let eligibleAt = $0.eligibleAt else { return false }
            return eligibleAt >= asOf.addingTimeInterval(-CohortRange.days30.duration) && eligibleAt <= asOf
        }.map(\.id))
        let reviewEvents = second.snapshot.events.filter { event in
            guard cohortIDs.contains(event.pullRequestID),
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
            "pendingReviews30d": metrics.pending,
            "rateRemaining": second.snapshot.metadata.rateState.remaining ?? -1
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func validate(
        _ snapshot: AppSnapshot,
        viewer: GitHubUser
    ) throws {
        let asOf = Date()
        try require(snapshot.viewer == viewer, "viewer identity changed")
        try require(Set(snapshot.pullRequests.map(\.id)).count == snapshot.pullRequests.count, "duplicate pull requests")
        try require(Set(snapshot.events.map(\.id)).count == snapshot.events.count, "duplicate timeline events")
        try require(Set(snapshot.handoffs.map(\.id)).count == snapshot.handoffs.count, "duplicate review cycles")
        try require(snapshot.pullRequests.allSatisfy { $0.authorID == viewer.id }, "non-viewer authored PR")
        try require(Set(snapshot.attentionItems.map(\.id)).count == snapshot.attentionItems.count, "duplicate mention threads")
        try require(snapshot.attentionItems.allSatisfy {
            $0.isVerifiedDirectMention && $0.url.scheme == "https" && $0.url.host == "github.com"
        }, "unverified or unsafe direct-mention item")
        try require(snapshot.metadata.baselineEstablished, "baseline not established")
        try require(snapshot.metadata.lastSuccessfulSync != nil, "missing sync timestamp")
        try require(snapshot.metadata.lastError == nil, "sync reported: \(snapshot.metadata.lastError ?? "unknown error")")

        for range in CohortRange.allCases {
            let metrics = snapshot.metrics(range: range, asOf: asOf)
            let activity = snapshot.activity(range: range, asOf: asOf)
            try require(activity.decisions == activity.approved + activity.changesRequested, "activity review partition for \(range.rawValue)")
            try require(activity.awaiting <= activity.handoffs, "activity pending handoffs for \(range.rawValue)")
            try require(metrics.opened == metrics.merged + metrics.open + metrics.closedUnmerged, "shipping partition for \(range.rawValue)")
            try require(metrics.decisions == metrics.approved + metrics.changesRequested, "review partition for \(range.rawValue)")
            if let completion = metrics.mergeCompletionRate {
                try require(metrics.opened > 0, "completion denominator for \(range.rawValue)")
                try require(abs(completion - Double(metrics.merged) / Double(metrics.opened)) < 0.000_001, "completion rate for \(range.rawValue)")
            } else {
                try require(metrics.opened == 0, "missing completion rate for \(range.rawValue)")
            }
            try require((metrics.medianOpenAge == nil) == (metrics.open == 0), "open-age availability for \(range.rawValue)")
            if let acceptance = metrics.acceptanceRate, let rework = metrics.reworkRate {
                try require(abs(acceptance + rework - 1) < 0.000_001, "review rates for \(range.rawValue)")
            } else {
                try require(metrics.decisions == 0, "missing rates with decisions for \(range.rawValue)")
            }
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw LiveE2EError.invariant(message) }
    }

    private struct Options {
        let canonicalMetrics: Bool

        init(arguments: [String]) throws {
            var canonicalMetrics = false
            for argument in arguments {
                switch argument {
                case "--canonical-metrics":
                    canonicalMetrics = true
                default:
                    throw LiveE2EError.invalidArguments("Unknown argument: \(argument)")
                }
            }
            self.canonicalMetrics = canonicalMetrics
        }
    }
}
