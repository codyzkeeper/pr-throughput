import Foundation

enum GitHubActorKind: String, Codable, Sendable {
    case user
    case team
    case bot
    case mannequin
    case enterpriseTeam
    case unknown
}

struct GitHubUser: Codable, Hashable, Sendable {
    let id: String
    let login: String
    let kind: GitHubActorKind
}
