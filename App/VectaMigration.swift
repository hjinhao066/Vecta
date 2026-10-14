import Foundation
import Darwin

/// Compatibility is deliberately isolated. Legacy secrets are read in memory;
/// no backend, database, SDK or personal runtime resource enters the app bundle.
enum VectaLegacyAuthorization {
    static var oldServices: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PinPointServices") }
    static func credentials(services: URL, userID: String) throws -> VectaPartnerCredentials {
        if let value = try VectaCredentialStore.load() {
            guard value.userID == userID else { throw VectaAuthorizationError.identityMismatch }
            return value
        }
        let fields = try legacyFields()
        let value = VectaPartnerCredentials(clientID: fields["PLAUD_CLIENT_ID"] ?? "", clientSecret: fields["PLAUD_CLIENT_SECRET"] ?? "",
                                           domain: fields["PLAUD_API_DOMAIN"] ?? "platform-us.plaud.ai", userID: userID)
        try value.validate()
        return value
    }
    private static func legacyFields() throws -> [String: String] {
        let file = oldServices.appendingPathComponent("backend.env")
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 65536 else { throw VectaAuthorizationError.unavailable }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw VectaAuthorizationError.unavailable }
        let text = try String(contentsOf: file, encoding: .utf8)
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            guard ["PLAUD_CLIENT_ID", "PLAUD_CLIENT_SECRET", "PLAUD_API_DOMAIN", "PINPOINT_USER_ID_SECRET_V1"].contains(key) else { continue }
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") { value = String(value.dropFirst().dropLast()) }
            guard fields[key] == nil else { throw VectaAuthorizationError.invalidCredentials }
            fields[key] = value
        }
        return fields
    }
    static func identity() throws -> String {
        guard let secret = try legacyFields()["PINPOINT_USER_ID_SECRET_V1"], secret.utf8.count >= 32 else { throw VectaAuthorizationError.invalidCredentials }
        return identity(secret: secret)
    }
    static func identity(secret: String) -> String {
        // Immutable v1 local identity contract. It must match existing recorder
        // authorization and the library hash; never create a substitute owner.
        let bytes = HMAC<SHA256>.authenticationCode(for: Data("v1:local:primary".utf8), using: SymmetricKey(data: Data(secret.utf8)))
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var output: [UInt8] = [];var accumulator: UInt32 = 0;var bits = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | UInt32(byte);bits += 8
            while bits >= 5 { bits -= 5;output.append(alphabet[Int((accumulator >> bits) & 31)]) }
        }
        if bits > 0 { output.append(alphabet[Int((accumulator << (5 - bits)) & 31)]) }
        return "pinpoint_" + String(decoding: output.prefix(32), as: UTF8.self)
    }
    static func hasLegacyConfiguration() -> Bool {
        FileManager.default.fileExists(atPath: oldServices.appendingPathComponent("backend.env").path)
    }
}

