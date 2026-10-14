import CryptoKit
import Darwin
import Foundation

public enum FactoryResetBackupPublicationError: Error, Equatable {
    case invalidInput
    case cancelled
    case destinationUnavailable
    case sourceChanged
    case publicationFailed
    case expectationNotRetained
}

/// Immutable recorder facts captured from one authenticated list transaction.
/// The publisher never derives these facts from the local recording library.
public struct FactoryResetBackupSnapshot: Equatable {
    public let serialNumber: String
    public let model: String
    public let protocolVersion: UInt16
    public let recorderInventory: [ProtocolRecordingFile]

    public init(serialNumber: String, model: String, protocolVersion: UInt16, recorderInventory: [ProtocolRecordingFile]) {
        self.serialNumber = serialNumber
        self.model = model
        self.protocolVersion = protocolVersion
        self.recorderInventory = recorderInventory
    }
}

/// A validated raw transfer owned by the caller's private staging area.
public struct FactoryResetBackupSourceArtifact: Equatable {
    public let sessionID: UInt32
    public let rawURL: URL

    public init(sessionID: UInt32, rawURL: URL) {
        self.sessionID = sessionID
        self.rawURL = rawURL
    }
}

public struct FactoryResetBackupPublication: Equatable {
    public let backupRoot: URL
    public let expectation: FactoryResetBackupExpectation

    public init(backupRoot: URL, expectation: FactoryResetBackupExpectation) {
        self.backupRoot = backupRoot
        self.expectation = expectation
    }
}

/// Stores the expectation outside the mutable backup directory. A sink must
/// return only after durable independent retention has succeeded.
public protocol FactoryResetBackupExpectationSink {
    func retain(_ expectation: FactoryResetBackupExpectation) throws
}

/// Publishes a complete raw backup into a new child of a caller-authorized
/// directory. It cannot initiate a transfer, talk to a recorder, or issue a
/// reset request.
public enum FactoryResetBackupPublisher {
    public static func publish(
        snapshot: FactoryResetBackupSnapshot,
        rawArtifacts: [FactoryResetBackupSourceArtifact],
        selectedDestination: URL,
        expectationSink: FactoryResetBackupExpectationSink,
        shouldCancel: () -> Bool = { false }
    ) throws -> FactoryResetBackupPublication {
        do {
            try checkCancelled(shouldCancel)
            _ = try inventoryMap(snapshot.recorderInventory)
            guard !snapshot.serialNumber.isEmpty,
                  !snapshot.model.isEmpty,
                  snapshot.protocolVersion > 0 else {
                throw FactoryResetBackupPublicationError.invalidInput
            }

            let required = snapshot.recorderInventory.filter { $0.byteSize > 0 }
            let sources = try sourceMap(rawArtifacts)
            guard sources.count == required.count,
                  Set(sources.keys) == Set(required.map(\.sessionID)) else {
                throw FactoryResetBackupPublicationError.invalidInput
            }

            let destination = try FactoryResetBackupPublisher.AnchoredDirectory.openSelected(selectedDestination)
            let name = "Vecta-reset-backup-" + UUID().uuidString.lowercased()
            let stagingName = "." + name + ".staging"
            let staging = try FactoryResetBackupPublisher.AnchoredDirectory.createChild(in: destination, named: stagingName)
            let recordings = try FactoryResetBackupPublisher.AnchoredDirectory.createChild(in: staging, named: "recordings")

            var artifacts: [FactoryResetBackupArtifact] = []
            for file in required {
                try checkCancelled(shouldCancel)
                guard let source = sources[file.sessionID] else {
                    throw FactoryResetBackupPublicationError.invalidInput
                }
                let path = "recordings/\(file.sessionID).plaudaudio"
                let receipt = try copyRawArtifact(source.rawURL, to: recordings,
                                                   named: "\(file.sessionID).plaudaudio", shouldCancel: shouldCancel)
                guard receipt.bytes == UInt64(file.byteSize) else {
                    throw FactoryResetBackupPublicationError.sourceChanged
                }
                artifacts.append(FactoryResetBackupArtifact(sessionID: file.sessionID, path: path,
                                                            sha256: receipt.sha256, bytes: receipt.bytes))
            }

            try recordings.synchronize()
            try checkCancelled(shouldCancel)
            let manifest = FactoryResetBackupManifest(serialNumber: snapshot.serialNumber,
                                                      model: snapshot.model,
                                                      protocolVersion: snapshot.protocolVersion,
                                                      recorderInventory: snapshot.recorderInventory,
                                                      artifacts: artifacts)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try writeExclusive(manifestData, in: staging, named: "manifest.json")
            try staging.synchronize()
            try checkCancelled(shouldCancel)
            guard destination.matchesSelectedPath(), destination.matchesChild(named: stagingName, directory: staging) else {
                throw FactoryResetBackupPublicationError.destinationUnavailable
            }
            try renameExclusive(in: destination, from: stagingName, to: name)
            try destination.synchronize()
            guard destination.matchesSelectedPath() else {
                throw FactoryResetBackupPublicationError.destinationUnavailable
            }
            let finalRoot = destination.selectedURL.appendingPathComponent(name, isDirectory: true)

            let expectation = FactoryResetBackupExpectation(serialNumber: snapshot.serialNumber,
                                                             model: snapshot.model,
                                                             protocolVersion: snapshot.protocolVersion,
                                                             recorderInventory: snapshot.recorderInventory,
                                                             manifestSHA256: sha256(manifestData))
            try checkCancelled(shouldCancel)
            try FactoryResetBackupVerifier.verify(backupRoot: finalRoot, expectation: expectation)
            try checkCancelled(shouldCancel)
            guard destination.matchesSelectedPath() else {
                throw FactoryResetBackupPublicationError.destinationUnavailable
            }
            do {
                try expectationSink.retain(expectation)
            } catch {
                throw FactoryResetBackupPublicationError.expectationNotRetained
            }
            return FactoryResetBackupPublication(backupRoot: finalRoot, expectation: expectation)
        } catch let error as FactoryResetBackupPublicationError {
            throw error
        } catch {
            throw FactoryResetBackupPublicationError.publicationFailed
        }
    }

