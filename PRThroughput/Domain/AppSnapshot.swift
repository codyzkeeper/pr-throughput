import CryptoKit
import Foundation

enum NotificationLevel: String, Codable, CaseIterable, Sendable {
    case loud
    case persistent
    case quiet
}

enum AttentionKind: String, Codable, Sendable {
    case mention
    case assigned
    case reviewRequested
    case changesRequested
    case actionLabels
}

struct AttentionItem: Codable, Hashable, Identifiable, Sendable {
    static let directMentionVerificationVersion = 1

    let id: String
    let kind: AttentionKind
    let level: NotificationLevel
    let title: String
    let repository: String
    let url: URL
    let createdAt: Date
    var acknowledgedAt: Date?
    let revisionID: String?
    let verificationVersion: Int?
    var seenRevisionID: String?
    var acknowledgedRevisionID: String?
    let pullRequestID: String?
    let pullRequestNumber: Int?
    var actionApplications: [ActionLabelApplication]?
    var deliveredApplicationRevision: String?

    init(
        id: String,
        kind: AttentionKind,
        level: NotificationLevel,
        title: String,
        repository: String,
        url: URL,
        createdAt: Date,
        acknowledgedAt: Date? = nil,
        revisionID: String? = nil,
        verificationVersion: Int? = nil,
        seenRevisionID: String? = nil,
        acknowledgedRevisionID: String? = nil,
        pullRequestID: String? = nil,
        pullRequestNumber: Int? = nil,
        actionApplications: [ActionLabelApplication]? = nil,
        deliveredApplicationRevision: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.level = level
        self.title = title
        self.repository = repository
        self.url = url
        self.createdAt = createdAt
        self.acknowledgedAt = acknowledgedAt
        self.revisionID = revisionID
        self.verificationVersion = verificationVersion
        self.seenRevisionID = seenRevisionID
        self.acknowledgedRevisionID = acknowledgedRevisionID
        self.pullRequestID = pullRequestID
        self.pullRequestNumber = pullRequestNumber
        self.actionApplications = actionApplications
        self.deliveredApplicationRevision = deliveredApplicationRevision
    }

    var isVerifiedDirectMention: Bool {
        kind == .mention
            && verificationVersion == Self.directMentionVerificationVersion
            && revisionID != nil
    }

    var isActive: Bool {
        // GitHub is the sole authority for action-row visibility. Local interaction
        // may mark an application seen, but it must never hide a label that is
        // still present on an open pull request.
        if kind == .actionLabels { return !applications.isEmpty }
        guard let revisionID, isVerifiedDirectMention else { return false }
        return acknowledgedRevisionID != revisionID
    }

    var isUnseen: Bool {
        if kind == .actionLabels { return applications.contains(where: \.isUnseen) }
        guard let revisionID, isActive else { return false }
        return seenRevisionID != revisionID
    }

    var notificationID: String {
        guard let revisionID else { return id }
        return "\(id):\(revisionID)"
    }

    var applications: [ActionLabelApplication] { actionApplications ?? [] }

    var highestPriorityUnseenApplication: ActionLabelApplication? {
        applications.filter(\.isUnseen).min {
            if $0.ruleID.priority != $1.ruleID.priority { return $0.ruleID.priority < $1.ruleID.priority }
            return $0.appliedAt > $1.appliedAt
        }
    }

    var highestPriorityUndeliveredApplication: ActionLabelApplication? {
        applications.filter { $0.isUnseen && $0.deliveredAt == nil }.min {
            if $0.ruleID.priority != $1.ruleID.priority { return $0.ruleID.priority < $1.ruleID.priority }
            return $0.appliedAt > $1.appliedAt
        }
    }

    var hasUndeliveredApplication: Bool {
        highestPriorityUndeliveredApplication != nil
    }

    func markingUndeliveredApplicationsDelivered(at date: Date) -> AttentionItem {
        var copy = self
        var values = applications
        for index in values.indices where values[index].isUnseen && values[index].deliveredAt == nil {
            values[index].deliveredAt = date
        }
        copy.actionApplications = values
        return copy
    }

    var highestPriorityActiveApplication: ActionLabelApplication? {
        applications.min {
            if $0.ruleID.priority != $1.ruleID.priority { return $0.ruleID.priority < $1.ruleID.priority }
            return $0.appliedAt > $1.appliedAt
        }
    }

    static func action(
        pullRequestID: String,
        title: String,
        repository: String,
        number: Int,
        url: URL,
        applications: [ActionLabelApplication],
        deliveredApplicationRevision: String? = nil
    ) -> AttentionItem {
        let revision = Self.actionRevision(applications)
        return AttentionItem(
            id: "action:\(pullRequestID)", kind: .actionLabels, level: .persistent,
            title: title, repository: repository, url: url,
            createdAt: applications.map(\.appliedAt).max() ?? .distantPast,
            revisionID: revision, pullRequestID: pullRequestID,
            pullRequestNumber: number, actionApplications: applications,
            deliveredApplicationRevision: deliveredApplicationRevision
        )
    }

