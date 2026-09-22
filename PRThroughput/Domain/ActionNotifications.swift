import CryptoKit
import Foundation

enum ActionRuleID: String, Codable, CaseIterable, Sendable {
    case decide
    case invokeR2
    case assignReviewer
    case mergeable

    var priority: Int {
        switch self {
        case .decide: 0
        case .invokeR2: 1
        case .assignReviewer: 2
        case .mergeable: 3
        }
    }

    var displayName: String {
        switch self {
        case .decide: "Decision"
        case .invokeR2: "Invoke R2"
        case .assignReviewer: "Assign reviewer"
        case .mergeable: "Mergeable"
        }
    }
}

struct ActionLabelRuleConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var labelName: String
    var notificationLevel: NotificationLevel

    init(id: String? = nil, labelName: String, notificationLevel: NotificationLevel = .persistent) {
        let name = labelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? Self.key(for: name)
        self.labelName = name
        self.notificationLevel = notificationLevel
    }

    static func key(for labelName: String) -> String {
        labelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Compatibility shape retained for decoding and tests of the fixed-rule settings.
struct ActionRuleConfiguration: Codable, Equatable, Sendable {
    let id: ActionRuleID
    var labelName: String
    var isEnabled: Bool
}

private typealias LegacyActionRuleConfiguration = ActionRuleConfiguration

enum ActionConfigurationError: LocalizedError, Equatable {
    case invalidOrganization
    case invalidRules
    case invalidLabel

    var errorDescription: String? {
        switch self {
        case .invalidOrganization: "Enter a GitHub organization name using letters, numbers, or hyphens."
        case .invalidRules: "The notification rules are incomplete or duplicated."
        case .invalidLabel: "Enter a valid GitHub label."
        }
    }
}

struct ActionNotificationConfiguration: Codable, Equatable, Sendable {
    static let schemaVersion = 3
    static let storageKey = "notification.actionLabels.configuration.v1"

    let schemaVersion: Int
    var organization: String
    var rules: [ActionLabelRuleConfiguration]

    static let blank = ActionNotificationConfiguration(
        schemaVersion: schemaVersion,
        organization: "",
        rules: []
    )

    var enabledRules: [ActionLabelRuleConfiguration] {
        rules.sorted { lhs, rhs in
            let lhsName = ActionLabelRuleConfiguration.key(for: lhs.labelName)
            let rhsName = ActionLabelRuleConfiguration.key(for: rhs.labelName)
            return lhsName == rhsName ? lhs.id < rhs.id : lhsName < rhsName
        }
    }

    var isConfigured: Bool {
        (try? validated()) != nil && !enabledRules.isEmpty
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion else { throw ActionConfigurationError.invalidRules }
        let organization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard organization.caseInsensitiveCompare("Keeper-Dating") == .orderedSame else {
            throw ActionConfigurationError.invalidOrganization
        }
        var copy = self
        var enabledNames = Set<String>()
        for index in copy.rules.indices {
            copy.rules[index].labelName = copy.rules[index].labelName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = copy.rules[index].labelName
            guard !value.isEmpty, value.count <= 100,
                  value.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ActionConfigurationError.invalidLabel
            }
            let key = ActionLabelRuleConfiguration.key(for: value)
            guard enabledNames.insert(key).inserted else {
                throw ActionConfigurationError.invalidRules
            }
            copy.rules[index].id = key
        }
        copy.organization = "Keeper-Dating"
        copy.rules.sort { ActionLabelRuleConfiguration.key(for: $0.labelName) < ActionLabelRuleConfiguration.key(for: $1.labelName) }
        return copy
    }

    func searchQuery(for rule: ActionLabelRuleConfiguration) throws -> String {
        let valid = try validated()
        guard let rule = valid.rules.first(where: { $0.id == rule.id }) else {
            throw ActionConfigurationError.invalidLabel
        }
        let escaped = rule.labelName.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "org:\(valid.organization) is:pr is:open label:\"\(escaped)\""
    }

    var revision: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canonical = (try? validated()) ?? self
        let data = (try? encoder.encode(canonical)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = envelope["schemaVersion"] as? Int else { return .blank }
        if version == Self.schemaVersion,
           let stored = try? JSONDecoder().decode(Self.self, from: data),
           let value = try? stored.validated() { return value }
        guard version == 1 || version == 2,
              let legacy = try? JSONDecoder().decode(LegacyConfiguration.self, from: data) else { return .blank }
        let rules = legacy.rules.compactMap { rule -> ActionLabelRuleConfiguration? in
            guard rule.isEnabled else { return nil }
            return ActionLabelRuleConfiguration(labelName: rule.labelName, notificationLevel: .persistent)
        }
        let migrated = Self(schemaVersion: Self.schemaVersion, organization: "Keeper-Dating", rules: rules)
        return (try? migrated.validated()) ?? .blank
    }

    func save(defaults: UserDefaults = .standard) throws {
        let value = try validated()
        defaults.set(try JSONEncoder().encode(value), forKey: Self.storageKey)
    }
}

