import CryptoKit
import Darwin
import Foundation

public enum FactoryResetBackupVerificationError: Error, Equatable {
    case invalidBackup
}

public struct FactoryResetBackupArtifact: Codable, Equatable {
    public let sessionID: UInt32
    public let path: String
    public let sha256: String
    public let bytes: UInt64

    public init(sessionID: UInt32, path: String, sha256: String, bytes: UInt64) {
        self.sessionID = sessionID
        self.path = path
        self.sha256 = sha256
        self.bytes = bytes
    }
}

public struct FactoryResetBackupManifest: Codable, Equatable {
    public let version: Int
    public let serialNumber: String
    public let model: String
    public let protocolVersion: UInt16
    public let recorderInventory: [ProtocolRecordingFile]
    public let artifacts: [FactoryResetBackupArtifact]

    public init(version: Int = 1, serialNumber: String, model: String, protocolVersion: UInt16, recorderInventory: [ProtocolRecordingFile], artifacts: [FactoryResetBackupArtifact]) {
        self.version = version
        self.serialNumber = serialNumber
        self.model = model
        self.protocolVersion = protocolVersion
        self.recorderInventory = recorderInventory
        self.artifacts = artifacts
    }
}

public struct FactoryResetBackupExpectation: Equatable {
    public let serialNumber: String
    public let model: String
    public let protocolVersion: UInt16
    public let recorderInventory: [ProtocolRecordingFile]
    public let manifestSHA256: String

    public init(serialNumber: String, model: String, protocolVersion: UInt16, recorderInventory: [ProtocolRecordingFile], manifestSHA256: String) {
        self.serialNumber = serialNumber
        self.model = model
        self.protocolVersion = protocolVersion
        self.recorderInventory = recorderInventory
        self.manifestSHA256 = manifestSHA256
    }
}

public enum FactoryResetBackupVerifier {
    public static func verify(backupRoot: URL, expectation: FactoryResetBackupExpectation) throws {
        do {
            guard !expectation.serialNumber.isEmpty,
                  !expectation.model.isEmpty,
                  expectation.protocolVersion > 0,
                  isLowercaseSHA256(expectation.manifestSHA256) else {
                throw FactoryResetBackupVerificationError.invalidBackup
            }
            let root = try canonicalDirectory(backupRoot)
            let manifestURL = root.url.appendingPathComponent("manifest.json")
            let manifestData = try regularData(manifestURL, maximumBytes: 1_048_576)
            guard sha256(manifestData) == expectation.manifestSHA256 else {
                throw FactoryResetBackupVerificationError.invalidBackup
            }
            let manifest = try JSONDecoder().decode(FactoryResetBackupManifest.self, from: manifestData)
            guard manifest.version == 1,
                  manifest.serialNumber == expectation.serialNumber,
                  manifest.model == expectation.model,
                  manifest.protocolVersion == expectation.protocolVersion else {
                throw FactoryResetBackupVerificationError.invalidBackup
            }

            let current = try inventoryMap(expectation.recorderInventory)
            let recorded = try inventoryMap(manifest.recorderInventory)
            guard current == recorded else { throw FactoryResetBackupVerificationError.invalidBackup }

            let required = manifest.recorderInventory.filter { $0.byteSize > 0 }
            let artifacts = try artifactMap(manifest.artifacts)
            guard artifacts.count == required.count,
                  Set(artifacts.keys) == Set(required.map(\.sessionID)) else {
                throw FactoryResetBackupVerificationError.invalidBackup
            }

            var paths = Set<String>()
            for file in required {
                guard file.sessionID > 0,
                      let artifact = artifacts[file.sessionID],
                      artifact.bytes == UInt64(file.byteSize),
                      isLowercaseSHA256(artifact.sha256),
                      isSafeRelativePath(artifact.path),
                      paths.insert(artifact.path).inserted else {
                    throw FactoryResetBackupVerificationError.invalidBackup
                }
            }

            let actual = try fileInventory(root)
            guard Set(actual.keys) == paths else { throw FactoryResetBackupVerificationError.invalidBackup }
            for artifact in manifest.artifacts {
                guard let file = actual[artifact.path],
                      file.bytes == artifact.bytes,
                      file.sha256 == artifact.sha256 else {
                    throw FactoryResetBackupVerificationError.invalidBackup
                }
            }
        } catch {
            throw FactoryResetBackupVerificationError.invalidBackup
        }
    }

    private static func canonicalDirectory(_ url: URL) throws -> (url: URL, path: String) {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let raw = realpath(url.path, nil) else {
            throw FactoryResetBackupVerificationError.invalidBackup
        }
        defer { free(raw) }
        let path = String(cString: raw)
        return (URL(fileURLWithPath: path, isDirectory: true), path + "/")
    }

    private static func regularData(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= maximumBytes else {
            throw FactoryResetBackupVerificationError.invalidBackup
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func inventoryMap(_ files: [ProtocolRecordingFile]) throws -> [UInt32: ProtocolRecordingFile] {
        var result: [UInt32: ProtocolRecordingFile] = [:]
        for file in files {
            guard file.sessionID > 0, result[file.sessionID] == nil else {
                throw FactoryResetBackupVerificationError.invalidBackup
            }
            result[file.sessionID] = file
        }
        return result
    }

    private static func artifactMap(_ artifacts: [FactoryResetBackupArtifact]) throws -> [UInt32: FactoryResetBackupArtifact] {
        var result: [UInt32: FactoryResetBackupArtifact] = [:]
        for artifact in artifacts {
            guard artifact.sessionID > 0, result[artifact.sessionID] == nil else {
                throw FactoryResetBackupVerificationError.invalidBackup
            }
            result[artifact.sessionID] = artifact
        }
        return result
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private static func fileInventory(_ root: (url: URL, path: String)) throws -> [String: (bytes: UInt64, sha256: String)] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in
            enumerationFailed = true
            return false
        }) else {
            throw FactoryResetBackupVerificationError.invalidBackup
        }

        var result: [String: (bytes: UInt64, sha256: String)] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw FactoryResetBackupVerificationError.invalidBackup }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true,
                  let size = values.fileSize, size >= 0,
                  let raw = realpath(url.path, nil) else {
                throw FactoryResetBackupVerificationError.invalidBackup
            }
            defer { free(raw) }
            let canonical = String(cString: raw)
            guard canonical.hasPrefix(root.path) else { throw FactoryResetBackupVerificationError.invalidBackup }
            let relative = String(canonical.dropFirst(root.path.count))
            if relative == "manifest.json" { continue }
            guard result[relative] == nil else { throw FactoryResetBackupVerificationError.invalidBackup }
            result[relative] = (UInt64(size), try sha256(url))
        }
        guard !enumerationFailed else { throw FactoryResetBackupVerificationError.invalidBackup }
        return result
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
