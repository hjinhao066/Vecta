import Foundation

/// Ledger §5.10 and NB100 docs/04-commands: request 30, response 31.
/// This is not stop-sync (request 29 / response 30) or a factory reset.
public enum ProtocolFileDeletion {
    public static func request(sessionID: UInt32) throws -> Data {
        guard sessionID > 0 else { throw ProtocolWireError.malformedResponse }
        return Data([1, 0x1e, 0] + (0..<4).map { UInt8(truncatingIfNeeded: sessionID >> ($0 * 8)) })
    }
    public static func response(_ payload: Data, version: UInt16, expectedSession: UInt32) throws -> UInt8 {
        let bytes = Array(payload)
        guard version >= 7, bytes.count == 8, Array(bytes.prefix(3)) == [1, 0x1f, 0] else { throw ProtocolWireError.malformedResponse }
        let session = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[3 + $1]) << ($1 * 8) }
        guard session == expectedSession else { throw ProtocolWireError.malformedResponse }
        return bytes[7]
    }
}

/// Serial operation scope: acknowledgement advances only the confirmed list;
/// local unlink is permitted only after a fresh empty recorder list.
public struct ProtocolDeletionPlan {
    public private(set) var remaining: [UInt32]
    public private(set) var awaiting: UInt32?
    public init(sessions: [UInt32]) throws {
        guard Set(sessions).count == sessions.count, sessions.allSatisfy({ $0 > 0 }) else { throw ProtocolWireError.malformedResponse }
        remaining = sessions
    }
    public mutating func next() throws -> UInt32? {
        guard awaiting == nil else { throw ProtocolWireError.malformedResponse }
        guard !remaining.isEmpty else { return nil }
        awaiting = remaining.removeFirst(); return awaiting
    }
    public mutating func acknowledge(_ payload: Data, version: UInt16) throws {
        guard let awaiting, try ProtocolFileDeletion.response(payload, version: version, expectedSession: awaiting) == 0 else { throw ProtocolWireError.malformedResponse }
        self.awaiting = nil
    }
    public func confirmEmpty(_ sessions: [UInt32]) throws {
        guard remaining.isEmpty, awaiting == nil, sessions.isEmpty else { throw ProtocolWireError.malformedResponse }
    }
}
