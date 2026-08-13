import Foundation

enum ReviewDecisionState: String, Codable, Sendable {
    case approved
    case changesRequested
    case commented
    case dismissed
    case pending
}

enum TimelineEventKind: Codable, Hashable, Sendable {
    case assigned(GitHubUser)
    case unassigned(GitHubUser)
    case reviewRequested(GitHubUser)
    case reviewRequestRemoved(GitHubUser)
    case reviewed(reviewer: GitHubUser, state: ReviewDecisionState)
    case readyForReview
    case convertedToDraft
    case reopened
    case merged
    case closed
}

struct TimelineEvent: Codable, Hashable, Sendable {
    static let sourceSchemaVersion = 3

    let id: String
    let pullRequestID: String
    let kind: TimelineEventKind
    let at: Date
}
