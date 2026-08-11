import Foundation
import XCTest
@testable import PRThroughput

final class OAuthDeviceFlowTests: XCTestCase {
    func testOAuthClientIDResolutionFallsBackFromBlankSavedValue() {
        XCTAssertEqual(
            AppModel.resolveOAuthClientID(saved: "  \n", configured: "bundled-client"),
            "bundled-client"
        )
        XCTAssertEqual(
            AppModel.resolveOAuthClientID(saved: nil, configured: " bundled-client "),
            "bundled-client"
        )
        XCTAssertEqual(
            AppModel.resolveOAuthClientID(saved: nil, configured: "$(GITHUB_CLIENT_ID)"),
            ""
        )
    }

    func testOAuthClientIDResolutionPreservesNonblankUserOverride() {
        XCTAssertEqual(
            AppModel.resolveOAuthClientID(saved: " saved-client ", configured: "bundled-client"),
            "saved-client"
        )
        XCTAssertEqual(AppModel.resolveOAuthClientID(saved: " ", configured: " \n"), "")
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testBeginRejectsBlankDeviceAndUserCodes() async {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/device/code")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"device_code":" ","user_code":"","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#.utf8))
        }
        let service = OAuthDeviceFlowService(clientID: "client", session: stubSession())

        do {
            _ = try await service.begin()
            XCTFail("Expected invalid response")
        } catch OAuthDeviceFlowError.invalidResponse {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBeginRejectsNonGitHubVerificationURL() async {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"device_code":"device","user_code":"ABCD-1234","verification_uri":"https://example.com/login/device","expires_in":900,"interval":5}"#.utf8))
        }
        let service = OAuthDeviceFlowService(clientID: "client", session: stubSession())

        do {
            _ = try await service.begin()
            XCTFail("Expected invalid response")
        } catch OAuthDeviceFlowError.invalidResponse {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNewAuthorizationOmitsNotificationsScope() async throws {
        StubURLProtocol.handler = { request in
            let body = try XCTUnwrap(request.httpBody ?? Self.readBodyStream(request.httpBodyStream))
            let value = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(value.contains("scope=repo%20read%3Auser"))
            XCTAssertFalse(value.contains("notifications"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"device_code":"device","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#.utf8))
        }
        let service = OAuthDeviceFlowService(clientID: "client", session: stubSession())

        _ = try await service.begin()
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
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
}
