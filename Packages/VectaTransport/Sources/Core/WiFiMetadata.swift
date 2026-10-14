import Foundation
import CryptoKit

public protocol WiFiMetadata: Codable {
    static var command: WiFiCommand { get }
    static var permitsBinary: Bool { get }
    func validate() throws
}

public extension WiFiMetadata {
    static var permitsBinary: Bool { false }
    func validate() throws {}
}

public extension WiFiEnvelope {
    init<M: WiFiMetadata>(metadata: M, binary: Data = Data()) throws {
        try metadata.validate()
        guard M.permitsBinary || binary.isEmpty else { throw WiFiProtocolError.unexpectedBinary }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try self.init(command: M.command, json: encoder.encode(metadata), binary: binary)
    }

    func metadata<M: WiFiMetadata>(as type: M.Type) throws -> M {
        guard command == M.command else { throw WiFiProtocolError.unexpectedCommand }
        guard M.permitsBinary || binary.isEmpty else { throw WiFiProtocolError.unexpectedBinary }
        let value: M
        do { value = try JSONDecoder().decode(type, from: json) }
        catch { throw WiFiProtocolError.invalidMetadata }
        try value.validate()
        return value
    }
}

public struct WiFiHandshake: WiFiMetadata, Equatable {
    public static let command = WiFiCommand.handshake
    public let token: String
    /// Integer Unix seconds, supplied explicitly rather than consulting a clock.
    public let stamp: UInt64
    /// Pads the cached owner token with ASCII '0' to a minimum of 32 bytes;
    /// longer tokens are preserved, never truncated. This is not an MD5 operation.
    public init(token: String, stamp: UInt64) throws {
        guard !token.isEmpty, token.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            throw WiFiProtocolError.invalidMetadata
        }
        self.token = token + String(repeating: "0", count: max(0, 32 - token.utf8.count))
        self.stamp = stamp
    }
    public func validate() throws {
        guard token.utf8.count >= 32, token.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            throw WiFiProtocolError.invalidMetadata
        }
    }
}

/// Status must be present and exactly zero for acceptance. An absent/empty session
/// is not universally invalid; firmware-specific session/token semantics are unverified.
public struct WiFiHandshakeResponse: WiFiMetadata, Equatable {
    public static let command = WiFiCommand.handshake
    public let status: Int32
    public let session: String?
    public var accepted: Bool { status == 0 }
    public init(status: Int32, session: String? = nil) { self.status = status; self.session = session }
}

