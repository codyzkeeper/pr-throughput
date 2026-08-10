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
        acknowledgedRevisionID: String? = nil
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
    }

    var isVerifiedDirectMention: Bool {
        kind == .mention
            && verificationVersion == Self.directMentionVerificationVersion
            && revisionID != nil
    }

    var isActive: Bool {
        guard let revisionID, isVerifiedDirectMention else { return false }
        return acknowledgedRevisionID != revisionID
    }

    var isUnseen: Bool {
        guard let revisionID, isActive else { return false }
        return seenRevisionID != revisionID
    }

    var notificationID: String {
        guard let revisionID else { return id }
        return "\(id):\(revisionID)"
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

    init(
        lastSuccessfulSync: Date?,
        lastNotificationSync: Date?,
        lastError: String?,
        rateState: GitHubRateState,
        baselineEstablished: Bool,
        timelineSchemaVersion: Int? = TimelineEvent.sourceSchemaVersion,
        attentionVisibilityVersion: Int? = 6
    ) {
        self.lastSuccessfulSync = lastSuccessfulSync
        self.lastNotificationSync = lastNotificationSync
        self.lastError = lastError
        self.rateState = rateState
        self.baselineEstablished = baselineEstablished
        self.timelineSchemaVersion = timelineSchemaVersion
        self.attentionVisibilityVersion = attentionVisibilityVersion
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

    func metrics(range: CohortRange, asOf: Date = Date()) -> CohortMetrics {
        CohortMetrics.calculate(
            pullRequests: pullRequests,
            handoffs: handoffs,
            viewerID: viewer.id,
            range: range,
            asOf: asOf
        )
    }

    func activity(range: CohortRange, asOf: Date = Date()) -> WindowActivityMetrics {
        WindowActivityMetrics.calculate(
            pullRequests: pullRequests,
            events: events,
            handoffs: handoffs,
            viewerID: viewer.id,
            range: range,
            asOf: asOf
        )
    }

    func canonicalMetrics(asOf: Date = Date()) throws -> CanonicalMetricSnapshot {
        try MetricContract.snapshot(from: self, asOf: asOf)
    }

    func reconciliation(asOf: Date = Date()) -> ReconciliationReport {
        SnapshotReconciler.validate(self, asOf: asOf)
    }
}
