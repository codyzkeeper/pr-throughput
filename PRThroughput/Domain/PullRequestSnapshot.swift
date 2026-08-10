import Foundation

enum PullRequestState: String, Codable, Sendable {
    case open
    case closed
    case merged
}

struct PullRequestSnapshot: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let repository: String
    let number: Int
    let title: String
    let url: URL
    let authorID: String
    let eligibleAt: Date?
    let updatedAt: Date
    let isDraft: Bool
    let state: PullRequestState
    var mergedAt: Date?
    var closedAt: Date?

    init(
        id: String,
        repository: String,
        number: Int,
        title: String,
        url: URL,
        authorID: String,
        eligibleAt: Date?,
        updatedAt: Date = .distantPast,
        isDraft: Bool,
        state: PullRequestState,
        mergedAt: Date? = nil,
        closedAt: Date? = nil
    ) {
        self.id = id
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
        self.authorID = authorID
        self.eligibleAt = eligibleAt
        self.updatedAt = updatedAt
        self.isDraft = isDraft
        self.state = state
        self.mergedAt = mergedAt
        self.closedAt = closedAt
    }
}