/// Version fields differ across protocol evidence; preserve integer/string forms
/// without inventing a conversion or treating them as authorization evidence.
public enum WiFiVersion: Codable, Equatable {
    case number(UInt64)
    case signedNumber(Int64)
    case string(String)
    public var numericValue: UInt64? {
        if case .number(let value) = self { return value }
        return nil
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(UInt64.self) { self = .number(value) }
        else if let value = try? container.decode(Int64.self) { self = .signedNumber(value) }
        else { self = .string(try container.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .signedNumber(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// Firmware may identify itself by serial, the SDK's serial digest, or both.
/// Match only after authenticated decryption; version metadata is not BLE authorization.
public struct WiFiSayHello: WiFiMetadata, Equatable {
    public static let command = WiFiCommand.sayHello
    public let sn: String?
    public let version: WiFiVersion?
    public let token: String
    public let pVer: WiFiVersion?
    public init(sn: String? = nil, version: WiFiVersion? = nil, token: String = "", pVer: WiFiVersion? = nil) {
        self.sn = sn; self.version = version; self.token = token; self.pVer = pVer
    }
    private enum CodingKeys: String, CodingKey { case sn, version, token, pVer }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sn = try container.decodeIfPresent(String.self, forKey: .sn)
        version = try container.decodeIfPresent(WiFiVersion.self, forKey: .version)
        token = container.contains(.token) ? try container.decode(String.self, forKey: .token) : ""
        pVer = try container.decodeIfPresent(WiFiVersion.self, forKey: .pVer)
    }

    public func matches(serial: String) -> Bool {
        guard !serial.isEmpty, serial.utf8.count <= 128,
              serial.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return false }
        // The newer SDK's serial-bearing hello can carry an opaque owner/session token.
        // Do not confuse it with the older token-only serial-checksum identity form.
        if let sn, !sn.isEmpty { return sn == serial }
        guard token.utf8.count == 32,
              token.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return false }
        // Official SDK wire identity checksum, not password hashing or a substitute for AEAD.
        let expected = Insecure.MD5.hash(data: Data(serial.utf8)).map { String(format: "%02x", $0) }.joined()
        return token.lowercased() == expected
    }
}

public struct WiFiHeartbeat: WiFiMetadata, Equatable {
    public static let command = WiFiCommand.heartbeat
    public let stamp: UInt64?
    public init(stamp: UInt64? = nil) { self.stamp = stamp }
}

public struct WiFiListRequest: WiFiMetadata, Equatable {
    public static let command = WiFiCommand.list
    public let uid: UInt32
    public let start: UInt32
    public let single: UInt8
    public init(uid: UInt32, start: UInt32 = 0, single: UInt8 = 0) {
        self.uid = uid; self.start = start; self.single = single
    }
    public func validate() throws {
        guard single <= 1 else { throw WiFiProtocolError.invalidMetadata }
    }
}

public struct WiFiListResponse: WiFiMetadata, Equatable {
    public static let command = WiFiCommand.list
    public static let permitsBinary = true
    public let status: Int32
    public let uid: UInt32?
    /// Total inventory count, not this page's entry count. Entries are ten bytes each.
    public let count: UInt32
    public let offset: UInt32
    public var accepted: Bool { status == 0 }
    public init(status: Int32, count: UInt32, offset: UInt32, uid: UInt32? = nil) {
        self.status = status; self.count = count; self.offset = offset; self.uid = uid
    }
}

/// WiFi's u16 scene is distinct from BLE's scene/attribute byte pair.
public struct WiFiRecordingFile: Codable, Equatable, Hashable {
    public let session: UInt32
    public let size: UInt32
    public let scene: UInt16
    public init(session: UInt32, size: UInt32, scene: UInt16) {
        self.session = session; self.size = size; self.scene = scene
    }
}

public struct WiFiDownloadRequest: WiFiMetadata, Equatable {
    public static let command = WiFiCommand.download
    public let session: UInt32
    public let scene: UInt16
    public let start: UInt32
    public let end: UInt32
    public init(session: UInt32, scene: UInt16, start: UInt32, end: UInt32) {
        self.session = session; self.scene = scene; self.start = start; self.end = end
    }
    public func validate() throws {
        guard start <= end else { throw WiFiProtocolError.invalidMetadata }
    }
}

public struct WiFiDownloadResponse: WiFiMetadata, Equatable {
    public static let command = WiFiCommand.download
    public let status: Int32
    public let session: UInt32
    /// SDK replies may omit total or send zero; the authenticated inventory remains authoritative.
    public let total: UInt32?
    public var accepted: Bool { status == 0 }
    public init(status: Int32, session: UInt32, total: UInt32? = nil) {
        self.status = status; self.session = session; self.total = total
    }
}

public struct WiFiContentMetadata: WiFiMetadata, Equatable {
    public static let command = WiFiCommand.content
    public static let permitsBinary = true
    public let session: UInt32
    public let offset: UInt32
    public let length: UInt32
    public let last: UInt8
    public init(session: UInt32, offset: UInt32, length: UInt32, last: UInt8) {
        self.session = session; self.offset = offset; self.length = length; self.last = last
    }
    public func validate() throws {
        guard last <= 1 else { throw WiFiProtocolError.invalidTerminal }
    }
}

public struct WiFiFileListPage: Equatable {
    public let metadata: WiFiListResponse
    public let files: [WiFiRecordingFile]

    public init(envelope: WiFiEnvelope, maximumFiles: Int = 4096) throws {
        guard maximumFiles >= 0 else { throw WiFiProtocolError.invalidLimit }
        let metadata = try envelope.metadata(as: WiFiListResponse.self)
        guard metadata.accepted else { throw WiFiProtocolError.remoteStatus(metadata.status) }
        let entrySize = 10
        guard envelope.binary.count % entrySize == 0 else { throw WiFiProtocolError.wrongLength }
        let entries = envelope.binary.count / entrySize
        guard UInt64(metadata.count) <= UInt64(maximumFiles), metadata.offset <= metadata.count,
              UInt64(entries) <= UInt64(metadata.count - metadata.offset) else {
            throw WiFiProtocolError.inconsistentInventory
        }
        var files: [WiFiRecordingFile] = []
        files.reserveCapacity(entries)
        // Use relative indices so Data slices with a nonzero startIndex also work.
        for index in 0..<entries {
            let base = envelope.binary.startIndex + index * entrySize
            func u32(_ offset: Int) -> UInt32 {
                (0..<4).reduce(UInt32(0)) { $0 | UInt32(envelope.binary[base + offset + $1]) << ($1 * 8) }
            }
            let scene = UInt16(envelope.binary[base + 8]) | UInt16(envelope.binary[base + 9]) << 8
            files.append(WiFiRecordingFile(session: u32(0), size: u32(4), scene: scene))
        }
        self.metadata = metadata
        self.files = files
    }
}
