import Foundation

public enum PartnerPlatformError: Error, Equatable {
    case unsupportedDomain
    case invalidInput
    case httpStatus(Int)
    case invalidResponse
}

public struct PreparedPartnerIdentity: CustomStringConvertible, CustomDebugStringConvertible {
    public let privateKey: PartnerRSAKey
    public let publicKeyPEM: String
    public let serialSignature: Data
    public var privateKeyPEM: String? = nil
    public init(privateKey: PartnerRSAKey, publicKeyPEM: String, serialSignature: Data, privateKeyPEM: String? = nil) {
        self.privateKey = privateKey; self.publicKeyPEM = publicKeyPEM
        self.serialSignature = serialSignature; self.privateKeyPEM = privateKeyPEM
    }
    public var description: String { "PreparedPartnerIdentity(<redacted>)" }
    public var debugDescription: String { description }
}

/// Only the SDK's gen-key and sn-sign endpoints. Never binds/unbinds devices,
/// uploads recordings, or calls an OpenAI API. Tokens remain memory-only.
public final class PartnerPlatform {
    private let domain: String
    private let accessToken: String

    public init(domain: String, accessToken: String) throws {
        guard ["platform-us.plaud.ai", "platform-jp.plaud.ai"].contains(domain) else {
            throw PartnerPlatformError.unsupportedDomain
        }
        guard accessToken.count >= 20, accessToken.count <= 16384,
              accessToken.utf8.allSatisfy({ $0 != 13 && $0 != 10 }) else {
            throw PartnerPlatformError.invalidInput
        }
        self.domain = domain
        self.accessToken = accessToken
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        // These are two independent authorization exchanges. Do not retain a
        // pooled connection from key generation for the signed-device request.
        return URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    public func prepare(serialNumber: String, deviceType: String, onProgress: ((String) -> Void)? = nil) async throws -> PreparedPartnerIdentity {
        guard ["notepins": "882", "notepro": "881"][deviceType].map({ serialNumber.hasPrefix($0) }) == true, serialNumber.count <= 128,
              serialNumber.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }) else {
            throw PartnerPlatformError.invalidInput
        }
        onProgress?("partner-key")
        let keys: Keys = try await post("gen-key", body: nil)
        let key = try PartnerRSAKey(pkcs8PEM: keys.privateKey)
        guard keys.publicKey.hasPrefix("-----BEGIN PUBLIC KEY-----"), keys.publicKey.utf8.count <= 16384 else {
            throw PartnerPlatformError.invalidResponse
        }
        onProgress?("partner-signature")
        let signed: Signed = try await post("sn-sign", body: ["type": deviceType, "sn": serialNumber])
        guard let signature = Data(base64Encoded: signed.signature), !signature.isEmpty, signature.count <= 4096 else {
            throw PartnerPlatformError.invalidResponse
        }
        return PreparedPartnerIdentity(privateKey: key, publicKeyPEM: keys.publicKey, serialSignature: signature, privateKeyPEM: keys.privateKey)
    }

    private struct Keys: Decodable {
        let publicKey: String, privateKey: String
        enum CodingKeys: String, CodingKey { case publicKey = "public_key", privateKey = "private_key" }
    }
    private struct Signed: Decodable { let signature: String }
    private func post<T: Decodable>(_ endpoint: String, body: [String: String]?) async throws -> T {
        let url = URL(string: "https://\(domain)/developer/api/open/partner/sdk/\(endpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        // Identify this independent client. Some API edge filters reject an
        // empty/default framework user agent before checking authorization.
        // Keep the real bearer token, TLS and signed device proof unchanged.
        request.setValue("Vecta/1.0 (macOS; independent native BLE client)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else { request.httpBody = Data() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PartnerPlatformError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw PartnerPlatformError.httpStatus(response.statusCode) }
        guard data.count <= 65536 else { throw PartnerPlatformError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw PartnerPlatformError.invalidResponse }
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
