import CryptoKit
import Foundation

struct GitHubRateState: Codable, Equatable, Sendable {
    let remaining: Int?
    let resetAt: Date?
}

enum GitHubAPIError: LocalizedError {
    case invalidResponse
    case unauthorized
    case rateLimited(resetAt: Date?)
    case server(status: Int, message: String)
    case graphQL([String])
    case incompleteDiscovery(expected: Int, received: Int)
    case unsafeURL
    case unsupportedMentionEndpoint(String)
    case unsafeGraphQLDocument

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "GitHub returned an unreadable response."
        case .unauthorized: "GitHub authorization is invalid or expired."
        case let .rateLimited(reset): "GitHub rate limit reached\(reset.map { "; resets \($0.formatted())" } ?? "")."
        case let .server(status, message): "GitHub request failed (\(status)): \(message)"
        case let .graphQL(messages): messages.joined(separator: "\n")
        case let .incompleteDiscovery(expected, received): "GitHub discovery was incomplete (expected \(expected), received \(received))."
        case .unsafeURL: "Refused a non-GitHub or non-HTTPS API URL."
        case let .unsupportedMentionEndpoint(shape): "Unsupported GitHub mention endpoint shape: \(shape)"
        case .unsafeGraphQLDocument: "Refused a GraphQL document that is not a read-only query."
        }
    }
}

