import Security
import XCTest
@testable import PRThroughput

final class KeychainTokenStoreTests: XCTestCase {
    func testOnlyTemporaryKeychainAvailabilityFailuresAreRetryable() {
        XCTAssertTrue(KeychainTokenError.unexpectedStatus(errSecInDarkWake).isTemporarilyUnavailable)
        XCTAssertTrue(KeychainTokenError.unexpectedStatus(errSecInteractionNotAllowed).isTemporarilyUnavailable)
        XCTAssertTrue(KeychainTokenError.unexpectedStatus(errSecNotAvailable).isTemporarilyUnavailable)
        XCTAssertFalse(KeychainTokenError.unexpectedStatus(errSecAuthFailed).isTemporarilyUnavailable)
        XCTAssertFalse(KeychainTokenError.unexpectedStatus(errSecItemNotFound).isTemporarilyUnavailable)
    }

    func testSaveUpdatesAnExistingToken() throws {
        let service = "app.prthroughput.PRThroughputTests.\(UUID().uuidString)"
        let store = KeychainTokenStore(service: service, account: "test-token")
        defer { try? store.delete() }

        try store.save("first")
        XCTAssertEqual(try store.load(), "first")

        try store.save("second")
        XCTAssertEqual(try store.load(), "second")

        XCTAssertFalse(try store.delete(ifMatching: "first"))
        XCTAssertEqual(try store.load(), "second")
        XCTAssertTrue(try store.delete(ifMatching: "second"))
        XCTAssertNil(try store.load())
    }
}
