import Foundation

enum WindowRange: String, CaseIterable, Codable, Identifiable, Sendable {
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

/// One rolling-window ledger. Events use `[windowStart, asOf]`; opening state
/// is the instant immediately before `windowStart`.
struct WindowMetrics: Codable, Equatable, Sendable {
    let windowStart: Date
    let asOf: Date
    let openAtStartIDs: [String]
    let newIDs: [String]
    let reenteredTransitions: [WindowBacklogTransition]
    let mergedIDs: [String]
    let closedTransitions: [WindowBacklogTransition]
    let draftedTransitions: [WindowBacklogTransition]
    let openAtEndIDs: [String]
    let handoffIDs: [String]
    let approvalEventIDs: [String]
    let changesRequestedEventIDs: [String]
    let awaitingHandoffIDs: [String]
    let medianOpenAge: TimeInterval?
    let medianTimeToMerge: TimeInterval?

    var openAtStart: Int { openAtStartIDs.count }
    var new: Int { newIDs.count }
    var reentered: Int { reenteredTransitions.count }
    var merged: Int { mergedIDs.count }
    var closed: Int { closedTransitions.count }
    var drafted: Int { draftedTransitions.count }
    var openNow: Int { openAtEndIDs.count }
    var netChange: Int { openNow - openAtStart }
    var handoffs: Int { handoffIDs.count }
    var approved: Int { approvalEventIDs.count }
    var changesRequested: Int { changesRequestedEventIDs.count }
    var awaitingNow: Int { awaitingHandoffIDs.count }
    var decisions: Int { approved + changesRequested }
    var acceptanceRate: Double? { Self.ratio(approved, decisions) }
    var reworkRate: Double? { Self.ratio(changesRequested, decisions) }

    init(
        windowStart: Date, asOf: Date,
        openAtStartIDs: [String], newIDs: [String],
        reenteredTransitions: [WindowBacklogTransition], mergedIDs: [String],
        closedTransitions: [WindowBacklogTransition], draftedTransitions: [WindowBacklogTransition],
        openAtEndIDs: [String], handoffIDs: [String], approvalEventIDs: [String],
        changesRequestedEventIDs: [String], awaitingHandoffIDs: [String],
        medianOpenAge: TimeInterval?, medianTimeToMerge: TimeInterval?
    ) {
        self.windowStart = windowStart
        self.asOf = asOf
        self.openAtStartIDs = openAtStartIDs
        self.newIDs = newIDs
        self.reenteredTransitions = reenteredTransitions
        self.mergedIDs = mergedIDs
        self.closedTransitions = closedTransitions
        self.draftedTransitions = draftedTransitions
        self.openAtEndIDs = openAtEndIDs
        self.handoffIDs = handoffIDs
        self.approvalEventIDs = approvalEventIDs
        self.changesRequestedEventIDs = changesRequestedEventIDs
        self.awaitingHandoffIDs = awaitingHandoffIDs
        self.medianOpenAge = medianOpenAge
        self.medianTimeToMerge = medianTimeToMerge
    }

    private enum CodingKeys: String, CodingKey {
        case windowStart, asOf, openAtStartIDs, newIDs, reenteredTransitions, mergedIDs
        case closedTransitions, draftedTransitions, openAtEndIDs, handoffIDs
        case approvalEventIDs, changesRequestedEventIDs, awaitingHandoffIDs
        case medianOpenAge, medianTimeToMerge
        case openAtStart, new, reentered, merged, closed, drafted, openNow, netChange
        case handoffs, approved, changesRequested, awaitingNow, decisions, acceptanceRate, reworkRate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windowStart = try values.decode(Date.self, forKey: .windowStart)
        asOf = try values.decode(Date.self, forKey: .asOf)
        openAtStartIDs = try values.decode([String].self, forKey: .openAtStartIDs)
        newIDs = try values.decode([String].self, forKey: .newIDs)
        reenteredTransitions = try values.decode([WindowBacklogTransition].self, forKey: .reenteredTransitions)
        mergedIDs = try values.decode([String].self, forKey: .mergedIDs)
        closedTransitions = try values.decode([WindowBacklogTransition].self, forKey: .closedTransitions)
        draftedTransitions = try values.decode([WindowBacklogTransition].self, forKey: .draftedTransitions)
        openAtEndIDs = try values.decode([String].self, forKey: .openAtEndIDs)
        handoffIDs = try values.decode([String].self, forKey: .handoffIDs)
        approvalEventIDs = try values.decode([String].self, forKey: .approvalEventIDs)
        changesRequestedEventIDs = try values.decode([String].self, forKey: .changesRequestedEventIDs)
        awaitingHandoffIDs = try values.decode([String].self, forKey: .awaitingHandoffIDs)
        medianOpenAge = try values.decodeIfPresent(TimeInterval.self, forKey: .medianOpenAge)
        medianTimeToMerge = try values.decodeIfPresent(TimeInterval.self, forKey: .medianTimeToMerge)

