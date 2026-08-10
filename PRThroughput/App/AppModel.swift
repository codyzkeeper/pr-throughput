import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
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
    @Published var selectedRange: CohortRange = .days7
    @Published var isSyncing = false
    @Published var errorMessage: String?
    @Published var deviceAuthorization: DeviceAuthorization?
    @Published var transientKind: TransientEventKind?
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
    private var notificationLoop: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var transientResetTask: Task<Void, Never>?
    private var signInAttemptID: UUID?
    private var activeSessionID: UUID?
    private var activeSyncID: UUID?
    private var hasStarted = false

    init() {
        snapshotStore = try? SnapshotStore()
        let configured = Bundle.main.object(forInfoDictionaryKey: "GITHUB_CLIENT_ID") as? String
        oauthClientID = UserDefaults.standard.string(forKey: "github.oauthClientID")
            ?? configured?.replacingOccurrences(of: "$(GITHUB_CLIENT_ID)", with: "")
            ?? ""
    }

    var assignedCount: Int { snapshot?.assignedCount ?? 0 }

    var unacknowledgedItems: [AttentionItem] {
        snapshot?.attentionItems.filter(\.isActive) ?? []
    }

    var unseenItems: [AttentionItem] {
        snapshot?.attentionItems.filter(\.isUnseen) ?? []
    }

    var isStale: Bool {
        guard let last = snapshot?.metadata.lastSuccessfulSync else { return false }
        return Date().timeIntervalSince(last) > 600
    }

    func start() async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !hasStarted else { return }
        hasStarted = true
        var storedToken: String?
        do {
            guard let token = try tokenStore.load() else { return }
            storedToken = token
            connectionState = .authorizing
            try await connect(token: token)
        } catch GitHubAPIError.unauthorized {
            if let storedToken { _ = try? tokenStore.delete(ifMatching: storedToken) }
            errorMessage = GitHubAPIError.unauthorized.localizedDescription
            connectionState = .disconnected
        } catch {
            errorMessage = error.localizedDescription
            connectionState = .disconnected
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
                let service = OAuthDeviceFlowService(clientID: self.oauthClientID)
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
        notificationLoop?.cancel()
        signInTask = nil
        refreshLoop = nil
        notificationLoop = nil
        signInAttemptID = nil
        activeSessionID = nil
        activeSyncID = nil
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
            let result = try await coordinator.refresh(previous: previous)
            guard activeSessionID == sessionID, connectionState == .connected else { return }
            let currentBeforePublish = snapshot
            let merged = mergeLocalAttention(into: result.snapshot, current: currentBeforePublish)
            try snapshotStore?.save(merged)
            snapshot = merged
            isDataVerified = true
            let previousRevisions = revisionMap(currentBeforePublish?.attentionItems ?? [])
            for item in merged.attentionItems where item.isUnseen && previousRevisions[item.id] != item.revisionID {
                await notifications.deliver(item)
                guard activeSessionID == sessionID else { return }
            }
            showTransient(result.transientEvents)
        } catch {
            handleSyncFailure(error, sessionID: sessionID)
        }
    }

    func acknowledge(_ item: AttentionItem, open: Bool = true) {
        guard var updated = snapshot,
              let revisionID = item.revisionID,
              let index = updated.attentionItems.firstIndex(where: { $0.id == item.id }),
              updated.attentionItems[index].revisionID == revisionID else { return }
        updated.attentionItems[index].seenRevisionID = revisionID
        updated.attentionItems[index].acknowledgedRevisionID = revisionID
        updated.attentionItems[index].acknowledgedAt = Date()
        do {
            try snapshotStore?.save(updated)
            snapshot = updated
        } catch {
            errorMessage = "Could not save acknowledgement: \(error.localizedDescription)"
            return
        }
        notifications.remove(id: item.notificationID)
        if open { NSWorkspace.shared.open(item.url) }
    }

    func markSeen(_ item: AttentionItem) {
        guard isPopoverPresented, item.isUnseen,
              var updated = snapshot,
              let revisionID = item.revisionID,
              let index = updated.attentionItems.firstIndex(where: { $0.id == item.id }),
              updated.attentionItems[index].revisionID == revisionID else { return }
        updated.attentionItems[index].seenRevisionID = revisionID
        do {
            try snapshotStore?.save(updated)
            snapshot = updated
            notifications.remove(id: item.notificationID)
        } catch {
            errorMessage = "Could not save notification state: \(error.localizedDescription)"
        }
    }

    func setPopoverPresented(_ presented: Bool) {
        isPopoverPresented = presented
    }

    func acknowledgeAll() {
        guard var updated = snapshot else { return }
        let activeIndices = updated.attentionItems.indices.filter { updated.attentionItems[$0].isActive }
        let notificationIDs = activeIndices.map { updated.attentionItems[$0].notificationID }
        for index in activeIndices {
            guard let revisionID = updated.attentionItems[index].revisionID else { continue }
            updated.attentionItems[index].seenRevisionID = revisionID
            updated.attentionItems[index].acknowledgedRevisionID = revisionID
            updated.attentionItems[index].acknowledgedAt = Date()
        }
        do {
            try snapshotStore?.save(updated)
            snapshot = updated
            for id in notificationIDs { notifications.remove(id: id) }
        } catch {
            errorMessage = "Could not save acknowledgements: \(error.localizedDescription)"
        }
    }

    func signOut() {
        signInTask?.cancel()
        refreshLoop?.cancel()
        notificationLoop?.cancel()
        transientResetTask?.cancel()
        signInTask = nil
        refreshLoop = nil
        notificationLoop = nil
        transientResetTask = nil
        signInAttemptID = nil
        activeSessionID = nil
        activeSyncID = nil
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
            let migratedAttention = SyncCoordinator.normalizeAttention(cached.attentionItems, now: Date())
            if migratedAttention != cached.attentionItems {
                cached.attentionItems = migratedAttention
                // Re-evaluate current unread mention threads after discarding the
                // old unverified taxonomy so legitimate tags are not lost.
                cached.metadata.lastNotificationSync = nil
                cacheChanged = true
            }
            if cached.metadata.attentionVisibilityVersion != 6 {
                for index in cached.attentionItems.indices where cached.attentionItems[index].isActive {
                    cached.attentionItems[index].seenRevisionID = nil
                }
                cached.metadata.attentionVisibilityVersion = 6
                cacheChanged = true
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
        await notifications.requestAuthorization()
        guard activeSessionID == sessionID else { return }
        await refresh()
        guard activeSessionID == sessionID else { return }
        startRefreshLoop()
        startNotificationLoop()
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

    nonisolated static func scheduledRefresh(atTick tick: Int) -> ScheduledRefresh {
        guard tick > 0 else { return .assignedOnly }
        return tick.isMultiple(of: 20) ? .full : .assignedOnly
    }

    private func startNotificationLoop() {
        notificationLoop?.cancel()
        notificationLoop = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await self?.coordinator?.recommendedNotificationPollInterval() ?? 60
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.pollNotifications()
            }
        }
    }

    private func refreshAssignedOnly() async {
        guard let coordinator, let snapshot, let sessionID = activeSessionID, let syncID = beginSync() else { return }
        defer { endSync(syncID) }
        do {
            let result = try await coordinator.refreshAssigned(previous: snapshot)
            guard activeSessionID == sessionID, connectionState == .connected else { return }
            let currentBeforePublish = self.snapshot
            let merged = mergeLocalAttention(into: result.snapshot, current: currentBeforePublish)
            try snapshotStore?.save(merged)
            self.snapshot = merged
            isDataVerified = true
            errorMessage = merged.metadata.lastError
            let previousRevisions = revisionMap(currentBeforePublish?.attentionItems ?? [])
            for item in merged.attentionItems where item.isUnseen && previousRevisions[item.id] != item.revisionID {
                await notifications.deliver(item)
                guard activeSessionID == sessionID else { return }
            }
            showTransient(result.transientEvents)
        } catch {
            handleSyncFailure(error, sessionID: sessionID)
        }
    }

    private func pollNotifications() async {
        guard let coordinator, let snapshot, snapshot.metadata.baselineEstablished,
              let sessionID = activeSessionID, let syncID = beginSync() else { return }
        defer { endSync(syncID) }
        do {
            let (updated, _) = try await coordinator.pollNotifications(previous: snapshot)
            guard activeSessionID == sessionID, connectionState == .connected else { return }
            let currentBeforePublish = self.snapshot
            let merged = mergeLocalAttention(into: updated, current: currentBeforePublish)
            try snapshotStore?.save(merged)
            self.snapshot = merged
            let previousRevisions = revisionMap(currentBeforePublish?.attentionItems ?? [])
            for item in merged.attentionItems where item.isUnseen && previousRevisions[item.id] != item.revisionID {
                await notifications.deliver(item)
                guard activeSessionID == sessionID else { return }
            }
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

    private func revisionMap(_ items: [AttentionItem]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.revisionID.map { (item.id, $0) }
        })
    }

    private func mergeLocalAttention(into incoming: AppSnapshot, current: AppSnapshot?) -> AppSnapshot {
        guard let current else { return incoming }
        var merged = incoming
        merged.attentionItems = SyncCoordinator.normalizeAttention(
            incoming.attentionItems + current.attentionItems,
            now: Date()
        )
        return merged
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
        notificationLoop?.cancel()
        refreshLoop = nil
        notificationLoop = nil
        activeSessionID = nil
        coordinator = nil
        connectionState = .disconnected
        do {
            try tokenStore.delete()
        } catch {
            errorMessage = "GitHub authorization expired, and its cached credential could not be removed: \(error.localizedDescription)"
        }
    }
}