    private static func inventoryMap(_ files: [ProtocolRecordingFile]) throws -> [UInt32: ProtocolRecordingFile] {
        var result: [UInt32: ProtocolRecordingFile] = [:]
        for file in files {
            guard file.sessionID > 0, result[file.sessionID] == nil else {
                throw FactoryResetBackupPublicationError.invalidInput
            }
            result[file.sessionID] = file
        }
        return result
    }

    private static func sourceMap(_ sources: [FactoryResetBackupSourceArtifact]) throws -> [UInt32: FactoryResetBackupSourceArtifact] {
        var result: [UInt32: FactoryResetBackupSourceArtifact] = [:]
        for source in sources {
            guard source.sessionID > 0, source.rawURL.isFileURL, result[source.sessionID] == nil else {
                throw FactoryResetBackupPublicationError.invalidInput
            }
            result[source.sessionID] = source
        }
        return result
    }

    private final class AnchoredDirectory {
        let descriptor: Int32
        private let device: dev_t
        private let inode: ino_t
        private let selectedPath: String?

        var selectedURL: URL {
            guard let selectedPath else { fatalError("Only the selected destination has a public path") }
            return URL(fileURLWithPath: selectedPath, isDirectory: true)
        }

        private init(descriptor: Int32, selectedPath: String?) throws {
            var values = stat()
            guard fstat(descriptor, &values) == 0, values.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                close(descriptor)
                throw FactoryResetBackupPublicationError.destinationUnavailable
            }
            self.descriptor = descriptor
            device = values.st_dev
            inode = values.st_ino
            self.selectedPath = selectedPath
        }