    static func actionRevision(_ applications: [ActionLabelApplication]) -> String {
        let data = Data(applications.map(\.labelEventID).sorted().joined(separator: "\0").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func markingSeen(revision: String, at date: Date) -> (item: AttentionItem, didMutate: Bool) {
        guard kind == .actionLabels, revisionID == revision else { return (self, false) }
        var copy = self
        var values = applications
        var changed = false
        for index in values.indices where values[index].isUnseen {
            values[index].seenAt = date
            changed = true
        }
        copy.actionApplications = values
        return (copy, changed)
    }
}

enum DirectMentionMatcher {
    static func containsDirectMention(in markdown: String, login: String) -> Bool {
        guard !login.isEmpty else { return false }
        let withoutHTMLHiddenContent = markdown
            .replacingOccurrences(
                of: #"<!--[\s\S]*?-->"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)<(code|pre)\b[^>]*>[\s\S]*?</\1\s*>"#,
                with: "",
                options: .regularExpression
            )
        var visibleLines: [String] = []
        var activeFence: String?
        for line in withoutHTMLHiddenContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = activeFence {
                if trimmed.hasPrefix(fence) { activeFence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let remainder = trimmed.dropFirst(3)
                if !remainder.contains(fence) { activeFence = fence }
                continue
            }
            let quoteRange = trimmed.range(
                of: #"^(?:(?:[-+*]|\d+[.)])\s+)*>"#,
                options: .regularExpression
            )
            guard quoteRange == nil else { continue }
            visibleLines.append(line)
        }
        let withoutInlineCode = removingInlineCode(from: visibleLines.joined(separator: "\n"))
        let escaped = NSRegularExpression.escapedPattern(for: login)
        let pattern = "(?i)(?<![A-Za-z0-9-])@\(escaped)(?![A-Za-z0-9-])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(withoutInlineCode.startIndex..<withoutInlineCode.endIndex, in: withoutInlineCode)
        return regex.firstMatch(in: withoutInlineCode, range: range) != nil
    }

    private static func removingInlineCode(from markdown: String) -> String {
        let characters = Array(markdown)
        var visible: [Character] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "`" else {
                visible.append(characters[index])
                index += 1
                continue
            }
            var openingEnd = index
            while openingEnd < characters.count, characters[openingEnd] == "`" { openingEnd += 1 }
            let delimiterLength = openingEnd - index
            var search = openingEnd
            var closingEnd: Int?
            while search < characters.count {
                guard characters[search] == "`" else {
                    search += 1
                    continue
                }
                var runEnd = search
                while runEnd < characters.count, characters[runEnd] == "`" { runEnd += 1 }
                if runEnd - search == delimiterLength {
                    closingEnd = runEnd
                    break
                }
                search = runEnd
            }
            if let closingEnd {
                index = closingEnd
            } else {
                visible.append(contentsOf: characters[index..<openingEnd])
                index = openingEnd
            }
        }
        return String(visible)
    }
}

enum TransientEventKind: String, Codable, Sendable {
    case approved
    case merged
}

struct TransientEvent: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let kind: TransientEventKind
    let title: String
    let url: URL
}

struct SyncMetadata: Codable, Equatable, Sendable {
    var lastSuccessfulSync: Date?
    var lastNotificationSync: Date?
    var lastError: String?
    var rateState: GitHubRateState
    var baselineEstablished: Bool
    var timelineSchemaVersion: Int?
    var attentionVisibilityVersion: Int?
    var actionAuthorityVersion: Int?
    var actionConfigurationRevision: String?
    var lastSuccessfulActionLabelSync: Date?
    var lastActionLabelError: String?
    var actionSearchDisagreementCount: Int?

    init(
        lastSuccessfulSync: Date?,
        lastNotificationSync: Date?,
        lastError: String?,
        rateState: GitHubRateState,
        baselineEstablished: Bool,
        timelineSchemaVersion: Int? = TimelineEvent.sourceSchemaVersion,
        attentionVisibilityVersion: Int? = 6,
        actionAuthorityVersion: Int? = nil,
        actionConfigurationRevision: String? = nil,
        lastSuccessfulActionLabelSync: Date? = nil,
        lastActionLabelError: String? = nil,
        actionSearchDisagreementCount: Int? = nil
    ) {
        self.lastSuccessfulSync = lastSuccessfulSync
        self.lastNotificationSync = lastNotificationSync
        self.lastError = lastError
        self.rateState = rateState
        self.baselineEstablished = baselineEstablished
        self.timelineSchemaVersion = timelineSchemaVersion
        self.attentionVisibilityVersion = attentionVisibilityVersion
        self.actionAuthorityVersion = actionAuthorityVersion
        self.actionConfigurationRevision = actionConfigurationRevision
        self.lastSuccessfulActionLabelSync = lastSuccessfulActionLabelSync
        self.lastActionLabelError = lastActionLabelError
        self.actionSearchDisagreementCount = actionSearchDisagreementCount
    }

    static let empty = SyncMetadata(
        lastSuccessfulSync: nil,
        lastNotificationSync: nil,
        lastError: nil,
        rateState: GitHubRateState(remaining: nil, resetAt: nil),
        baselineEstablished: false,
        timelineSchemaVersion: TimelineEvent.sourceSchemaVersion,
        attentionVisibilityVersion: 6
    )
}

struct AppSnapshot: Codable, Sendable {
    var viewer: GitHubUser
    var pullRequests: [PullRequestSnapshot]
    var events: [TimelineEvent]
    var handoffs: [Handoff]
    var assignedPullRequestIDs: Set<String>
    var attentionItems: [AttentionItem]
    var metadata: SyncMetadata

    var assignedCount: Int { assignedPullRequestIDs.count }

    func windowMetrics(range: WindowRange, asOf: Date = Date()) -> WindowMetrics {
        WindowMetrics.calculate(
            pullRequests: pullRequests,
            events: events,
            handoffs: handoffs,
            viewerID: viewer.id,
            range: range,
            asOf: asOf
        )
    }

    func canonicalMetrics(asOf: Date? = nil) throws -> CanonicalMetricSnapshot {
        let verifiedBoundary = asOf ?? metadata.lastSuccessfulSync ?? Date()
        return try MetricContract.snapshot(from: self, asOf: verifiedBoundary)
    }

    func reconciliation(asOf: Date = Date()) -> ReconciliationReport {
        SnapshotReconciler.validate(self, asOf: asOf)
    }
}
