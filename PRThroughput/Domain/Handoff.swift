import Foundation

enum HandoffOutcome: Codable, Hashable, Sendable {
    case pending
    case approved(at: Date, reviewID: String)
    case changesRequested(at: Date, reviewID: String)
    case withdrawn(at: Date, reason: String)
}

struct Handoff: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let pullRequestID: String
    let reviewerID: String
    let at: Date
    var outcome: HandoffOutcome
}
