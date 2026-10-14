import CryptoKit
import Darwin
import Foundation

/// Copies completed recordings to the folder explicitly selected by this user.
/// The source and any existing destination remain authoritative and untouched.
final class VectaLocalAudioExporter {
    private let localCache=LocalAIReadCache()
    private let defaults: UserDefaults
    private let bookmarkKey: String
    private let folderNameKey: String
    private let preferencesLock = NSLock()
    private let queue = DispatchQueue(label: "app.vecta.local-audio-export", qos: .utility)
    private static let requestLock = NSLock()
    // Accessed only on queue. Large audio is hashed again only when its inode,
    // size, modification time or change time changes.
    private var audioFingerprints: [String: (FileStamp, String)] = [:]
    private var requestManifests: [String: (FileStamp, RequestManifest?)] = [:]

    init(userID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let prefix = "Vecta.LocalAudioExport." + VectaRecordingStore.userDirectoryName(for: userID)
        bookmarkKey = prefix + ".bookmark"
        folderNameKey = prefix + ".folderName"
    }

    var folderName: String? {
        preferencesLock.lock()
        defer { preferencesLock.unlock() }
        guard defaults.data(forKey: bookmarkKey) != nil else { return nil }
        return defaults.string(forKey: folderNameKey)
    }

    func configureFolder(_ folder: URL) throws {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        try Self.validateFolder(folder)
        let (bookmark, folderName) = try Self.coordinateFolder(folder, writing: true) { coordinated in
            _ = try Self.managedDirectory("Inbox", under: coordinated, create: true)
            _ = try Self.managedDirectory("Results", under: coordinated, create: true)
            do {
                // The picker URL already carries security scope. Empty options
                // preserve it; minimalBookmark is rejected for this scoped URL
                // when the iPad app runs on Mac.
                let bookmark = try coordinated.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                return (bookmark, coordinated.lastPathComponent)
            } catch {
                throw Self.folderFailure(error, stage: .saveBookmark)
            }
        }
        preferencesLock.lock()
        defaults.set(bookmark, forKey: bookmarkKey)
        defaults.set(folderName, forKey: folderNameKey)
        preferencesLock.unlock()
    }

