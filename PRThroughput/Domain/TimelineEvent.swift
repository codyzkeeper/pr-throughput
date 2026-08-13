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
    static let sourceSchemaVersion = 4

    let id: String
    let pullRequestID: String
    let kind: TimelineEventKind
    let at: Date
    /// Stable position in GitHub's timeline connection. GitHub timestamps have
    /// second-level collisions, so timestamps alone cannot reconstruct state.
    let sourceOrder: Int

    init(id: String, pullRequestID: String, kind: TimelineEventKind, at: Date, sourceOrder: Int = 0) {
        self.id = id
        self.pullRequestID = pullRequestID
        self.kind = kind
        self.at = at
        self.sourceOrder = sourceOrder
    }

    private enum CodingKeys: String, CodingKey { case id, pullRequestID, kind, at, sourceOrder }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        pullRequestID = try values.decode(String.self, forKey: .pullRequestID)
        kind = try values.decode(TimelineEventKind.self, forKey: .kind)
        at = try values.decode(Date.self, forKey: .at)
        sourceOrder = try values.decodeIfPresent(Int.self, forKey: .sourceOrder) ?? 0
    }
}
