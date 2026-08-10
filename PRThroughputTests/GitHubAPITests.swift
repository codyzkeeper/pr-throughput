import Foundation
import XCTest
@testable import PRThroughput

final class GitHubAPITests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testViewerUsesReadOnlyGraphQLQuery() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/graphql")
            let body = try XCTUnwrap(request.httpBody ?? Self.readBodyStream(request.httpBodyStream))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let query = try XCTUnwrap(object["query"] as? String)
            XCTAssertTrue(query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("query"))
            XCTAssertFalse(query.contains("mutation"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["x-ratelimit-remaining": "4999"])!
            let data = Data(#"{"data":{"viewer":{"id":"viewer","login":"me"}}}"#.utf8)
            return (response, data)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "not-a-real-token", session: URLSession(configuration: configuration))

        let viewer = try await api.viewer()

        XCTAssertEqual(viewer.login, "me")
        let state = await api.rateState
        XCTAssertEqual(state.remaining, 4_999)
    }

    func testReadOnlyGraphQLRetriesTransientNetworkLoss() async throws {
        var attempts = 0
        StubURLProtocol.handler = { request in
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data":{"viewer":{"id":"viewer","login":"me"}}}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "not-a-real-token", session: URLSession(configuration: configuration), retryBaseDelay: 0)

        let viewer = try await api.viewer()
        XCTAssertEqual(viewer.login, "me")
        XCTAssertEqual(attempts, 2)
    }

    func testReadOnlyGraphQLDoesNotRetryNonTransientFailure() async {
        var attempts = 0
        StubURLProtocol.handler = { _ in
            attempts += 1
            throw URLError(.userAuthenticationRequired)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "not-a-real-token", session: URLSession(configuration: configuration), retryBaseDelay: 0)

        do {
            _ = try await api.viewer()
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(attempts, 1)
        }
    }

    func testRESTSecondaryRateLimitHonorsRetryAfter() async throws {
        var attempts = 0
        StubURLProtocol.handler = { request in
            attempts += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Retry-After": "120", "x-ratelimit-remaining": "4999"]
            )!
            return (response, Data(#"{"message":"You have exceeded a secondary rate limit."}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "not-a-real-token", session: URLSession(configuration: configuration))
        let before = Date()

        do {
            _ = try await api.notifications(since: nil)
            XCTFail("Expected secondary rate limit")
        } catch let GitHubAPIError.rateLimited(resetAt) {
            let delay = try XCTUnwrap(resetAt).timeIntervalSince(before)
            XCTAssertGreaterThanOrEqual(delay, 119)
            XCTAssertLessThanOrEqual(delay, 121)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await api.notifications(since: nil)
            XCTFail("Expected local retry gate")
        } catch GitHubAPIError.rateLimited {
            XCTAssertEqual(attempts, 1, "A blocked retry must not contact GitHub")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGraphQLRateLimitErrorUsesResetHeader() async {
        let reset = Date().addingTimeInterval(300)
        var attempts = 0
        StubURLProtocol.handler = { request in
            attempts += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "x-ratelimit-remaining": "0",
                    "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970))
                ]
            )!
            return (response, Data(#"{"errors":[{"message":"API rate limit exceeded"}]}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "not-a-real-token", session: URLSession(configuration: configuration))

        do {
            _ = try await api.viewer()
            XCTFail("Expected GraphQL rate limit")
        } catch let GitHubAPIError.rateLimited(resetAt) {
            XCTAssertEqual(try XCTUnwrap(resetAt).timeIntervalSince1970, TimeInterval(Int(reset.timeIntervalSince1970)), accuracy: 0.001)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await api.viewer()
            XCTFail("Expected local retry gate")
        } catch GitHubAPIError.rateLimited {
            XCTAssertEqual(attempts, 1, "A blocked retry must not contact GitHub")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    func testRefusesCommentURLOutsideGitHubAPI() async {
        let api = GitHubAPI(token: "not-a-real-token")
        do {
            _ = try await api.comment(url: URL(string: "https://example.com/comment")!)
            XCTFail("Expected unsafe URL to be rejected")
        } catch GitHubAPIError.unsafeURL {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMentionVerificationRejectsUnsupportedGitHubAPIEndpoint() async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = Data(#"{"id":"27","unread":true,"reason":"mention","updated_at":"2026-08-06T18:00:00Z","subject":{"title":"Wrong endpoint","url":"https://api.github.com/repos/o/r/pulls/27","latest_comment_url":"https://api.github.com/repos/other/private/actions/runs/99","type":"PullRequest"},"repository":{"full_name":"o/r","html_url":"https://github.com/o/r"}}"#.utf8)
        let thread = try decoder.decode(GitHubNotificationThread.self, from: data)
        let api = GitHubAPI(token: "not-a-real-token")

        do {
            _ = try await api.mentionContents(thread: thread)
            XCTFail("Expected an unsupported API endpoint to be rejected")
        } catch let GitHubAPIError.unsupportedMentionEndpoint(shape) {
            XCTAssertEqual(shape, "/repos/:owner/:repository/actions/runs/:id")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMentionVerificationSupportsPullRequestBodyAsLatestSource() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/repos/o/r/pulls/27")
            let payload = #"{"id":2700,"body":"@me choose an option","updated_at":"2026-08-06T18:00:00Z","user":{"login":"alice"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = Data(#"{"id":"27","unread":true,"reason":"mention","updated_at":"2026-08-06T18:00:00Z","subject":{"title":"Body mention","url":"https://api.github.com/repos/o/r/pulls/27","latest_comment_url":"https://api.github.com/repos/o/r/pulls/27","type":"PullRequest"},"repository":{"full_name":"o/r","html_url":"https://github.com/o/r"}}"#.utf8)
        let thread = try decoder.decode(GitHubNotificationThread.self, from: data)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "test", session: URLSession(configuration: configuration))

        let contents = try await api.mentionContents(thread: thread)

        XCTAssertEqual(contents.count, 1)
        XCTAssertTrue(contents[0].revisionID.hasPrefix("pull:27:"))
        XCTAssertEqual(contents[0].authorLogin, "alice")
    }

    func testNotificationsHonorServerPollingFloor() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.url?.path, "/notifications")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "per_page" })?.value, "50")
            XCTAssertEqual(query.first(where: { $0.name == "all" })?.value, "true")
            XCTAssertEqual(query.first(where: { $0.name == "participating" })?.value, "true")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Poll-Interval": "90"]
            )!
            return (response, Data("[]".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "not-a-real-token", session: URLSession(configuration: configuration))

        _ = try await api.notifications(since: nil)

        let interval = await api.notificationPollInterval
        XCTAssertEqual(interval, 90)
    }

    func testNotificationsFollowOnlySafeGitHubPaginationLinks() async throws {
        var requestedPages: [String?] = []
        StubURLProtocol.handler = { request in
            let page = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })?.value
            requestedPages.append(page)
            let headers = page == nil
                ? ["Link": #"<https://api.github.com/notifications?page=2>; rel="next""#]
                : [:]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
            return (response, Data("[]".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "not-a-real-token", session: URLSession(configuration: configuration))

        _ = try await api.notifications(since: nil)

        XCTAssertEqual(requestedPages, [nil, "2"])
    }

    func testNotificationsRejectUnsafePaginationLink() async {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Link": #"<https://example.com/steal-token>; rel="next""#]
            )!
            return (response, Data("[]".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "not-a-real-token", session: URLSession(configuration: configuration))

        do {
            _ = try await api.notifications(since: nil)
            XCTFail("Expected unsafe pagination URL to be rejected")
        } catch GitHubAPIError.unsafeURL {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDecodesSearchAndTimelineContracts() async throws {
        StubURLProtocol.handler = { request in
            let body = try XCTUnwrap(request.httpBody ?? Self.readBodyStream(request.httpBodyStream))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let query = try XCTUnwrap(object["query"] as? String)
            let payload: String
            if query.contains("SearchPullRequests") {
                payload = #"{"data":{"search":{"issueCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"__typename":"PullRequest","id":"pr","number":7,"title":"Title","url":"https://github.com/o/r/pull/7","createdAt":"2026-08-01T12:00:00Z","updatedAt":"2026-08-02T12:00:00Z","isDraft":false,"state":"OPEN","mergedAt":null,"closedAt":null,"author":{"__typename":"User","login":"me","id":"viewer"},"repository":{"nameWithOwner":"o/r"}}]}}}"#
            } else {
                XCTAssertFalse(query.contains("assignee { __typename ... on User { id login } ... on Bot { id login } ... on Team"))
                XCTAssertFalse(query.contains("requestedReviewer { __typename ... on User { id login } ... on Bot { id login } ... on Team"))
                payload = #"{"data":{"node":{"timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[null,{"__typename":"AssignedEvent","id":"assigned","createdAt":"2026-08-02T12:00:00Z","assignee":{"__typename":"User","id":"reviewer","login":"alice"}},{"__typename":"PullRequestReview","id":"review","submittedAt":"2026-08-02T13:00:00Z","state":"CHANGES_REQUESTED","author":{"__typename":"User","id":"reviewer","login":"alice"}}]}}}}"#
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "not-a-real-token", session: URLSession(configuration: configuration))

        let pulls = try await api.searchPullRequests(query: "is:pr author:me")
        let timeline = try await api.timeline(pullRequestID: "pr")

        XCTAssertEqual(pulls.first?.repository.nameWithOwner, "o/r")
        XCTAssertEqual(pulls.first?.author?.user?.id, "viewer")
        XCTAssertEqual(timeline.count, 2)
        guard case let .reviewed(reviewer, state) = timeline.last?.kind else {
            return XCTFail("Expected review event")
        }
        XCTAssertEqual(reviewer.login, "alice")
        XCTAssertEqual(state, .changesRequested)
    }

    func testDismissedReviewPreservesOriginalDecisionEvent() async throws {
        StubURLProtocol.handler = { request in
            let body = try XCTUnwrap(request.httpBody ?? Self.readBodyStream(request.httpBodyStream))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let query = try XCTUnwrap(object["query"] as? String)
            XCTAssertTrue(query.contains("REVIEW_DISMISSED_EVENT"))
            let payload = #"{"data":{"node":{"timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"__typename":"PullRequestReview","id":"review","submittedAt":"2026-08-02T13:00:00Z","state":"DISMISSED","author":{"__typename":"User","id":"reviewer","login":"alice"}},{"__typename":"ReviewDismissedEvent","id":"dismissal","createdAt":"2026-08-02T14:00:00Z","previousReviewState":"CHANGES_REQUESTED","review":{"id":"review","submittedAt":"2026-08-02T13:00:00Z","author":{"__typename":"User","id":"reviewer","login":"alice"}}}]}}}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "not-a-real-token", session: URLSession(configuration: configuration))

        let timeline = try await api.timeline(pullRequestID: "pr")

        XCTAssertEqual(timeline.count, 1)
        XCTAssertEqual(timeline.first?.id, "review")
        XCTAssertEqual(timeline.first?.at, ISO8601DateFormatter().date(from: "2026-08-02T13:00:00Z"))
        guard case let .reviewed(reviewer, state) = timeline.first?.kind else {
            return XCTFail("Expected the dismissed review's original decision")
        }
        XCTAssertEqual(reviewer.id, "reviewer")
        XCTAssertEqual(state, .changesRequested)
    }

    func testSearchRejectsRepeatedPaginationCursor() async {
        StubURLProtocol.handler = { request in
            let payload = #"{"data":{"search":{"issueCount":2,"pageInfo":{"hasNextPage":true,"endCursor":"same"},"nodes":[]}}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let api = GitHubAPI(token: "not-a-real-token", session: URLSession(configuration: configuration))

        do {
            _ = try await api.searchPullRequests(query: "is:pr author:me")
            XCTFail("Expected repeated cursor to be rejected")
        } catch GitHubAPIError.invalidResponse {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOAuthFormEncodesClientIDAndValidatesVerificationHost() async {
        StubURLProtocol.handler = { request in
            let body = try XCTUnwrap(request.httpBody ?? Self.readBodyStream(request.httpBodyStream))
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("client_id=abc%26scope%3Dwrite"))
            let payload = #"{"device_code":"device","user_code":"ABCD-EFGH","verification_uri":"https://example.com/device","expires_in":900,"interval":5}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let service = OAuthDeviceFlowService(clientID: "abc&scope=write", session: URLSession(configuration: configuration))

        do {
            _ = try await service.begin()
            XCTFail("Expected non-GitHub verification URL to be rejected")
        } catch OAuthDeviceFlowError.invalidResponse {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
