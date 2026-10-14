import Foundation
import Security

public enum PartnerRSAError: Error, Equatable {
    case invalidPEM
    case invalidDER
    case unsupportedKeyAlgorithm
    case invalidKey
    case invalidCiphertext
    case decryptionFailed
}

/// Imports the PLAUD gen-key PKCS#8 private key into Apple's Security framework.
/// This does not generate a replacement partner key, bypass server signing, or
/// persist any credentials. No key material is included in diagnostic errors.
public final class PartnerRSAKey {
    private let key: SecKey

    public init(pkcs8PEM: String) throws {
        let text = pkcs8PEM.trimmingCharacters(in: .whitespacesAndNewlines)
        let begin = "-----BEGIN \( "PRIVATE KEY" )-----", end = "-----END \( "PRIVATE KEY" )-----"
        guard text.hasPrefix(begin), text.hasSuffix(end) else { throw PartnerRSAError.invalidPEM }
        let body = text.dropFirst(begin.count).dropLast(end.count).filter { !$0.isWhitespace }
        guard body.count <= 24_000, let der = Data(base64Encoded: String(body)) else {
            throw PartnerRSAError.invalidPEM
        }
        var outer = DERReader(der)
        var content = DERReader(try outer.value(tag: 0x30))
        guard outer.isEmpty, try content.value(tag: 0x02) == Data([0]) else {
            throw PartnerRSAError.invalidDER
        }
        var algorithm = DERReader(try content.value(tag: 0x30))
        guard try algorithm.value(tag: 0x06) == Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1]) else {
            throw PartnerRSAError.unsupportedKeyAlgorithm
        }
        if !algorithm.isEmpty {
            guard try algorithm.value(tag: 0x05).isEmpty else { throw PartnerRSAError.invalidDER }
        }
        guard algorithm.isEmpty else { throw PartnerRSAError.invalidDER }
        let pkcs1 = try content.value(tag: 0x04)
        guard content.isEmpty else { throw PartnerRSAError.invalidDER }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            _ = error?.takeRetainedValue()
            throw PartnerRSAError.invalidKey
        }
        self.key = key
    }

    public func matches(publicKeyPEM: String) throws -> Bool {
        let text = publicKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        let begin = "-----BEGIN PUBLIC KEY-----", end = "-----END PUBLIC KEY-----"
        guard text.hasPrefix(begin), text.hasSuffix(end) else { throw PartnerRSAError.invalidPEM }
        let body = text.dropFirst(begin.count).dropLast(end.count).filter { !$0.isWhitespace }
        guard body.count <= 24_000, let der = Data(base64Encoded: String(body)) else { throw PartnerRSAError.invalidPEM }
        var outer = DERReader(der)
        var content = DERReader(try outer.value(tag: 0x30))
        var algorithm = DERReader(try content.value(tag: 0x30))
        guard outer.isEmpty, try algorithm.value(tag: 0x06) == Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1]) else {
            throw PartnerRSAError.invalidDER
        }
        if !algorithm.isEmpty { guard try algorithm.value(tag: 0x05).isEmpty else { throw PartnerRSAError.invalidDER } }
        let bits = try content.value(tag: 0x03)
        guard algorithm.isEmpty, content.isEmpty, bits.first == 0,
              let publicKey = SecKeyCopyPublicKey(key),
              let expected = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw PartnerRSAError.invalidKey }
        return Data(bits.dropFirst()) == expected
    }

    public func decryptBootstrap(_ ciphertext: Data) throws -> Data {
        guard ciphertext.count == SecKeyGetBlockSize(key) else { throw PartnerRSAError.invalidCiphertext }
        guard SecKeyIsAlgorithmSupported(key, .decrypt, .rsaEncryptionPKCS1) else {
            throw PartnerRSAError.unsupportedKeyAlgorithm
        }
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(key, .rsaEncryptionPKCS1, ciphertext as CFData, &error) else {
            _ = error?.takeRetainedValue()
            throw PartnerRSAError.decryptionFailed
        }
        return plain as Data
    }
}

private struct DERReader {
    private let bytes: [UInt8]
    private var position = 0
    init(_ data: Data) { bytes = Array(data) }
    var isEmpty: Bool { position == bytes.count }
    private mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw PartnerRSAError.invalidDER }
        defer { position += 1 }
        return bytes[position]
    }
    mutating func value(tag: UInt8) throws -> Data {
        guard try byte() == tag else { throw PartnerRSAError.invalidDER }
        let first = try byte()
        var length = Int(first)
        if first & 0x80 != 0 {
            let count = Int(first & 0x7f)
            guard count > 0, count <= 4 else { throw PartnerRSAError.invalidDER }
            length = 0
            for index in 0..<count {
                let part = try byte()
                guard index != 0 || part != 0 else { throw PartnerRSAError.invalidDER }
                length = length * 256 + Int(part)
            }
            guard length >= 128 else { throw PartnerRSAError.invalidDER }
        }
        guard length <= bytes.count - position else { throw PartnerRSAError.invalidDER }
        defer { position += length }
        return Data(bytes[position..<(position + length)])
    }
}