private struct LegacyConfiguration: Codable {
    let schemaVersion: Int
    let organization: String
    let rules: [LegacyActionRuleConfiguration]
}

enum GitHubPullRequestURL {
    static func isSafe(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && url.path.range(of: #"^/[^/]+/[^/]+/pull/[0-9]+/?$"#, options: .regularExpression) != nil
    }
}

struct AttentionBrowserTarget: Equatable, Sendable {
    let itemID: String
    let revisionID: String
    let url: URL
}

enum AttentionBrowserPlan {
    static func targets(for items: [AttentionItem]) -> [AttentionBrowserTarget] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard item.isActive, let revisionID = item.revisionID,
                  GitHubPullRequestURL.isSafe(item.url) else { return nil }
            let identity = item.url.path.hasSuffix("/")
                ? String(item.url.path.dropLast()).lowercased()
                : item.url.path.lowercased()
            guard seen.insert(identity).inserted else { return nil }
            return AttentionBrowserTarget(itemID: item.id, revisionID: revisionID, url: item.url)
        }
    }

    static func urls(for items: [AttentionItem]) -> [URL] {
        targets(for: items).map(\.url)
    }
}

struct AttentionSeenMutation: Sendable {
    let items: [AttentionItem]
    let markedItemIDs: [String]
}

enum AttentionAcknowledgementPlan {
    static func markingSeen(
        targets: [AttentionBrowserTarget],
        in items: [AttentionItem],
        at date: Date
    ) -> AttentionSeenMutation {
        let revisions = Dictionary(
            targets.map { ($0.itemID, $0.revisionID) },
            uniquingKeysWith: { first, _ in first }
        )
        var updated = items
        var markedItemIDs: [String] = []
        for index in updated.indices {
            let item = updated[index]
            guard item.isActive, let revision = revisions[item.id], item.revisionID == revision else { continue }
            let mutation = item.markingSeen(revision: revision, at: date)
            guard mutation.didMutate else { continue }
            updated[index] = mutation.item
            markedItemIDs.append(item.id)
        }
        return AttentionSeenMutation(items: updated, markedItemIDs: markedItemIDs)
    }
}

struct ActionLabelApplication: Codable, Hashable, Identifiable, Sendable {
    let pullRequestID: String
    let labelKey: String
    let labelID: String
    let labelEventID: String
    let labelName: String
    let colorHex: String
    let notificationLevel: NotificationLevel
    let appliedAt: Date
    var seenAt: Date?
    var dismissedAt: Date?
    var deliveredAt: Date? = nil

