import Foundation
import Security

enum KeychainTokenError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var isTemporarilyUnavailable: Bool {
        guard case let .unexpectedStatus(status) = self else { return false }
        return status == errSecInDarkWake
            || status == errSecInteractionNotAllowed
            || status == errSecNotAvailable
    }

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            isTemporarilyUnavailable
                ? "The macOS Keychain is temporarily unavailable."
                : "Keychain operation failed (\(status))."
        }
    }
}

struct KeychainTokenStore: Sendable {
    private let service: String
    private let account: String

    init(service: String = "app.prthroughput.PRThroughput.github", account: String = "oauth-token") {
        self.service = service
        self.account = account
    }

    func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainTokenError.unexpectedStatus(status) }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return token
    }

    func save(_ token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updates: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8)
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainTokenError.unexpectedStatus(updateStatus)
        }
        let attributes = query.merging(updates, uniquingKeysWith: { _, new in new })
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
            guard retryStatus == errSecSuccess else { throw KeychainTokenError.unexpectedStatus(retryStatus) }
            return
        }
        throw KeychainTokenError.unexpectedStatus(addStatus)
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenError.unexpectedStatus(status)
        }
    }

    @discardableResult
    func delete(ifMatching token: String) throws -> Bool {
        guard try load() == token else { return false }
        try delete()
        return true
    }
}