        guard windowStart <= asOf else {
            throw DecodingError.dataCorruptedError(
                forKey: .windowStart, in: values,
                debugDescription: "Window start must not be later than its closing boundary."
            )
        }

        let encoded = [
            CodingKeys.openAtStart: openAtStart, .new: new, .reentered: reentered,
            .merged: merged, .closed: closed, .drafted: drafted, .openNow: openNow,
            .netChange: netChange, .handoffs: handoffs, .approved: approved,
            .changesRequested: changesRequested, .awaitingNow: awaitingNow, .decisions: decisions
        ]
        for (key, expected) in encoded {
            let actual = try values.decode(Int.self, forKey: key)
            if actual != expected {
                throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Derived metric does not match its source IDs.")
            }
        }
        try Self.validateEncodedRate(
            try values.decodeIfPresent(Double.self, forKey: .acceptanceRate),
            expected: acceptanceRate, key: .acceptanceRate, in: values
        )
        try Self.validateEncodedRate(
            try values.decodeIfPresent(Double.self, forKey: .reworkRate),
            expected: reworkRate, key: .reworkRate, in: values
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(windowStart, forKey: .windowStart)
        try values.encode(asOf, forKey: .asOf)
        try values.encode(openAtStartIDs, forKey: .openAtStartIDs)
        try values.encode(newIDs, forKey: .newIDs)
        try values.encode(reenteredTransitions, forKey: .reenteredTransitions)
        try values.encode(mergedIDs, forKey: .mergedIDs)
        try values.encode(closedTransitions, forKey: .closedTransitions)
        try values.encode(draftedTransitions, forKey: .draftedTransitions)
        try values.encode(openAtEndIDs, forKey: .openAtEndIDs)
        try values.encode(handoffIDs, forKey: .handoffIDs)
        try values.encode(approvalEventIDs, forKey: .approvalEventIDs)
        try values.encode(changesRequestedEventIDs, forKey: .changesRequestedEventIDs)
        try values.encode(awaitingHandoffIDs, forKey: .awaitingHandoffIDs)
        try values.encodeIfPresent(medianOpenAge, forKey: .medianOpenAge)
        try values.encodeIfPresent(medianTimeToMerge, forKey: .medianTimeToMerge)
        try values.encode(openAtStart, forKey: .openAtStart)
        try values.encode(new, forKey: .new)
        try values.encode(reentered, forKey: .reentered)
        try values.encode(merged, forKey: .merged)
        try values.encode(closed, forKey: .closed)
        try values.encode(drafted, forKey: .drafted)
        try values.encode(openNow, forKey: .openNow)
        try values.encode(netChange, forKey: .netChange)
        try values.encode(handoffs, forKey: .handoffs)
        try values.encode(approved, forKey: .approved)
        try values.encode(changesRequested, forKey: .changesRequested)
        try values.encode(awaitingNow, forKey: .awaitingNow)
        try values.encode(decisions, forKey: .decisions)
        try values.encodeIfPresent(acceptanceRate, forKey: .acceptanceRate)
        try values.encodeIfPresent(reworkRate, forKey: .reworkRate)
    }

