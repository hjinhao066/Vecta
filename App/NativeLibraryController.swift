import AVFoundation
import Combine
import CryptoKit
import Darwin
import Foundation
#if canImport(NotePinAudio)
import NotePinAudio
#endif

struct NativeRecordingIdentity: Hashable, Identifiable, Codable {
    let serialNumber: String
    let sessionID: Int
    var id: Self { self }
}

/// A read-only list entry is not a persisted copying attempt.
struct NativeRemoteRecording: Equatable, Identifiable {
    let identity: NativeRecordingIdentity
    let duration: TimeInterval
    let byteSize: UInt32
    var id: NativeRecordingIdentity { identity }
}

struct NativeLibraryItem: Identifiable {
    let identity: NativeRecordingIdentity
    let local: VectaRecording?
    let remote: NativeRemoteRecording?
    let audioURL: URL?
    var id: NativeRecordingIdentity { identity }
    var title: String {
        if let local { return local.title }
        let date = Date(timeIntervalSince1970: TimeInterval(identity.sessionID))
        return VL.text("Запись · ") + date.vectaFormatted(date: .abbreviated, time: .shortened)
    }
    var createdAt: Date { local?.createdAt ?? Date(timeIntervalSince1970: TimeInterval(identity.sessionID)) }
    var duration: TimeInterval { local?.duration ?? remote?.duration ?? 0 }
}

struct NativeDeletedRecording: Codable, Identifiable {
    let identity: NativeRecordingIdentity
    let title: String
    let deletedAt: Date
    var id: NativeRecordingIdentity { identity }
}

@MainActor final class NativeLibraryController: ObservableObject {
    @Published private(set) var items: [NativeLibraryItem] = []
    private(set) var oldestFirstItems:[NativeLibraryItem]=[]
    private(set) var localItemCount=0
    private var itemIndex:[NativeRecordingIdentity:NativeLibraryItem]=[:]
    func item(for identity:NativeRecordingIdentity)->NativeLibraryItem? {itemIndex[identity]}
    @Published private(set) var formats: [VectaSummaryInterpretation] = []
    @Published private(set) var message: String?
    let recordingStore: VectaRecordingStore
    let formatStore: VectaSummaryFormatStore
    let exporter: VectaLocalAudioExporter
    @Published private(set) var deletedRecordings: [NativeDeletedRecording] = []
    private let deletionURL: URL
    private let purgeURL: URL
    private(set) var purgedRecordings: Set<NativeRecordingIdentity> = []
    private var remote: [NativeRecordingIdentity: NativeRemoteRecording] = [:]

