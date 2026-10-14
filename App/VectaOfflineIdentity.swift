import Foundation
import Security
import NotePinTransport

/// Long-term identity only. Session AEAD material and expiring API tokens are never cached here.
struct VectaOfflineIdentity: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let version: Int
    let serialNumber: String
    let deviceType: String
    let protocolVersion: UInt16
    let ownerToken: String
    let publicKeyPEM: String
    let privateKeyPEM: String
    let serialSignature: Data
    var description: String { "VectaOfflineIdentity(<redacted>)" }
    var debugDescription: String { description }

    func prepared(for device: SavedPlaudDevice) throws -> PreparedPartnerIdentity {
        guard version == 1, serialNumber == device.serialNumber,
              deviceType == device.model.partnerType, protocolVersion == device.protocolVersion,
              VectaPartnerCredentials.validOwnerToken(ownerToken),
              serialSignature.count == 256,
              publicKeyPEM.hasPrefix("-----BEGIN PUBLIC KEY-----"), publicKeyPEM.utf8.count <= 16384 else {
            throw VectaAuthorizationError.invalidResponse
        }
        let privateKey = try PartnerRSAKey(pkcs8PEM: privateKeyPEM)
        guard try privateKey.matches(publicKeyPEM: publicKeyPEM) else { throw VectaAuthorizationError.invalidResponse }
        return PreparedPartnerIdentity(privateKey: privateKey, publicKeyPEM: publicKeyPEM, serialSignature: serialSignature)
    }
}

/// Injectable boundary for retirement checks; tests never access the login Keychain.
struct VectaIdentityKeychain {
    let read: ([String: Any]) -> (OSStatus, Data?)
    let add: ([String: Any]) -> OSStatus
    let delete: ([String: Any]) -> OSStatus
    static let system = VectaIdentityKeychain(read: { query in
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        return (status, value as? Data)
    }, add: { SecItemAdd($0 as CFDictionary, nil) }, delete: { SecItemDelete($0 as CFDictionary) })
}

enum VectaOfflineIdentityStore {
    static let service = "app.vecta.offline-device-identity"
    static func load(serial: String) throws -> VectaOfflineIdentity? {
        var value: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: serial,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw VectaAuthorizationError.keychain(status) }
        return try JSONDecoder().decode(VectaOfflineIdentity.self, from: data)
    }
    /// Retire only reset-device authorization; retained keys never auto-reenroll.
    static func retireAfterReset(serial: String, using keychain: VectaIdentityKeychain = .system) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: serial]
        var read = query
        read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, stored) = keychain.read(read)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let data = stored else { throw VectaAuthorizationError.keychain(status) }
        var archive = query
        archive[kSecAttrService as String] = service + ".retired"
        archive[kSecAttrAccount as String] = serial + "." + UUID().uuidString
        var insertion = archive
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let saved = keychain.add(insertion)
        guard saved == errSecSuccess else { throw VectaAuthorizationError.keychain(saved) }
        archive[kSecReturnData as String] = true; archive[kSecMatchLimit as String] = kSecMatchLimitOne
        let (verified, retained) = keychain.read(archive)
        guard verified == errSecSuccess, retained == data else { throw VectaAuthorizationError.invalidResponse }
        let deleted = keychain.delete(query)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw VectaAuthorizationError.keychain(deleted) }
    }

    static func save(_ identity: VectaOfflineIdentity, device: SavedPlaudDevice) throws {
        _ = try identity.prepared(for: device)
        let data = try JSONEncoder().encode(identity)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: identity.serialNumber]
        var insertion = query
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insertion as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let existing = try load(serial: identity.serialNumber), existing == identity else {
                throw VectaAuthorizationError.invalidResponse
            }
        } else if status != errSecSuccess { throw VectaAuthorizationError.keychain(status) }
    }
}
