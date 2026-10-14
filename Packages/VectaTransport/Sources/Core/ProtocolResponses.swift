import Foundation

/// These values are decoded protocol facts, not inferred device states.
public struct ProtocolOwnerStatus: Equatable {
    public let status: UInt8
    public let protocolVersion: UInt16
    public let timezone: UInt8
    public let timezoneMinutes: UInt8?
    public let audioChannels: UInt8?
    public let supportsWiFi: Bool?
    public let noNSAGC: Bool?
    public let isOggAudio: Bool?
    /// HandShakeRsp + BleAgentImpl: status exactly0 succeeds, all others fail.
    public var accepted: Bool { status == 0 }
}

public enum ProtocolOwnerResponse: Equatable {
    case status(ProtocolOwnerStatus)
    case serialNumber(String)

    public static func decode(_ payload: Data) throws -> ProtocolOwnerResponse {
        let bytes = Array(payload)
        guard bytes.count >= 3, bytes[0] == 1, bytes[2] == 0 else {
            throw ProtocolWireError.malformedResponse
        }
        switch bytes[1] {
        case 1:
            guard bytes.count >= 7 else { throw ProtocolWireError.malformedResponse }
            return .status(ProtocolOwnerStatus(status: bytes[3], protocolVersion: u16(bytes, 4),
                timezone: bytes[6], timezoneMinutes: optional(bytes, 7),
                audioChannels: optional(bytes, 8), supportsWiFi: optional(bytes, 9).map { $0 == 1 },
                noNSAGC: optional(bytes, 10).map { $0 == 1 },
                isOggAudio: optional(bytes, 11).map { $0 == 1 }))
        case 2:
            // GetSsnRsp: a56-byte NUL-terminated serial field at offset3.
            guard bytes.count >= 59 else { throw ProtocolWireError.malformedResponse }
            let field = Array(bytes[3..<59].prefix { $0 != 0 })
            guard !field.isEmpty, field.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }),
                  let serial = String(bytes: field, encoding: .ascii) else {
                throw ProtocolWireError.malformedResponse
            }
            return .serialNumber(serial)
        default: throw ProtocolWireError.unexpectedCommand
        }
    }
}

public struct ProtocolRecorderState: Equatable {
    public let state: UInt32
    public let privacyEnabled: Bool
    public let keyStateValue: UInt8?
    public let usbConnected: Bool?
    public let scene: UInt8?
    public let sessionID: UInt32?
    public let findMyState: UInt8?
    public let soundPlusKeyState: UInt8?
    public let httpTokenState: UInt8?

    public static func decode(_ payload: Data) throws -> ProtocolRecorderState {
        let bytes = Array(payload)
        try checkHeader(bytes, command: 3)
        guard bytes.count >= 8 else { throw ProtocolWireError.malformedResponse }
        return ProtocolRecorderState(state: u32(bytes, 3), privacyEnabled: bytes[7] == 1,
            keyStateValue: optional(bytes, 8), usbConnected: optional(bytes, 9).map { $0 == 1 },
            scene: bytes.count >= 15 ? bytes[10] : nil,
            sessionID: bytes.count >= 15 ? u32(bytes, 11) : nil,
            findMyState: optional(bytes, 15), soundPlusKeyState: optional(bytes, 16),
            httpTokenState: optional(bytes, 17))
    }
}

public struct ProtocolRecordingFile: Equatable, Codable {
    public let sessionID: UInt32
    public let byteSize: UInt32
    public let scene: UInt8
    public let attribute: UInt8
}

public struct ProtocolFileListPage: Equatable {
    public let requestID: UInt32
    public let total: Int
    public let startIndex: Int
    public let files: [ProtocolRecordingFile]

    /// GetRecSessionsRsp: header3, correlation4, total2, index2, entries8/9/10.
    public static func decode(_ payload: Data, protocolVersion: UInt16) throws -> ProtocolFileListPage {
        let bytes = Array(payload)
        try checkHeader(bytes, command: 0x1a)
        guard bytes.count >= 9, protocolVersion >= 1 else { throw ProtocolWireError.malformedResponse }
        // Vendor constructs total from the nine-byte header before looking for
        // entries. A zero-entry response can omit the start-index field.
        if bytes.count == 9, u16(bytes, 7) == 0 {
            return ProtocolFileListPage(requestID: u32(bytes, 3), total: 0, startIndex: 0, files: [])
        }
        guard bytes.count >= 11 else { throw ProtocolWireError.malformedResponse }
        let width = protocolVersion == 1 ? 8 : (protocolVersion <= 6 ? 9 : 10)
        guard (bytes.count - 11) % width == 0 else { throw ProtocolWireError.malformedResponse }
        let total = Int(u16(bytes, 7)), start = Int(u16(bytes, 9)), count = (bytes.count - 11) / width
        guard start <= total, count <= total - start else { throw ProtocolWireError.inconsistentPage }
        var files: [ProtocolRecordingFile] = []
        for offset in stride(from: 11, to: bytes.count, by: width) {
            files.append(ProtocolRecordingFile(sessionID: u32(bytes, offset), byteSize: u32(bytes, offset + 4),
                scene: width == 10 ? bytes[offset + 8] : 0,
                attribute: width == 10 ? bytes[offset + 9] : (width == 9 ? bytes[offset + 8] : 0)))
        }
        return ProtocolFileListPage(requestID: u32(bytes, 3), total: total, startIndex: start, files: files)
    }
}

/// Correlates the full response and rejects changed totals/overlapping conflicts.
/// Duplicate notifications are safe; completion requires all advertised entries.
public struct ProtocolFileListCollector {
    private let requestID: UInt32
    private let maximumFiles: Int
    private var total: Int?
    private var received: [Int: ProtocolRecordingFile] = [:]
    public init(requestID: UInt32, maximumFiles: Int = 4096) {
        self.requestID = requestID
        self.maximumFiles = max(0, maximumFiles)
    }
    public var receivedCount: Int { received.count }
    public mutating func accept(_ page: ProtocolFileListPage) throws -> [ProtocolRecordingFile]? {
        guard page.requestID == requestID else { throw ProtocolWireError.unexpectedRequestID }
        guard page.total <= maximumFiles else { throw ProtocolWireError.inconsistentPage }
        guard total == nil || total == page.total else { throw ProtocolWireError.inconsistentPage }
        for (index, file) in page.files.enumerated() {
            if let old = received[page.startIndex + index], old != file { throw ProtocolWireError.conflictingPage }
        }
        total = page.total
        for (index, file) in page.files.enumerated() { received[page.startIndex + index] = file }
        guard received.count == page.total else { return nil }
        return (0..<page.total).map { received[$0]! }
    }
}

private func checkHeader(_ bytes: [UInt8], command: UInt8) throws {
    guard bytes.count >= 3 else { throw ProtocolWireError.malformedResponse }
    guard bytes[0] == 1, bytes[1] == command, bytes[2] == 0 else { throw ProtocolWireError.unexpectedCommand }
}
private func optional(_ bytes: [UInt8], _ offset: Int) -> UInt8? {
    offset < bytes.count ? bytes[offset] : nil
}
private func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}
private func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
}
