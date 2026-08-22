import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum SyncHealth: Equatable {
        case reconciled
        case actionError
        case syncError
        case stale
        case unverified
    }

    enum ConnectionState: Equatable {
        case disconnected
        case authorizing
        case connected
    }

    enum ScheduledRefresh: Equatable {
        case assignedOnly
        case full
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var snapshot: AppSnapshot?
    @Published var selectedRange: WindowRange = .days7
    @Published var isSyncing = false
    @Published var errorMessage: String?
    @Published var deviceAuthorization: DeviceAuthorization?
    @Published var transientKind: TransientEventKind?
    @Published private(set) var notificationAuthorizationStatus = "Checking…"
    @Published private(set) var actionConfiguration: ActionNotificationConfiguration
    @Published private(set) var isDataVerified = false
    @Published private(set) var isPopoverPresented = false
    @Published var oauthClientID: String {
        didSet { UserDefaults.standard.set(oauthClientID, forKey: "github.oauthClientID") }
    }

    private let tokenStore = KeychainTokenStore()
    private let snapshotStore: SnapshotStore?
    private let notifications = LocalNotificationService()
    private var coordinator: SyncCoordinator?
    private var refreshLoop: Task<Void, Never>?
    private var actionRefreshLoop: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var transientResetTask: Task<Void, Never>?
    private var signInAttemptID: UUID?
    private var activeSessionID: UUID?
    private var activeSyncID: UUID?
    private var activeActionSyncID: UUID?
    private var hasStarted = false

    convenience init() {
        self.init(snapshotStore: try? SnapshotStore(), actionConfiguration: .load())
    }

    init(snapshotStore: SnapshotStore?, actionConfiguration: ActionNotificationConfiguration) {
        self.snapshotStore = snapshotStore
        self.actionConfiguration = actionConfiguration
        let configured = Bundle.main.object(forInfoDictionaryKey: "GITHUB_CLIENT_ID") as? String
        oauthClientID = Self.resolveOAuthClientID(
            saved: UserDefaults.standard.string(forKey: "github.oauthClientID"),
            configured: configured
        )
        notifications.setOpenHandler { [weak self] identifier in
            self?.markSystemNotificationSeen(identifier)
        }
        Task { await refreshNotificationAuthorizationStatus() }
    }

    nonisolated static func resolveOAuthClientID(saved: String?, configured: String?) -> String {
        for candidate in [saved, configured] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty, trimmed != "$(GITHUB_CLIENT_ID)" { return trimmed }
        }
        return ""
    }

    var assignedCount: Int { snapshot?.assignedCount ?? 0 }

    var hasBundledOAuthClientID: Bool {
        let configured = Bundle.main.object(forInfoDictionaryKey: "GITHUB_CLIENT_ID") as? String
        return !Self.resolveOAuthClientID(saved: nil, configured: configured).isEmpty
    }

    var unacknowledgedItems: [AttentionItem] {
        (snapshot?.attentionItems.filter(\.isActive) ?? []).sorted { lhs, rhs in
            let left = lhs.applications.map(\.ruleID.priority).min() ?? .max
            let right = rhs.applications.map(\.ruleID.priority).min() ?? .max
            if left != right { return left < right }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return (lhs.repository, lhs.pullRequestNumber ?? 0) < (rhs.repository, rhs.pullRequestNumber ?? 0)
        }
    }

    var unseenItems: [AttentionItem] {
        snapshot?.attentionItems.filter(\.isUnseen) ?? []
    }

    var isStale: Bool {
        guard let last = snapshot?.metadata.lastSuccessfulSync else { return false }
        return Date().timeIntervalSince(last) > 600
    }

    var isActionSyncStale: Bool {
        guard actionConfiguration.isConfigured else { return false }
        guard let last = snapshot?.metadata.lastSuccessfulActionLabelSync else { return true }
        return Date().timeIntervalSince(last) > 60
    }

    var syncHealth: SyncHealth {
        Self.resolveSyncHealth(
            dataVerified: isDataVerified,
            fullSyncDate: snapshot?.metadata.lastSuccessfulSync,
            actionSyncDate: snapshot?.metadata.lastSuccessfulActionLabelSync,
            actionConfigured: actionConfiguration.isConfigured,
            actionError: snapshot?.metadata.lastActionLabelError,
            syncError: snapshot?.metadata.lastError,
            now: Date()
        )
    }

    var syncHealthHelp: String {
        switch syncHealth {
        case .reconciled:
            return "Source facts and all displayed metric equations passed reconciliation checks."
        case .actionError:
            let detail = snapshot?.metadata.lastActionLabelError ?? "The GitHub label notification refresh failed."
            return "GitHub label notifications are showing the last verified state until refresh succeeds. \(detail)"
        case .syncError:
            return snapshot?.metadata.lastError ?? "The latest GitHub sync failed. Previously verified totals are being shown."
        case .stale:
            return "One or more GitHub data lanes have not completed a recent successful sync."
        case .unverified:
            return "The app has not completed a verified sync yet."
        }
    }

    nonisolated static func resolveSyncHealth(
        dataVerified: Bool,
        fullSyncDate: Date?,
        actionSyncDate: Date?,
        actionConfigured: Bool,
        actionError: String?,
        syncError: String?,
        now: Date,
        fullSyncStaleAfter: TimeInterval = 600,
        actionSyncStaleAfter: TimeInterval = 60
    ) -> SyncHealth {
        if actionError != nil { return .actionError }
        if syncError != nil { return .syncError }
        guard dataVerified else { return .unverified }
        guard let fullSyncDate,
              now.timeIntervalSince(fullSyncDate) <= fullSyncStaleAfter else { return .stale }
        if actionConfigured {
            guard let actionSyncDate,
                  now.timeIntervalSince(actionSyncDate) <= actionSyncStaleAfter else { return .stale }
        }
        return .reconciled
    }

    func start() async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !hasStarted else { return }
        hasStarted = true
        while !Task.isCancelled {
            var storedToken: String?
            do {
                guard let token = try tokenStore.load() else { return }
                storedToken = token
                connectionState = .authorizing
                try await connect(token: token)
                return
            } catch GitHubAPIError.unauthorized {
                if let storedToken { _ = try? tokenStore.delete(ifMatching: storedToken) }
                errorMessage = GitHubAPIError.unauthorized.localizedDescription
                connectionState = .disconnected
                return
            } catch let error as KeychainTokenError where error.isTemporarilyUnavailable {
                errorMessage = "The macOS Keychain is temporarily unavailable. Retrying after wake or unlock."
                connectionState = .disconnected
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard connectionState == .disconnected, signInTask == nil else { return }
            } catch {
                errorMessage = error.localizedDescription
                connectionState = .disconnected
                return
            }
        }
    }

    func signIn() {
        guard signInTask == nil else { return }
        let attemptID = UUID()
        signInAttemptID = attemptID
        errorMessage = nil
        connectionState = .authorizing
        signInTask = Task { [weak self] in
            guard let self else { return }
            var savedToken: String?
            defer {
                if self.signInAttemptID == attemptID {
                    self.signInTask = nil
                    self.signInAttemptID = nil
                }
            }
            do {
                let clientID = Self.resolveOAuthClientID(saved: self.oauthClientID, configured: nil)
                let service = OAuthDeviceFlowService(clientID: clientID)
                let authorization = try await service.begin()
                try Task.checkCancellation()
                self.deviceAuthorization = authorization
                NSWorkspace.shared.open(authorization.verificationURL)
                let token = try await service.waitForToken(authorization)
                try Task.checkCancellation()
                try self.tokenStore.save(token)
                savedToken = token
                try Task.checkCancellation()
                self.deviceAuthorization = nil
                try await self.connect(token: token)
            } catch is CancellationError {
                if let savedToken { _ = try? self.tokenStore.delete(ifMatching: savedToken) }
                if self.signInAttemptID == attemptID { self.connectionState = .disconnected }
            } catch {
                if let savedToken { _ = try? self.tokenStore.delete(ifMatching: savedToken) }
                if self.signInAttemptID == attemptID {
                    self.errorMessage = error.localizedDescription
                    self.connectionState = .disconnected
                }
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        refreshLoop?.cancel()
        actionRefreshLoop?.cancel()
        signInTask = nil
        refreshLoop = nil
        actionRefreshLoop = nil
        signInAttemptID = nil
        activeSessionID = nil
        activeSyncID = nil
        activeActionSyncID = nil
        isSyncing = false
        coordinator = nil
        deviceAuthorization = nil
        connectionState = .disconnected
    }

    func refresh() async {
        guard let coordinator, let sessionID = activeSessionID, let syncID = beginSync() else { return }
        defer { endSync(syncID) }
        errorMessage = nil
        let previous = snapshot
        do {
            let needsActionAuthority = previous == nil
                || previous?.metadata.lastSuccessfulActionLabelSync == nil
                || previous?.metadata.actionConfigurationRevision != actionConfiguration.revision
            let result = try await coordinator.refresh(
                previous: previous,
                configuration: actionConfiguration,
                includeActionAuthority: needsActionAuthority
            )
            guard activeSessionID == sessionID, connectionState == .connected else { return }
            guard result.snapshot.metadata.actionConfigurationRevision == actionConfiguration.revision else {
                DispatchQueue.main.async { [weak self] in Task { await self?.refreshAssignedOnly() } }
                return
            }
            let currentBeforePublish = snapshot
            let merged = Self.mergeLocalPresentation(into: result.snapshot, current: currentBeforePublish)
            try SnapshotReconciler.requireValid(merged, actionConfiguration: actionConfiguration)
            try snapshotStore?.save(merged)
            snapshot = merged
            isDataVerified = true
            await reconcileSystemNotifications(previous: currentBeforePublish, sessionID: sessionID)
            showTransient(result.transientEvents)
        } catch {
            handleSyncFailure(error, sessionID: sessionID)
        }
    }

    func acknowledge(_ item: AttentionItem, open: Bool = true) {
        if open {
            guard GitHubPullRequestURL.isSafe(item.url), NSWorkspace.shared.open(item.url) else {
                errorMessage = "Could not open this pull request in your browser."
                return
            }
        }
        guard var updated = snapshot,
              let revisionID = item.revisionID,
              let index = updated.attentionItems.firstIndex(where: { $0.id == item.id }),
              updated.attentionItems[index].revisionID == revisionID else { return }
        if item.kind == .actionLabels {
            let mutation = updated.attentionItems[index].markingSeen(revision: revisionID, at: Date())
            guard mutation.didMutate else { return }
            updated.attentionItems[index] = mutation.item
        } else {
            updated.attentionItems[index].seenRevisionID = revisionID
            updated.attentionItems[index].acknowledgedRevisionID = revisionID
            updated.attentionItems[index].acknowledgedAt = Date()
        }
        do {
            try snapshotStore?.save(updated)
            snapshot = updated
        } catch {
            errorMessage = "Could not save acknowledgement: \(error.localizedDescription)"
            return
        }
        notifications.remove(id: systemNotificationID(for: item, accountID: updated.viewer.id))
    }

    func markSeen(_ item: AttentionItem) {
        guard isPopoverPresented, item.isUnseen,
              var updated = snapshot,
              let revisionID = item.revisionID,
              let index = updated.attentionItems.firstIndex(where: { $0.id == item.id }),
              updated.attentionItems[index].revisionID == revisionID else { return }
        if item.kind == .actionLabels {
            let mutation = updated.attentionItems[index].markingSeen(revision: revisionID, at: Date())
            guard mutation.didMutate else { return }
            updated.attentionItems[index] = mutation.item
        } else {
            updated.attentionItems[index].seenRevisionID = revisionID
        }
        do {
            try snapshotStore?.save(updated)
            snapshot = updated
            notifications.remove(id: systemNotificationID(for: item, accountID: updated.viewer.id))
        } catch {
            errorMessage = "Could not save notification state: \(error.localizedDescription)"
        }
    }

    func setPopoverPresented(_ presented: Bool) {
        isPopoverPresented = presented
        if presented { Task { await refreshAssignedOnly() } }
    }

    func acknowledgeAll() {
        guard var updated = snapshot else { return }
        let activeIndices = updated.attentionItems.indices.filter { updated.attentionItems[$0].isActive }
        let notificationIDs = activeIndices.map {
            systemNotificationID(for: updated.attentionItems[$0], accountID: updated.viewer.id)
        }
        for index in activeIndices {
            guard let revisionID = updated.attentionItems[index].revisionID else { continue }
            if updated.attentionItems[index].kind == .actionLabels {
                updated.attentionItems[index] = updated.attentionItems[index]
                    .markingSeen(revision: revisionID, at: Date()).item
            } else {
                updated.attentionItems[index].seenRevisionID = revisionID
                updated.attentionItems[index].acknowledgedRevisionID = revisionID
                updated.attentionItems[index].acknowledgedAt = Date()
            }
        }
        do {
            try snapshotStore?.save(updated)
            snapshot = updated
            for id in notificationIDs { notifications.remove(id: id) }
        } catch {
            errorMessage = "Could not save acknowledgements: \(error.localizedDescription)"
        }
    }

    func openAllAttentionItems() {
        let targets = AttentionBrowserPlan.targets(for: unacknowledgedItems)
        let urls = targets.map(\.url)
        guard let first = urls.first else { return }
        guard let browserURL = NSWorkspace.shared.urlForApplication(toOpen: first) else {
            errorMessage = "No browser is available to open these pull requests."
            return
        }
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: browserURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.errorMessage = "Could not open all pull requests: \(error.localizedDescription)"
                } else {
                    self?.markAttentionTargetsSeen(targets)
                }
            }
        }
    }

    private func markAttentionTargetsSeen(_ targets: [AttentionBrowserTarget]) {
        guard var updated = snapshot else { return }
        let mutation = AttentionAcknowledgementPlan.markingSeen(
            targets: targets,
            in: updated.attentionItems,
            at: Date()
        )
        guard !mutation.markedItemIDs.isEmpty else { return }
        updated.attentionItems = mutation.items
        let markedIDs = Set(mutation.markedItemIDs)
        let notificationIDs = updated.attentionItems.filter { markedIDs.contains($0.id) }.map {
            systemNotificationID(for: $0, accountID: updated.viewer.id)
        }
        do {
            try snapshotStore?.save(updated)
            snapshot = updated
            for id in notificationIDs { notifications.remove(id: id) }
        } catch {
            errorMessage = "Could not save notification state: \(error.localizedDescription)"
        }
    }

    func saveActionConfiguration(_ configuration: ActionNotificationConfiguration) throws {
        let configuration = try configuration.validated()
        try configuration.save()
        actionConfiguration = configuration
        notifications.removeAll()
        if var updated = snapshot {
            updated.attentionItems = []
            updated.metadata.actionConfigurationRevision = configuration.revision
            updated.metadata.lastSuccessfulActionLabelSync = nil
            updated.metadata.lastActionLabelError = nil
            // Configuration is authoritative immediately. Never leave rows from the
            // previous authority visible merely because the derived cache write fails.
            snapshot = updated
            do {
                try snapshotStore?.save(updated)
            } catch {
                errorMessage = "The action-label configuration was saved, but the derived cache could not be cleared: \(error.localizedDescription)"
            }
        }
        Task { await refreshActionsOnly() }
    }

    func signOut() {
        signInTask?.cancel()
        refreshLoop?.cancel()
        actionRefreshLoop?.cancel()
        transientResetTask?.cancel()
        signInTask = nil
        refreshLoop = nil
        actionRefreshLoop = nil
        transientResetTask = nil
        signInAttemptID = nil
        activeSessionID = nil
        activeSyncID = nil
        activeActionSyncID = nil
        isSyncing = false
        coordinator = nil
        var signOutErrors: [String] = []
        do { try tokenStore.delete() } catch { signOutErrors.append(error.localizedDescription) }
        do { try snapshotStore?.deleteAll() } catch { signOutErrors.append(error.localizedDescription) }
        notifications.removeAll()
        snapshot = nil
        isDataVerified = false
        transientKind = nil
        errorMessage = signOutErrors.isEmpty ? nil : "Sign-out cleanup was incomplete: \(signOutErrors.joined(separator: " "))"
        deviceAuthorization = nil
        connectionState = .disconnected
    }

    private func connect(token: String) async throws {
        let api = GitHubAPI(token: token)
        let viewer = try await api.viewer()
        try Task.checkCancellation()
        let cached = try snapshotStore?.load(accountID: viewer.id)
        try Task.checkCancellation()
        let sessionID = UUID()
        activeSessionID = sessionID
        if var cached {
            var cacheChanged = false
            if cached.metadata.actionAuthorityVersion != 1 {
                cached.attentionItems = []
                cached.metadata.lastNotificationSync = nil
                cached.metadata.actionAuthorityVersion = 1
                cacheChanged = true
                notifications.removeAll()
            }
            if cached.metadata.actionConfigurationRevision != actionConfiguration.revision {
                cached.attentionItems = []
                cached.metadata.actionConfigurationRevision = actionConfiguration.revision
                cached.metadata.lastSuccessfulActionLabelSync = nil
                cached.metadata.lastActionLabelError = nil
                cacheChanged = true
                notifications.removeAll()
            }
            if cacheChanged { try snapshotStore?.save(cached) }
            let report = cached.reconciliation()
            if report.isValid {
                snapshot = cached
                isDataVerified = true
            } else {
                snapshot = nil
                isDataVerified = false
                errorMessage = DataIntegrityError(issues: report.issues).localizedDescription
            }
        } else {
            snapshot = nil
            isDataVerified = false
        }
        coordinator = SyncCoordinator(api: api)
        connectionState = .connected
        await notifications.requestAuthorizationIfNeeded()
        await refreshNotificationAuthorizationStatus()
        guard activeSessionID == sessionID else { return }
        await refresh()
        guard activeSessionID == sessionID else { return }
        await refreshActionsOnly()
        guard activeSessionID == sessionID else { return }
        startRefreshLoop()
        startActionRefreshLoop()
    }

    private func startRefreshLoop() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                tick += 1
                switch Self.scheduledRefresh(atTick: tick) {
                case .full: await self?.refresh()
                case .assignedOnly: await self?.refreshAssignedOnly()
                }
            }
        }
    }

    private func startActionRefreshLoop() {
        actionRefreshLoop?.cancel()
        actionRefreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.refreshActionsOnly()
            }
        }
    }

    private func refreshNotificationAuthorizationStatus() async {
        notificationAuthorizationStatus = await notifications.authorizationStatusDescription()
    }

    nonisolated static func scheduledRefresh(atTick tick: Int) -> ScheduledRefresh {
        guard tick > 0 else { return .assignedOnly }
        return tick.isMultiple(of: 20) ? .full : .assignedOnly
    }

    private func refreshAssignedOnly() async {
        guard let coordinator, let snapshot, let sessionID = activeSessionID, let syncID = beginSync() else { return }
        defer { endSync(syncID) }
        do {
            let result = try await coordinator.refreshAssigned(
                previous: snapshot,
                configuration: actionConfiguration,
                includeActionAuthority: false
            )
            guard activeSessionID == sessionID, connectionState == .connected else { return }
            guard result.snapshot.metadata.actionConfigurationRevision == actionConfiguration.revision else {
                DispatchQueue.main.async { [weak self] in Task { await self?.refreshAssignedOnly() } }
                return
            }
            let currentBeforePublish = self.snapshot
            let merged = Self.mergeLocalPresentation(into: result.snapshot, current: currentBeforePublish)
            try SnapshotReconciler.requireValid(merged, actionConfiguration: actionConfiguration)
            try snapshotStore?.save(merged)
            self.snapshot = merged
            isDataVerified = true
            errorMessage = merged.metadata.lastError
            await reconcileSystemNotifications(previous: currentBeforePublish, sessionID: sessionID)
            showTransient(result.transientEvents)
        } catch {
            handleSyncFailure(error, sessionID: sessionID)
        }
    }

    private func refreshActionsOnly() async {
        guard let coordinator,
              let previous = snapshot,
              let sessionID = activeSessionID,
              activeActionSyncID == nil else { return }
        let syncID = UUID()
        activeActionSyncID = syncID
        defer {
            if activeActionSyncID == syncID { activeActionSyncID = nil }
        }
        do {
            let authority = try await coordinator.refreshActions(
                previous: previous,
                configuration: actionConfiguration
            )
            guard activeSessionID == sessionID,
                  connectionState == .connected,
                  authority.metadata.actionConfigurationRevision == actionConfiguration.revision,
                  var current = snapshot else { return }
            let currentBeforePublish = current
            current.attentionItems = authority.attentionItems
            current.metadata.actionAuthorityVersion = authority.metadata.actionAuthorityVersion
            current.metadata.actionConfigurationRevision = authority.metadata.actionConfigurationRevision
            current.metadata.lastSuccessfulActionLabelSync = authority.metadata.lastSuccessfulActionLabelSync
            current.metadata.lastActionLabelError = authority.metadata.lastActionLabelError
            current.metadata.actionSearchDisagreementCount = authority.metadata.actionSearchDisagreementCount
            current.metadata.rateState = authority.metadata.rateState
            let merged = Self.mergeLocalPresentation(into: current, current: currentBeforePublish)
            try SnapshotReconciler.requireValid(merged, actionConfiguration: actionConfiguration)
            try snapshotStore?.save(merged)
            snapshot = merged
            isDataVerified = true
            await reconcileSystemNotifications(previous: currentBeforePublish, sessionID: sessionID)
        } catch {
            handleSyncFailure(error, sessionID: sessionID)
        }
    }

    private func showTransient(_ events: [TransientEvent]) {
        let enabled = events.filter { event in
            let key = "notification.\(event.kind.rawValue).enabled"
            return UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key)
        }
        guard let last = enabled.last else { return }
        transientResetTask?.cancel()
        transientKind = last.kind
        transientResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.transientKind = nil
        }
    }

    nonisolated static func mergeLocalPresentation(
        into incoming: AppSnapshot,
        current: AppSnapshot?
    ) -> AppSnapshot {
        guard let current else { return incoming }
        var merged = incoming
        if (current.metadata.lastSuccessfulActionLabelSync ?? .distantPast)
            > (incoming.metadata.lastSuccessfulActionLabelSync ?? .distantPast) {
            merged.attentionItems = current.attentionItems
            merged.metadata.actionAuthorityVersion = current.metadata.actionAuthorityVersion
            merged.metadata.actionConfigurationRevision = current.metadata.actionConfigurationRevision
            merged.metadata.lastSuccessfulActionLabelSync = current.metadata.lastSuccessfulActionLabelSync
            merged.metadata.lastActionLabelError = current.metadata.lastActionLabelError
            merged.metadata.actionSearchDisagreementCount = current.metadata.actionSearchDisagreementCount
        }
        let currentByPull = Dictionary(uniqueKeysWithValues: current.attentionItems.compactMap { item in
            item.pullRequestID.map { ($0, item) }
        })
        // `merged` now contains the newest authoritative label facts. Mapping the
        // original `incoming` rows here would undo the timestamp guard above when
        // a slower general sync finishes after the dedicated label refresh.
        merged.attentionItems = merged.attentionItems.map { item in
            guard item.kind == .actionLabels,
                  let pullRequestID = item.pullRequestID,
                  let old = currentByPull[pullRequestID] else { return item }
            let applications = ActionAttentionMerger.mergePresentation(
                incoming: item.applications,
                previous: old.applications
            )
            return AttentionItem.action(
                pullRequestID: pullRequestID,
                title: item.title,
                repository: item.repository,
                number: item.pullRequestNumber ?? 0,
                url: item.url,
                applications: applications,
                deliveredApplicationRevision: nil,
                sourceUpdatedAt: item.actionSourceUpdatedAt
            )
        }
        return merged
    }

    private func reconcileSystemNotifications(previous: AppSnapshot?, sessionID: UUID) async {
        guard let published = snapshot, activeSessionID == sessionID else { return }
        let configurationRevision = published.metadata.actionConfigurationRevision
        let accountID = published.viewer.id
        let incomingIDs = Set(published.attentionItems.compactMap(\.pullRequestID))
        for old in previous?.attentionItems ?? [] where old.kind == .actionLabels {
            guard let pullRequestID = old.pullRequestID else { continue }
            let current = published.attentionItems.first { $0.pullRequestID == pullRequestID }
            if !incomingIDs.contains(pullRequestID) || current?.isUnseen != true {
                notifications.remove(id: ActionNotificationIdentifier.value(
                    accountID: accountID, pullRequestID: pullRequestID
                ))
            }
        }

        let candidates = published.attentionItems.filter { item in
            item.kind == .actionLabels && item.hasUndeliveredApplication
        }
        for item in candidates {
            guard item.kind == .actionLabels, item.hasUndeliveredApplication else { continue }
            if await notifications.deliver(item, accountID: accountID) {
                guard activeSessionID == sessionID,
                      actionConfiguration.revision == configurationRevision,
                      var latest = snapshot,
                      let index = latest.attentionItems.firstIndex(where: { $0.id == item.id }),
                      latest.attentionItems[index].revisionID == item.revisionID,
                      latest.attentionItems[index].isUnseen else {
                    notifications.remove(id: systemNotificationID(for: item, accountID: accountID))
                    continue
                }
                latest.attentionItems[index] = latest.attentionItems[index]
                    .markingUndeliveredApplicationsDelivered(at: Date())
                snapshot = latest
                do {
                    try snapshotStore?.save(latest)
                } catch {
                    errorMessage = "Could not save notification delivery state: \(error.localizedDescription)"
                }
            }
        }
    }

    private func systemNotificationID(for item: AttentionItem, accountID: String) -> String {
        guard item.kind == .actionLabels, let pullRequestID = item.pullRequestID else { return item.notificationID }
        return ActionNotificationIdentifier.value(accountID: accountID, pullRequestID: pullRequestID)
    }

    private func markSystemNotificationSeen(_ identifier: String) {
        guard var updated = snapshot,
              let index = updated.attentionItems.firstIndex(where: {
                  systemNotificationID(for: $0, accountID: updated.viewer.id) == identifier
              }),
              let revisionID = updated.attentionItems[index].revisionID else { return }
        let mutation = updated.attentionItems[index].markingSeen(revision: revisionID, at: Date())
        guard mutation.didMutate else { return }
        updated.attentionItems[index] = mutation.item
        do {
            try SnapshotReconciler.requireValid(updated, actionConfiguration: actionConfiguration)
            try snapshotStore?.save(updated)
            snapshot = updated
            notifications.remove(id: identifier)
        } catch {
            errorMessage = "Could not save notification state: \(error.localizedDescription)"
        }
    }

    private func beginSync() -> UUID? {
        guard activeSyncID == nil else { return nil }
        let id = UUID()
        activeSyncID = id
        isSyncing = true
        return id
    }

    private func endSync(_ id: UUID) {
        guard activeSyncID == id else { return }
        activeSyncID = nil
        isSyncing = false
    }

    nonisolated static func shouldDisconnect(after error: Error) -> Bool {
        guard let apiError = error as? GitHubAPIError else { return false }
        if case .unauthorized = apiError { return true }
        return false
    }

    private func handleSyncFailure(_ error: Error, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        errorMessage = error.localizedDescription
        if var cached = snapshot {
            cached.metadata.lastError = error.localizedDescription
            snapshot = cached
        }
        guard Self.shouldDisconnect(after: error) else { return }

        refreshLoop?.cancel()
        actionRefreshLoop?.cancel()
        refreshLoop = nil
        actionRefreshLoop = nil
        activeSessionID = nil
        activeActionSyncID = nil
        coordinator = nil
        connectionState = .disconnected
        do {
            try tokenStore.delete()
        } catch {
            errorMessage = "GitHub authorization expired, and its cached credential could not be removed: \(error.localizedDescription)"
        }
    }
}
