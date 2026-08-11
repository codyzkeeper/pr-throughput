import CryptoKit
import Foundation

enum ActionRuleID: String, Codable, CaseIterable, Sendable {
    case decide
    case invokeR2
    case assignReviewer

    var priority: Int {
        switch self {
        case .decide: 0
        case .invokeR2: 1
        case .assignReviewer: 2
        }
    }

    var displayName: String {
        switch self {
        case .decide: "Decision"
        case .invokeR2: "Invoke R2"
        case .assignReviewer: "Assign reviewer"
        }
    }
}

struct ActionRuleConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: ActionRuleID
    var labelName: String
    var isEnabled: Bool
}

enum ActionConfigurationError: LocalizedError, Equatable {
    case invalidOrganization
    case invalidRules
    case invalidLabel(ActionRuleID)

    var errorDescription: String? {
        switch self {
        case .invalidOrganization: "Enter a GitHub organization name using letters, numbers, or hyphens."
        case .invalidRules: "The three notification rules are incomplete or duplicated."
        case let .invalidLabel(rule): "Enter a valid GitHub label for \(rule.displayName)."
        }
    }
}

struct ActionNotificationConfiguration: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let storageKey = "notification.actionLabels.configuration.v1"

    let schemaVersion: Int
    var organization: String
    var rules: [ActionRuleConfiguration]

    static let blank = ActionNotificationConfiguration(
        schemaVersion: schemaVersion,
        organization: "",
        rules: ActionRuleID.allCases.map { ActionRuleConfiguration(id: $0, labelName: "", isEnabled: false) }
    )

    var enabledRules: [ActionRuleConfiguration] {
        rules.filter(\.isEnabled).sorted { $0.id.priority < $1.id.priority }
    }

    var isConfigured: Bool {
        (try? validated()) != nil && !enabledRules.isEmpty
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              Set(rules.map(\.id)) == Set(ActionRuleID.allCases),
              rules.count == ActionRuleID.allCases.count else { throw ActionConfigurationError.invalidRules }
        let organization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard organization.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"#, options: .regularExpression) != nil else {
            throw ActionConfigurationError.invalidOrganization
        }
        var copy = self
        copy.organization = organization
        var enabledNames = Set<String>()
        for index in copy.rules.indices {
            copy.rules[index].labelName = copy.rules[index].labelName.trimmingCharacters(in: .whitespacesAndNewlines)
            if copy.rules[index].isEnabled {
                let value = copy.rules[index].labelName
                guard !value.isEmpty, value.count <= 50,
                      value.rangeOfCharacter(from: .controlCharacters) == nil,
                      !value.contains("\""), !value.contains("\\") else {
                    throw ActionConfigurationError.invalidLabel(copy.rules[index].id)
                }
                guard enabledNames.insert(value.lowercased()).inserted else {
                    throw ActionConfigurationError.invalidRules
                }
            }
        }
        copy.rules.sort { $0.id.priority < $1.id.priority }
        return copy
    }

    func searchQuery(for rule: ActionRuleConfiguration) throws -> String {
        let valid = try validated()
        guard let rule = valid.rules.first(where: { $0.id == rule.id }), rule.isEnabled else {
            throw ActionConfigurationError.invalidLabel(rule.id)
        }
        return #"org:\#(valid.organization) is:pr is:open label:\"\#(rule.labelName)\""#
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
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return .blank }
        return value
    }

    func save(defaults: UserDefaults = .standard) throws {
        let value = try validated()
        defaults.set(try JSONEncoder().encode(value), forKey: Self.storageKey)
    }
}

struct ActionLabelApplication: Codable, Hashable, Identifiable, Sendable {
    let pullRequestID: String
    let ruleID: ActionRuleID
    let labelID: String
    let labelEventID: String
    let labelName: String
    let colorHex: String
    let appliedAt: Date
    var seenAt: Date?
    var dismissedAt: Date?
    var deliveredAt: Date? = nil

    var id: String { labelEventID }
    var isUnseen: Bool { dismissedAt == nil && seenAt == nil }
    var normalizedColorHex: String? {
        colorHex.range(of: #"^[0-9A-Fa-f]{6}$"#, options: .regularExpression) == nil ? nil : colorHex.uppercased()
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
