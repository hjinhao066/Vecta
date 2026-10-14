import Foundation
import Security

// Research-only replacement for PartnerPlatform.swift: no HTTP and no Keychain.
public struct PreparedPartnerIdentity {
    public let privateKey: PartnerRSAKey
    public let publicKeyPEM: String
    public let serialSignature: Data
}
public enum LocalResearchIdentity {
    private static func der(_ tag: UInt8, _ data: Data) -> Data {
        let n = data.count
        let length: [UInt8] = n < 128 ? [UInt8(n)] : n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 255)]
        return Data([tag] + length) + data
    }
    private static func exported(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) else { throw PartnerRSAError.invalidKey }
        return data as Data
    }
    private static func pem(_ label: String, _ data: Data) -> String {
        "-----BEGIN \(label)-----\n" + data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END \(label)-----"
    }
    public static func generate() throws -> PreparedPartnerIdentity {
        var error: Unmanaged<CFError>?
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
                                    kSecPrivateKeyAttrs: [kSecAttrIsPermanent: false]]
        guard let secret = SecKeyCreateRandomKey(attrs as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(secret) else { throw PartnerRSAError.invalidKey }
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1, 0x05, 0])
        let pkcs8 = der(0x30, Data([2,1,0]) + algorithm + der(4, try exported(secret)))
        let spki = der(0x30, algorithm + der(3, Data([0]) + (try exported(publicKey))))
        return PreparedPartnerIdentity(privateKey: try PartnerRSAKey(pkcs8PEM: pem("PRIVATE KEY", pkcs8)), publicKeyPEM: pem("PUBLIC KEY", spki), serialSignature: Data())
    }
}