    init(userID: String, layout: NativeStorageLayout, exporter: VectaLocalAudioExporter) throws {
        recordingStore = try VectaRecordingStore(userID: userID, directory: layout.recordingBase)
        formatStore = try VectaSummaryFormatStore(userID: userID, directory: layout.recordingBase)
        self.exporter = exporter
        deletionURL = layout.recordingBase.appendingPathComponent("Users").appendingPathComponent(VectaRecordingStore.userDirectoryName(for: userID)).appendingPathComponent("native-recording-trash.json")
        purgeURL = deletionURL.deletingLastPathComponent().appendingPathComponent("native-recording-purged.json")
        if FileManager.default.fileExists(atPath: purgeURL.path) {
            let values = try purgeURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) < 8_000_000 else { throw NativeLibraryError.persistenceFailed }
            purgedRecordings = try JSONDecoder().decode(Set<NativeRecordingIdentity>.self, from: Data(contentsOf: purgeURL))
            guard purgedRecordings.allSatisfy({ $0.sessionID > 0 && !$0.serialNumber.isEmpty }) else { throw NativeLibraryError.persistenceFailed }
        }
        if FileManager.default.fileExists(atPath: deletionURL.path) {
            let values = try deletionURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) < 8_000_000 else { throw NativeLibraryError.persistenceFailed }
            deletedRecordings = try JSONDecoder().decode([NativeDeletedRecording].self, from: Data(contentsOf: deletionURL))
            guard Set(deletedRecordings.map(\.identity)).count == deletedRecordings.count,
                  deletedRecordings.allSatisfy({ $0.identity.sessionID > 0 && !$0.identity.serialNumber.isEmpty && $0.deletedAt.timeIntervalSince1970.isFinite }) else { throw NativeLibraryError.persistenceFailed }
        }
        reloadLibrary()
        reloadFormats()
    }

    /// Call only with the authenticated recorder's complete list. Clearing it
    /// on disconnect retains every local row and saved analysis.
    func replaceRemoteList(_ values: [NativeRemoteRecording]) throws {
        var next: [NativeRecordingIdentity: NativeRemoteRecording] = [:]
        for value in values {
            guard value.identity.sessionID > 0,
                  VectaDeviceModel(serialNumber: value.identity.serialNumber) != nil,
                  value.duration.isFinite, value.duration >= 0, value.byteSize > 0,
                  next.updateValue(value, forKey: value.identity) == nil else {
                throw NativeLibraryError.invalidRecording
            }
        }
        guard remote != next else { return }
        remote = next
        reloadLibrary()
    }

    private(set) var revision=0
    func reloadLibrary() {
        revision+=1
        let saved = Dictionary(uniqueKeysWithValues: recordingStore.all.map {
            (NativeRecordingIdentity(serialNumber: $0.deviceSerialNumber, sessionID: $0.sessionID), $0)
        })
        let next = Set(saved.keys).union(remote.keys).subtracting(deletedRecordings.map(\.identity)).subtracting(purgedRecordings).map { identity in
            let local = saved[identity]
            let audio = local.flatMap { $0.status == .copying ? nil : recordingStore.audioURL(for: $0) }
            return NativeLibraryItem(identity: identity, local: local, remote: remote[identity], audioURL: audio)
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            if $0.identity.serialNumber != $1.identity.serialNumber {
                return $0.identity.serialNumber < $1.identity.serialNumber
            }
            return $0.identity.sessionID > $1.identity.sessionID
        }
        oldestFirstItems=next.sorted{$0.createdAt<$1.createdAt}
        localItemCount=next.reduce(0){$0+($1.audioURL == nil ? 0:1)}
        itemIndex=Dictionary(uniqueKeysWithValues:next.map{($0.identity,$0)})
        items=next
    }

    /// Recoverable local deletion. The recorder is never a command target.
    /// Keeping owned files allows restoration of audio and all historical analyses.
    func deleteRecording(_ identity: NativeRecordingIdentity) throws {
        guard let item = items.first(where: { $0.identity == identity }), item.local?.status != .copying else { throw NativeLibraryError.invalidRecording }
        try saveTrash(deletedRecordings + [NativeDeletedRecording(identity: identity, title: item.title, deletedAt: Date())])
    }

    func restoreRecording(_ identity: NativeRecordingIdentity) throws {
        guard !purgedRecordings.contains(identity), deletedRecordings.contains(where: { $0.identity == identity }) else { throw NativeLibraryError.invalidRecording }
        try saveTrash(deletedRecordings.filter { $0.identity != identity })
    }

    /// Called only after a separate destructive confirmation in the trash UI.
    /// Persist identity-only suppression first so a crash cannot auto-redownload
    /// or offer restoration of an already partially purged recording.
    func permanentlyDeleteRecording(_ identity: NativeRecordingIdentity) async throws {
        guard deletedRecordings.contains(where: { $0.identity == identity }) else { throw NativeLibraryError.invalidRecording }
        let next = purgedRecordings.union([identity])
        try JSONEncoder().encode(next).write(to: purgeURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: purgeURL.path)
        purgedRecordings = next
        if let recording = recordingStore.recording(sessionID: identity.sessionID, serialNumber: identity.serialNumber) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                exporter.permanentlyDelete(recording: recording) { continuation.resume(with: $0) }
            }
        }
        try recordingStore.permanentlyRemove(sessionID: identity.sessionID, serialNumber: identity.serialNumber)
        try saveTrash(deletedRecordings.filter { $0.identity != identity })
    }

    private func saveTrash(_ next: [NativeDeletedRecording]) throws {
        try JSONEncoder().encode(next).write(to: deletionURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: deletionURL.path)
        deletedRecordings = next
        reloadLibrary()
    }

    func beginTransfer(_ identity: NativeRecordingIdentity) throws {
        guard !purgedRecordings.contains(identity), !deletedRecordings.contains(where: { $0.identity == identity }), let value = remote[identity] else { throw NativeLibraryError.notOnRecorder }
        if let existing = recordingStore.recording(sessionID: identity.sessionID, serialNumber: identity.serialNumber),
           existing.status != .copying, recordingStore.audioURL(for: existing) != nil {
            throw NativeLibraryError.alreadyLocal
        }
        guard recordingStore.begin(sessionID: identity.sessionID, serialNumber: identity.serialNumber,
                                   duration: value.duration) else { throw NativeLibraryError.persistenceFailed }
        reloadLibrary()
    }

    func failTransfer(_ identity: NativeRecordingIdentity, message: String) {
        guard recordingStore.recording(sessionID: identity.sessionID, serialNumber: identity.serialNumber)?.status == .copying else { return }
        _ = recordingStore.markFailed(sessionID: identity.sessionID, serialNumber: identity.serialNumber, message: message)
        reloadLibrary()
    }

    /// Invoke only after the transport's complete-size/CRC and codec success.
    /// An additional AVFoundation check rejects an unreadable/empty artifact;
    /// this is not a replacement for the transport completion proof.
    func publishCompletedMP3(_ stagedMP3: URL, for identity: NativeRecordingIdentity, recorderHighlights: [Double]? = nil) async throws -> URL {
        guard let recording = recordingStore.recording(sessionID: identity.sessionID, serialNumber: identity.serialNumber),
              recording.status == .copying else { throw NativeLibraryError.noTransferAttempt }
        let asset = AVURLAsset(url: stagedMP3)
        guard stagedMP3.pathExtension.lowercased() == "mp3",
              try await asset.load(.isPlayable),
              !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw NativeLibraryError.invalidAudio
        }
        let duration = try await asset.load(.duration).seconds
        try AIAudioPolicy.validate(duration:duration)
        guard recordingStore.recording(sessionID: identity.sessionID, serialNumber: identity.serialNumber)?.status == .copying else {
            throw NativeLibraryError.noTransferAttempt
        }
        let directory = recordingStore.audioDirectory(serialNumber: identity.serialNumber)
        let destination = directory.appendingPathComponent("\(identity.sessionID).mp3")
        let publication = Task.detached(priority: .utility) {
            try NativeAudioPublication.copyExclusively(stagedMP3, to: destination)
        }
        let published = try await withTaskCancellationHandler(operation: {
            try await publication.value
        }, onCancel: { publication.cancel() })
        guard recordingStore.recording(sessionID: identity.sessionID, serialNumber: identity.serialNumber)?.status == .copying else {
            // A cancellation while the exclusive copy finishes leaves a
            // recoverable complete file but never reports a cancelled row ready.
            throw NativeLibraryError.noTransferAttempt
        }
        guard recordingStore.markLocal(sessionID: identity.sessionID, serialNumber: identity.serialNumber,
                                      outputPath: published.path, verifiedDuration: duration, recorderHighlightSeconds: recorderHighlights) else {
            // The complete file remains recoverable. Never report it as a
            // committed library row if metadata publication failed.
            throw NativeLibraryError.persistenceFailed
        }
        reloadLibrary()
        return published
    }

    func importAudio(_ source: URL) async throws -> NativeRecordingIdentity {
        try Task.checkCancellation()
        guard ["mp3", "m4a", "wav", "aiff", "aif", "caf", "ogg", "opus"].contains(source.pathExtension.lowercased()) else {
            throw NativeLibraryError.invalidAudio
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let hashTask = Task.detached(priority: .utility) { try NativeAudioPublication.digest(source) }
        let digest = try await withTaskCancellationHandler(operation: { try await hashTask.value }, onCancel: { hashTask.cancel() })
        let identity = NativeRecordingIdentity(serialNumber: "local-audio-" + digest, sessionID: 1)
        if let row = recordingStore.recording(sessionID: 1, serialNumber: identity.serialNumber), recordingStore.audioURL(for: row) != nil {
            try clearPermanentSuppressionForImport(identity)
            if deletedRecordings.contains(where: { $0.identity == identity }) { try restoreRecording(identity) }
            return identity
        }
        let ogg=["ogg","opus"].contains(source.pathExtension.lowercased())
        let folder=recordingStore.audioDirectory(serialNumber:identity.serialNumber)
        let destination=folder.appendingPathComponent("1."+(ogg ? "mp3":source.pathExtension.lowercased()))
        let copyTask=Task.detached(priority:.utility) { ()async throws->Double in
            let original=ogg ? folder.appendingPathComponent("original."+source.pathExtension.lowercased()):destination
            if FileManager.default.fileExists(atPath:original.path) {
                guard try NativeAudioPublication.digest(original)==digest else {throw NativeLibraryError.destinationExists}
            } else {
                _ = try NativeAudioPublication.copyExclusively(source,to:original)
                guard try NativeAudioPublication.digest(original)==digest else {throw NativeLibraryError.audioChanged}
            }
            try Task.checkCancellation()
            if ogg {
                #if canImport(NotePinAudio)
                // Decode to a new private file first. Existing output from an interrupted
                // import is retained and compared with a fresh complete conversion.
                let staging=folder.appendingPathComponent(".ogg-import-"+UUID().uuidString+".mp3")
                defer {try? FileManager.default.removeItem(at:staging)}
                _ = try NativeAudioConverter.convertImportedOgg(rawURL:original,outputURL:staging,maximumDuration:AIAudioPolicy.maximumDuration)
                if FileManager.default.fileExists(atPath:destination.path) {
                    guard try NativeAudioPublication.digest(destination)==NativeAudioPublication.digest(staging) else {throw NativeLibraryError.destinationExists}
                } else {_ = try NativeAudioPublication.copyExclusively(staging,to:destination)}
                #else
                throw NativeLibraryError.invalidAudio
                #endif
            }
            let asset=AVURLAsset(url:destination)
            guard try await asset.load(.isPlayable),!(try await asset.loadTracks(withMediaType:.audio)).isEmpty else {throw NativeLibraryError.invalidAudio}
            let duration=try await asset.load(.duration).seconds
            try AIAudioPolicy.validate(duration:duration);try Task.checkCancellation()
            return duration
        }
        let duration=try await withTaskCancellationHandler(operation:{try await copyTask.value},onCancel:{copyTask.cancel()})
        try Task.checkCancellation()
        let title = String(source.deletingPathExtension().lastPathComponent.prefix(200))
        guard recordingStore.commitImportedAudio(digest: digest, outputURL: destination, duration: duration, title: title) else {
            throw NativeLibraryError.persistenceFailed
        }
        try clearPermanentSuppressionForImport(identity)
        reloadLibrary()
        return identity
    }

    private func clearPermanentSuppressionForImport(_ identity: NativeRecordingIdentity) throws {
        guard purgedRecordings.contains(identity) else { return }
        let next = purgedRecordings.subtracting([identity])
        try JSONEncoder().encode(next).write(to: purgeURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: purgeURL.path)
        purgedRecordings = next
    }

    func localHistory(for identity: NativeRecordingIdentity) async throws -> [AIProcessingResult] {
        guard let recording = recordingStore.recording(sessionID: identity.sessionID, serialNumber: identity.serialNumber),
              recording.status != .copying, let audio = recordingStore.audioURL(for: recording) else {
            throw NativeLibraryError.audioUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            exporter.localSnapshot(recording: recording, audioURL: audio) { result in
                continuation.resume(with: result.map { $0.1.sorted { $0.request.createdAt > $1.request.createdAt } })
            }
        }
    }

    func legacyHistory(for identity: NativeRecordingIdentity) async throws -> VectaSavedAnalysisSnapshot {
        guard let recording = recordingStore.recording(sessionID: identity.sessionID, serialNumber: identity.serialNumber) else {
            throw NativeLibraryError.invalidRecording
        }
        return try await withCheckedThrowingContinuation { continuation in
            exporter.snapshot(recording: recording, audioURL: recordingStore.audioURL(for: recording)) {
                continuation.resume(with: $0)
            }
        }
    }

    /// Explicit analysis or the user's enabled post-sync automation. Selecting
    /// a format never calls this method; snapshots and prior results stay intact.
    func requestLocalAI(for identity: NativeRecordingIdentity, format: VectaSummaryInterpretation,
                        transcriptRequestID: UUID? = nil,summaryTemplate:AISummaryTemplate? = nil,automaticSettings:AIAutomaticSettings? = nil,visualEnabled:Bool? = nil) async throws -> UUID {
        guard let recording = recordingStore.recording(sessionID: identity.sessionID, serialNumber: identity.serialNumber),
              recording.status != .copying, let audio = recordingStore.audioURL(for: recording) else {
            throw NativeLibraryError.audioUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            exporter.requestLocalAI(recording: recording, audioURL: audio, interpretation: format,
                                    transcriptRequestID: transcriptRequestID,summaryTemplate:summaryTemplate,automaticSettings:automaticSettings,visualEnabled:visualEnabled) { continuation.resume(with: $0) }
        }
    }

    func cancelLocalAI(_ requestID: UUID) { exporter.cancelLocalAI(requestID) }

    func reloadFormats() {
        formats = formatStore.all
    }

    func createFormat(title: String, prompt: String) throws -> VectaSummaryInterpretation {
        defer { reloadFormats() }
        return try formatStore.create(title: title, prompt: prompt)
    }

    func updateFormat(_ format: VectaSummaryInterpretation, title: String, prompt: String) throws {
        defer { reloadFormats() }
        _ = try formatStore.update(id: format.id, title: title, prompt: prompt, expectedRevision: format.revision)
    }

    func deleteFormat(_ format: VectaSummaryInterpretation) throws {
        defer { reloadFormats() }
        _ = try formatStore.delete(id: format.id, expectedRevision: format.revision)
    }
}