    static func empty(range: WindowRange, asOf: Date) -> WindowMetrics {
        WindowMetrics(
            windowStart: asOf.addingTimeInterval(-range.duration), asOf: asOf,
            openAtStartIDs: [], newIDs: [], reenteredTransitions: [], mergedIDs: [],
            closedTransitions: [], draftedTransitions: [], openAtEndIDs: [],
            handoffIDs: [], approvalEventIDs: [], changesRequestedEventIDs: [],
            awaitingHandoffIDs: [], medianOpenAge: nil, medianTimeToMerge: nil
        )
    }

    static func calculate(
        pullRequests: [PullRequestSnapshot],
        events: [TimelineEvent],
        handoffs: [Handoff],
        viewerID: String,
        range: WindowRange,
        asOf: Date
    ) -> WindowMetrics {
        let start = asOf.addingTimeInterval(-range.duration)
        let authored = pullRequests.filter { $0.authorID == viewerID && $0.eligibleAt != nil }
        let authoredIDs = Set(authored.map(\.id))
        let eventsByPull = Dictionary(
            grouping: events.filter { authoredIDs.contains($0.pullRequestID) },
            by: \.pullRequestID
        )
        var openAtStart = Set<String>()
        var new = Set<String>()
        var reentered: [WindowBacklogTransition] = []
        var merged = Set<String>()
        var closed: [WindowBacklogTransition] = []
        var drafted: [WindowBacklogTransition] = []
        var openAtEnd = Set<String>()

        for pull in authored {
            guard let eligibleAt = pull.eligibleAt else { continue }
            let transitions = lifecycleTransitions(
                pull: pull,
                events: eventsByPull[pull.id] ?? [],
                eligibleAt: eligibleAt,
                asOf: asOf
            )
            var state = LifecycleState()
            for transition in transitions where transition.at < start { state.apply(transition.kind) }
            if state.isActive { openAtStart.insert(pull.id) }

            for transition in transitions where transition.at >= start && transition.at <= asOf {
                let wasActive = state.isActive
                let hadEverEntered = state.hasEverEntered
                state.apply(transition.kind)
                if !wasActive && state.isActive {
                    if transition.kind == .firstReady && !hadEverEntered {
                        new.insert(pull.id)
                    } else {
                        reentered.append(.init(id: transition.id, pullRequestID: pull.id, at: transition.at))
                    }
                } else if wasActive && !state.isActive {
                    switch transition.kind {
                    case .merged: merged.insert(pull.id)
                    case .closed: closed.append(.init(id: transition.id, pullRequestID: pull.id, at: transition.at))
                    case .drafted: drafted.append(.init(id: transition.id, pullRequestID: pull.id, at: transition.at))
                    default: break
                    }
                }
            }
            if state.isActive { openAtEnd.insert(pull.id) }
        }

        let reviewEvents = events.filter { event in
            guard authoredIDs.contains(event.pullRequestID),
                  event.at >= start, event.at <= asOf,
                  case let .reviewed(reviewer, decision) = event.kind,
                  reviewer.kind == .user, reviewer.id != viewerID else { return false }
            return decision == .approved || decision == .changesRequested
        }
        let approvals = reviewEvents.filter {
            if case .reviewed(_, .approved) = $0.kind { return true }
            return false
        }.map(\.id).sorted()
        let changes = reviewEvents.filter {
            if case .reviewed(_, .changesRequested) = $0.kind { return true }
            return false
        }.map(\.id).sorted()
        let handoffIDs = handoffs.filter { handoff in
            guard authoredIDs.contains(handoff.pullRequestID),
                  handoff.at >= start, handoff.at <= asOf else { return false }
            if case let .withdrawn(at, _) = handoff.outcome, at <= asOf { return false }
            return true
        }.map(\.id).sorted()
        let awaiting = handoffs.filter { handoff in
            guard authoredIDs.contains(handoff.pullRequestID), handoff.at <= asOf else { return false }
            switch handoff.outcome {
            case .pending: return true
            case let .approved(at, _), let .changesRequested(at, _), let .withdrawn(at, _):
                return at > asOf
            }
        }.map(\.id).sorted()
        let openAges = authored.filter { openAtEnd.contains($0.id) }.compactMap {
            $0.eligibleAt.map { max(0, asOf.timeIntervalSince($0)) }
        }.sorted()
        let mergeDurations = authored.compactMap { pull -> TimeInterval? in
            guard merged.contains(pull.id), let eligibleAt = pull.eligibleAt,
                  let mergedAt = pull.mergedAt else { return nil }
            return max(0, mergedAt.timeIntervalSince(eligibleAt))
        }.sorted()

        return WindowMetrics(
            windowStart: start, asOf: asOf,
            openAtStartIDs: openAtStart.sorted(), newIDs: new.sorted(),
            reenteredTransitions: reentered.sorted { $0.id < $1.id }, mergedIDs: merged.sorted(),
            closedTransitions: closed.sorted { $0.id < $1.id },
            draftedTransitions: drafted.sorted { $0.id < $1.id },
            openAtEndIDs: openAtEnd.sorted(), handoffIDs: handoffIDs,
            approvalEventIDs: approvals, changesRequestedEventIDs: changes,
            awaitingHandoffIDs: awaiting, medianOpenAge: median(openAges),
            medianTimeToMerge: median(mergeDurations)
        )
    }

