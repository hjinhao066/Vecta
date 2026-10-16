import Foundation
import Darwin

/// Serial model mutation. A failed/cancelled install never becomes usable.
actor LocalModelManager {
    let root: URL
    let registry: LocalModelRegistry
    private var mutations = Set<String>()
    private var reservedSpace: [String: Int64] = [:]
    private var inUse = Set<String>()
    private var verified:[String:[String]]=[:]
    private func signatures(_ model:LocalModelDefinition,_ directory:URL)throws->[String] {
        try model.files.map {file in
            let url=directory.appendingPathComponent(file.name);var info=stat()
            guard lstat(url.path,&info)==0,(info.st_mode & S_IFMT)==S_IFREG,info.st_size==file.size else{throw LocalModelError.checksum(file.name)}
            return "\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec)|\(info.st_ctimespec.tv_nsec)"
        }
    }
    private let makeDownloader: @Sendable () -> any LocalModelDownloading
    private let freeSpace: @Sendable (URL) throws -> Int64

    init(registry: LocalModelRegistry, root: URL? = nil,
         makeDownloader: @escaping @Sendable () -> any LocalModelDownloading = { LocalModelDownloader() },
         freeSpace: @escaping @Sendable (URL) throws -> Int64 = { url in
             let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
             return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
         }) throws {
        self.registry = registry
        self.makeDownloader = makeDownloader
        self.freeSpace = freeSpace
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Vecta/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }

    func directory(for id: String) throws -> URL {
        guard let model = registry.models.first(where: { $0.id == id }) else { throw LocalModelError.invalidManifest }
        return VectaLegacyPaths.modelDirectory(name: model.id + "-" + model.revision, preferred: root.appendingPathComponent(model.id + "-" + model.revision, isDirectory: true))
    }

    func verify(_ id: String) throws -> URL {
        guard let model = registry.models.first(where: { $0.id == id }) else { throw LocalModelError.invalidManifest }
        let directory = try directory(for: id)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw LocalModelError.incomplete }
        let before=try signatures(model,directory)
        let cached=verified[id]==before
        for file in model.files {
            var parent=directory
            for part in file.name.split(separator:"/").dropLast() {
                parent=parent.appendingPathComponent(String(part))
                let values=try parent.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard values.isDirectory == true,values.isSymbolicLink != true else { throw LocalModelError.incomplete }
            }
            if !cached {try LocalModelIntegrity.verify(file,at:directory.appendingPathComponent(file.name))}
        }
        let after=try signatures(model,directory)
        guard before==after else{verified[id]=nil;throw LocalModelError.incomplete}
        verified[id]=after
        return directory
    }

    /// Call only from an explicit Install command. Merely choosing local mode
    /// does not call install. Cancellation propagates to the URLSession task.
    func install(_ id: String, progress: @escaping @Sendable (LocalModelStatus) -> Void) async throws {
        guard !mutations.contains(id), !inUse.contains(id) else { throw LocalModelError.inUse }
        guard let model = registry.models.first(where: { $0.id == id }) else { throw LocalModelError.invalidManifest }
        try model.validate()
        try Task.checkCancellation()
        if (try? verify(id)) != nil {
            progress(LocalModelStatus(modelID: id, state: .installed, received: model.size, total: model.size, error: nil))
            return
        }
        try Task.checkCancellation()
        mutations.insert(id)
        defer { mutations.remove(id); reservedSpace[id] = nil }
        let temporary = root.appendingPathComponent(".install-" + id + "-" + model.revision, isDirectory: true)
        if FileManager.default.fileExists(atPath: temporary.path) {
            let values = try temporary.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw LocalModelError.incomplete }
        } else {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        // Partial pinned downloads remain private for explicit resume.
        do {
            progress(LocalModelStatus(modelID: id, state: .preparing, received: 0, total: model.size, error: nil))
            let required = reservedSpace.values.reduce(model.size, +) + 256 * 1_048_576
            guard try freeSpace(root) > required else { throw LocalModelError.insufficientSpace }
            reservedSpace[id] = model.size
            var received: Int64 = 0
            for file in model.files {
                try Task.checkCancellation()
                let previous = received
                let destination = temporary.appendingPathComponent(file.name)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
                if (try? LocalModelIntegrity.verify(file, at: destination)) == nil {
                    // Small partial files cannot be resumed; large files use
                    // strict byte ranges and final full-file SHA-256.
                    if file.size < LocalModelDownloader.rangeThreshold && FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    if let size = (try? destination.resourceValues(forKeys:[.fileSizeKey]))?.fileSize, Int64(size) == file.size { try FileManager.default.removeItem(at:destination) }
                    let downloader = makeDownloader()
                    try await downloader.download(file, to: destination) { bytes in
                        progress(LocalModelStatus(modelID: id, state: .downloading, received: previous + bytes, total: model.size, error: nil))
                    }
                }
                try LocalModelIntegrity.verify(file, at: temporary.appendingPathComponent(file.name))
                received += file.size
            }
            progress(LocalModelStatus(modelID: id, state: .verifying, received: received, total: model.size, error: nil))
            for file in model.files { try LocalModelIntegrity.verify(file, at: temporary.appendingPathComponent(file.name)) }
            try Task.checkCancellation()
            let destination = try directory(for: id)
            // Existing valid installs are preserved; damaged installs are moved
            // aside until the replacement has been published successfully.
            let backup = root.appendingPathComponent(".previous-" + UUID().uuidString)
            let exists = FileManager.default.fileExists(atPath: destination.path)
            if exists { try FileManager.default.moveItem(at: destination, to: backup) }
            do { try FileManager.default.moveItem(at: temporary, to: destination) }
            catch {
                if exists { try? FileManager.default.moveItem(at: backup, to: destination) }
                throw error
            }
            if exists { try? FileManager.default.removeItem(at: backup) }
            progress(LocalModelStatus(modelID: id, state: .installed, received: received, total: model.size, error: nil))
        } catch {
            let partials = (try? FileManager.default.subpathsOfDirectory(atPath: temporary.path)) ?? []
            let resumable = partials.contains { path in
                guard let size=(try? temporary.appendingPathComponent(path).resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])),size.isRegularFile==true else{return false}
                return (size.fileSize ?? 0)>0
            }
            var corrupt=false
            if case LocalModelError.checksum = error { corrupt=true }
            if corrupt || !resumable { try? FileManager.default.removeItem(at:temporary) }
            progress(LocalModelStatus(modelID: id, state: error is CancellationError ? .notInstalled : .failed,
                                      received: 0, total: model.size, error: error is CancellationError ? nil : error.localizedDescription))
            throw error
        }
    }

    static let speechIDs = ["whisper", "speaker", "tokenizer"]
    func installSpeech(progress: @escaping @Sendable (LocalModelStatus) -> Void) async throws {
        try await withThrowingTaskGroup(of: Result<Void, Error>.self) { group in
            for id in Self.speechIDs {
                group.addTask {
                    do { try await self.install(id, progress: progress); return .success(()) }
                    catch { return .failure(error) }
                }
            }
            var failure: Error?
            for try await result in group {
                if case .failure(let error) = result, failure == nil { failure = error }
            }
            if let failure { throw failure }
        }
    }
    func acquire(_ id: String) throws -> URL {
        guard !mutations.contains(id), !inUse.contains(id) else { throw LocalModelError.inUse }
        let directory = try verify(id)
        inUse.insert(id)
        return directory
    }
    func release(_ id: String) { inUse.remove(id) }
    func remove(_ id: String) throws {
        verified[id]=nil
        guard !mutations.contains(id), !inUse.contains(id) else { throw LocalModelError.inUse }
        let directory = try directory(for: id)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        if let model=registry.models.first(where:{$0.id==id}) {
            let partial=root.appendingPathComponent(".install-"+id+"-"+model.revision)
            if FileManager.default.fileExists(atPath:partial.path) { try FileManager.default.removeItem(at:partial) }
        }
    }
}