    func export(
        recording: VectaRecording,
        audioURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        queue.async { [self] in
            let result: Result<URL, Error>
            do {
                result = .success(try exportOnQueue(recording: recording, audioURL: audioURL))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func results(
        recording: VectaRecording,
        completion: @escaping (Result<[VectaSavedAnalysisResult], Error>) -> Void
    ) {
        snapshot(recording: recording) { result in
            completion(result.map(\.results))
        }
    }

    func snapshot(recording: VectaRecording, audioURL: URL? = nil,
                  completion: @escaping (Result<VectaSavedAnalysisSnapshot, Error>) -> Void) {
        queue.async { [self] in
            let result: Result<VectaSavedAnalysisSnapshot, Error>
            do {
                result = .success(try readSnapshot(recording: recording, audioURL: audioURL))
            } catch let error as VectaLocalAudioExportError {
                result = .failure(error)
            } catch {
                result = .failure(VectaLocalAudioExportError.resultsUnavailable)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func localSnapshot(recording: VectaRecording, audioURL: URL,
                       completion: @escaping (Result<(AIProviderID, [AIProcessingResult]), Error>) -> Void) {
        queue.async { [self] in
            let result = Result { try withFolder(writing: false) { root in
                let store = LocalAIFileStore(root: root)
                let provider = try store.provider()
                let filenames = Set(Self.filenames(for: recording))
                guard !filenames.isEmpty else { throw VectaLocalAudioExportError.invalidRecording }
                let digest = try cachedAudioDigest(audioURL)
                let requests = try localCache.requests(root:root).filter { filenames.contains($0.audioFilename) && $0.audioSHA256 == digest }
                return (provider, try requests.compactMap { try localCache.result($0.id,root:root) })
            } }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func requestLocalAI(recording: VectaRecording, audioURL: URL, interpretation: VectaSummaryInterpretation,
                        transcriptRequestID: UUID? = nil, summaryTemplate:AISummaryTemplate? = nil, automaticSettings:AIAutomaticSettings? = nil, visualEnabled:Bool? = nil, completion: @escaping (Result<UUID, Error>) -> Void) {
        queue.async { [self] in
            let result = Result { () throws -> UUID in
                let previousFilename: String? = try withFolder(writing: false) { root in
                    guard let transcriptRequestID else { return nil }
                    guard let source = try LocalAIFileStore(root: root).result(transcriptRequestID),
                          Self.filenames(for: recording).contains(source.request.audioFilename) else { throw AIProcessingError.invalidTranscript }
                    return source.request.audioFilename
                }
                let copy = try exportOnQueue(recording: recording, audioURL: audioURL, preferredFilename: previousFilename)
                return try withFolder { root in
                    let store = LocalAIFileStore(root: root)
                    guard try store.provider() == .local else { throw AIProcessingError.invalidRequest }
                    var request = AIProcessingRequest(version: 1, id: UUID(), recordingID: copy.deletingPathExtension().lastPathComponent,
                        audioFilename: copy.lastPathComponent, audioSHA256: try cachedAudioDigest(copy), provider: .local,
                        format: interpretation, createdAt: Date(), summaryOnly: transcriptRequestID != nil, transcriptRequestID: transcriptRequestID, summaryModel: try (automaticSettings?.model ?? store.summaryModel()))
                    request.outputLanguage=VL.language.rawValue
                    request.summaryTemplate=summaryTemplate
                    request.visualEnabled=try (visualEnabled ?? automaticSettings?.visual ?? store.automaticAISettings().visual)
                    request.visualSummaryModel=request.selectedSummaryModel
                    try store.submit(request,cache:self.localCache)
                    return request.id
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func cancelLocalAI(_ id: UUID) {
        queue.async { [self] in _ = try? withFolder { root in try LocalAIFileStore(root: root).cancel(id) } }
    }

    func openLocalAISettings(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let result = Result { try withFolder { root in try LocalAIFileStore(root: root).requestSettings() } }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func localAISettings(completion: @escaping (Result<LocalAISettingsSnapshot?, Error>) -> Void) {
        queue.async { [self] in
            let result = Result { try withFolder(writing: false) { root in try LocalAIFileStore(root: root).settingsSnapshot() } }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func configureLocalAI(action: LocalAISettingsAction, modelID: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let result = Result { try withFolder { root in try LocalAIFileStore(root: root).submitSettingsCommand(action: action, modelID: modelID) } }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func readSnapshot(recording: VectaRecording, audioURL: URL?) throws -> VectaSavedAnalysisSnapshot {
        return try withFolder(writing: false) { root in
            guard let filename = Self.resolvedFilename(for: recording, root: root) else { throw VectaLocalAudioExportError.invalidRecording }
            let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
            guard Self.itemExists(inbox) else {
                return VectaSavedAnalysisSnapshot(requests: [], results: [], submissions: [])
            }
            try Self.validateFolder(inbox)
            let audioCopy = inbox.appendingPathComponent(filename)
            guard Self.itemExists(audioCopy) else {
                return VectaSavedAnalysisSnapshot(requests: [], results: [], submissions: [])
            }
            let sourceDigest = try cachedAudioDigest(audioCopy)
            if let audioURL, try cachedAudioDigest(audioURL) != sourceDigest {
                throw VectaLocalAudioExportError.audioChanged
            }
            let catalog = try requestCatalog(audioCopy: audioCopy, sourceDigest: sourceDigest)
            let directory = root.appendingPathComponent("Results", isDirectory: true)
            guard Self.itemExists(directory) else {
                return VectaSavedAnalysisSnapshot(requests: catalog.requests, results: [], submissions: [])
            }
            try Self.validateFolder(directory)
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles])
            var results: [VectaSavedAnalysisResult] = []
            var submissions: [VectaSavedAnalysisSubmission] = []
            for url in entries where url.pathExtension == "json" {
                if url.lastPathComponent.hasSuffix(".status.json") {
                    if let submission = Self.readSubmission(url, filename: filename, sourceDigest: sourceDigest, catalog: catalog) {
                        submissions.append(submission)
                    }
                } else if let output = Self.readResult(url, directory: directory, filename: filename,
                                                      sourceDigest: sourceDigest, catalog: catalog) {
                    results.append(output)
                }
            }
            results.sort { $0.completedAt == $1.completedAt ? $0.id < $1.id : $0.completedAt > $1.completedAt }
            submissions.sort { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
            return VectaSavedAnalysisSnapshot(requests: catalog.requests, results: results, submissions: submissions)
        }
    }

    private func exportOnQueue(recording: VectaRecording, audioURL: URL, preferredFilename: String? = nil) throws -> URL {
        guard recording.status != .copying else { throw VectaLocalAudioExportError.recordingStillCopying }
        let destination = try withFolder { root in
            guard let filename = preferredFilename ?? Self.resolvedFilename(for: recording, root: root) else { throw VectaLocalAudioExportError.invalidRecording }
            let folder = try Self.managedDirectory("Inbox", under: root, create: true)
            return try copyAudio(audioURL, to: folder.appendingPathComponent(filename), in: folder)
        }
        // A coordinator may return an equivalent directory URL containing
        // redundant path components. Keep the public recording identity stable.
        return destination.standardizedFileURL
    }

    func submissions(recording: VectaRecording, completion: @escaping (Result<[VectaSavedAnalysisSubmission], Error>) -> Void) {
        snapshot(recording: recording) { result in
            completion(result.map(\.submissions))
        }
    }

    private struct SubmissionMetadata: Decodable {
        let version: Int
        let id: String
        let filename: String
        let sourceSHA256: String
        let interpretationID: String
        let formatSnapshot: VectaSummaryInterpretation?
        let requestID: String
        let status: VectaSavedAnalysisSubmissionPhase
        let updatedAt: String
        let error: String?
        let conversationURL: String?
        enum CodingKeys: String, CodingKey {
            case version, id, filename, status, error
            case sourceSHA256 = "source_sha256", interpretationID = "interpretation_id", requestID = "request_id"
            case formatSnapshot = "format_snapshot"
            case updatedAt = "updated_at", conversationURL = "conversation_url"
        }
    }

    static func filenames(for recording: VectaRecording) -> [String] {
        if recording.deviceSerialNumber.hasPrefix("local-audio-"), let local = recording.localFileName {
            let ext = URL(fileURLWithPath:local).pathExtension.lowercased()
            guard ["mp3", "m4a", "wav", "aiff", "aif", "caf"].contains(ext) else { return [] }
            return ["Vecta_" + recording.deviceSerialNumber + "." + ext]
        }
        guard let identity = VectaRecordingStore.cloudSourceIdentifier(sessionID: recording.sessionID,
            serialNumber: recording.deviceSerialNumber, duration: recording.duration) else { return [] }
        // Existing filenames are immutable request identities, not UI branding.
        return VectaLegacyPaths.exportFilenames(identity: identity)
    }
    private static func resolvedFilename(for recording: VectaRecording, root: URL) -> String? {
        let candidates = filenames(for: recording)
        return candidates.first { itemExists(root.appendingPathComponent("Inbox/" + $0)) } ?? candidates.first
    }

    private func withFolder<T>(writing: Bool = true, _ work: (URL) throws -> T) throws -> T {
        preferencesLock.lock()
        let bookmark = defaults.data(forKey: bookmarkKey)
        preferencesLock.unlock()
        guard let bookmark else { throw VectaLocalAudioExportError.folderNotConfigured }
        var stale = false
        let folder: URL
        do {
            folder = try URL(
                resolvingBookmarkData: bookmark,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw Self.folderFailure(error, stage: .resolveBookmark)
        }
        let folderScoped = folder.startAccessingSecurityScopedResource()
        defer { if folderScoped { folder.stopAccessingSecurityScopedResource() } }
        try Self.validateFolder(folder)
        if stale {
            // Renew only the bookmark this operation resolved. A newly selected
            // folder must not be replaced by an older background export.
            if let renewed = try? folder.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                preferencesLock.lock()
                if defaults.data(forKey: bookmarkKey) == bookmark {
                    defaults.set(renewed, forKey: bookmarkKey)
                    defaults.set(folder.lastPathComponent, forKey: folderNameKey)
                }
                preferencesLock.unlock()
            }
        }
        return try Self.coordinateFolder(folder, writing: writing, work)
    }

    /// Coordinate the selected directory while its security scope is active.
    /// Merging adds/updates children; it does not replace the chosen directory.
    private static func coordinateFolder<T>(
        _ folder: URL,
        writing: Bool,
        _ work: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { coordinated in
            result = Result {
                try validateFolder(coordinated)
                return try work(coordinated)
            }
        }
        if writing {
            coordinator.coordinate(
                writingItemAt: folder, options: .forMerging,
                error: &coordinationError, byAccessor: accessor
            )
        } else {
            coordinator.coordinate(
                readingItemAt: folder, options: [],
                error: &coordinationError, byAccessor: accessor
            )
        }
        let stage: VectaLocalFolderStage = writing ? .coordinateWriting : .coordinateReading
        if let coordinationError { throw folderFailure(coordinationError, stage: stage) }
        guard let result else {
            throw VectaLocalAudioExportError.folderOperationFailed(
                stage: stage, domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteUnknown.rawValue
            )
        }
        return try result.get()
    }

    private static func folderFailure(_ error: Error, stage: VectaLocalFolderStage) -> VectaLocalAudioExportError {
        if let known = error as? VectaLocalAudioExportError { return known }
        let underlying = error as NSError
        if (underlying.domain == NSCocoaErrorDomain && [
            CocoaError.Code.fileNoSuchFile.rawValue,
            CocoaError.Code.fileReadNoSuchFile.rawValue
        ].contains(underlying.code))
            || (underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)) {
            return .folderUnavailable
        }
        // Never include provider descriptions, userInfo, URLs, or paths.
        let safeDomains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSMachErrorDomain]
        let domain = safeDomains.contains(underlying.domain) ? underlying.domain : VL.text("провайдер файлов")
        return .folderOperationFailed(stage: stage, domain: domain, code: underlying.code)
    }

    private func copyAudio(_ audioURL: URL, to destination: URL, in folder: URL) throws -> URL {
        let sourceScoped = audioURL.startAccessingSecurityScopedResource()
        defer { if sourceScoped { audioURL.stopAccessingSecurityScopedResource() } }
        let source = try Self.openAudio(audioURL)
        defer { try? source.close() }
        let sourceFingerprint = try Self.fingerprint(source)
        if Self.itemExists(destination) {
            try Self.requireMatching(destination, fingerprint: sourceFingerprint)
            return destination
        }

        let temporary = folder.appendingPathComponent(".vecta-export-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw VectaLocalAudioExportError.exportFailed }
        // Remove exactly this operation's temporary file, including failures.
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            defer { try? output.close() }
            try source.seek(toOffset: 0)
            var copiedHash = SHA256()
            var copiedSize: UInt64 = 0
            while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                copiedHash.update(data: chunk)
                copiedSize += UInt64(chunk.count)
            }
            guard Fingerprint(digest: Data(copiedHash.finalize()), size: copiedSize) == sourceFingerprint else {
                throw VectaLocalAudioExportError.audioChanged
            }
            try output.synchronize()
            try output.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            // RENAME_EXCL makes publication atomic and refuses to overwrite a
            // destination created by another exporter or app during the copy.
            if renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST {
                    try Self.requireMatching(destination, fingerprint: sourceFingerprint)
                } else {
                    throw VectaLocalAudioExportError.exportFailed
                }
            }
            return destination
        } catch let error as VectaLocalAudioExportError {
            throw error
        } catch {
            throw VectaLocalAudioExportError.exportFailed
        }
    }

    private struct Fingerprint: Equatable {
        let digest: Data
        let size: UInt64
    }

    private struct FileStamp: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = Int64(value.st_dev)
            inode = UInt64(value.st_ino)
            size = Int64(value.st_size)
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private func cachedAudioDigest(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try Self.openAudio(url)
        defer { try? file.close() }
        var before = stat()
        guard fstat(file.fileDescriptor, &before) == 0 else { throw VectaLocalAudioExportError.audioUnavailable }
        let stamp = FileStamp(before)
        let key = url.standardizedFileURL.path
        if let cached = audioFingerprints[key], cached.0 == stamp { return cached.1 }
        let fingerprint = try Self.fingerprint(file)
        var after = stat()
        guard fstat(file.fileDescriptor, &after) == 0, FileStamp(after) == stamp,
              fingerprint.size == UInt64(before.st_size) else { throw VectaLocalAudioExportError.audioChanged }
        let digest = fingerprint.digest.map { String(format: "%02x", $0) }.joined()
        if audioFingerprints.count > 32 { audioFingerprints.removeAll() }
        audioFingerprints[key] = (stamp, digest)
        return digest
    }

    private func cachedRequest(_ url: URL, filename: String) -> RequestManifest? {
        var before = stat()
        guard lstat(url.path, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        let stamp = FileStamp(before)
        let key = url.standardizedFileURL.path
        if let cached = requestManifests[key], cached.0 == stamp { return cached.1 }
        let request = Self.readRequest(url, filename: filename)
        var after = stat()
        guard lstat(url.path, &after) == 0, FileStamp(after) == stamp else { return nil }
        if requestManifests.count > 512 { requestManifests.removeAll() }
        requestManifests[key] = (stamp, request)
        return request
    }

    private struct RequestCatalog {
        let byID: [String: VectaSavedAnalysisRequest]
        let invalidIDs: Set<String>
        var requests: [VectaSavedAnalysisRequest] {
            byID.values.sorted {
                $0.requestedAt == $1.requestedAt
                    ? $0.identity.requestID < $1.identity.requestID : $0.requestedAt > $1.requestedAt
            }
        }

        func accepts(_ identity: VectaSavedAnalysisRequestIdentity, requireManifest: Bool) -> Bool {
            guard !invalidIDs.contains(identity.requestID) else { return false }
            if let request = byID[identity.requestID] { return request.identity == identity }
            // Old v1 outputs may predate immutable request archives. They remain
            // readable as history, but cannot become a current request/status.
            return !requireManifest
        }
    }

    private func requestCatalog(audioCopy: URL, sourceDigest: String) throws -> RequestCatalog {
        let filename = audioCopy.lastPathComponent
        let stem = audioCopy.deletingPathExtension().lastPathComponent
        let entries = try FileManager.default.contentsOfDirectory(at: audioCopy.deletingLastPathComponent(),
                                                                  includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var requests: [String: VectaSavedAnalysisRequest] = [:]
        var invalid = Set<String>()
        for url in entries where url.lastPathComponent == stem + ".request.json"
            || (url.lastPathComponent.hasPrefix(stem + ".") && url.lastPathComponent.hasSuffix(".request.json")) {
            let canonical = url.lastPathComponent == stem + ".request.json"
            let archivedID = canonical ? nil : Self.normalizedRequestID(String(url.lastPathComponent
                .dropFirst(stem.count + 1).dropLast(".request.json".count)))
            guard let manifest = cachedRequest(url, filename: filename),
                  let id = Self.normalizedRequestID(manifest.requestID),
                  canonical || archivedID == id,
                  let interpretation = Self.interpretation(for: manifest),
                  let requestedAt = Self.date(from: manifest.requestedAt) else {
                if let archivedID { invalid.insert(archivedID) }
                continue
            }
            let request = VectaSavedAnalysisRequest(identity: VectaSavedAnalysisRequestIdentity(filename: filename,
                sourceSHA256: sourceDigest, requestID: id, interpretation: interpretation), requestedAt: requestedAt)
            if let previous = requests[id], previous != request { invalid.insert(id) }
            requests[id] = request
        }
        for id in invalid { requests.removeValue(forKey: id) }
        return RequestCatalog(byID: requests, invalidIDs: invalid)
    }

    private static func readSubmission(_ url: URL, filename: String, sourceDigest: String,
                                       catalog: RequestCatalog) -> VectaSavedAnalysisSubmission? {
        guard let data = readRegularFile(url, maximumBytes: 64 * 1_024),
              let metadata = try? JSONDecoder().decode(SubmissionMetadata.self, from: data),
              (metadata.version == 1 || (metadata.version == 2 && metadata.formatSnapshot != nil)), metadata.filename == filename, metadata.sourceSHA256 == sourceDigest,
              isDigest(metadata.id), let requestID = normalizedRequestID(metadata.requestID),
              metadata.id == SHA256.hash(data: Data((sourceDigest + ":" + requestID).utf8))
                .map({ String(format: "%02x", $0) }).joined(),
              url.lastPathComponent == metadata.id + ".status.json",
              let interpretation = readInterpretation(data: data, id: metadata.interpretationID, snapshot: metadata.formatSnapshot),
              let updatedAt = date(from: metadata.updatedAt), (metadata.error?.count ?? 0) <= 1_000 else { return nil }
        let identity = VectaSavedAnalysisRequestIdentity(filename: filename, sourceSHA256: sourceDigest,
                                                 requestID: requestID, interpretation: interpretation)
        guard catalog.accepts(identity, requireManifest: true) else { return nil }
        return VectaSavedAnalysisSubmission(id: metadata.id, interpretation: interpretation, phase: metadata.status,
            updatedAt: updatedAt, error: metadata.error, conversationURL: metadata.conversationURL.flatMap(chatGPTURL),
            requestIdentity: identity)
    }

    private struct RequestManifest: Codable {
        let version: Int
        let filename: String
        let interpretationID: String
        let formatSnapshot: VectaSummaryInterpretation?
        let requestID: String
        let requestedAt: String

        private enum CodingKeys: String, CodingKey {
            case version, filename
            case interpretationID = "interpretation_id"
            case formatSnapshot = "format_snapshot"
            case requestID = "request_id"
            case requestedAt = "requested_at"
        }
    }

    private struct ResultMetadata: Decodable {
        let id: String
        let sourceSHA256: String
        let filename: String
        let interpretationID: String
        let formatSnapshot: VectaSummaryInterpretation?
        let requestID: String
        let completedAt: String
        let responseFilename: String
        let conversationURL: String
        let status: String

        private enum CodingKeys: String, CodingKey {
            case id, filename, status
            case sourceSHA256 = "source_sha256"
            case interpretationID = "interpretation_id"
            case formatSnapshot = "format_snapshot"
            case requestID = "request_id"
            case completedAt = "completed_at"
            case responseFilename = "response_filename"
            case conversationURL = "conversation_url"
        }
    }

    private static func managedDirectory(_ name: String, under root: URL, create: Bool) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        if !itemExists(directory), create {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw folderFailure(error, stage: name == "Inbox" ? .createInbox : .createResults)
            }
        }
        try validateFolder(directory)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw folderFailure(error, stage: name == "Inbox" ? .protectInbox : .protectResults)
        }
        return directory
    }

    private static func interpretation(for request: RequestManifest) -> VectaSummaryInterpretation? {
        if request.version == 1, request.formatSnapshot == nil {
            return VectaSummaryInterpretation(rawValue: request.interpretationID)
        }
        guard request.version == 2, let snapshot = request.formatSnapshot,
              snapshot.isValid, snapshot.id == request.interpretationID else { return nil }
        return snapshot
    }

    private static func readInterpretation(data: Data, id: String,
                                          snapshot: VectaSummaryInterpretation?) -> VectaSummaryInterpretation? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if object.keys.contains("format_snapshot") {
            guard let validated = VectaSummaryInterpretation.decodeSnapshot(object["format_snapshot"]),
                  validated == snapshot, validated.id == id else { return nil }
            return validated
        }
        return VectaSummaryInterpretation(rawValue: id)
    }

    private static func readRequest(_ url: URL, filename: String) -> RequestManifest? {
        guard let data = readRegularFile(url, maximumBytes: 64 * 1_024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? NSNumber,
              ["s", "i", "l", "q", "S", "I", "L", "Q"].contains(String(cString: version.objCType)),
              let request = try? JSONDecoder().decode(RequestManifest.self, from: data),
              request.filename == filename, normalizedRequestID(request.requestID) != nil,
              date(from: request.requestedAt) != nil else { return nil }
        let baseKeys = Set(["version", "filename", "interpretation_id", "request_id", "requested_at"])
        if request.version == 1 {
            guard data.count <= 16 * 1_024, Set(object.keys) == baseKeys,
                  Self.interpretation(for: request) != nil else { return nil }
        } else {
            guard request.version == 2, Set(object.keys) == baseKeys.union(["format_snapshot"]),
                  let snapshot = VectaSummaryInterpretation.decodeSnapshot(object["format_snapshot"]),
                  snapshot == request.formatSnapshot, snapshot.id == request.interpretationID else { return nil }
        }
        return request
    }

    private static func readResult(_ url: URL, directory: URL, filename: String, sourceDigest: String,
                                   catalog: RequestCatalog) -> VectaSavedAnalysisResult? {
        guard let data = readRegularFile(url, maximumBytes: 64 * 1_024),
              let metadata = try? JSONDecoder().decode(ResultMetadata.self, from: data),
              metadata.filename == filename,
              metadata.sourceSHA256 == sourceDigest,
              metadata.status == "completed",
              isDigest(metadata.id), isDigest(metadata.sourceSHA256),
              let requestID = normalizedRequestID(metadata.requestID),
              metadata.id == SHA256.hash(data: Data((metadata.sourceSHA256 + ":" + requestID).utf8))
                .map({ String(format: "%02x", $0) }).joined(),
              url.lastPathComponent == metadata.id + ".json",
              metadata.responseFilename == metadata.id + ".md",
              let interpretation = readInterpretation(data: data, id: metadata.interpretationID, snapshot: metadata.formatSnapshot),
              catalog.accepts(VectaSavedAnalysisRequestIdentity(filename: filename, sourceSHA256: sourceDigest,
                  requestID: requestID, interpretation: interpretation), requireManifest: metadata.formatSnapshot != nil),
              let completedAt = date(from: metadata.completedAt),
              let conversationURL = chatGPTURL(metadata.conversationURL),
              let bodyData = readRegularFile(
                directory.appendingPathComponent(metadata.responseFilename), maximumBytes: 4 * 1_024 * 1_024
              ),
              let body = String(data: bodyData, encoding: .utf8),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return VectaSavedAnalysisResult(
            id: metadata.id,
            interpretation: interpretation,
            body: body,
            completedAt: completedAt,
            conversationURL: conversationURL,
            requestIdentity: VectaSavedAnalysisRequestIdentity(filename: filename, sourceSHA256: sourceDigest,
                requestID: requestID, interpretation: interpretation)
        )
    }

    private static func readRegularFile(_ url: URL, maximumBytes: Int) -> Data? {
        guard url.isFileURL else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_size > 0,
              attributes.st_size <= maximumBytes,
              let data = try? file.read(upToCount: maximumBytes + 1),
              !data.isEmpty, data.count <= maximumBytes else { return nil }
        return data
    }

    private static func normalizedRequestID(_ value: String) -> String? {
        guard let parsed = UUID(uuidString: value),
              parsed.uuidString.lowercased() == value.lowercased() else { return nil }
        return parsed.uuidString.lowercased()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    }

    private static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func chatGPTURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme == "https", components.host == "chatgpt.com",
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == "/"
                || components.percentEncodedPath.range(of: #"^/c/[A-Za-z0-9_-]{8,128}$"#, options: .regularExpression) != nil else { return nil }
        return components.url
    }

    private static func validateFolder(_ folder: URL) throws {
        guard folder.isFileURL else { throw VectaLocalAudioExportError.folderUnavailable }
        let values: URLResourceValues
        do {
            values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw folderFailure(error, stage: .inspectFolder)
        }
        guard values.isDirectory == true,
              values.isSymbolicLink != true else { throw VectaLocalAudioExportError.folderUnavailable }
    }

    private static func openAudio(_ url: URL) throws -> FileHandle {
        guard url.isFileURL else { throw VectaLocalAudioExportError.audioUnavailable }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw VectaLocalAudioExportError.audioUnavailable }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_size > 0 else {
            close(descriptor)
            throw VectaLocalAudioExportError.audioUnavailable
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func fingerprint(_ file: FileHandle) throws -> Fingerprint {
        var hash = SHA256()
        var size: UInt64 = 0
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
            size += UInt64(chunk.count)
        }
        return Fingerprint(digest: Data(hash.finalize()), size: size)
    }

    private static func itemExists(_ url: URL) -> Bool {
        var attributes = stat()
        return lstat(url.path, &attributes) == 0
    }

    private static func requireMatching(_ destination: URL, fingerprint expected: Fingerprint) throws {
        do {
            let existing = try openAudio(destination)
            defer { try? existing.close() }
            guard try fingerprint(existing) == expected else { throw VectaLocalAudioExportError.destinationConflict }
        } catch {
            throw VectaLocalAudioExportError.destinationConflict
        }
    }
}

enum VectaLocalFolderStage: String {
    case inspectFolder = "проверка папки"
    case createInbox = "создание папки записей"
    case createResults = "создание папки результатов"
    case protectInbox = "права папки записей"
    case protectResults = "права папки результатов"
    case saveBookmark = "сохранение доступа к папке"
    case resolveBookmark = "восстановление доступа к папке"
    case coordinateWriting = "подготовка записи в папку"
    case coordinateReading = "подготовка чтения папки"

    var localizedTitle: String { VL.string(rawValue) }
}

enum VectaLocalAudioExportError: LocalizedError {
    case folderNotConfigured
    case folderUnavailable
    case folderOperationFailed(stage: VectaLocalFolderStage, domain: String, code: Int)
    case recordingStillCopying
    case invalidRecording
    case audioUnavailable
    case audioChanged
    case destinationConflict
    case exportFailed
    case folderChanged
    case requestUnavailable
    case resultsUnavailable

    var errorDescription: String? {
        switch self {
        case .folderNotConfigured:
            return VL.text("Сначала выберите папку записей.")
        case .folderUnavailable:
            return VL.text("Рабочая папка недоступна. Выберите доступную папку ещё раз.")
        case .folderOperationFailed(let stage, let domain, let code):
            return VL.text("Не удалось получить доступ к рабочей папке: \(stage.localizedTitle) (\(domain), код \(code)). Выберите папку ещё раз и разрешите доступ.")
        case .recordingStillCopying:
            return VL.text("Запись ещё копируется с диктофона. Vecta сохранит её в рабочую папку после завершения.")
        case .invalidRecording:
            return VL.text("Не удалось определить эту запись. Подключите диктофон заново и повторите попытку.")
        case .audioUnavailable:
            return VL.text("Локальный MP3 недоступен. Подключите диктофон и скопируйте запись заново.")
        case .audioChanged:
            return VL.text("Аудиофайл изменился при сохранении. Дождитесь завершения копирования и повторите попытку.")
        case .destinationConflict:
            return VL.text("В рабочей папке уже есть другой файл с таким именем. Выберите другую папку.")
        case .exportFailed:
            return VL.text("Не удалось сохранить MP3. Проверьте доступ к папке и свободное место, затем повторите попытку.")
        case .folderChanged:
            return VL.text("Рабочая папка изменилась при сохранении. Выберите вариант саммари ещё раз и повторите отправку.")
        case .requestUnavailable:
            return VL.text("Не удалось сохранить запрос анализа. Проверьте доступ к папке и повторите отправку.")
        case .resultsUnavailable:
            return VL.text("Не удалось прочитать сохранённые результаты. Проверьте рабочую папку и повторите попытку.")
        }
    }
}