        private convenience init(opening url: URL, selectedPath: String?) throws {
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw FactoryResetBackupPublicationError.destinationUnavailable }
            try self.init(descriptor: descriptor, selectedPath: selectedPath)
        }

        deinit {
            close(descriptor)
        }

        static func openSelected(_ url: URL) throws -> AnchoredDirectory {
            guard url.isFileURL else { throw FactoryResetBackupPublicationError.destinationUnavailable }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let raw = realpath(url.path, nil) else {
                throw FactoryResetBackupPublicationError.destinationUnavailable
            }
            defer { free(raw) }
            let selectedPath = String(cString: raw)
            return try AnchoredDirectory(opening: URL(fileURLWithPath: selectedPath, isDirectory: true),
                                         selectedPath: selectedPath)
        }

        static func createChild(in parent: AnchoredDirectory, named name: String) throws -> AnchoredDirectory {
            guard isSafeChildName(name), mkdirat(parent.descriptor, name, mode_t(0o700)) == 0 else {
                throw FactoryResetBackupPublicationError.publicationFailed
            }
            let descriptor = openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw FactoryResetBackupPublicationError.publicationFailed }
            return try AnchoredDirectory(descriptor: descriptor, selectedPath: nil)
        }

        func matchesSelectedPath() -> Bool {
            guard let selectedPath else { return false }
            var values = stat()
            return lstat(selectedPath, &values) == 0 &&
                values.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) &&
                values.st_dev == device && values.st_ino == inode
        }

        func matchesChild(named name: String, directory: AnchoredDirectory) -> Bool {
            guard Self.isSafeChildName(name) else { return false }
            var values = stat()
            return fstatat(descriptor, name, &values, AT_SYMLINK_NOFOLLOW) == 0 &&
                values.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) &&
                values.st_dev == directory.device && values.st_ino == directory.inode
        }

        func synchronize() throws {
            guard fsync(descriptor) == 0 else { throw FactoryResetBackupPublicationError.publicationFailed }
        }

        static func isSafeChildName(_ name: String) -> Bool {
            !name.isEmpty && !name.contains("/") && name != "." && name != ".."
        }
    }

    private static func copyRawArtifact(_ sourceURL: URL, to destination: AnchoredDirectory,
                                        named name: String, shouldCancel: () -> Bool) throws -> (bytes: UInt64, sha256: String) {
        guard AnchoredDirectory.isSafeChildName(name) else { throw FactoryResetBackupPublicationError.invalidInput }
        let inputFD = open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard inputFD >= 0 else { throw FactoryResetBackupPublicationError.invalidInput }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }

        var before = stat()
        guard fstat(inputFD, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_size > 0 else {
            throw FactoryResetBackupPublicationError.invalidInput
        }

        let temporary = ".vecta-reset-artifact-" + UUID().uuidString.lowercased() + ".tmp"
        let outputFD = openat(destination.descriptor, temporary,
                              O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard outputFD >= 0 else { throw FactoryResetBackupPublicationError.publicationFailed }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }

        var count: UInt64 = 0
        var digest = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try checkCancelled(shouldCancel)
            try output.write(contentsOf: bytes)
            digest.update(data: bytes)
            count += UInt64(bytes.count)
        }
        var after = stat()
        guard fstat(inputFD, &after) == 0,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              count == UInt64(before.st_size) else {
            throw FactoryResetBackupPublicationError.sourceChanged
        }
        try output.synchronize()
        try output.close()
        try checkCancelled(shouldCancel)
        guard linkat(destination.descriptor, temporary, destination.descriptor, name, 0) == 0 else {
            throw FactoryResetBackupPublicationError.publicationFailed
        }
        guard unlinkat(destination.descriptor, temporary, 0) == 0 else {
            throw FactoryResetBackupPublicationError.publicationFailed
        }
        return (count, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func writeExclusive(_ data: Data, in directory: AnchoredDirectory, named name: String) throws {
        guard AnchoredDirectory.isSafeChildName(name) else { throw FactoryResetBackupPublicationError.invalidInput }
        let fd = openat(directory.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw FactoryResetBackupPublicationError.publicationFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func renameExclusive(in directory: AnchoredDirectory, from source: String, to destination: String) throws {
        guard AnchoredDirectory.isSafeChildName(source), AnchoredDirectory.isSafeChildName(destination),
              renameatx_np(directory.descriptor, source, directory.descriptor, destination, UInt32(RENAME_EXCL)) == 0 else {
            throw FactoryResetBackupPublicationError.publicationFailed
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func checkCancelled(_ shouldCancel: () -> Bool) throws {
        guard !shouldCancel() else { throw FactoryResetBackupPublicationError.cancelled }
    }
}
