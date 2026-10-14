import Foundation

public enum HandshakeChunkError: Error, Equatable {
    case invalidHeader
    case inconsistentCount
    case conflictingDuplicate
    case payloadLimitExceeded
}

/// Bounded, receive-only reconstruction of RSA bootstrap notifications.
/// Android SDK: header FE12 (little endian), count, zero-based index, data.
/// A valid reconstructed payload still requires RSA decryption and proof check.
public struct HandshakeChunks {
    private var expectedCount: Int?
    private var chunks: [Int: Data] = [:]
    private var byteCount = 0
    private let maximumPayloadBytes: Int

    public init(maximumPayloadBytes: Int = 4096) {
        self.maximumPayloadBytes = max(0, maximumPayloadBytes)
    }

    public mutating func accept(_ notification: Data) throws -> Data? {
        let bytes = Array(notification)
        guard bytes.count > 4, bytes[0] == 0x12, bytes[1] == 0xfe,
              bytes[2] > 0, bytes[3] < bytes[2] else {
            throw HandshakeChunkError.invalidHeader
        }
        let count = Int(bytes[2]), index = Int(bytes[3])
        if let expectedCount, expectedCount != count { throw HandshakeChunkError.inconsistentCount }
        let payload = Data(bytes.dropFirst(4))
        if let prior = chunks[index] {
            guard prior == payload else { throw HandshakeChunkError.conflictingDuplicate }
        } else {
            guard payload.count <= maximumPayloadBytes - byteCount else {
                throw HandshakeChunkError.payloadLimitExceeded
            }
            expectedCount = count
            chunks[index] = payload
            byteCount += payload.count
        }
        guard chunks.count == count else { return nil }
        return (0..<count).reduce(into: Data()) { $0.append(chunks[$1]!) }
    }
}
