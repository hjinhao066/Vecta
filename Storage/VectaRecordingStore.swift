import Foundation
import CryptoKit
import Darwin

/// Local recording repository. Mutations publish a complete snapshot only after
/// validation and atomic persistence. No cloud workflow or remote API is present.
final class VectaRecordingStore {
    private let root: URL
    private let metadata: URL
    private let lock = NSLock()
    private var rows: [VectaRecording]
    private let archivedAssociation: VectaRecorderAssociation?

    init(userID: String, fileManager: FileManager = .default, directory base: URL? = nil) throws {
        guard !userID.isEmpty else { throw VectaRecordingStoreError.corruptRecordingMetadata }
        let base = base ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Vecta")
        root = base.appendingPathComponent("Users/" + Self.userDirectoryName(for: userID))
        metadata = root.appendingPathComponent("recordings.json")
        try Self.createDirectory(root)
        if fileManager.fileExists(atPath: metadata.path) {
            try Self.requireRegularFile(metadata, maximumSize: 32 * 1024 * 1024)
            rows = try JSONDecoder.vectaStorage.decode([VectaRecording].self, from: Data(contentsOf: metadata))
            guard Self.valid(rows) else { throw VectaRecordingStoreError.corruptRecordingMetadata }
        } else { rows = [] }
        let association = root.appendingPathComponent("recorder-association.json")
        if fileManager.fileExists(atPath: association.path) {
            try Self.requireRegularFile(association, maximumSize: 65536)
            archivedAssociation = try JSONDecoder.vectaStorage.decode(VectaRecorderAssociation.self, from: Data(contentsOf: association))
        } else { archivedAssociation = nil }
        // Interrupted transfers never become completed audio merely because a
        // partial file exists. The next explicit transfer may restart them.
    }
    static func userDirectoryName(for userID: String) -> String { digest(userID) }
    var all: [VectaRecording] {
        lock.lock();defer { lock.unlock() }
        return rows.sorted { $0.createdAt > $1.createdAt }
    }
    func recorderAssociation() -> VectaRecorderAssociation? { archivedAssociation }
    func recording(sessionID: Int, serialNumber: String) -> VectaRecording? {
        lock.lock();defer { lock.unlock() }
        return rows.first { $0.sessionID == sessionID && $0.deviceSerialNumber == serialNumber }
    }
    func begin(sessionID: Int, serialNumber: String, duration: TimeInterval) -> Bool {
        guard sessionID > 0, !serialNumber.isEmpty, duration.isFinite, duration >= 0 else { return false }
        return update(sessionID, serialNumber, create: VectaRecording(sessionID: sessionID, deviceSerialNumber: serialNumber,
            createdAt: Date(timeIntervalSince1970: Double(sessionID)), duration: duration, localFileName: nil,
            status: .copying, statusDetail: nil, transcript: nil, cloudCheckpoint: nil, updatedAt: Date())) {
                $0.status = .copying; $0.statusDetail = nil
            }
    }
    func audioDirectory(serialNumber: String) -> URL {
        let destination = root.appendingPathComponent("Audio/" + Self.digest(serialNumber))
        // Caller verifies publication and file identity after the transfer.
        try? Self.createDirectory(destination)
        return destination
    }
    func markLocal(sessionID: Int, serialNumber: String, outputPath: String, verifiedDuration: TimeInterval? = nil) -> Bool {
        if let duration = verifiedDuration, !duration.isFinite || duration <= 0 { return false }
        guard let relative = verifiedRelativePath(URL(fileURLWithPath: outputPath)) else { return false }
        return update(sessionID, serialNumber) { row in
            if row.status == .copying, let duration = verifiedDuration { row.duration = duration }
            row.localFileName = relative;row.status = .local;row.statusDetail = nil
        }
    }
    func commitImportedAudio(digest: String, outputURL: URL, duration: TimeInterval, title: String) -> Bool {
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit), duration.isFinite, duration > 0,
              !title.isEmpty, title.count <= 200, let relative = verifiedRelativePath(outputURL) else { return false }
        let serial = "local-audio-" + digest
        lock.lock();defer { lock.unlock() }
        guard !rows.contains(where: { $0.sessionID == 1 && $0.deviceSerialNumber == serial }) else { return false }
        var next = rows
        next.append(VectaRecording(sessionID: 1, deviceSerialNumber: serial, createdAt: Date(), duration: duration,
            localFileName: relative, status: .local, statusDetail: nil, transcript: nil,
            cloudCheckpoint: nil, updatedAt: Date(), importedTitle: title))
        return publish(next)
    }
    func saveGeneratedTitle(sessionID: Int, serialNumber: String, title: String) -> Bool {
        guard let normalized = AIRecordingTitle.validated(title),
              recording(sessionID: sessionID, serialNumber: serialNumber)?.generatedTitle == nil else { return false }
        return update(sessionID, serialNumber) { $0.generatedTitle = normalized }
    }
    func markFailed(sessionID: Int, serialNumber: String, message: String) -> Bool {
        update(sessionID, serialNumber) { $0.status = .failed;$0.statusDetail = message }
    }
    func markNeedsSupport(sessionID: Int, serialNumber: String, message: String) -> Bool {
        update(sessionID, serialNumber) { $0.status = .needsSupport;$0.statusDetail = message }
    }
    func audioURL(for recording: VectaRecording) -> URL? {
        guard let path = recording.localFileName else { return nil }
        let file = root.appendingPathComponent(path.contains("/") ? path : "Audio/" + path).standardizedFileURL
        return verifiedRelativePath(file) == nil ? nil : file
    }
    /// Historical AI requests use this immutable source digest. Compatibility
    /// hashing lives separately from new product identity and brand names.
    static func cloudSourceIdentifier(sessionID: Int, serialNumber: String, duration: TimeInterval) -> String? {
        guard sessionID > 0, !serialNumber.isEmpty, duration.isFinite, duration >= 0 else { return nil }
        return VectaLegacySourceIdentity.digest(sessionID: sessionID, serialNumber: serialNumber)
    }
    private func update(_ session: Int, _ serial: String, create: VectaRecording? = nil,
                        _ change: (inout VectaRecording) -> Void) -> Bool {
        lock.lock();defer { lock.unlock() }
        var next = rows
        if let index = next.firstIndex(where: { $0.sessionID == session && $0.deviceSerialNumber == serial }) {
            change(&next[index]);next[index].updatedAt = Date()
        } else if var new = create { change(&new);next.append(new) }
        else { return false }
        return publish(next)
    }
    private func publish(_ next: [VectaRecording]) -> Bool {
        guard Self.valid(next) else { return false }
        do {
            try Self.requireDirectory(root)
            if FileManager.default.fileExists(atPath: metadata.path) { try Self.requireRegularFile(metadata, maximumSize: 32 * 1024 * 1024) }
            let bytes = try JSONEncoder.vectaStorage.encode(next)
            try bytes.write(to: metadata, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
            rows = next
            return true
        } catch { return false }
    }
    private func verifiedRelativePath(_ file: URL) -> String? {
        let normalized = file.standardizedFileURL
        let prefix = root.standardizedFileURL.path + "/"
        guard normalized.path.hasPrefix(prefix) else { return nil }
        let path = String(normalized.path.dropFirst(prefix.count))
        do {
            var parent = root
            try Self.requireDirectory(parent)
            for part in path.split(separator: "/").dropLast() { parent.appendPathComponent(String(part));try Self.requireDirectory(parent) }
            try Self.requireRegularFile(normalized, maximumSize: nil)
            let size = try normalized.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { return nil }
            return path
        } catch { return nil }
    }
    private static func valid(_ values: [VectaRecording]) -> Bool {
        var identities = Set<String>()
        return values.allSatisfy { row in
            guard row.sessionID > 0, !row.deviceSerialNumber.isEmpty,
                  row.duration.isFinite, row.duration >= 0,
                  row.createdAt.timeIntervalSince1970.isFinite, row.updatedAt.timeIntervalSince1970.isFinite,
                  identities.insert(row.deviceSerialNumber + "\0" + String(row.sessionID)).inserted else { return false }
            if let path = row.localFileName {
                guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
                      !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return false }
            }
            if let title = row.generatedTitle, AIRecordingTitle.validated(title) == nil { return false }
            return true
        }
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func createDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try createDirectory(directory.deletingLastPathComponent())
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(directory)
    }
    private static func requireDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw VectaRecordingStoreError.secureStorageUnavailable }
    }
    private static func requireRegularFile(_ file: URL, maximumSize: Int?) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              maximumSize == nil || (values.fileSize ?? Int.max) <= maximumSize! else { throw VectaRecordingStoreError.corruptRecordingMetadata }
    }
}

enum VectaRecordingStoreError: LocalizedError {
    case secureStorageUnavailable, corruptRecordingMetadata
    var errorDescription: String? {
        switch self {
        case .secureStorageUnavailable: return VL.text("Хранилище Vecta недоступно. Проверьте разрешения; записи сохранены.")
        case .corruptRecordingMetadata: return VL.text("Сведения о записях повреждены. Исходные данные сохранены; библиотека не перезаписана.")
        }
    }
}
