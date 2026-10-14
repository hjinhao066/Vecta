import Foundation
import Darwin

public enum NativeAudioError: Error, Equatable {
    case malformedPacket, unsupportedPacket, invalidHeader, unsupportedChannels
    case encryptedFileRequiresKey, invalidKey, malformedOpus, malformedOgg
    case checksumMismatch, incompleteAudio, codecFailure(Int32), outputExists
    case invalidFileSize, sessionMismatch, unexpectedOffset, duplicatePacket
}

/// Parses the authenticated plaintext, AFTER removal of the transport sequence.
/// Vendor evidence: Android BleAgentImpl$1.onCallback, SyncFileHeadRsp/TailRsp.
/// This API intentionally offers only full-file transfer; it cannot resume.
public enum AudioDownloadPacket: Equatable {
    case head(session: UInt32, status: UInt8)
    case data(session: UInt32, offset: UInt32, bytes: Data)
    case empty(session: UInt32, code: UInt8)
    case tail(session: UInt32, crc: UInt16)

    /// SyncRecFileStartReq. `end` is the complete byte size requested from
    /// offset zero; there is deliberately no resume-offset API here.
    public static func fullRequest(session: UInt32, end: UInt32) -> Data {
        Data([1, 0x1c, 0]) + audioLE(session) + audioLE(0) + audioLE(end)
    }

    /// The vendor's transfer callback shares TX with other control responses.
    /// Dispatch only the two transfer commands; malformed transfer/data frames
    /// still throw rather than being mistaken for an unrelated notification.
    public static func parseTransfer(_ plaintext: Data, protocolVersion: UInt16 = 20, expectedSession: UInt32? = nil) throws -> AudioDownloadPacket? {
        if plaintext.first == 1 {
            let header = Array(plaintext.prefix(3))
            guard header.count == 3 else { throw NativeAudioError.malformedPacket }
            let command = audioUInt16(header, 1)
            guard command == 0x1c || command == 0x1d else { return nil }
        }
        return try parse(plaintext, protocolVersion: protocolVersion, expectedSession: expectedSession)
    }

    public static func parse(_ plaintext: Data, protocolVersion: UInt16 = 20, expectedSession: UInt32? = nil) throws -> AudioDownloadPacket {
        let b = Array(plaintext)
        guard let type = b.first else { throw NativeAudioError.malformedPacket }
        if type == 1 {
            guard b.count >= 3 else { throw NativeAudioError.malformedPacket }
            if b[1] == 0x1c, b[2] == 0 {
                guard b.count == 8 else { throw NativeAudioError.malformedPacket }
                return .head(session: audioUInt32(b, 3), status: b[7])
            }
            if b[1] == 0x1d, b[2] == 0 {
                guard b.count == 9 else { throw NativeAudioError.malformedPacket }
                return .tail(session: audioUInt32(b, 3), crc: audioUInt16(b, 7))
            }
            throw NativeAudioError.unsupportedPacket
        }
        guard type == 2 || type == 3 else { throw NativeAudioError.unsupportedPacket }
        let cursor = protocolVersion >= 7 ? 5 : 1
        guard b.count >= cursor + 5 else { throw NativeAudioError.malformedPacket }
        let session: UInt32
        if protocolVersion >= 7 { session = audioUInt32(b, 1) }
        else { guard let selected = expectedSession else { throw NativeAudioError.sessionMismatch }; session = selected }
        let offset = audioUInt32(b, cursor)
        if offset == UInt32.max {
            // NotePin S firmware sends the end sentinel in a full-size
            // authenticated notification. Remaining bytes are not audio.
            guard b.count >= cursor + 6 else { throw NativeAudioError.malformedPacket }
            return .empty(session: session, code: b[cursor + 5])
        }
        let length = Int(b[cursor + 4])
        guard length > 0, b.count == cursor + 5 + length else { throw NativeAudioError.malformedPacket }
        return .data(session: session, offset: offset, bytes: Data(b[(cursor + 5)...]))
    }
}

