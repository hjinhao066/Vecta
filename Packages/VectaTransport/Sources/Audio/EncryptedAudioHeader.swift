import Foundation
import NotePinTransport

/// File E2EE is a different layer from authenticated Bluetooth packets.
/// Layout verified against the pinned Android PlaudEncryptHeader constructor.
public struct EncryptedAudioHeader: Equatable {
    public static let size = 512
    public let version: UInt16
    public let fileType: UInt16
    public let channels: UInt16
    public let encryptionType: UInt16
    public let durationSeconds: UInt32
    public let counter: UInt32
    public let segment: UInt32
    public let nonce: Data
    public let encryptedKey: Data

    public init(data: Data) throws {
        let b = Array(data)
        guard b.count >= Self.size, Data(b[0..<8]) == Data("PLAUD.AI".utf8),
              audioUInt16(b, 10) == Self.size else { throw NativeAudioError.invalidHeader }
        version = audioUInt16(b, 8)
        fileType = audioUInt16(b, 48)
        channels = audioUInt16(b, 50)
        encryptionType = audioUInt16(b, 52)
        durationSeconds = audioUInt32(b, 54)
        counter = audioUInt32(b, 128)
        segment = audioUInt32(b, 144)
        nonce = Data(b[132..<144])
        encryptedKey = Data(b[256..<512])
    }

    public static func isEncrypted(_ prefix: Data) -> Bool {
        prefix.prefix(8) == Data("PLAUD.AI".utf8)
    }

    public func decrypt(_ ciphertext: Data, privateKey: PartnerRSAKey) throws -> Data {
        let decoded = try privateKey.decryptBootstrap(encryptedKey)
        guard decoded.count == 32 else { throw NativeAudioError.invalidKey }
        return try decryptPayload(ciphertext, key: decoded)
    }

    // AudioExporter restarts the stream for each header.segment bytes;
    // the separate AudioDecryptor helper incorrectly ignores this field.
    // Source: protocol-ledger §8; NotePin S observed segment = 80.
    func decryptPayload(_ ciphertext: Data, key: Data) throws -> Data {
        if segment == 0 { return try AudioChaCha20.apply(ciphertext, key: key, nonce: nonce) }
        var output = Data(); output.reserveCapacity(ciphertext.count)
        let bytes = Array(ciphertext)
        for offset in stride(from: 0, to: bytes.count, by: Int(segment)) {
            try Task.checkCancellation()
            output.append(try AudioChaCha20.apply(Data(bytes[offset..<min(offset + Int(segment), bytes.count)]), key: key, nonce: nonce))
        }
        return output
    }
}

/// IETF ChaCha20 stream cipher (no authentication tag), RFC 8439 §2.3.
/// Used only after file-header RSA decryption; never substitutes for BLE AEAD.
enum AudioChaCha20 {
    static func apply(_ input: Data, key: Data, nonce: Data, initialCounter: UInt32 = 0) throws -> Data {
        guard key.count == 32, nonce.count == 12 else { throw NativeAudioError.invalidKey }
        let blocks = (input.count + 63) / 64
        guard UInt64(initialCounter) + UInt64(blocks) <= UInt64(UInt32.max) + 1 else {
            throw NativeAudioError.incompleteAudio
        }
        let k = Array(key), n = Array(nonce), original = Array(input)
        var output = original
        for blockIndex in 0..<blocks {
            let state: [UInt32] = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]
                + stride(from: 0, to: 32, by: 4).map { audioUInt32(k, $0) }
                + [initialCounter &+ UInt32(blockIndex)]
                + stride(from: 0, to: 12, by: 4).map { audioUInt32(n, $0) }
            var x = state
            for _ in 0..<10 {
                quarter(&x, 0, 4, 8, 12); quarter(&x, 1, 5, 9, 13)
                quarter(&x, 2, 6, 10, 14); quarter(&x, 3, 7, 11, 15)
                quarter(&x, 0, 5, 10, 15); quarter(&x, 1, 6, 11, 12)
                quarter(&x, 2, 7, 8, 13); quarter(&x, 3, 4, 9, 14)
            }
            let bytes = x.enumerated().flatMap { Array(audioLE($0.element &+ state[$0.offset])) }
            let start = blockIndex * 64
            for i in 0..<min(64, original.count - start) { output[start + i] ^= bytes[i] }
        }
        return Data(output)
    }
    private static func rotate(_ x: UInt32, _ count: UInt32) -> UInt32 { (x << count) | (x >> (32 - count)) }
    private static func quarter(_ x: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        x[a] = x[a] &+ x[b]; x[d] = rotate(x[d] ^ x[a], 16)
        x[c] = x[c] &+ x[d]; x[b] = rotate(x[b] ^ x[c], 12)
        x[a] = x[a] &+ x[b]; x[d] = rotate(x[d] ^ x[a], 8)
        x[c] = x[c] &+ x[d]; x[b] = rotate(x[b] ^ x[c], 7)
    }
}