/// Copy-first migration: originals are never removed. A published directory is
/// accepted only after every byte has been checked. Ambiguous destinations fail.
enum VectaMigration {
    struct Manifest: Codable, Equatable {
        let version: Int
        let files: [String: String]
    }
    static func copyVerified(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let manifestName = ".vecta-migration.json"
        try Task.checkCancellation()
        let expected = try inventory(source)
        if manager.fileExists(atPath: destination.path) {
            let properties = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw NativeStorageError.libraryUnavailable }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: destination.appendingPathComponent(manifestName)))
            guard manifest.version == 1, manifest.files == expected else { throw NativeStorageError.ambiguousLibrary }
            // The source remains a rollback archive. The migrated library may
            // subsequently change; never overwrite it from an older snapshot.
            return
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".vecta-migration-" + UUID().uuidString)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        do {
            try manager.copyItem(at: source, to: staging)
            let copied = try inventory(staging)
            guard copied == expected, try inventory(source) == expected else { throw NativeStorageError.libraryUnavailable }
            try JSONEncoder().encode(Manifest(version: 1, files: expected)).write(to: staging.appendingPathComponent(manifestName), options: .atomic)
            try Task.checkCancellation()
            try manager.moveItem(at: staging, to: destination)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }
    static func inventory(_ sourceRoot: URL) throws -> [String: String] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        let properties = try sourceRoot.resourceValues(forKeys: Set(keys))
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw NativeStorageError.libraryUnavailable }
        let root = sourceRoot
        guard let rootPath = realpath(root.path, nil) else { throw NativeStorageError.libraryUnavailable }
        let prefix = String(cString: rootPath) + "/";free(rootPath)
        var enumerationFailed = false
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys, errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw NativeStorageError.libraryUnavailable }
        var result: [String: String] = [:]
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw NativeStorageError.libraryUnavailable }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw NativeStorageError.libraryUnavailable }
            guard let filePath = realpath(file.path, nil) else { throw NativeStorageError.libraryUnavailable }
            let canonicalFile = String(cString: filePath);free(filePath)
            guard canonicalFile.hasPrefix(prefix) else { throw NativeStorageError.libraryUnavailable }
            let relative = String(canonicalFile.dropFirst(prefix.count))
            guard relative != ".vecta-migration.json" else { continue }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
            result[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard !enumerationFailed else { throw NativeStorageError.libraryUnavailable }
        return result
    }
    static func migratePreferences(defaults: UserDefaults) throws {
        let key = "Vecta.namespaceMigration.v1"
        guard !defaults.bool(forKey: key) else { return }
        if let previous = defaults.persistentDomain(forName: "org.pinpoint.community.launcher") {
            for (name, value) in previous {
                let target = name.replacingOccurrences(of: "PinPoint.AIProvider.", with: "Vecta.AIProvider.").replacingOccurrences(of: "PinPoint.LocalAudioExport.", with: "Vecta.LocalAudioExport.")
                if defaults.object(forKey: target) == nil { defaults.set(value, forKey: target) }
            }
        }
        defaults.set(true, forKey: key)
    }
    static func prepareServices(_ destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["recordings-root.txt", "recordings-folder.bookmark", "native-library.bookmark", "native-analysis-queue.json", "selected-device.json"] {
            let source = VectaLegacyAuthorization.oldServices.appendingPathComponent(name)
            let target = destination.appendingPathComponent(name)
            if !manager.fileExists(atPath: source.path) || manager.fileExists(atPath: target.path) { continue }
            if name == "selected-device.json", manager.fileExists(atPath: target.appendingPathExtension("retired").path) { continue }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw NativeStorageError.libraryUnavailable }
            try manager.copyItem(at: source, to: target)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }
    static func standaloneRoot(home: URL) throws -> URL {
        let destination = home.appendingPathComponent("Library/Application Support/VectaNative")
        let source = home.appendingPathComponent("Library/Application Support/OpenPlaudNative")
        if FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: destination.path) {
            try copyVerified(from: source, to: destination)
        }
        return destination
    }
}
import CryptoKit

/// Preserves identity of archived recording requests across a product rename.
enum VectaLegacySourceIdentity {
    static func digest(sessionID: Int, serialNumber: String) -> String {
        let material = "pinpoint-recording-v3\u{0}\(serialNumber)\u{0}\(sessionID)"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Immutable compatibility aliases. New state always uses Vecta names.
enum VectaLegacyPaths {
    static let recorderBundle = "dev.codex.plaudreceiver.a01a11651"
    static let ownerKeychainService = "org.pinpoint.community.native-ble-owner"
    static func modelDirectory(name: String, preferred: URL) -> URL {
        let old = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PinPoint/Models/" + name)
        return FileManager.default.fileExists(atPath: preferred.path) || !FileManager.default.fileExists(atPath: old.path) ? preferred : old
    }
    static var sharedLeaseRoot: URL {
        let own = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VectaServices")
        // Older Vecta workers can still be alive during an update. Continue to
        // share their lock when that namespace exists, never run two heavy jobs.
        return FileManager.default.fileExists(atPath: VectaLegacyAuthorization.oldServices.path) ? VectaLegacyAuthorization.oldServices : own
    }
    static func libraryBases(home: URL) -> [URL] {
        var bases = [home.appendingPathComponent("Library/Application Support/PinPoint"),
                     home.appendingPathComponent("Library/Containers/" + recorderBundle + "/Data/Library/Application Support/PinPoint")]
        let containers = home.appendingPathComponent("Library/Containers")
        if let entries = try? FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let folder = entry.appendingPathComponent("Data/Library/Application Support/PinPoint")
                if FileManager.default.fileExists(atPath: folder.path) { bases.append(folder) }
            }
        }
        return bases
    }
    static func exportFilenames(identity: String) -> [String] { ["Vecta", "OpenPlaud", "PinPoint"].map { "\($0)_\(identity).mp3" } }
    static func presentationFolder(_ name: String?) -> String { name == "PinPoint" ? "Vecta" : (name ?? VL.text("Не настроена")) }
    static func migrateAutomaticSummary(_ defaults: UserDefaults) {
        if defaults.object(forKey: "Vecta.autoSummaryAfterSync") == nil, let value = defaults.object(forKey: "OpenPlaud.autoSummaryAfterSync") as? Bool { defaults.set(value, forKey: "Vecta.autoSummaryAfterSync") }
    }
    static func migrateSyncPreferences(_ defaults: UserDefaults) {
        for suffix in ["interval", "nextAttempt"] {
            let key = "Vecta.nativeAutoSync." + suffix
            if defaults.object(forKey: key) == nil, let value = defaults.object(forKey: "OpenPlaud.nativeAutoSync." + suffix) { defaults.set(value, forKey: key) }
        }
    }
}