/// Collects one authenticated file transfer. The staging file is published
/// only after the vendor's tail CRC and the advertised byte count agree.
public final class AudioDownloadCollector {
    public let session: UInt32
    public let expectedByteSize: UInt32
    public let stagingURL: URL
    private let handle: FileHandle
    private var nextOffset: UInt32 = 0
    private var crc: UInt16
    public var computedCRC: UInt16 { crc }
    private var sawHead = false
    private var finished = false
    private let authenticatedPackets: Bool
    public var receivedByteCount: UInt32 { nextOffset }

    public init(session: UInt32, expectedByteSize: UInt32, stagingURL: URL, crcInitial: UInt16 = 0, authenticatedPackets: Bool = false) throws {
        self.crc = crcInitial
        self.authenticatedPackets = authenticatedPackets
        guard stagingURL.isFileURL, expectedByteSize > 0, expectedByteSize <= 536_870_912 else {
            throw NativeAudioError.invalidFileSize
        }
        self.session = session
        self.expectedByteSize = expectedByteSize
        self.stagingURL = stagingURL
        try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        let fd = open(stagingURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST { throw NativeAudioError.outputExists }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    deinit {
        try? handle.close()
        if !finished { try? FileManager.default.removeItem(at: stagingURL) }
    }

    /// Accepts a parsed plaintext packet. Returns the staging URL only for a
    /// verified tail packet; all earlier packets return nil.
    @discardableResult
    public func accept(_ packet: AudioDownloadPacket) throws -> URL? {
        guard !finished else { throw NativeAudioError.duplicatePacket }
        switch packet {
        case let .head(packetSession, status):
            guard packetSession == session else { throw NativeAudioError.sessionMismatch }
            guard !sawHead, status == 0 else { throw NativeAudioError.incompleteAudio }
            sawHead = true
        case let .data(packetSession, offset, bytes):
            guard packetSession == session else { throw NativeAudioError.sessionMismatch }
            guard sawHead else { throw NativeAudioError.incompleteAudio }
            guard offset == nextOffset else { throw NativeAudioError.unexpectedOffset }
            guard !bytes.isEmpty,
                  UInt64(nextOffset) + UInt64(bytes.count) <= UInt64(expectedByteSize) else {
                throw NativeAudioError.invalidFileSize
            }
            try handle.write(contentsOf: bytes)
            crc = NativeAudioCRC.update(crc, bytes)
            nextOffset += UInt32(bytes.count)
        case let .empty(packetSession, code):
            guard packetSession == session else { throw NativeAudioError.sessionMismatch }
            guard sawHead, nextOffset == expectedByteSize, code == 0 || code == 1 else { throw NativeAudioError.incompleteAudio }
            // End marker alone is never success. Await tail and verify full CRC.
        case let .tail(packetSession, expectedCRC):
            guard packetSession == session else { throw NativeAudioError.sessionMismatch }
            guard sawHead, nextOffset == expectedByteSize else { throw NativeAudioError.incompleteAudio }
            // Modern NotePin S returns 0xffff rather than a file CRC.
            // Only an AEAD-authenticated transport may use full-size/offset
            // integrity when firmware omits that checksum. Legacy stays strict.
            guard crc == expectedCRC || (authenticatedPackets && expectedCRC == 0xffff) else { throw NativeAudioError.checksumMismatch }
            try handle.synchronize(); try handle.close()
            finished = true
            return stagingURL
        }
        return nil
    }
}

/// CRC used by TntBleCommUtils for the file tail, recovered from the pinned
/// vendor binary. It is intentionally separate from Ogg page CRC handling.
public enum NativeAudioCRC {
    public static func update(_ initial: UInt16, _ data: Data) -> UInt16 {
        data.reduce(initial) { crc, byte in
            let rotated = (crc << 8) | (crc >> 8)
            let mixed = rotated ^ UInt16(byte)
            let folded = mixed ^ ((mixed >> 4) & 0x000f)
            return folded ^ (folded << 12) ^ ((folded & 0x00ff) << 5)
        }
    }
    public static func calculate(_ data: Data) -> UInt16 { update(0, data) }
}

func audioLE(_ n: UInt32) -> Data {
    Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) })
}
func audioUInt32(_ b: [UInt8], _ at: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(b[at + $1]) << ($1 * 8) }
}
func audioUInt16(_ b: [UInt8], _ at: Int) -> UInt16 {
    UInt16(b[at]) | UInt16(b[at + 1]) << 8
}
