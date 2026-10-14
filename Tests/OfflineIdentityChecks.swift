import Foundation
import Security
import NotePinTransport

@main struct OfflineIdentityChecks {
    static func tlv(_ tag: UInt8, _ data: Data) -> Data {
        let length: [UInt8] = data.count < 128 ? [UInt8(data.count)] : [0x82, UInt8(data.count >> 8), UInt8(data.count & 255)]
        return Data([tag] + length) + data
    }
    static func pem(_ label: String, _ data: Data) -> String {
        "-----BEGIN \(label)-----\n" + data.base64EncodedString() + "\n-----END \(label)-----"
    }
    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Invalid identity was accepted") } catch {}
    }
    static func main() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false, kSecUseDataProtectionKeychain: true]
        let generated = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        let publicKey = SecKeyCopyPublicKey(generated)!
        let privateDER = SecKeyCopyExternalRepresentation(generated, nil)! as Data
        let publicDER = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        let algorithm = tlv(0x30, Data([6, 9, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1, 5, 0]))
        let privatePEM = pem("PRIVATE KEY", tlv(0x30, Data([2, 1, 0]) + algorithm + tlv(4, privateDER)))
        let publicPEM = pem("PUBLIC KEY", tlv(0x30, algorithm + tlv(3, Data([0]) + publicDER)))
        let device = try SavedPlaudDevice(serialNumber: "882TEST00001", model: .notePinS, protocolVersion: 20)
        let identity = VectaOfflineIdentity(version: 1, serialNumber: device.serialNumber, deviceType: "notepins", protocolVersion: 20,
            ownerToken: "disposable-test-owner", publicKeyPEM: publicPEM, privateKeyPEM: privatePEM, serialSignature: Data(repeating: 1, count: 256))
        let prepared = try identity.prepared(for: device)
        let plain = Data("disposable bootstrap".utf8)
        let encrypted = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1, plain as CFData, nil)! as Data
        let decrypted = try prepared.privateKey.decryptBootstrap(encrypted)
        let matching = try prepared.privateKey.matches(publicKeyPEM: publicPEM)
        precondition(decrypted == plain && matching)
        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(VectaOfflineIdentity.self, from: data)
        _ = try decoded.prepared(for: device)
        let other = try SavedPlaudDevice(serialNumber: "882TEST00002", model: .notePinS, protocolVersion: 20)
        rejects { _ = try identity.prepared(for: other) }
        let upgraded = try SavedPlaudDevice(serialNumber: device.serialNumber, model: .notePinS, protocolVersion: 21)
        rejects { _ = try identity.prepared(for: upgraded) }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for (key, bad) in [("version", 2 as Any), ("ownerToken", "bad\nowner" as Any), ("privateKeyPEM", "bad" as Any), ("deviceType", "notepro" as Any), ("serialSignature", Data([0]).base64EncodedString() as Any)] {
            var malformed = object; malformed[key] = bad
            rejects { _ = try JSONDecoder().decode(VectaOfflineIdentity.self, from: JSONSerialization.data(withJSONObject: malformed)).prepared(for: device) }
        }
        var corrupted = publicDER; corrupted[corrupted.count - 1] ^= 1
        object["publicKeyPEM"] = pem("PUBLIC KEY", tlv(0x30, algorithm + tlv(3, Data([0]) + corrupted)))
        rejects { _ = try JSONDecoder().decode(VectaOfflineIdentity.self, from: JSONSerialization.data(withJSONObject: object)).prepared(for: device) }
        precondition(identity.description == "VectaOfflineIdentity(<redacted>)" && identity.debugDescription == identity.description)
        precondition(prepared.privateKeyPEM == nil)
        precondition(!String(decoding: data, as: UTF8.self).contains("plaudUserAccessToken"))
        // In-memory Keychain adapter: archive-before-delete, byte verification,
        // missing identity and every failure preserve active bytes.
        for scenario in ["success", "missing", "read-failure", "add-failure", "corrupt-archive", "delete-failure"] {
            let active = Data("disposable identity bytes".utf8)
            var calls: [String] = []
            var archived: Data?
            var activeDeleted = false
            let keychain = VectaIdentityKeychain(read: { query in
                let retired = query[kSecAttrService as String] as? String == VectaOfflineIdentityStore.service + ".retired"
                calls.append(retired ? "verify" : "read")
                if retired { return (errSecSuccess, scenario == "corrupt-archive" ? Data([0]) : archived) }
                if scenario == "missing" { return (errSecItemNotFound, nil) }
                if scenario == "read-failure" { return (errSecInteractionNotAllowed, nil) }
                return (errSecSuccess, active)
            }, add: { query in
                calls.append("archive")
                precondition(query[kSecAttrService as String] as? String == VectaOfflineIdentityStore.service + ".retired")
                precondition((query[kSecAttrAccount as String] as? String)?.hasPrefix(device.serialNumber + ".") == true)
                precondition(query[kSecValueData as String] as? Data == active)
                if scenario == "add-failure" { return errSecInteractionNotAllowed }
                archived = query[kSecValueData as String] as? Data
                return errSecSuccess
            }, delete: { query in
                calls.append("delete")
                precondition(query[kSecAttrService as String] as? String == VectaOfflineIdentityStore.service)
                precondition(archived == active)
                if scenario == "delete-failure" { return errSecInteractionNotAllowed }
                activeDeleted = true
                return errSecSuccess
            })
            if scenario == "success" || scenario == "missing" {
                try VectaOfflineIdentityStore.retireAfterReset(serial: device.serialNumber, using: keychain)
            } else {
                rejects { try VectaOfflineIdentityStore.retireAfterReset(serial: device.serialNumber, using: keychain) }
            }
            precondition(activeDeleted == (scenario == "success"))
            if scenario == "success" { precondition(calls == ["read", "archive", "verify", "delete"]) }
            if scenario == "missing" { precondition(calls == ["read"]) }
            if ["read-failure", "add-failure", "corrupt-archive"].contains(scenario) { precondition(!calls.contains("delete")) }
        }
        print("PASS offline identity: RSA pairing/decrypt, Codable roundtrip, target/version isolation, malformed fields, mismatched public key, redaction, no API token and six mock retirement scenarios; no Keychain or network used")
    }
}
