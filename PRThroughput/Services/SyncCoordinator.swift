import Foundation

struct SyncResult: Sendable {
    let snapshot: AppSnapshot
    let transientEvents: [TransientEvent]
}

actor SyncCoordinator {
    private let api: GitHubAPI
    private var priorityTimelineWatchUntil: [String: Date] = [:]
    private var assignedRefreshCount = 0

    init(api: GitHubAPI) {
        self.api = api
    }

    func refresh(
        previous: AppSnapshot?,
        configuration: ActionNotificationConfiguration = .load()
    ) async throws -> SyncResult {
        let now = Date()
        let viewer = try await api.viewer()
        let since = now.addingTimeInterval(-30 * 24 * 3_600)
        let authoredNodes = try await discoverAuthored(login: viewer.login, from: since, through: now)
        let assignedNodes = try await api.searchPullRequests(query: "is:pr is:open assignee:\(viewer.login) draft:false")

        let previousEventsByPull = Dictionary(grouping: previous?.events ?? [], by: \.pullRequestID)
        let previousPulls = Dictionary(
            (previous?.pullRequests ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { old, new in old.updatedAt >= new.updatedAt ? old : new }
        )
        var allEvents: [TimelineEvent] = []
        var pulls: [PullRequestSnapshot] = []
        for node in authoredNodes {
            let events: [TimelineEvent]
            if Self.canReuseTimeline(
                schemaVersion: previous?.metadata.timelineSchemaVersion,
                cachedUpdatedAt: previousPulls[node.id]?.updatedAt,
                currentUpdatedAt: node.updatedAt
            ),
               let cached = previousEventsByPull[node.id] {
                events = cached
            } else {
                events = try await api.timeline(pullRequestID: node.id)
            }
            allEvents.append(contentsOf: events)
            pulls.append(snapshot(from: node, events: events))
        }

        let rawHandoffs = HandoffMatcher.match(events: allEvents, viewerID: viewer.id)
        let resolvedHandoffs = HandoffResolver.resolve(handoffs: rawHandoffs, events: allEvents)
        let newEvents = Self.timelineNotificationDelta(events: allEvents, previous: previous)

        var transient: [TransientEvent] = []
        if previous?.metadata.baselineEstablished == true {
            let generated = timelineNotifications(events: newEvents, pulls: pulls, viewerID: viewer.id)
            transient.append(contentsOf: generated.transient)
        }

        let metadata = SyncMetadata(
            lastSuccessfulSync: now,
            lastNotificationSync: nil,
            lastError: nil,
            rateState: await api.rateState,
            baselineEstablished: true,
            timelineSchemaVersion: TimelineEvent.sourceSchemaVersion,
            attentionVisibilityVersion: previous?.metadata.attentionVisibilityVersion ?? 6,
            actionAuthorityVersion: 1,
            actionConfigurationRevision: previous?.metadata.actionConfigurationRevision,
            lastSuccessfulActionLabelSync: previous?.metadata.lastSuccessfulActionLabelSync,
            lastActionLabelError: previous?.metadata.lastActionLabelError,
            actionSearchDisagreementCount: previous?.metadata.actionSearchDisagreementCount
        )
        var snapshot = AppSnapshot(
            viewer: viewer,
            pullRequests: pulls,
            events: Dictionary(allEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.at < $1.at },
            handoffs: resolvedHandoffs,
            assignedPullRequestIDs: Set(assignedNodes.filter { !$0.isDraft }.map(\.id)),
            attentionItems: [],
            metadata: metadata
        )
        do {
            try await applyActionAuthority(to: &snapshot, previous: previous, configuration: configuration, now: now)
        } catch GitHubAPIError.unauthorized {
            throw GitHubAPIError.unauthorized
        } catch {
            preserveActionAuthority(on: &snapshot, previous: previous, configuration: configuration, error: error)
        }
        try SnapshotReconciler.requireValid(snapshot, asOf: now, actionConfiguration: configuration)
        return SyncResult(snapshot: snapshot, transientEvents: transient)
    }

    func refreshAssigned(
        previous: AppSnapshot,
        now: Date = Date(),
        configuration: ActionNotificationConfiguration = .load()
    ) async throws -> SyncResult {
        let nodes = try await api.searchPullRequests(query: "is:pr is:open assignee:\(previous.viewer.login) draft:false")
        let assignedIDs = Set(nodes.filter { !$0.isDraft }.map(\.id))
        let authoredIDs = Set(previous.pullRequests.lazy.filter { $0.authorID == previous.viewer.id }.map(\.id))
        let removedAuthoredIDs = previous.assignedPullRequestIDs.subtracting(assignedIDs).intersection(authoredIDs)

        // GitHub can publish the assignment and review-request timeline events shortly
        // after its search index reflects the assignee change. Keep recently removed PRs
        // on a short watch so the complete handoff triple is not missed.
        let watchDuration = HandoffMatcher.matchingWindow + 60
        for id in removedAuthoredIDs {
            priorityTimelineWatchUntil[id] = now.addingTimeInterval(watchDuration)
        }
        priorityTimelineWatchUntil = priorityTimelineWatchUntil.filter { $0.value >= now }

        assignedRefreshCount += 1
        let pendingIDs = Set(previous.handoffs.lazy.filter { $0.outcome == .pending }.map(\.pullRequestID))
        var timelineIDs = Set(priorityTimelineWatchUntil.keys)
        // Pending decisions do not need the 15-second assignment cadence; 30 seconds
        // remains responsive while keeping GraphQL traffic bounded.
        if assignedRefreshCount.isMultiple(of: 2) {
            timelineIDs.formUnion(pendingIDs)
        }

        var recentUpdates: [RecentPullRequestUpdate] = []
        var timelineError: Error?
        for id in timelineIDs.sorted() {
            do {
                recentUpdates.append(try await api.recentTimeline(pullRequestID: id))
            } catch GitHubAPIError.unauthorized {
                throw GitHubAPIError.unauthorized
            } catch {
                // Assignment state is independently useful and already fresh. Preserve
                // it, surface the degraded timeline sync, and retry the watched PR on
                // the next tick rather than withholding the menu-bar update.
                timelineError = error
                break
            }
        }

        let refreshedEvents = recentUpdates.flatMap(\.events)
        var allEvents = previous.events + refreshedEvents
        allEvents = Dictionary(allEvents.map { ($0.id, $0) }, uniquingKeysWith: { _, refreshed in refreshed })
            .values.sorted { $0.at < $1.at }

        let handoffs = HandoffResolver.resolve(
            handoffs: HandoffMatcher.match(events: allEvents, viewerID: previous.viewer.id),
            events: allEvents
        )
        let stillPendingIDs = Set(handoffs.lazy.filter { $0.outcome == .pending }.map(\.pullRequestID))
        let terminalIDs = Set(recentUpdates.lazy.filter { $0.mergedAt != nil || $0.state == "CLOSED" }.map(\.id))
        // A merge commonly follows an approval within minutes. Continue the cheap,
        // targeted timeline watch after a pending review becomes decided so the
        // merged KPI and quiet merge signal do not wait for the five-minute crawl.
        for id in pendingIDs.subtracting(stillPendingIDs).subtracting(terminalIDs) {
            priorityTimelineWatchUntil[id] = max(
                priorityTimelineWatchUntil[id] ?? .distantPast,
                now.addingTimeInterval(10 * 60)
            )
        }
        for id in terminalIDs {
            priorityTimelineWatchUntil.removeValue(forKey: id)
        }
        let newEvents = Self.timelineNotificationDelta(events: allEvents, previous: previous)
        var transient: [TransientEvent] = []
        if previous.metadata.baselineEstablished {
            let generated = timelineNotifications(
                events: newEvents,
                pulls: previous.pullRequests,
                viewerID: previous.viewer.id
            )
            transient = generated.transient
        }

        var updated = previous
        let recentByID = Dictionary(uniqueKeysWithValues: recentUpdates.map { ($0.id, $0) })
        updated.pullRequests = previous.pullRequests.map { pull in
            guard let recent = recentByID[pull.id] else { return pull }
            let state: PullRequestState = recent.mergedAt != nil
                ? .merged
                : (recent.state == "CLOSED" ? .closed : .open)
            let eligibleAt = pull.eligibleAt ?? allEvents.compactMap { event -> Date? in
                guard event.pullRequestID == pull.id, case .readyForReview = event.kind else { return nil }
                return event.at
            }.min()
            return PullRequestSnapshot(
                id: pull.id,
                repository: pull.repository,
                number: pull.number,
                title: pull.title,
                url: pull.url,
                authorID: pull.authorID,
                eligibleAt: eligibleAt,
                updatedAt: recent.updatedAt,
                isDraft: recent.isDraft,
                state: state,
                mergedAt: recent.mergedAt,
                closedAt: recent.closedAt
            )
        }
        updated.assignedPullRequestIDs = assignedIDs
        updated.events = allEvents
        updated.handoffs = handoffs
        updated.metadata.lastError = timelineError?.localizedDescription
        updated.metadata.rateState = await api.rateState
        do {
            try await applyActionAuthority(to: &updated, previous: previous, configuration: configuration, now: now)
        } catch GitHubAPIError.unauthorized {
            throw GitHubAPIError.unauthorized
        } catch {
            preserveActionAuthority(on: &updated, previous: previous, configuration: configuration, error: error)
        }
        try SnapshotReconciler.requireValid(updated, asOf: now, actionConfiguration: configuration)
        return SyncResult(snapshot: updated, transientEvents: transient)
    }

    func pollNotifications(previous: AppSnapshot) async throws -> (AppSnapshot, [AttentionItem]) {
        let now = Date()
        let threads = try await api.notifications(since: previous.metadata.lastNotificationSync)
        var updated = previous
        let previousRevisions = Dictionary(
            uniqueKeysWithValues: updated.attentionItems.compactMap { item in
                item.revisionID.map { (item.id, $0) }
            }
        )
        var verificationError: Error?
        for thread in threads {
            let threadID = "thread:\(thread.id)"
            do {
                guard let item = try await attentionItem(from: thread, viewer: previous.viewer) else {
                    updated.attentionItems.removeAll { $0.id == threadID && $0.isActive }
                    continue
                }
                updated.attentionItems.append(item)
            } catch GitHubAPIError.unauthorized {
                throw GitHubAPIError.unauthorized
            } catch {
                verificationError = verificationError ?? error
            }
        }
        updated.attentionItems = Self.normalizeAttention(updated.attentionItems, now: now)
        let newItems = updated.attentionItems.filter {
            $0.isUnseen && previousRevisions[$0.id] != $0.revisionID
        }
        if verificationError == nil { updated.metadata.lastNotificationSync = now }
        updated.metadata.lastError = verificationError?.localizedDescription
        updated.metadata.rateState = await api.rateState
        return (updated, newItems)
    }

    func recommendedNotificationPollInterval() async -> TimeInterval {
        await api.notificationPollInterval
    }

    static func timelineNotificationDelta(events: [TimelineEvent], previous: AppSnapshot?) -> [TimelineEvent] {
        guard let previous, previous.metadata.baselineEstablished else { return [] }
        let knownIDs = Set(previous.events.map(\.id))
        let floor = previous.metadata.lastSuccessfulSync?.addingTimeInterval(-300) ?? .distantPast
        return events.filter { !knownIDs.contains($0.id) && $0.at >= floor }
    }

    static func eligibleAt(createdAt: Date, currentIsDraft: Bool, events: [TimelineEvent]) -> Date? {
        let firstReady = events.compactMap { event -> Date? in
            if case .readyForReview = event.kind { return event.at }
            return nil
        }.min()
        let firstDraft = events.compactMap { event -> Date? in
            if case .convertedToDraft = event.kind { return event.at }
            return nil
        }.min()

        switch (firstReady, firstDraft) {
        case (nil, nil): return currentIsDraft ? nil : createdAt
        case let (ready?, nil): return ready
        case (nil, _?): return createdAt
        case let (ready?, draft?):
            if ready < draft { return ready }
            if draft < ready { return createdAt }
            return currentIsDraft ? ready : createdAt
        }
    }

    static func canReuseTimeline(
        schemaVersion: Int?,
        cachedUpdatedAt: Date?,
        currentUpdatedAt: Date
    ) -> Bool {
        schemaVersion == TimelineEvent.sourceSchemaVersion && cachedUpdatedAt == currentUpdatedAt
    }

    static func normalizeAttention(_ items: [AttentionItem], now: Date) -> [AttentionItem] {
        let cutoff = now.addingTimeInterval(-30 * 24 * 3_600)
        let eligible = items.filter { $0.isVerifiedDirectMention && $0.createdAt >= cutoff }
        let grouped = Dictionary(grouping: eligible, by: \.id)
        return grouped.values.compactMap { group -> AttentionItem? in
            guard var newest = group.max(by: { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return (lhs.revisionID ?? "") < (rhs.revisionID ?? "")
            }) else { return nil }
            let stateSource = group.sorted { lhs, rhs in
                let lhsHasState = lhs.seenRevisionID != nil || lhs.acknowledgedRevisionID != nil
                let rhsHasState = rhs.seenRevisionID != nil || rhs.acknowledgedRevisionID != nil
                if lhsHasState != rhsHasState { return lhsHasState && !rhsHasState }
                return lhs.createdAt > rhs.createdAt
            }.first
            if newest.seenRevisionID == nil { newest.seenRevisionID = stateSource?.seenRevisionID }
            if newest.acknowledgedRevisionID == nil { newest.acknowledgedRevisionID = stateSource?.acknowledgedRevisionID }
            return newest
        }.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }

    private func applyActionAuthority(
        to snapshot: inout AppSnapshot,
        previous: AppSnapshot?,
        configuration: ActionNotificationConfiguration,
        now: Date
    ) async throws {
        let revision = configuration.revision
        snapshot.metadata.actionAuthorityVersion = 1
        snapshot.metadata.actionConfigurationRevision = revision
        snapshot.metadata.lastNotificationSync = nil

        guard configuration.isConfigured else {
            snapshot.attentionItems = []
            snapshot.metadata.lastSuccessfulActionLabelSync = now
            snapshot.metadata.lastActionLabelError = nil
            snapshot.metadata.actionSearchDisagreementCount = 0
            return
        }

        let priorItems = previous?.metadata.actionConfigurationRevision == revision
            ? previous?.attentionItems.filter { $0.kind == .actionLabels } ?? []
            : []
        // Search is the complete organization-wide discovery lane, but GitHub's
        // search index can lag behind a label mutation. Directly recheck a bounded
        // hot set so recently active automation PRs update on the 15-second lane
        // without crawling every open PR in the organization.
        let candidateIDs = Self.actionCandidateIDs(snapshot: snapshot, priorItems: priorItems)
        let discovery = try await api.actionPullRequests(
            configuration: configuration,
            candidateIDs: candidateIDs
        )
        let priorByPull = Dictionary(
            uniqueKeysWithValues: priorItems.compactMap { item in item.pullRequestID.map { ($0, item) } }
        )
        snapshot.attentionItems = discovery.pullRequests.map { pull in
            let old = priorByPull[pull.id]
            let applications = ActionAttentionMerger.mergePresentation(
                incoming: pull.applications,
                previous: old?.applications ?? []
            )
            return AttentionItem.action(
                pullRequestID: pull.id,
                title: pull.title,
                repository: pull.repository,
                number: pull.number,
                url: pull.url,
                applications: applications,
                deliveredApplicationRevision: nil
            )
        }
        snapshot.metadata.lastSuccessfulActionLabelSync = now
        snapshot.metadata.lastActionLabelError = nil
        snapshot.metadata.actionSearchDisagreementCount = discovery.searchDisagreementCount
        snapshot.metadata.rateState = await api.rateState
    }

    static func actionCandidateIDs(snapshot: AppSnapshot, priorItems: [AttentionItem]) -> Set<String> {
        let recentOpenAuthoredIDs = snapshot.pullRequests
            .filter { $0.state == .open }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(20)
            .map(\.id)
        return Set(priorItems.compactMap(\.pullRequestID))
            .union(snapshot.assignedPullRequestIDs)
            .union(recentOpenAuthoredIDs)
    }

    private func preserveActionAuthority(
        on snapshot: inout AppSnapshot,
        previous: AppSnapshot?,
        configuration: ActionNotificationConfiguration,
        error: Error
    ) {
        let revision = configuration.revision
        snapshot.metadata.actionAuthorityVersion = 1
        snapshot.metadata.actionConfigurationRevision = revision
        snapshot.metadata.lastActionLabelError = error.localizedDescription
        if previous?.metadata.actionConfigurationRevision == revision {
            snapshot.attentionItems = previous?.attentionItems.filter { $0.kind == .actionLabels } ?? []
            snapshot.metadata.lastSuccessfulActionLabelSync = previous?.metadata.lastSuccessfulActionLabelSync
            snapshot.metadata.actionSearchDisagreementCount = previous?.metadata.actionSearchDisagreementCount
        } else {
            snapshot.attentionItems = []
            snapshot.metadata.lastSuccessfulActionLabelSync = nil
            snapshot.metadata.actionSearchDisagreementCount = nil
        }
    }

    private func discoverAuthored(login: String, from start: Date, through end: Date) async throws -> [GitHubPullRequestNode] {
        // Search the complete backfill range first. discoverSlice recursively bisects
        // only if GitHub's 1,000-result search ceiling is actually reached, avoiding
        // ten fixed-window requests for ordinary account sizes without sacrificing
        // completeness for unusually active accounts.
        let created = try await discoverSlice(login: login, qualifier: "created", from: start, through: end)
        let updated = try await discoverSlice(login: login, qualifier: "updated", from: start, through: end)
        let nodes = created + updated
        return Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, second in
            first.updatedAt >= second.updatedAt ? first : second
        }).values.sorted { $0.createdAt < $1.createdAt }
    }

    private func discoverSlice(
        login: String,
        qualifier: String,
        from start: Date,
        through end: Date
    ) async throws -> [GitHubPullRequestNode] {
        let formatter = ISO8601DateFormatter()
        let range = "\(formatter.string(from: start))..\(formatter.string(from: end))"
        do {
            return try await api.searchPullRequests(query: "is:pr author:\(login) \(qualifier):\(range)")
        } catch GitHubAPIError.incompleteDiscovery where end.timeIntervalSince(start) > 60 {
            let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let first = try await discoverSlice(login: login, qualifier: qualifier, from: start, through: midpoint)
            let second = try await discoverSlice(login: login, qualifier: qualifier, from: midpoint, through: end)
            return Dictionary((first + second).map { ($0.id, $0) }, uniquingKeysWith: { old, new in
                old.updatedAt >= new.updatedAt ? old : new
            }).map(\.value)
        }
    }

    private func snapshot(from node: GitHubPullRequestNode, events: [TimelineEvent]) -> PullRequestSnapshot {
        let eligibleAt = Self.eligibleAt(createdAt: node.createdAt, currentIsDraft: node.isDraft, events: events)
        let state: PullRequestState = node.mergedAt != nil ? .merged : (node.state == "CLOSED" ? .closed : .open)
        return PullRequestSnapshot(
            id: node.id,
            repository: node.repository.nameWithOwner,
            number: node.number,
            title: node.title,
            url: node.url,
            authorID: node.author?.user?.id ?? "unknown",
            eligibleAt: eligibleAt,
            updatedAt: node.updatedAt,
            isDraft: node.isDraft,
            state: state,
            mergedAt: node.mergedAt,
            closedAt: node.closedAt
        )
    }

    private func timelineNotifications(
        events: [TimelineEvent],
        pulls: [PullRequestSnapshot],
        viewerID: String
    ) -> (attention: [AttentionItem], transient: [TransientEvent]) {
        let pullsByID = Dictionary(pulls.map { ($0.id, $0) }, uniquingKeysWith: { old, new in
            old.updatedAt >= new.updatedAt ? old : new
        })
        let attention: [AttentionItem] = []
        var transient: [TransientEvent] = []
        for event in events {
            guard let pull = pullsByID[event.pullRequestID], pull.authorID == viewerID else { continue }
            switch event.kind {
            case let .reviewed(_, state) where state == .changesRequested:
                continue
            case let .reviewed(_, state) where state == .approved:
                transient.append(TransientEvent(id: event.id, kind: .approved, title: pull.title, url: pull.url))
            case .merged:
                transient.append(TransientEvent(id: event.id, kind: .merged, title: pull.title, url: pull.url))
            default:
                continue
            }
        }
        return (attention, transient)
    }

    private func attentionItem(
        from thread: GitHubNotificationThread,
        viewer: GitHubUser
    ) async throws -> AttentionItem? {
        guard thread.unread,
              thread.reason == "mention",
              thread.subject.type == "PullRequest" else { return nil }
        let candidates = try await api.mentionContents(thread: thread)
            .filter { content in
                content.authorLogin?.caseInsensitiveCompare(viewer.login) != .orderedSame
                    && DirectMentionMatcher.containsDirectMention(in: content.body, login: viewer.login)
            }
        guard let mention = candidates.max(by: { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
            return lhs.revisionID < rhs.revisionID
        }) else { return nil }
        return makeThreadAttention(
            thread,
            revisionID: mention.revisionID,
            createdAt: mention.occurredAt
        )
    }

    private func makeThreadAttention(
        _ thread: GitHubNotificationThread,
        revisionID: String,
        createdAt: Date
    ) -> AttentionItem? {
        guard let apiURL = thread.subject.url,
              let number = Int(apiURL.lastPathComponent) else { return nil }
        let url = thread.repository.htmlURL.appending(path: "pull/\(number)")
        return AttentionItem(
            id: "thread:\(thread.id)",
            kind: .mention,
            level: .loud,
            title: thread.subject.title,
            repository: thread.repository.fullName,
            url: url,
            createdAt: createdAt,
            revisionID: revisionID,
            verificationVersion: AttentionItem.directMentionVerificationVersion
        )
    }
}