    private enum LifecycleKind: Int, Equatable {
        // Merge precedes its companion close event at an identical timestamp.
        case merged = 0, drafted = 1, closed = 2, firstReady = 3, ready = 4, reopened = 5
    }

    private struct LifecycleTransition {
        let id: String
        let at: Date
        let kind: LifecycleKind
    }

    private struct LifecycleState {
        var isOpen = true
        var isReady = false
        var isMerged = false
        var hasEverEntered = false
        var isActive: Bool { isOpen && isReady && !isMerged }

        mutating func apply(_ kind: LifecycleKind) {
            switch kind {
            case .firstReady, .ready: isReady = true
            case .drafted: isReady = false
            case .closed: isOpen = false
            case .reopened: isOpen = true
            case .merged: isMerged = true; isOpen = false
            }
            if isActive { hasEverEntered = true }
        }
    }

    private static func lifecycleTransitions(
        pull: PullRequestSnapshot,
        events: [TimelineEvent],
        eligibleAt: Date,
        asOf: Date
    ) -> [LifecycleTransition] {
        var result = [LifecycleTransition(id: "eligible:\(pull.id)", at: eligibleAt, kind: .firstReady)]
        for event in events where event.at <= asOf {
            let kind: LifecycleKind?
            switch event.kind {
            case .readyForReview: kind = .ready
            case .convertedToDraft: kind = .drafted
            case .reopened: kind = .reopened
            case .merged: kind = .merged
            case .closed: kind = .closed
            default: kind = nil
            }
            if let kind { result.append(LifecycleTransition(id: event.id, at: event.at, kind: kind)) }
        }
        if let mergedAt = pull.mergedAt, mergedAt <= asOf {
            if !result.contains(where: { $0.kind == .merged && $0.at == mergedAt }) {
                result.append(LifecycleTransition(id: "merged:\(pull.id)", at: mergedAt, kind: .merged))
            }
        } else if let closedAt = pull.closedAt, closedAt <= asOf {
            if !result.contains(where: { $0.kind == .closed && $0.at == closedAt }) {
                result.append(LifecycleTransition(
                    id: "closed:\(pull.id):\(closedAt.timeIntervalSinceReferenceDate)",
                    at: closedAt,
                    kind: .closed
                ))
            }
        }
        return result.sorted {
            if $0.at != $1.at { return $0.at < $1.at }
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.id < $1.id
        }
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double? {
        denominator == 0 ? nil : Double(numerator) / Double(denominator)
    }

    private static func validateEncodedRate(
        _ actual: Double?,
        expected: Double?,
        key: CodingKeys,
        in values: KeyedDecodingContainer<CodingKeys>
    ) throws {
        let isValid: Bool
        switch (actual, expected) {
        case (nil, nil): isValid = true
        case let (actual?, expected?): isValid = abs(actual - expected) <= 0.000_000_1
        default: isValid = false
        }
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: values,
                debugDescription: "Derived rate does not match its source event IDs."
            )
        }
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return values.count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2
            : values[middle]
    }
}

struct WindowBacklogTransition: Codable, Equatable, Hashable, Sendable {
    let id: String
    let pullRequestID: String
    let at: Date
}