enum NativeAudioPublication {
    static func digest(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeLibraryError.invalidAudio }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation(); hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Stream, hash, synchronize, then atomically publish without replacing an
    /// existing file. Only this operation's private temporary file is removed.
    static func copyExclusively(_ sourceURL: URL, to destination: URL) throws -> URL {
        guard sourceURL.isFileURL, destination.isFileURL else { throw NativeLibraryError.invalidAudio }
        let parent = destination.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw NativeLibraryError.persistenceFailed
        }
        let inputFD = open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard inputFD >= 0 else { throw NativeLibraryError.invalidAudio }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(inputFD, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_size > 0 else {
            throw NativeLibraryError.invalidAudio
        }
        let temporary = parent.appendingPathComponent(".native-publish-\(UUID().uuidString).tmp")
        let outputFD = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard outputFD >= 0 else { throw NativeLibraryError.persistenceFailed }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var count: Int64 = 0
        var sourceHash = SHA256()
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: data)
            sourceHash.update(data: data)
            count += Int64(data.count)
        }
        var after = stat()
        guard fstat(inputFD, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              count == before.st_size else { throw NativeLibraryError.audioChanged }
        try output.synchronize()
        try output.close()
        let copy = try FileHandle(forReadingFrom: temporary)
        defer { try? copy.close() }
        var copiedHash = SHA256()
        while let data = try copy.read(upToCount: 1_048_576), !data.isEmpty { copiedHash.update(data: data) }
        guard Data(sourceHash.finalize()) == Data(copiedHash.finalize()) else { throw NativeLibraryError.audioChanged }
        try Task.checkCancellation()
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST ? NativeLibraryError.destinationExists : NativeLibraryError.persistenceFailed
        }
        return destination.standardizedFileURL
    }
}

enum NativeLibraryError: LocalizedError {
    case invalidRecording, notOnRecorder, alreadyLocal, noTransferAttempt, audioUnavailable
    case invalidAudio, audioChanged, destinationExists, persistenceFailed
    var errorDescription: String? {
        switch self {
        case .invalidRecording: return VL.text("Некорректная запись в списке диктофона.")
        case .notOnRecorder: return VL.text("Запись отсутствует в текущем списке диктофона. Обновите подключение.")
        case .alreadyLocal: return VL.text("Полная запись уже сохранена на Mac.")
        case .noTransferAttempt: return VL.text("Для этой записи нет текущей попытки передачи.")
        case .audioUnavailable: return VL.text("Полная аудиозапись пока не сохранена на Mac.")
        case .invalidAudio: return VL.text("Не удалось открыть файл как аудиозапись поддерживаемого формата.")
        case .audioChanged: return VL.text("Аудиофайл изменился во время сохранения. Повторите передачу.")
        case .destinationExists: return VL.text("Файл с таким именем уже существует. Существующая запись сохранена.")
        case .persistenceFailed: return VL.text("Не удалось сохранить запись в библиотеку.")
        }
    }
}
