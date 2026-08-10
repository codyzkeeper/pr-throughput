import Foundation
import XCTest
@testable import PRThroughput

final class OAuthDeviceFlowTests: XCTestCase {
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

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
