import CryptoKit
import Foundation

public enum TransportDecodeError: Error, Equatable {
    case malformedSessionMaterial
    case invalidRecorderProof
    case malformedEncryptedPacket
}

/// Experimental receive-side decoder for the SDK's protocol >= 20.
/// Source: Android BluetoothLeOperation.BleGattCallback, pinned in README.
/// Connection ownership and the allowed command set are the driver's job.
public final class SessionMaterial {
    private let key: SymmetricKey
    private let nonce: ChaChaPoly.Nonce
    private let additionalData: Data

    private init(key: Data, nonce: Data, additionalData: Data) throws {
        self.key = SymmetricKey(data: key)
        self.nonce = try ChaChaPoly.Nonce(data: nonce)
        self.additionalData = additionalData
    }

    /// Input must already have been decrypted by the user's PLAUD-issued RSA
    /// private key. The recorder proof is authenticated before use of keys.
    public static func authenticate(rsaPlaintext: Data) throws -> SessionMaterial {
        let bytes = Data(rsaPlaintext)
        guard bytes.count >= 56 + 16 else {
            throw TransportDecodeError.malformedSessionMaterial
        }
        let material = try SessionMaterial(key: bytes.subdata(in: 0..<32),
            nonce: bytes.subdata(in: 32..<44), additionalData: bytes.subdata(in: 44..<56))
        let proof = try material.open(bytes.subdata(in: 56..<bytes.count))
        guard proof == Data("PLAUD.AI".utf8) else {
            throw TransportDecodeError.invalidRecorderProof
        }
        return material
    }

    /// SDK ciphertext is followed by a 16-byte tag, without CryptoKit's
    /// combined representation's 12-byte nonce prefix.
    func open(_ ciphertextAndTag: Data) throws -> Data {
        guard ciphertextAndTag.count >= 16 else {
            throw TransportDecodeError.malformedEncryptedPacket
        }
        let bytes = Data(ciphertextAndTag)
        let box = try ChaChaPoly.SealedBox(nonce: nonce,
            ciphertext: bytes.dropLast(16), tag: bytes.suffix(16))
        return try ChaChaPoly.open(box, using: key, authenticating: additionalData)
    }

    public func decodePacket(_ ciphertextAndTag: Data) throws -> ReceivedPacket {
        let plain = try open(ciphertextAndTag)
        guard plain.count >= 4 else { throw TransportDecodeError.malformedEncryptedPacket }
        let bytes = Array(plain.prefix(4))
        let sequence = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        return ReceivedPacket(sequence: sequence, payload: Data(plain.dropFirst(4)))
    }

    /// The complete audio file uses the negotiated AEAD material but has no
    /// control-packet sequence prefix. Authenticate before decoding any audio.
    public func decodeAudioFile(ciphertextAndTag: Data) throws -> Data {
        try open(ciphertextAndTag)
    }

    /// BluetoothLeOperation.sendData: sequenceLE32 + command encrypted with the
    /// negotiated key/nonce/AAD, followed by16-byte tag, no nonce prefix.
    /// Drivers must serialize sequence allocation and enforce their command set.
    public func sealPacket(sequence: UInt32, payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= 4096 else {
            throw TransportDecodeError.malformedEncryptedPacket
        }
        var plain = Data((0..<4).map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) })
        plain.append(payload)
        let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce, authenticating: additionalData)
        // CryptoKit's ciphertext is a Data slice whose startIndex may be12.
        // Appending into fresh Data makes the public wire packet zero-indexed.
        var packet = Data()
        packet.append(box.ciphertext)
        packet.append(box.tag)
        return packet
    }

    /// WiFi uses the negotiated material and a sequence-prefixed complete PDU.
    /// This preserves firmware framing; it does not resolve fixed-nonce reuse.
    public func sealWiFiPacket(sequence: UInt32, payload: Data, cipher: WiFiPacketCipher) throws -> Data {
        guard !payload.isEmpty, payload.count <= 0xffffff else { throw TransportDecodeError.malformedEncryptedPacket }
        var plain = Data((0..<4).map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) })
        plain.append(payload)
        switch cipher {
        case .chaChaPoly:
            let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce, authenticating: additionalData)
            return Data(box.ciphertext) + Data(box.tag)
        case .aesGCM:
            let aesNonce = try AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) })
            let box = try AES.GCM.seal(plain, using: key, nonce: aesNonce, authenticating: additionalData)
            return Data(box.ciphertext) + Data(box.tag)
        }
    }
    public func decodeWiFiPacket(_ bytes: Data, cipher: WiFiPacketCipher) throws -> ReceivedPacket {
        guard bytes.count >= 20, bytes.count <= 0xffffff + 20 else { throw TransportDecodeError.malformedEncryptedPacket }
        let plain: Data
        switch cipher {
        case .chaChaPoly: plain = try open(bytes)
        case .aesGCM:
            let aesNonce = try AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) })
            let box = try AES.GCM.SealedBox(nonce: aesNonce, ciphertext: bytes.dropLast(16), tag: bytes.suffix(16))
            plain = try AES.GCM.open(box, using: key, authenticating: additionalData)
        }
        guard plain.count > 4 else { throw TransportDecodeError.malformedEncryptedPacket }
        let sequence = plain.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        return ReceivedPacket(sequence: sequence, payload: Data(plain.dropFirst(4)))
    }
}

public enum WiFiPacketCipher: Equatable, Sendable { case chaChaPoly, aesGCM }

public struct ReceivedPacket: Equatable {
    public let sequence: UInt32
    public let payload: Data
}