    var id: String { labelEventID }
    // `dismissedAt` is retained only to decode caches written by v0.2.0. It no
    // longer controls visibility; only the label's presence on GitHub does.
    var isUnseen: Bool { seenAt == nil }
    var normalizedColorHex: String? {
        colorHex.range(of: #"^[0-9A-Fa-f]{6}$"#, options: .regularExpression) == nil ? nil : colorHex.uppercased()
    }

    private enum CodingKeys: String, CodingKey {
        case pullRequestID, labelKey, ruleID, labelID, labelEventID, labelName, colorHex
        case notificationLevel, appliedAt, seenAt, dismissedAt, deliveredAt
    }

    init(
        pullRequestID: String,
        labelKey: String,
        labelID: String,
        labelEventID: String,
        labelName: String,
        colorHex: String,
        notificationLevel: NotificationLevel = .persistent,
        appliedAt: Date,
        seenAt: Date?,
        dismissedAt: Date?,
        deliveredAt: Date? = nil
    ) {
        self.pullRequestID = pullRequestID
        self.labelKey = ActionLabelRuleConfiguration.key(for: labelKey)
        self.labelID = labelID
        self.labelEventID = labelEventID
        self.labelName = labelName
        self.colorHex = colorHex
        self.notificationLevel = notificationLevel
        self.appliedAt = appliedAt
        self.seenAt = seenAt
        self.dismissedAt = dismissedAt
        self.deliveredAt = deliveredAt
    }

    init(
        pullRequestID: String,
        ruleID: ActionRuleID,
        labelID: String,
        labelEventID: String,
        labelName: String,
        colorHex: String,
        appliedAt: Date,
        seenAt: Date?,
        dismissedAt: Date?,
        deliveredAt: Date? = nil
    ) {
        self.init(
            pullRequestID: pullRequestID,
            labelKey: "legacy:\(ruleID.rawValue)",
            labelID: labelID,
            labelEventID: labelEventID,
            labelName: labelName,
            colorHex: colorHex,
            notificationLevel: .persistent,
            appliedAt: appliedAt,
            seenAt: seenAt,
            dismissedAt: dismissedAt,
            deliveredAt: deliveredAt
        )
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pullRequestID = try values.decode(String.self, forKey: .pullRequestID)
        if let key = try values.decodeIfPresent(String.self, forKey: .labelKey) {
            labelKey = ActionLabelRuleConfiguration.key(for: key)
        } else if let legacy = try values.decodeIfPresent(ActionRuleID.self, forKey: .ruleID) {
            labelKey = "legacy:\(legacy.rawValue)"
        } else {
            labelKey = "legacy:unknown"
        }
        labelID = try values.decode(String.self, forKey: .labelID)
        labelEventID = try values.decode(String.self, forKey: .labelEventID)
        labelName = try values.decode(String.self, forKey: .labelName)
        colorHex = try values.decode(String.self, forKey: .colorHex)
        notificationLevel = try values.decodeIfPresent(NotificationLevel.self, forKey: .notificationLevel) ?? .persistent
        appliedAt = try values.decode(Date.self, forKey: .appliedAt)
        seenAt = try values.decodeIfPresent(Date.self, forKey: .seenAt)
        dismissedAt = try values.decodeIfPresent(Date.self, forKey: .dismissedAt)
        deliveredAt = try values.decodeIfPresent(Date.self, forKey: .deliveredAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(pullRequestID, forKey: .pullRequestID)
        try values.encode(labelKey, forKey: .labelKey)
        try values.encode(labelID, forKey: .labelID)
        try values.encode(labelEventID, forKey: .labelEventID)
        try values.encode(labelName, forKey: .labelName)
        try values.encode(colorHex, forKey: .colorHex)
        try values.encode(notificationLevel, forKey: .notificationLevel)
        try values.encode(appliedAt, forKey: .appliedAt)
        try values.encodeIfPresent(seenAt, forKey: .seenAt)
        try values.encodeIfPresent(dismissedAt, forKey: .dismissedAt)
        try values.encodeIfPresent(deliveredAt, forKey: .deliveredAt)
    }
}

enum ActionAttentionMerger {
    static func mergePresentation(
        incoming: [ActionLabelApplication],
        previous: [ActionLabelApplication]
    ) -> [ActionLabelApplication] {
        let prior = Dictionary(previous.map { ($0.labelEventID, $0) }, uniquingKeysWith: { first, _ in first })
        return incoming.map { application in
            guard let old = prior[application.labelEventID] else { return application }
            var result = application
            result.seenAt = old.seenAt
            result.dismissedAt = old.dismissedAt
            result.deliveredAt = old.deliveredAt
            return result
        }
    }
}

enum ActionNotificationIdentifier {
    static func value(accountID: String, pullRequestID: String) -> String {
        let digest = SHA256.hash(data: Data("\(accountID)\0\(pullRequestID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "pr-throughput.action.\(digest.prefix(32))"
    }
}
