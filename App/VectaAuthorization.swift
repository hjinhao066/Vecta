import Foundation
import Security

/// A device credential is independent of library ownership and never contains audio.
struct VectaDeviceSession: Codable, Equatable {
    let plaudUserAccessToken: String
    let userID: String
    let plaudDomain: String
    let plaudTokenExpiresAt: Date
    var canResumeWithoutRefresh: Bool { plaudTokenExpiresAt.timeIntervalSinceNow > 300 }
    enum CodingKeys: String, CodingKey {
        case plaudUserAccessToken, plaudDomain, plaudTokenExpiresAt
        case userID = "userId"
    }
}

struct VectaPartnerCredentials: Codable {
    let clientID: String
    let clientSecret: String
    let domain: String
    let userID: String
    static func validOwnerToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
    }
    func validate() throws {
        guard ["platform-us.plaud.ai", "platform-jp.plaud.ai"].contains(domain),
              !clientID.isEmpty, !clientSecret.isEmpty, !userID.isEmpty,
              clientID.utf8.count < 1024, clientSecret.utf8.count < 4096,
              Self.validOwnerToken(userID), !clientID.contains(":") else {
            throw VectaAuthorizationError.invalidCredentials
        }
    }
}

enum VectaAuthorizationError: LocalizedError {
    case unavailable, invalidCredentials, invalidResponse, identityMismatch, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .unavailable: return VL.text("Для этого устройства нужны учётные данные PLAUD Partner. Настройте авторизацию Vecta.")
        case .invalidCredentials: return VL.text("Некорректные учётные данные авторизации устройства.")
        case .invalidResponse: return VL.text("Не удалось подтвердить авторизацию устройства.")
        case .identityMismatch: return VL.text("Авторизация принадлежит другой библиотеке. Данные сохранены.")
        case .keychain: return VL.text("Не удалось открыть защищённые учётные данные Vecta.")
        }
    }
}

/// The public app never embeds a shared client secret. Developer-owned partner
/// credentials are stored only in the user's login Keychain by configure-auth.
enum VectaCredentialStore {
    static let service = "app.vecta.device-authorization"
    static let account = "partner"
    static func load() throws -> VectaPartnerCredentials? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VectaAuthorizationError.keychain(status) }
        let credentials = try JSONDecoder().decode(VectaPartnerCredentials.self, from: data)
        try credentials.validate()
        return credentials
    }
    static func save(_ credentials: VectaPartnerCredentials) throws {
        try credentials.validate()
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(insertion as CFDictionary, nil)
            guard added == errSecSuccess else { throw VectaAuthorizationError.keychain(added) }
        } else if status != errSecSuccess { throw VectaAuthorizationError.keychain(status) }
    }
}

protocol DeviceAuthorizationProvider {
    func authorize(expectedUserID: String) async throws -> VectaDeviceSession
}

/// Two narrowly scoped HTTPS requests. No local HTTP server, upload, binding,
/// cloud transcription, account membership, invitation or hosted API exists.
final class VectaPartnerAuthorization: NSObject, DeviceAuthorizationProvider, URLSessionTaskDelegate {
    private let credentials: VectaPartnerCredentials
    private let exchange: ((URLRequest) async throws -> (Data, URLResponse))?
    init(credentials: VectaPartnerCredentials, exchange: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        try credentials.validate()
        self.credentials = credentials
        self.exchange = exchange
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func authorize(expectedUserID: String) async throws -> VectaDeviceSession {
        guard credentials.userID == expectedUserID else { throw VectaAuthorizationError.identityMismatch }
        let basic = Data("\(credentials.clientID):\(credentials.clientSecret)".utf8).base64EncodedString()
        let partner = try await request(path: "/developer/api/oauth/partner/access-token", authorization: "Basic " + basic, body: nil)
        let token = try await request(path: "/developer/api/open/partner/users/access-token", authorization: "Bearer " + partner,
                                     body: ["user_id": expectedUserID, "expires_in": 3600])
        let claims = try Self.claims(token)
        guard let subject = claims["sub"] as? String, !subject.isEmpty,
              (claims["user_id"] as? String ?? subject) == expectedUserID,
              claims["client_id"] as? String == credentials.clientID,
              let expiration = claims["exp"] as? Double,
              expiration > Date().timeIntervalSince1970 + 60,
              expiration <= Date().timeIntervalSince1970 + 3900 else { throw VectaAuthorizationError.invalidResponse }
        // JWT claims are consistency checks, not signature verification. TLS
        // authenticates the token endpoint; transport verifies device signatures.
        return VectaDeviceSession(plaudUserAccessToken: token, userID: expectedUserID,
                                  plaudDomain: credentials.domain, plaudTokenExpiresAt: Date(timeIntervalSince1970: expiration))
    }
    private func request(path: String, authorization: String, body: [String: Any]?) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://" + credentials.domain + path)!)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Vecta/0.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let (data, response): (Data, URLResponse)
        if let exchange { (data, response) = try await exchange(request) }
        else { (data, response) = try await session.data(for: request) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 65536,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VectaAuthorizationError.invalidResponse }
        let values = (payload["data"] as? [String: Any]) ?? payload
        guard let token = (values["access_token"] ?? values["token"]) as? String,
              !token.isEmpty, token.utf8.count <= 16384,
              !token.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw VectaAuthorizationError.invalidResponse }
        return token
    }
    static func claims(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw VectaAuthorizationError.invalidResponse }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value),
              let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VectaAuthorizationError.invalidResponse }
        return claims
    }
}
