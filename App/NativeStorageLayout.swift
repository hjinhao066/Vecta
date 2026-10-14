import Foundation
import CryptoKit
import Darwin

struct NativeStorageLayout: Equatable {
    static let launcherBundleIdentifier = "app.vecta.mac"
    static let recorderBundleIdentifier = VectaLegacyPaths.recorderBundle

    /// Library directory before Users/<stable SHA256(userID)>.
    let recordingBase: URL
    let userDirectory: URL
    let servicesDirectory: URL

    /// Read-only discovery. It must not create an empty native library while a
    /// sandboxed SDK library exists, or silently choose between two libraries.
    static func resolveExisting(
        userID: String,
        servicesDirectory: URL,
        candidateBases: [URL],
        selectedBase: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Self {
        guard !userID.isEmpty else { throw NativeStorageError.invalidIdentity }
        let hash = VectaRecordingStore.userDirectoryName(for: userID)
        let bases = Array(Set(candidateBases.map { $0.standardizedFileURL.path })).sorted().map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        var checks: [[String: Any]] = []
        func record(_ value: [String: Any]) {
            checks.append(value)
            if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]) {
                let file = servicesDirectory.appendingPathComponent("native-storage-checks.json")
                try? data.write(to: file, options: .atomic)
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        func existing(_ base: URL) throws -> Self? {
            let user = base.appendingPathComponent("Users", isDirectory: true)
                .appendingPathComponent(hash, isDirectory: true)
            record(["userExists": fileManager.fileExists(atPath: user.path)])
            guard fileManager.fileExists(atPath: user.path) else { return nil }
            // Validate every existing ancestor inside the supplied base. Reject
            // symlinked storage rather than resolving it into another account.
            for directory in [base, base.appendingPathComponent("Users"), user] {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                record(["directory": values.isDirectory == true, "symlink": values.isSymbolicLink == true,
                        "readable": fileManager.isReadableFile(atPath: directory.path)])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      fileManager.isReadableFile(atPath: directory.path) else {
                    throw NativeStorageError.libraryUnavailable
                }
            }
            let markers = [user.appendingPathComponent("recordings.json"),
                           user.appendingPathComponent("SummaryFormats/formats.json")]
            guard markers.contains(where: { fileManager.fileExists(atPath: $0.path) }) else { return nil }
            for marker in markers where fileManager.fileExists(atPath: marker.path) {
                let values = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                record(["regularMarker": values.isRegularFile == true, "symlink": values.isSymbolicLink == true,
                        "readable": fileManager.isReadableFile(atPath: marker.path)])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      fileManager.isReadableFile(atPath: marker.path) else {
                    throw NativeStorageError.libraryUnavailable
                }
            }
            return Self(recordingBase: base, userDirectory: user,
                        servicesDirectory: servicesDirectory.standardizedFileURL)
        }
        if let selectedBase {
            let base = selectedBase.standardizedFileURL
            record(["selectedBaseInCandidates": bases.contains(base)])
            guard bases.contains(base), let layout = try existing(base) else {
                throw NativeStorageError.libraryUnavailable
            }
            return layout
        }
        let layouts = try bases.compactMap(existing)
        guard !layouts.isEmpty else { throw NativeStorageError.libraryNotFound }
        guard layouts.count == 1 else { throw NativeStorageError.ambiguousLibrary }
        return layouts[0]
    }

    /// Resolve only the supplied identity in a declared default namespace.
    /// Unlike discovery/selection this permits an absent library, but performs
    /// no writes and never substitutes another owner's directory. Callers must
    /// hold RuntimeOwnership before initializing the returned layout's stores.
    /// Existing schemas are decoded by the stores; corrupt bytes are not reset.
    static func resolveFreshDefault(
        userID: String,
        servicesDirectory: URL,
        base: URL,
        fileManager: FileManager = .default
    ) throws -> Self {
        guard !userID.isEmpty else { throw NativeStorageError.invalidIdentity }
        guard base.isFileURL else { throw NativeStorageError.libraryUnavailable }
        let base = base.standardizedFileURL
        let users = base.appendingPathComponent("Users", isDirectory: true)
        let user = users.appendingPathComponent(VectaRecordingStore.userDirectoryName(for: userID), isDirectory: true)
        for directory in [base, users, user] {
            // attributesOfItem observes even dangling symlinks; fileExists
            // alone would mistake those for a fresh, writable default.
            do {
                let attributes = try fileManager.attributesOfItem(atPath: directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                      fileManager.isReadableFile(atPath: directory.path) else {
                    throw NativeStorageError.libraryUnavailable
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                continue
            }
        }
        return Self(recordingBase: base, userDirectory: user,
                    servicesDirectory: servicesDirectory.standardizedFileURL)
    }

    static func candidateBases(home: URL, recorderBundleIdentifier: String = recorderBundleIdentifier) -> [URL] {
        VectaLegacyPaths.libraryBases(home: home)
    }

}

/// Keeps the existing user-selected external Inbox/LocalAI root open for the
/// lifecycle owner. This reader neither changes nor renews the saved bookmark.
final class NativeRecordingsFolderAccess {
    let root: URL
    private let scoped: Bool

    init(servicesDirectory: URL, fileManager: FileManager = .default) throws {
        let settings = servicesDirectory.appendingPathComponent("recordings-root.txt")
        let bookmark = servicesDirectory.appendingPathComponent("recordings-folder.bookmark")
        do {
            for file in [settings, bookmark] {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw NativeStorageError.folderUnavailable
                }
            }
            let path = try String(contentsOf: settings, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), !path.contains("\0"), !path.isEmpty else {
                throw NativeStorageError.folderUnavailable
            }
            var stale = false
            let resolved: URL
            do {
                resolved = try URL(resolvingBookmarkData: Data(contentsOf: bookmark),
                                   options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                                   bookmarkDataIsStale: &stale)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadCorruptFileError {
                // Security-scoped bookmarks can be bound to the predecessor's
                // signing identity. The recorded path grants no permissions:
                // ordinary filesystem access must succeed below, or the user
                // must select the folder again. Original grants remain intact.
                resolved = URL(fileURLWithPath: path)
            }
            guard resolved.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path else {
                throw NativeStorageError.folderIdentityChanged
            }
            let started = resolved.startAccessingSecurityScopedResource()
            do {
                let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      fileManager.isReadableFile(atPath: resolved.path),
                      fileManager.isWritableFile(atPath: resolved.path) else {
                    throw NativeStorageError.folderUnavailable
                }
            } catch {
                if started { resolved.stopAccessingSecurityScopedResource() }
                throw error
            }
            root = resolved.standardizedFileURL
            scoped = started
        } catch let error as NativeStorageError { throw error }
        catch { throw NativeStorageError.folderUnavailable }
    }

    private init(root url: URL, fileManager: FileManager) throws {
        let started = url.startAccessingSecurityScopedResource()
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  fileManager.isReadableFile(atPath: url.path), fileManager.isWritableFile(atPath: url.path) else {
                throw NativeStorageError.folderUnavailable
            }
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        root = url.standardizedFileURL; scoped = started
    }

    private struct ProcessingRootBinding: Codable {
        let ownerHash: String
        let libraryBasePath: String
        let rootPath: String
        let bookmark: Data
    }
    private struct ProcessingRoots: Codable {
        let version: Int
        var inheritedBindingKey: String?
        var bindings: [String: ProcessingRootBinding]
    }
    private static func bindingKey(ownerHash: String, libraryBasePath: String) -> String {
        SHA256.hash(data: Data((ownerHash + "\0" + libraryBasePath).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func canonicalPath(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    private static func attributesIfPresent(_ url: URL, fileManager: FileManager) throws -> [FileAttributeKey: Any]? {
        do { return try fileManager.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
    private static func validAbsolutePath(_ path: String) -> Bool { path.hasPrefix("/") && !path.contains("\0") }

    /// Bind processing state to the exact library/owner, not to the global
    /// predecessor export preference. Must run under RuntimeOwnership, and the
    /// returned access must remain retained for the library/model lifecycle.
    /// Only an archived migration may claim the inherited root, at most once.
    /// Selection without a binding uses its own validated Exports directory.
    static func openForLibrary(layout: NativeStorageLayout, userID: String,
                               inheritGlobalRoot: Bool = false,
                               fileManager: FileManager = .default) throws -> NativeRecordingsFolderAccess {
        guard !userID.isEmpty, layout.recordingBase.isFileURL,
              layout.userDirectory.standardizedFileURL.path == layout.recordingBase.appendingPathComponent("Users/" + VectaRecordingStore.userDirectoryName(for: userID)).standardizedFileURL.path else {
            throw NativeStorageError.invalidIdentity
        }
        _ = try NativeStorageLayout.resolveFreshDefault(userID: userID, servicesDirectory: layout.servicesDirectory,
                                                       base: layout.recordingBase, fileManager: fileManager)
        let ownerHash = VectaRecordingStore.userDirectoryName(for: userID)
        let basePath = canonicalPath(layout.recordingBase)
        let key = bindingKey(ownerHash: ownerHash, libraryBasePath: basePath)
        let file = layout.servicesDirectory.appendingPathComponent("native-processing-roots.json")
        guard let serviceAttributes = try attributesIfPresent(layout.servicesDirectory, fileManager: fileManager),
              serviceAttributes[.type] as? FileAttributeType == .typeDirectory,
              (serviceAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw NativeStorageError.folderUnavailable
        }
        var roots = ProcessingRoots(version: 1, inheritedBindingKey: nil, bindings: [:])
        if let attributes = try attributesIfPresent(file, fileManager: fileManager) {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_000_000 else {
                throw NativeStorageError.folderUnavailable
            }
            do { roots = try JSONDecoder().decode(ProcessingRoots.self, from: Data(contentsOf: file)) }
            catch { throw NativeStorageError.folderUnavailable }
            guard roots.version == 1, roots.bindings.count <= 128,
                  roots.inheritedBindingKey == nil || roots.bindings[roots.inheritedBindingKey!] != nil else {
                throw NativeStorageError.folderUnavailable
            }
            for (storedKey, binding) in roots.bindings {
                guard binding.ownerHash.count == 64, binding.ownerHash.allSatisfy(\.isHexDigit),
                      validAbsolutePath(binding.libraryBasePath), validAbsolutePath(binding.rootPath),
                      !binding.bookmark.isEmpty, binding.bookmark.count <= 65536,
                      storedKey == bindingKey(ownerHash: binding.ownerHash, libraryBasePath: binding.libraryBasePath) else {
                    throw NativeStorageError.folderUnavailable
                }
            }
        }
        if let binding = roots.bindings[key] {
            guard binding.ownerHash == ownerHash, binding.libraryBasePath == basePath else {
                throw NativeStorageError.folderIdentityChanged
            }
            var stale = false
            let resolved: URL
            do {
                resolved = try URL(resolvingBookmarkData: binding.bookmark, options: [.withSecurityScope, .withoutUI],
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                // This is a new library-specific binding, not an inherited
                // predecessor grant. Corruption requires explicit recovery;
                // never downgrade a damaged binding into a path-only default.
                throw NativeStorageError.folderUnavailable
            }
            guard canonicalPath(resolved) == binding.rootPath else { throw NativeStorageError.folderIdentityChanged }
            return try NativeRecordingsFolderAccess(root: resolved, fileManager: fileManager)
        }
        guard roots.bindings.count < 128 else { throw NativeStorageError.folderUnavailable }
        let access: NativeRecordingsFolderAccess
        let settings = layout.servicesDirectory.appendingPathComponent("recordings-root.txt")
        let bookmark = layout.servicesDirectory.appendingPathComponent("recordings-folder.bookmark")
        let hasSettings = try attributesIfPresent(settings, fileManager: fileManager) != nil
        let hasBookmark = try attributesIfPresent(bookmark, fileManager: fileManager) != nil
        let claimsInherited = inheritGlobalRoot && roots.inheritedBindingKey == nil && (hasSettings || hasBookmark)
        if claimsInherited {
            // Missing/malformed inherited configuration fails rather than
            // discarding history or assigning the root to another library.
            access = try NativeRecordingsFolderAccess(servicesDirectory: layout.servicesDirectory, fileManager: fileManager)
        } else {
            let exports = layout.recordingBase.appendingPathComponent("Exports", isDirectory: true)
            if let attributes = try attributesIfPresent(exports, fileManager: fileManager) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw NativeStorageError.folderUnavailable }
            } else {
                try fileManager.createDirectory(at: exports, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            access = try NativeRecordingsFolderAccess(root: exports, fileManager: fileManager)
        }
        let rootPath = canonicalPath(access.root)
        // An automatically derived root must never alias another library's
        // workspace, queue, voice store or malformed preference evidence.
        guard !roots.bindings.values.contains(where: { $0.rootPath == rootPath }) else {
            throw NativeStorageError.folderIdentityChanged
        }
        let data = try access.root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        guard !data.isEmpty, data.count <= 65536 else { throw NativeStorageError.folderUnavailable }
        roots.bindings[key] = ProcessingRootBinding(ownerHash: ownerHash, libraryBasePath: basePath, rootPath: rootPath, bookmark: data)
        if claimsInherited { roots.inheritedBindingKey = key }
        let encoded = try JSONEncoder().encode(roots)
        guard encoded.count <= 1_000_000 else { throw NativeStorageError.folderUnavailable }
        try encoded.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return access
    }

    deinit { if scoped { root.stopAccessingSecurityScopedResource() } }
}

/// A standard folder-picker grant for the historical sandbox library. No
/// moving/copying denied data and no widening access to another account.
final class NativeLibraryFolderAccess {
    let root: URL
    private let scoped: Bool
    private init(_ url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            if started { url.stopAccessingSecurityScopedResource() }
            throw NativeStorageError.libraryUnavailable
        }
        root = url; scoped = started
    }
    static func restore(servicesDirectory: URL) throws -> NativeLibraryFolderAccess? {
        let file = servicesDirectory.appendingPathComponent("native-library.bookmark")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw NativeStorageError.libraryUnavailable }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: Data(contentsOf: file), options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return try NativeLibraryFolderAccess(url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadCorruptFileError {
            // Rediscover the exact owner using the conservative library resolver.
            // Multiple accessible matches still require a folder selection.
            return nil
        }
    }
    static func save(_ url: URL, servicesDirectory: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let file = servicesDirectory.appendingPathComponent("native-library.bookmark")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    deinit { if scoped { root.stopAccessingSecurityScopedResource() } }
}

enum NativeStorageError: LocalizedError {
    case invalidIdentity, libraryNotFound, libraryUnavailable, ambiguousLibrary
    case folderUnavailable, folderIdentityChanged

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return VL.text("Не удалось подтвердить существующий аккаунт.")
        case .libraryNotFound: return VL.text("Существующая библиотека не найдена. Выберите её папку для продолжения.")
        case .libraryUnavailable: return VL.text("Нет доступа к существующей библиотеке. Проверьте разрешение на выбранную папку.")
        case .ambiguousLibrary: return VL.text("Найдено несколько библиотек. Выберите ту, которую использовали ранее.")
        case .folderUnavailable: return VL.text("Не удалось открыть сохранённую папку записей. Выберите ту же папку снова.")
        case .folderIdentityChanged: return VL.text("Сохранённое разрешение указывает на другую папку. Выберите существующую папку записей.")
        }
    }
}
