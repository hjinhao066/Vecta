import Foundation

/// Read-only getMarking, verified against the pinned official SDK serializer.
/// Points stay lossless: the public SDK does not specify their time unit.
public enum ProtocolRecordingMarks {
    public static func request(session: UInt32) -> Data {
        Data([1, 0x23, 0, UInt8(truncatingIfNeeded: session), UInt8(truncatingIfNeeded: session >> 8),
              UInt8(truncatingIfNeeded: session >> 16), UInt8(truncatingIfNeeded: session >> 24)])
    }
}

public struct ProtocolRecordingMarksPage: Equatable {
    public let session: UInt32
    public let status: UInt8
    public let pageCount: Int
    public let index: Int
    public let points: [UInt32]

    public static func decode(_ data: Data) throws -> Self {
        let b = Array(data)
        guard b.count >= 8, Array(b.prefix(3)) == [1, 0x23, 0] else { throw ProtocolWireError.malformedResponse }
        let session = read32(b, 3), status = b[7]
        if status != 0 {
            guard b.count == 8 || (b.count == 11 && b[8...10].allSatisfy({ $0 == 0 })) else { throw ProtocolWireError.malformedResponse }
            return Self(session: session, status: status, pageCount: 0, index: 0, points: [])
        }
        guard b.count >= 9 else { throw ProtocolWireError.malformedResponse }
        if b[8] == 0 {
            guard b.count == 9 || (b.count == 11 && b[9] == 0 && b[10] == 0) else { throw ProtocolWireError.malformedResponse }
            return Self(session: session, status: 0, pageCount: 0, index: 0, points: [])
        }
        guard b.count >= 11, b[9] < b[8], b.count == 11 + Int(b[10]) * 4 else { throw ProtocolWireError.malformedResponse }
        return Self(session: session, status: 0, pageCount: Int(b[8]), index: Int(b[9]),
                    points: stride(from: 11, to: b.count, by: 4).map { read32(b, $0) })
    }
    private static func read32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24
    }
}

/// Pages may be reordered or duplicated; incomplete data is never published.
public struct ProtocolRecordingMarksCollector {
    public let session: UInt32
    private var total: Int?
    private var pages: [Int: [UInt32]] = [:]
    public init(session: UInt32) { self.session = session }
    public mutating func accept(_ page: ProtocolRecordingMarksPage) throws -> [UInt32]? {
        guard page.session == session, page.status == 0 else { throw ProtocolWireError.inconsistentPage }
        if let total, total != page.pageCount { throw ProtocolWireError.inconsistentPage }
        total = page.pageCount
        if let old = pages[page.index], old != page.points { throw ProtocolWireError.inconsistentPage }
        pages[page.index] = page.points
        guard page.pageCount == 0 || pages.count == page.pageCount else { return nil }
        return (0..<page.pageCount).flatMap { pages[$0] ?? [] }
    }
}