actor GitHubAPI {
    private let token: String
    private let session: URLSession
    private let retryBaseDelay: TimeInterval
    private let decoder: JSONDecoder
    private var blockedUntil: Date?
    private(set) var rateState = GitHubRateState(remaining: nil, resetAt: nil)
    private(set) var notificationPollInterval: TimeInterval = 60

    init(token: String, session: URLSession = .shared, retryBaseDelay: TimeInterval = 0.5) {
        self.token = token
        self.session = session
        self.retryBaseDelay = retryBaseDelay
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func viewer() async throws -> GitHubUser {
        struct ViewerEnvelope: Decodable { let data: ViewerData }
        struct ViewerData: Decodable { let viewer: Viewer }
        struct Viewer: Decodable { let id: String; let login: String }
        let envelope: ViewerEnvelope = try await graphQL(
            query: "query Viewer { viewer { id login } }",
            variables: [:]
        )
        return GitHubUser(id: envelope.data.viewer.id, login: envelope.data.viewer.login, kind: .user)
    }

    func searchPullRequests(query: String) async throws -> [GitHubPullRequestNode] {
        var cursor: String?
        var seenCursors = Set<String>()
        var expected = 0
        var nodes: [GitHubPullRequestNode] = []
        repeat {
            var variables: [String: Any] = ["query": query]
            if let cursor { variables["cursor"] = cursor }
            let envelope: SearchEnvelope = try await graphQL(query: Self.searchQuery, variables: variables)
            expected = envelope.data.search.issueCount
            nodes.append(contentsOf: envelope.data.search.nodes.compactMap { $0.pullRequest })
            if envelope.data.search.pageInfo.hasNextPage {
                guard let next = envelope.data.search.pageInfo.endCursor,
                      seenCursors.insert(next).inserted else { throw GitHubAPIError.invalidResponse }
                cursor = next
            } else {
                cursor = nil
            }
            if nodes.count >= 1_000, nodes.count < expected { throw GitHubAPIError.incompleteDiscovery(expected: expected, received: nodes.count) }
        } while cursor != nil
        guard nodes.count == expected else {
            throw GitHubAPIError.incompleteDiscovery(expected: expected, received: nodes.count)
        }
        return nodes
    }

    func actionPullRequests(
        configuration: ActionNotificationConfiguration,
        candidateIDs: Set<String>
    ) async throws -> GitHubActionDiscovery {
        let configuration = try configuration.validated()
        guard !configuration.enabledRules.isEmpty else {
            return GitHubActionDiscovery(pullRequests: [], searchDisagreementCount: 0)
        }

        var searchNodes: [String: GitHubPullRequestNode] = [:]
        for rule in configuration.enabledRules {
            for node in try await searchPullRequests(query: configuration.searchQuery(for: rule)) {
                searchNodes[node.id] = node
            }
        }
        let allIDs = Set(searchNodes.keys).union(candidateIDs)
        var direct: [GitHubActionPullRequest] = []
        for chunk in allIDs.sorted().chunked(into: 20) {
            direct.append(contentsOf: try await directActionPullRequests(ids: chunk, configuration: configuration))
        }

        let directIDs = Set(direct.map(\.id))
        let disagreement = searchNodes.keys.filter { !directIDs.contains($0) }.count
            + directIDs.filter { !searchNodes.keys.contains($0) }.count
        return GitHubActionDiscovery(
            pullRequests: direct.sorted { ($0.repository, $0.number) < ($1.repository, $1.number) },
            searchDisagreementCount: disagreement
        )
    }

    private func directActionPullRequests(
        ids: [String],
        configuration: ActionNotificationConfiguration
    ) async throws -> [GitHubActionPullRequest] {
        guard !ids.isEmpty else { return [] }
        let envelope: ActionNodesEnvelope = try await graphQL(
            query: Self.actionNodesQuery,
            variables: ["ids": ids]
        )
        var result: [GitHubActionPullRequest] = []
        for pull in envelope.data.nodes.compactMap({ $0 }) {
            guard pull.state == "OPEN",
                  pull.repository.nameWithOwner.split(separator: "/").first.map(String.init)?
                    .caseInsensitiveCompare(configuration.organization) == .orderedSame,
                  Self.isSafePullRequestURL(pull.url) else { continue }
            guard !pull.labels.pageInfo.hasNextPage else {
                throw GitHubAPIError.incompleteDiscovery(expected: pull.labels.nodes.count + 1, received: pull.labels.nodes.count)
            }

            let rulesByName = Dictionary(
                uniqueKeysWithValues: configuration.enabledRules.map { ($0.labelName.lowercased(), $0) }
            )
            let current = pull.labels.nodes.compactMap { label -> (ActionRuleConfiguration, ActionLabelNode)? in
                guard let rule = rulesByName[label.name.lowercased()] else { return nil }
                return (rule, label)
            }
            guard !current.isEmpty else { continue }

            var transitions = pull.timelineItems.nodes
            var didPaginateTransitions = false
            var cursor = pull.timelineItems.pageInfo.hasPreviousPage ? pull.timelineItems.pageInfo.startCursor : nil
            var unresolved = Set(current.map { $0.1.id })
            unresolved.subtract(transitions.map { $0.label.id })
            var seenCursors = Set<String>()
            while !unresolved.isEmpty, let currentCursor = cursor {
                didPaginateTransitions = true
                guard seenCursors.insert(currentCursor).inserted else { throw GitHubAPIError.invalidResponse }
                let page = try await actionTransitionPage(id: pull.id, before: currentCursor)
                transitions.append(contentsOf: page.nodes)
                unresolved.subtract(page.nodes.map { $0.label.id })
                cursor = page.pageInfo.hasPreviousPage ? page.pageInfo.startCursor : nil
            }
            guard unresolved.isEmpty else { throw GitHubAPIError.invalidResponse }

            if didPaginateTransitions {
                let verify: ActionCurrentEnvelope = try await graphQL(
                    query: Self.actionCurrentQuery,
                    variables: ["id": pull.id]
                )
                guard let currentPull = verify.data.node,
                      currentPull.updatedAt == pull.updatedAt,
                      currentPull.state == pull.state,
                      currentPull.repository.nameWithOwner == pull.repository.nameWithOwner,
                      !currentPull.labels.pageInfo.hasNextPage,
                      Set(currentPull.labels.nodes.map { "\($0.id)\0\($0.name)\0\($0.color)" })
                        == Set(pull.labels.nodes.map { "\($0.id)\0\($0.name)\0\($0.color)" }) else {
                    throw GitHubAPIError.invalidResponse
                }
            }

            var applications: [ActionLabelApplication] = []
            for (rule, label) in current {
                let latest = transitions
                    .filter { $0.label.id == label.id }
                    .max { $0.createdAt < $1.createdAt }
                guard let latest, latest.typeName == "LabeledEvent",
                      label.color.range(of: #"^[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else {
                    throw GitHubAPIError.invalidResponse
                }
                applications.append(ActionLabelApplication(
                    pullRequestID: pull.id,
                    ruleID: rule.id,
                    labelID: label.id,
                    labelEventID: latest.id,
                    labelName: label.name,
                    colorHex: label.color.uppercased(),
                    appliedAt: latest.createdAt,
                    seenAt: nil,
                    dismissedAt: nil
                ))
            }
            result.append(GitHubActionPullRequest(
                id: pull.id, number: pull.number, title: pull.title, url: pull.url,
                repository: pull.repository.nameWithOwner, updatedAt: pull.updatedAt,
                applications: applications
            ))
        }
        return result
    }

    private func actionTransitionPage(id: String, before: String) async throws -> ActionTimelineConnection {
        let envelope: ActionTimelineEnvelope = try await graphQL(
            query: Self.actionTimelineQuery,
            variables: ["id": id, "before": before]
        )
        guard let node = envelope.data.node else { throw GitHubAPIError.invalidResponse }
        return node.timelineItems
    }

    private static func isSafePullRequestURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
            && url.user == nil && url.password == nil
            && url.path.range(of: #"^/[^/]+/[^/]+/pull/[0-9]+/?$"#, options: .regularExpression) != nil
    }

    func timeline(pullRequestID: String) async throws -> [TimelineEvent] {
        var cursor: String?
        var seenCursors = Set<String>()
        var events: [TimelineEvent] = []
        repeat {
            var variables: [String: Any] = ["id": pullRequestID]
            if let cursor { variables["cursor"] = cursor }
            let envelope: TimelineEnvelope = try await graphQL(query: Self.timelineQuery, variables: variables)
            guard let pull = envelope.data.node else { throw GitHubAPIError.invalidResponse }
            events.append(contentsOf: pull.timelineItems.nodes.compactMap { $0?.event(pullRequestID: pullRequestID) })
            if pull.timelineItems.pageInfo.hasNextPage {
                guard let next = pull.timelineItems.pageInfo.endCursor,
                      seenCursors.insert(next).inserted else { throw GitHubAPIError.invalidResponse }
                cursor = next
            } else {
                cursor = nil
            }
        } while cursor != nil
        return Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.at < $1.at }
    }

    func recentTimeline(pullRequestID: String) async throws -> RecentPullRequestUpdate {
        let envelope: TimelineEnvelope = try await graphQL(
            query: Self.recentTimelineQuery,
            variables: ["id": pullRequestID]
        )
        guard let pull = envelope.data.node,
              let updatedAt = pull.updatedAt,
              let isDraft = pull.isDraft,
              let state = pull.state else { throw GitHubAPIError.invalidResponse }
        return RecentPullRequestUpdate(
            id: pullRequestID,
            updatedAt: updatedAt,
            isDraft: isDraft,
            state: state,
            mergedAt: pull.mergedAt,
            closedAt: pull.closedAt,
            events: pull.timelineItems.nodes.compactMap { $0?.event(pullRequestID: pullRequestID) }
                .sorted { $0.at < $1.at }
        )
    }

    func notifications(since: Date?) async throws -> [GitHubNotificationThread] {
        var components = URLComponents(string: "https://api.github.com/notifications")!
        var items = [URLQueryItem(name: "all", value: "true"), URLQueryItem(name: "participating", value: "true"), URLQueryItem(name: "per_page", value: "50")]
        if let since { items.append(URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since))) }
        components.queryItems = items
        guard let initialURL = components.url else { throw GitHubAPIError.invalidResponse }
        var nextURL: URL? = initialURL
        var seenURLs = Set<URL>()
        var threads: [GitHubNotificationThread] = []
        while let url = nextURL {
            guard isSafeAPIURL(url) else { throw GitHubAPIError.unsafeURL }
            guard seenURLs.insert(url).inserted, seenURLs.count <= 100 else { throw GitHubAPIError.invalidResponse }
            var request = authorizedRequest(url: url)
            request.httpMethod = "GET"
            let (data, response) = try await data(for: request)
            try updateAndValidate(response: response, data: data)
            guard let http = response as? HTTPURLResponse else { throw GitHubAPIError.invalidResponse }
            if let seconds = http.value(forHTTPHeaderField: "x-poll-interval").flatMap(TimeInterval.init) {
                notificationPollInterval = max(60, seconds)
            }
            threads.append(contentsOf: try decoder.decode([GitHubNotificationThread].self, from: data))
            nextURL = try nextPageURL(from: http)
        }
        return threads
    }

    func comment(url: URL) async throws -> GitHubComment {
        guard isSafeAPIURL(url) else { throw GitHubAPIError.unsafeURL }
        return try await restGET(url: url)
    }

    func mentionContents(thread: GitHubNotificationThread) async throws -> [GitHubMentionContent] {
        guard let pullURL = thread.subject.url,
              isSafeAPIURL(pullURL),
              let number = Int(pullURL.lastPathComponent) else { throw GitHubAPIError.unsafeURL }
        let nameParts = thread.repository.fullName.split(separator: "/", omittingEmptySubsequences: true)
        guard nameParts.count == 2 else { throw GitHubAPIError.invalidResponse }

        if let latestCommentURL = thread.subject.latestCommentURL {
            guard isSafeAPIURL(latestCommentURL) else { throw GitHubAPIError.unsafeURL }
            guard let source = mentionSource(
                for: latestCommentURL,
                pullNumber: number
            ) else {
                throw GitHubAPIError.unsupportedMentionEndpoint(sanitizedEndpointShape(latestCommentURL))
            }
            if source == .pullRequest {
                let pull: GitHubPullContent = try await restGET(url: latestCommentURL)
                return pull.mentionContent(number: number).map { [$0] } ?? []
            }
            let content: GitHubBodyContent = try await restGET(url: latestCommentURL)
            return content.mentionContent(source: source).map { [$0] } ?? []
        }

        // When GitHub provides no comment source, the notification can only be
        // verified against the PR body. Its body digest is stable across unrelated
        // updated_at changes, preventing false reactivation.
        let pull: GitHubPullContent = try await restGET(url: pullURL)
        return pull.mentionContent(number: number).map { [$0] } ?? []
    }

    private func restGET<T: Decodable>(url: URL) async throws -> T {
        var request = authorizedRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await data(for: request)
        try updateAndValidate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func mentionSource(
        for url: URL,
        pullNumber: Int
    ) -> GitHubMentionSource? {
        guard isSafeAPIURL(url) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        // The repository in a notification URL can retain its pre-rename spelling.
        // GitHub is the authenticated source, so constrain host and endpoint shape
        // without requiring its path to equal the current full_name byte-for-byte.
        guard parts.count >= 4, parts[0].caseInsensitiveCompare("repos") == .orderedSame else { return nil }
        let suffix = Array(parts.dropFirst(3))
        if suffix.count == 3, suffix[0] == "issues", suffix[1] == "comments", Int(suffix[2]) != nil {
            return .issueComment
        }
        if suffix.count == 3, suffix[0] == "pulls", suffix[1] == "comments", Int(suffix[2]) != nil {
            return .reviewComment
        }
        if suffix.count == 4, suffix[0] == "pulls", Int(suffix[1]) == pullNumber,
           suffix[2] == "reviews", Int(suffix[3]) != nil {
            return .review
        }
        if suffix.count == 2, suffix[0] == "comments", Int(suffix[1]) != nil {
            return .commitComment
        }
        if suffix.count == 2, suffix[0] == "pulls", Int(suffix[1]) == pullNumber {
            return .pullRequest
        }
        return nil
    }

    private func sanitizedEndpointShape(_ url: URL) -> String {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0].caseInsensitiveCompare("repos") == .orderedSame else {
            return "/unsupported"
        }
        let suffix = parts.dropFirst(3).map { Int($0) == nil ? $0 : ":id" }
        return "/repos/:owner/:repository/" + suffix.joined(separator: "/")
    }

    private func graphQL<T: Decodable>(query: String, variables: [String: Any]) async throws -> T {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("query") else {
            throw GitHubAPIError.unsafeGraphQLDocument
        }
        var request = authorizedRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await data(for: request)
        try updateAndValidate(response: response, data: data)
        if let errors = try? decoder.decode(GraphQLErrors.self, from: data), !errors.errors.isEmpty {
            let messages = errors.errors.map(\.message)
            if rateState.remaining == 0 || messages.contains(where: Self.isRateLimitMessage) {
                let retryAt = blockRequests(until: rateState.resetAt)
                throw GitHubAPIError.rateLimited(resetAt: retryAt)
            }
            throw GitHubAPIError.graphQL(messages)
        }
        return try decoder.decode(T.self, from: data)
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PRThroughput/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        for attempt in 0..<4 {
            try validateRequestTiming()
            do {
                return try await session.data(for: request)
            } catch let error as URLError where attempt < 3 && Self.isTransient(error) {
                let delay = retryBaseDelay * pow(2, Double(attempt))
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw URLError(.unknown)
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed, .secureConnectionFailed:
            true
        default:
            false
        }
    }

    private func updateAndValidate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw GitHubAPIError.invalidResponse }
        let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init)
        let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        let retryAt = http.value(forHTTPHeaderField: "retry-after")
            .flatMap(TimeInterval.init)
            .flatMap { $0.isFinite && $0 >= 0 ? Date().addingTimeInterval($0) : nil }
        rateState = GitHubRateState(remaining: remaining, resetAt: retryAt ?? reset)
        if remaining == 0 { _ = blockRequests(until: reset) }
        if http.statusCode == 401 { throw GitHubAPIError.unauthorized }
        if http.statusCode == 403 || http.statusCode == 429 {
            let message = (try? decoder.decode(GitHubErrorMessage.self, from: data).message) ?? "Unknown error"
            if remaining == 0 || retryAt != nil || http.statusCode == 429 || Self.isRateLimitMessage(message) {
                let blockedUntil = blockRequests(until: retryAt ?? reset)
                throw GitHubAPIError.rateLimited(resetAt: blockedUntil)
            }
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(GitHubErrorMessage.self, from: data).message) ?? "Unknown error"
            throw GitHubAPIError.server(status: http.statusCode, message: message)
        }
    }

    private static func isRateLimitMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("rate limit") || normalized.contains("abuse detection")
    }

    private func validateRequestTiming(now: Date = Date()) throws {
        guard let blockedUntil else { return }
        if blockedUntil > now { throw GitHubAPIError.rateLimited(resetAt: blockedUntil) }
        self.blockedUntil = nil
    }

    @discardableResult
    private func blockRequests(until suggestedDate: Date?, now: Date = Date()) -> Date {
        let futureSuggestion = suggestedDate.flatMap { $0 > now ? $0 : nil }
        let retryAt = futureSuggestion ?? now.addingTimeInterval(60)
        let result = max(blockedUntil ?? .distantPast, retryAt)
        blockedUntil = result
        rateState = GitHubRateState(remaining: rateState.remaining, resetAt: result)
        return result
    }

    private func nextPageURL(from response: HTTPURLResponse) throws -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for entry in link.split(separator: ",") {
            let parts = entry.split(separator: ";", omittingEmptySubsequences: true)
            guard parts.dropFirst().contains(where: { $0.trimmingCharacters(in: .whitespaces) == #"rel="next""# }) else {
                continue
            }
            let value = parts[0].trimmingCharacters(in: .whitespaces)
            guard value.first == "<", value.last == ">",
                  let url = URL(string: String(value.dropFirst().dropLast())),
                  isSafeAPIURL(url) else { throw GitHubAPIError.unsafeURL }
            return url
        }
        return nil
    }

    private func isSafeAPIURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host == "api.github.com"
            && (url.port == nil || url.port == 443)
            && url.user == nil
            && url.password == nil
    }

    private static let searchQuery = #"""
    query SearchPullRequests($query: String!, $cursor: String) {
      search(type: ISSUE, query: $query, first: 100, after: $cursor) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on PullRequest {
            id number title url createdAt updatedAt isDraft state mergedAt closedAt
            author { __typename login ... on User { id } }
            repository { nameWithOwner }
          }
        }
      }
    }
    """#

    private static let timelineQuery = #"""
    query PullRequestTimeline($id: ID!, $cursor: String) {
      node(id: $id) {
        ... on PullRequest {
          timelineItems(first: 100, after: $cursor, itemTypes: [ASSIGNED_EVENT, UNASSIGNED_EVENT, REVIEW_REQUESTED_EVENT, REVIEW_REQUEST_REMOVED_EVENT, REVIEW_DISMISSED_EVENT, PULL_REQUEST_REVIEW, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, MERGED_EVENT, CLOSED_EVENT]) {
            pageInfo { hasNextPage endCursor }
            nodes {
              __typename
              ... on AssignedEvent { id createdAt assignee { __typename ... on User { id login } ... on Bot { id login } } }
              ... on UnassignedEvent { id createdAt assignee { __typename ... on User { id login } ... on Bot { id login } } }
              ... on ReviewRequestedEvent { id createdAt requestedReviewer { __typename ... on User { id login } ... on Bot { id login } } }
              ... on ReviewRequestRemovedEvent { id createdAt requestedReviewer { __typename ... on User { id login } ... on Bot { id login } } }
              ... on PullRequestReview { id submittedAt state author { __typename login ... on User { id } } }
              ... on ReviewDismissedEvent {
                id createdAt previousReviewState
                review { id submittedAt author { __typename login ... on User { id } } }
              }
              ... on ReadyForReviewEvent { id createdAt }
              ... on ConvertToDraftEvent { id createdAt }
              ... on MergedEvent { id createdAt }
              ... on ClosedEvent { id createdAt }
            }
          }
        }
      }
    }
    """#

    private static let recentTimelineQuery = #"""
    query PullRequestRecentTimeline($id: ID!) {
      node(id: $id) {
        ... on PullRequest {
          updatedAt isDraft state mergedAt closedAt
          timelineItems(last: 100, itemTypes: [ASSIGNED_EVENT, UNASSIGNED_EVENT, REVIEW_REQUESTED_EVENT, REVIEW_REQUEST_REMOVED_EVENT, REVIEW_DISMISSED_EVENT, PULL_REQUEST_REVIEW, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, MERGED_EVENT, CLOSED_EVENT]) {
            pageInfo { hasNextPage endCursor }
            nodes {
              __typename
              ... on AssignedEvent { id createdAt assignee { __typename ... on User { id login } ... on Bot { id login } } }
              ... on UnassignedEvent { id createdAt assignee { __typename ... on User { id login } ... on Bot { id login } } }
              ... on ReviewRequestedEvent { id createdAt requestedReviewer { __typename ... on User { id login } ... on Bot { id login } } }
              ... on ReviewRequestRemovedEvent { id createdAt requestedReviewer { __typename ... on User { id login } ... on Bot { id login } } }
              ... on PullRequestReview { id submittedAt state author { __typename login ... on User { id } } }
              ... on ReviewDismissedEvent {
                id createdAt previousReviewState
                review { id submittedAt author { __typename login ... on User { id } } }
              }
              ... on ReadyForReviewEvent { id createdAt }
              ... on ConvertToDraftEvent { id createdAt }
              ... on MergedEvent { id createdAt }
              ... on ClosedEvent { id createdAt }
            }
          }
        }
      }
    }
    """#

    private static let actionNodesQuery = #"""
    query ActionPullRequests($ids: [ID!]!) {
      nodes(ids: $ids) {
        ... on PullRequest {
          id number title url updatedAt state isDraft
          repository { nameWithOwner }
          labels(first: 100) {
            pageInfo { hasNextPage endCursor hasPreviousPage startCursor }
            nodes { id name color }
          }
          timelineItems(last: 100, itemTypes: [LABELED_EVENT, UNLABELED_EVENT]) {
            pageInfo { hasNextPage endCursor hasPreviousPage startCursor }
            nodes {
              __typename
              ... on LabeledEvent { id createdAt label { id name color } }
              ... on UnlabeledEvent { id createdAt label { id name color } }
            }
          }
        }
      }
    }
    """#

    private static let actionTimelineQuery = #"""
    query ActionPullRequestTimeline($id: ID!, $before: String!) {
      node(id: $id) {
        ... on PullRequest {
          timelineItems(last: 100, before: $before, itemTypes: [LABELED_EVENT, UNLABELED_EVENT]) {
            pageInfo { hasNextPage endCursor hasPreviousPage startCursor }
            nodes {
              __typename
              ... on LabeledEvent { id createdAt label { id name color } }
              ... on UnlabeledEvent { id createdAt label { id name color } }
            }
          }
        }
      }
    }
    """#

    private static let actionCurrentQuery = #"""
    query ActionPullRequestCurrent($id: ID!) {
      node(id: $id) {
        ... on PullRequest {
          updatedAt state
          repository { nameWithOwner }
          labels(first: 100) {
            pageInfo { hasNextPage endCursor hasPreviousPage startCursor }
            nodes { id name color }
          }
        }
      }
    }
    """#
}

private struct GraphQLErrors: Decodable { struct Item: Decodable { let message: String }; let errors: [Item] }
private struct GitHubErrorMessage: Decodable { let message: String }

struct GitHubPullRequestNode: Decodable, Sendable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let createdAt: Date
    let updatedAt: Date
    let isDraft: Bool
    let state: String
    let mergedAt: Date?
    let closedAt: Date?
    let author: GitHubActor?
    let repository: Repository

    struct Repository: Decodable, Sendable { let nameWithOwner: String }
}

private struct SearchEnvelope: Decodable {
    let data: DataBody
    struct DataBody: Decodable { let search: Search }
    struct Search: Decodable { let issueCount: Int; let pageInfo: PageInfo; let nodes: [SearchNode] }
    struct SearchNode: Decodable {
        let pullRequest: GitHubPullRequestNode?
        init(from decoder: Decoder) throws { pullRequest = try? GitHubPullRequestNode(from: decoder) }
    }
}

private struct TimelineEnvelope: Decodable {
    let data: DataBody
    struct DataBody: Decodable { let node: Pull? }
    struct Pull: Decodable {
        let updatedAt: Date?
        let isDraft: Bool?
        let state: String?
        let mergedAt: Date?
        let closedAt: Date?
        let timelineItems: Items
    }
    struct Items: Decodable { let pageInfo: PageInfo; let nodes: [GitHubTimelineNode?] }
}

struct RecentPullRequestUpdate: Sendable {
    let id: String
    let updatedAt: Date
    let isDraft: Bool
    let state: String
    let mergedAt: Date?
    let closedAt: Date?
    let events: [TimelineEvent]
}

private struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }

struct GitHubActionDiscovery: Sendable {
    let pullRequests: [GitHubActionPullRequest]
    let searchDisagreementCount: Int
}

struct GitHubActionPullRequest: Sendable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repository: String
    let updatedAt: Date
    let applications: [ActionLabelApplication]
}

private struct ActionNodesEnvelope: Decodable {
    let data: Body
    struct Body: Decodable { let nodes: [ActionPullRequestNode?] }
}

private struct ActionTimelineEnvelope: Decodable {
    let data: Body
    struct Body: Decodable { let node: Node? }
    struct Node: Decodable { let timelineItems: ActionTimelineConnection }
}

private struct ActionCurrentEnvelope: Decodable {
    let data: Body
    struct Body: Decodable { let node: Node? }
    struct Node: Decodable {
        let updatedAt: Date
        let state: String
        let repository: GitHubPullRequestNode.Repository
        let labels: ActionLabelConnection
    }
}

private struct ActionPullRequestNode: Decodable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let updatedAt: Date
    let state: String
    let isDraft: Bool
    let repository: GitHubPullRequestNode.Repository
    let labels: ActionLabelConnection
    let timelineItems: ActionTimelineConnection
}

private struct ActionLabelConnection: Decodable {
    let pageInfo: ActionPageInfo
    let nodes: [ActionLabelNode]
}

private struct ActionTimelineConnection: Decodable {
    let pageInfo: ActionPageInfo
    let nodes: [ActionLabelTransition]
}

private struct ActionPageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
    let hasPreviousPage: Bool
    let startCursor: String?
}

private struct ActionLabelNode: Decodable {
    let id: String
    let name: String
    let color: String
}

private struct ActionLabelTransition: Decodable {
    let typeName: String
    let id: String
    let createdAt: Date
    let label: ActionLabelNode
    enum CodingKeys: String, CodingKey { case typeName = "__typename", id, createdAt, label }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

struct GitHubActor: Decodable, Sendable {
    let typeName: String
    let id: String?
    let login: String?
    let name: String?
    let slug: String?

    enum CodingKeys: String, CodingKey { case typeName = "__typename", id, login, name, slug }

    var user: GitHubUser? {
        let kind: GitHubActorKind = switch typeName {
        case "User": .user
        case "Bot": .bot
        case "Team": .team
        case "Mannequin": .mannequin
        case "EnterpriseTeam": .enterpriseTeam
        default: .unknown
        }
        guard let id else { return nil }
        return GitHubUser(id: id, login: login ?? slug ?? name ?? "unknown", kind: kind)
    }
}

private struct GitHubTimelineNode: Decodable {
    let typeName: String
    let id: String
    let createdAt: Date?
    let submittedAt: Date?
    let state: String?
    let assignee: GitHubActor?
    let requestedReviewer: GitHubActor?
    let author: GitHubActor?
    let previousReviewState: String?
    let review: DismissedReview?

    struct DismissedReview: Decodable {
        let id: String
        let submittedAt: Date?
        let author: GitHubActor?
    }

    enum CodingKeys: String, CodingKey {
        case typeName = "__typename", id, createdAt, submittedAt, state, assignee, requestedReviewer, author,
             previousReviewState, review
    }

    func event(pullRequestID: String) -> TimelineEvent? {
        let date = submittedAt ?? createdAt
        let kind: TimelineEventKind?
        switch typeName {
        case "AssignedEvent": kind = assignee?.user.map(TimelineEventKind.assigned)
        case "UnassignedEvent": kind = assignee?.user.map(TimelineEventKind.unassigned)
        case "ReviewRequestedEvent": kind = requestedReviewer?.user.map(TimelineEventKind.reviewRequested)
        case "ReviewRequestRemovedEvent": kind = requestedReviewer?.user.map(TimelineEventKind.reviewRequestRemoved)
        case "PullRequestReview":
            guard let reviewer = author?.user,
                  let normalized = Self.decisionState(from: state) else { return nil }
            kind = .reviewed(reviewer: reviewer, state: normalized)
        case "ReviewDismissedEvent":
            guard let review,
                  let reviewer = review.author?.user,
                  let submittedAt = review.submittedAt else { return nil }
            guard let normalized = Self.decisionState(from: previousReviewState) else { return nil }
            return TimelineEvent(
                id: review.id,
                pullRequestID: pullRequestID,
                kind: .reviewed(reviewer: reviewer, state: normalized),
                at: submittedAt
            )
        case "ReadyForReviewEvent": kind = .readyForReview
        case "ConvertToDraftEvent": kind = .convertedToDraft
        case "MergedEvent": kind = .merged
        case "ClosedEvent": kind = .closed
        default: kind = nil
        }
        guard let date else { return nil }
        return kind.map { TimelineEvent(id: id, pullRequestID: pullRequestID, kind: $0, at: date) }
    }

    private static func decisionState(from value: String?) -> ReviewDecisionState? {
        switch value {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        default: nil
        }
    }
}

struct GitHubNotificationThread: Decodable, Sendable {
    let id: String
    let reason: String
    let unread: Bool
    let updatedAt: Date
    let subject: Subject
    let repository: Repository

    struct Subject: Decodable, Sendable {
        let title: String
        let url: URL?
        let latestCommentURL: URL?
        let type: String
        enum CodingKeys: String, CodingKey { case title, url, latestCommentURL = "latest_comment_url", type }
    }
    struct Repository: Decodable, Sendable {
        let fullName: String
        let htmlURL: URL
        enum CodingKeys: String, CodingKey { case fullName = "full_name", htmlURL = "html_url" }
    }

    enum CodingKeys: String, CodingKey { case id, reason, unread, updatedAt = "updated_at", subject, repository }
}

struct GitHubComment: Decodable, Sendable {
    let id: Int
    let body: String
    let htmlURL: URL
    enum CodingKeys: String, CodingKey { case id, body, htmlURL = "html_url" }
}

enum GitHubMentionSource: String, Sendable {
    case pullRequest
    case issueComment
    case review
    case reviewComment
    case commitComment
}

struct GitHubMentionContent: Sendable {
    let revisionID: String
    let body: String
    let authorLogin: String?
    let occurredAt: Date
}

private struct GitHubContentAuthor: Decodable {
    let login: String?
}

private struct GitHubPullContent: Decodable {
    let body: String?
    let updatedAt: Date
    let user: GitHubContentAuthor?

    enum CodingKeys: String, CodingKey {
        case body, user
        case updatedAt = "updated_at"
    }

    func mentionContent(number: Int) -> GitHubMentionContent? {
        guard let body, !body.isEmpty else { return nil }
        return GitHubMentionContent(
            revisionID: "pull:\(number):\(Self.digest(body))",
            body: body,
            authorLogin: user?.login,
            occurredAt: updatedAt
        )
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct GitHubBodyContent: Decodable {
    let id: Int
    let body: String?
    let user: GitHubContentAuthor?
    let createdAt: Date?
    let updatedAt: Date?
    let submittedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, body, user
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case submittedAt = "submitted_at"
    }

    func mentionContent(source: GitHubMentionSource) -> GitHubMentionContent? {
        guard let body, !body.isEmpty,
              let occurredAt = updatedAt ?? submittedAt ?? createdAt else { return nil }
        let revisionStamp = Int(occurredAt.timeIntervalSince1970)
        return GitHubMentionContent(
            revisionID: "\(source.rawValue):\(id):\(revisionStamp)",
            body: body,
            authorLogin: user?.login,
            occurredAt: occurredAt
        )
    }
}
