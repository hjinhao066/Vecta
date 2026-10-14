import Foundation

/// Sequential full-inventory collection. A baseline, when supplied, must match exactly
/// (order-independent session/scene/size). No BLE schema conversion is implicit.
/// WiFi list pages echo uid. A live caller must supply its request identifier,
/// serialize requests and discard the collector whenever its connection changes.
public struct WiFiFileListCollector {
    private struct Identity: Hashable {
        let session: UInt32
        let scene: UInt16
        init(_ file: WiFiRecordingFile) { session = file.session; scene = file.scene }
    }
    private let maximumFiles: Int
    private let expectedUID: UInt32?
    private let expected: [Identity: UInt32]?
    private var total: UInt32?
    private var files: [WiFiRecordingFile] = []
    private var identities: Set<Identity> = []
    public private(set) var isComplete = false
    public var receivedCount: Int { files.count }
    public var completedFiles: [WiFiRecordingFile]? { isComplete ? files : nil }

    public init(maximumFiles: Int = 4096, expectedFiles: [WiFiRecordingFile]? = nil, expectedUID: UInt32? = nil) throws {
        guard maximumFiles >= 0 else { throw WiFiProtocolError.invalidLimit }
        self.maximumFiles = maximumFiles
        self.expectedUID = expectedUID
        if let expectedFiles {
            guard expectedFiles.count <= maximumFiles else { throw WiFiProtocolError.inconsistentInventory }
            var snapshot: [Identity: UInt32] = [:]
            for file in expectedFiles {
                guard snapshot.updateValue(file.size, forKey: Identity(file)) == nil else {
                    throw WiFiProtocolError.duplicateFile
                }
            }
            expected = snapshot
        } else {
            expected = nil
        }
    }

    public mutating func accept(_ envelope: WiFiEnvelope) throws -> [WiFiRecordingFile]? {
        try accept(WiFiFileListPage(envelope: envelope, maximumFiles: maximumFiles))
    }

    /// Rejected pages leave state unchanged. Duplicates, gaps and count changes fail.
    public mutating func accept(_ page: WiFiFileListPage) throws -> [WiFiRecordingFile]? {
        if let expectedUID, page.metadata.uid != expectedUID { throw WiFiProtocolError.unexpectedRequestID }
        guard !isComplete, UInt64(page.metadata.count) <= UInt64(maximumFiles),
              total == nil || total == page.metadata.count,
              expected == nil || UInt64(expected!.count) == UInt64(page.metadata.count) else {
            throw WiFiProtocolError.inconsistentInventory
        }
        guard UInt64(page.metadata.offset) == UInt64(files.count) else { throw WiFiProtocolError.unexpectedOffset }
        guard !page.files.isEmpty || page.metadata.count == 0 else { throw WiFiProtocolError.inconsistentInventory }
        var newIdentities: Set<Identity> = []
        for file in page.files {
            let identity = Identity(file)
            guard !identities.contains(identity), newIdentities.insert(identity).inserted else {
                throw WiFiProtocolError.duplicateFile
            }
            if let expected, expected[identity] != file.size { throw WiFiProtocolError.inconsistentInventory }
        }
        total = page.metadata.count
        identities.formUnion(newIdentities)
        files.append(contentsOf: page.files)
        isComplete = UInt64(files.count) == UInt64(page.metadata.count)
        return completedFiles
    }
}

/// Pure full-file verification state, suitable for a caller-owned streaming sink.
/// Starts at offset zero; there is deliberately no partial-BLE/resume initializer.
/// "Verified" means metadata/size/order/terminal consistency, not a checksum or
/// cryptographic authentication. The caller must bind the stream to its handshake.
public struct WiFiFileTransferState {
    public let expectedSession: UInt32
    public let expectedSize: UInt32
    public private(set) var receivedByteCount: UInt32 = 0
    public private(set) var isStarted = false
    public private(set) var isComplete = false

    public init(expectedSession: UInt32, expectedSize: UInt32) {
        self.expectedSession = expectedSession
        self.expectedSize = expectedSize
    }

    public mutating func begin(_ envelope: WiFiEnvelope) throws {
        try begin(envelope.metadata(as: WiFiDownloadResponse.self))
    }

    public mutating func begin(_ response: WiFiDownloadResponse) throws {
        guard !isStarted else { throw WiFiProtocolError.transferAlreadyStarted }
        guard response.accepted else { throw WiFiProtocolError.remoteStatus(response.status) }
        guard response.session == expectedSession else { throw WiFiProtocolError.wrongSession }
        if let total = response.total, total > 0, total != expectedSize { throw WiFiProtocolError.wrongTotal }
        isStarted = true
    }

    @discardableResult
    public mutating func accept(_ envelope: WiFiEnvelope) throws -> Bool {
        try accept(envelope.metadata(as: WiFiContentMetadata.self), binary: envelope.binary)
    }

    /// Validate before writing binary to a streaming sink. Rejections are atomic.
    /// A last=0 chunk may reach the total, but completion still requires last=1.
    @discardableResult
    public mutating func accept(_ metadata: WiFiContentMetadata, binary: Data) throws -> Bool {
        guard isStarted else { throw WiFiProtocolError.transferNotStarted }
        guard !isComplete else { throw WiFiProtocolError.transferComplete }
        try metadata.validate()
        guard metadata.session == expectedSession else { throw WiFiProtocolError.wrongSession }
        guard metadata.offset == receivedByteCount else { throw WiFiProtocolError.unexpectedOffset }
        guard UInt64(metadata.length) == UInt64(binary.count),
              metadata.length <= expectedSize - receivedByteCount else { throw WiFiProtocolError.wrongLength }
        let end = receivedByteCount + metadata.length // subtraction guard prevents overflow
        guard metadata.length > 0 || metadata.last == 1 else { throw WiFiProtocolError.wrongLength }
        guard metadata.last == 0 || end == expectedSize else { throw WiFiProtocolError.invalidTerminal }
        receivedByteCount = end
        isComplete = metadata.last == 1
        return isComplete
    }

    public func finish() throws {
        guard isComplete else { throw WiFiProtocolError.incompleteTransfer }
    }
}

/// Bounded in-memory alternative to the pure streaming state. Only a completed
/// full file is exposed. No filesystem, recorder mutation or implicit deletion.
public struct WiFiFileCollector {
    public static let defaultMaximumFileSize = 256 * 1024 * 1024
    public private(set) var state: WiFiFileTransferState
    private var bytes = Data()
    public var completedFile: Data? { state.isComplete ? bytes : nil }

    public init(expectedSession: UInt32, expectedSize: UInt32,
                maximumFileSize: Int = defaultMaximumFileSize) throws {
        guard maximumFileSize >= 0 else { throw WiFiProtocolError.invalidLimit }
        guard UInt64(expectedSize) <= UInt64(maximumFileSize) else { throw WiFiProtocolError.fileTooLarge }
        state = WiFiFileTransferState(expectedSession: expectedSession, expectedSize: expectedSize)
    }

    public mutating func begin(_ envelope: WiFiEnvelope) throws { try state.begin(envelope) }
    public mutating func begin(_ response: WiFiDownloadResponse) throws { try state.begin(response) }

    @discardableResult
    public mutating func accept(_ envelope: WiFiEnvelope) throws -> Data? {
        try state.accept(envelope)
        bytes.append(envelope.binary)
        return completedFile
    }

    public func finish() throws { try state.finish() }
}
