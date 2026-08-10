import Foundation

struct DeviceAuthorization: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: TimeInterval
}

enum OAuthDeviceFlowError: LocalizedError {
    case missingClientID
    case invalidResponse
    case expired
    case denied
    case github(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "GitHub OAuth client ID is not configured."
        case .invalidResponse: "GitHub returned an unreadable authentication response."
        case .expired: "The GitHub sign-in code expired. Please try again."
        case .denied: "GitHub sign-in was cancelled."
        case let .github(message): message
        }
    }
}

actor OAuthDeviceFlowService {
    private let clientID: String
    private let session: URLSession

    init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func begin() async throws -> DeviceAuthorization {
        guard !clientID.isEmpty, clientID != "$(GITHUB_CLIENT_ID)" else {
            throw OAuthDeviceFlowError.missingClientID
        }
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(clientID.urlQueryEncoded)&scope=repo%20notifications%20read%3Auser"
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        let payload = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        guard !payload.deviceCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.userCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              payload.expiresIn > 0,
              payload.interval > 0,
              let url = URL(string: payload.verificationURI),
              url.scheme == "https",
              url.host == "github.com",
              url.user == nil,
              url.password == nil else { throw OAuthDeviceFlowError.invalidResponse }
        return DeviceAuthorization(
            deviceCode: payload.deviceCode,
            userCode: payload.userCode,
            verificationURL: url,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn)),
            interval: TimeInterval(payload.interval)
        )
    }

    func waitForToken(_ authorization: DeviceAuthorization) async throws -> String {
        var interval = authorization.interval
        while Date() < authorization.expiresAt {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()
            guard Date() < authorization.expiresAt else { throw OAuthDeviceFlowError.expired }
            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = [
                "client_id=\(clientID.urlQueryEncoded)",
                "device_code=\(authorization.deviceCode.urlQueryEncoded)",
                "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
            ].joined(separator: "&")
            request.httpBody = Data(body.utf8)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response: response, data: data)
            let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
            if let token = payload.accessToken {
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            switch payload.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw OAuthDeviceFlowError.expired
            case "access_denied": throw OAuthDeviceFlowError.denied
            case let error?: throw OAuthDeviceFlowError.github(payload.errorDescription ?? error)
            case nil: throw OAuthDeviceFlowError.invalidResponse
            }
        }
        throw OAuthDeviceFlowError.expired
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(GitHubMessage.self, from: data).message) ?? "GitHub authentication failed."
            throw OAuthDeviceFlowError.github(message)
        }
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
        case errorDescription = "error_description"
    }
}

private struct GitHubMessage: Decodable { let message: String }

private extension String {
    var urlQueryEncoded: String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return addingPercentEncoding(withAllowedCharacters: unreserved) ?? self
    }
}
