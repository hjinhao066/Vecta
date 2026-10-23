import Foundation
import Darwin

/// Separate local-only mailbox. Nothing here is a ChatGPT bridge manifest.
struct LocalAIFileStore {
    let root: URL
    func speakerAlignment(for result:AIProcessingResult) throws -> AISpeakerAlignment? {
        var current=result,visited=Set<UUID>()
        for _ in 0..<64 {
            guard visited.insert(current.request.id).inserted else {throw AIProcessingError.invalidRequest}
            let url=resultURL(current.request.id).appendingPathExtension("alignment.json")
            if let bytes=try? Data(contentsOf:url),let alignment=try? JSONDecoder().decode(AISpeakerAlignment.self,from:bytes),alignment.complete {return alignment}
            guard let source=current.request.transcriptRequestID else {return nil}
            guard let parent=try self.result(source),parent.request.audioSHA256==result.request.audioSHA256,
                  parent.request.audioFilename==result.request.audioFilename else {throw AIProcessingError.invalidRequest}
            current=parent
        }
        throw AIProcessingError.invalidRequest
    }
    private var local: URL { root.appendingPathComponent("LocalAI", isDirectory: true) }
    func prepare() throws {
        for directory in [local, local.appendingPathComponent("Requests"), local.appendingPathComponent("Results")] {
            if FileManager.default.fileExists(atPath: directory.path) {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw AIProcessingError.invalidRequest }
            } else {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        }
    }
    // Legacy provider preference is ignored: inference is local-only now.
    func provider() throws -> AIProviderID { .local }
    func setProvider(_ value: AIProviderID) throws {
        guard value == .local else { throw AIProcessingError.invalidRequest }
        try prepare(); try write(value, to: local.appendingPathComponent("provider.json"))
    }
    /// Retire execution, not data: request files, checkpoints and completed
    /// outputs are never rewritten. Reprocessing creates a distinct request.
    func recoverLegacyRequests() throws -> [UUID] {
        var changed=[UUID]()
        for request in try requests() where !request.selectedSummaryModel.isProductionModel {
            let existing=try result(request.id)
            guard existing?.stage != .completed, existing?.stage != .cancelled else {continue}
            var value=existing ?? AIProcessingResult(version:1,request:request,stage:.queued,
                transcript:nil,segments:[],summary:nil,error:nil,updatedAt:request.createdAt,
                duration:nil,recognitionSeconds:nil,summarySeconds:nil)
            let reason=AIProcessingError.retiredModel.localizedDescription
            guard value.stage.isActive || !(value.error ?? "").contains(reason) else {continue}
            value.stage=value.transcript == nil ? .failed:.summaryFailed
            value.error=(value.error.map {$0+"\n"} ?? "")+reason
            value.processingProgress=nil;value.updatedAt=Date()
            try save(value);changed.append(request.id)
        }
        return changed
    }
    func summaryModel() throws -> AISummaryModelID {
        let url = local.appendingPathComponent("summary-model.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .qwen4b }
        return try JSONDecoder().decode(AISummaryModelID.self, from: Data(contentsOf: url))
    }
    func setSummaryModel(_ value: AISummaryModelID) throws {
        try prepare(); try write(value, to: local.appendingPathComponent("summary-model.json"))
    }
    /// Recognition engine for new recordings. Absent file: Whisper (previous behaviour).
    func speechEngine() throws -> AISpeechEngineID {
        let url = local.appendingPathComponent("speech-engine.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .whisper }
        try validateSmallFile(url)
        return try JSONDecoder().decode(AISpeechEngineID.self, from: Data(contentsOf: url))
    }
    func setSpeechEngine(_ value: AISpeechEngineID) throws {
        try prepare(); try write(value, to: local.appendingPathComponent("speech-engine.json"))
    }
    func visualModel() throws -> AISummaryModelID {
        let url=local.appendingPathComponent("visual-model.json")
        guard FileManager.default.fileExists(atPath:url.path) else {return .qwen9b}
        try validateSmallFile(url)
        let value=try JSONDecoder().decode(AISummaryModelID.self,from:Data(contentsOf:url))
        guard value == .qwen4b || value == .qwen9b else {throw AIProcessingError.invalidRequest}
        return value
    }
    func setVisualModel(_ value:AISummaryModelID)throws {
        guard value == .qwen4b || value == .qwen9b else {throw AIProcessingError.invalidRequest}
        try prepare();try write(value,to:local.appendingPathComponent("visual-model.json"))
    }
    func automaticAISettings() throws -> AIAutomaticSettings {
        let url=local.appendingPathComponent("automatic-processing.json")
        guard FileManager.default.fileExists(atPath:url.path) else {return AIAutomaticSettings()}
        try validateSmallFile(url)
        let value=try JSONDecoder().decode(AIAutomaticSettings.self,from:Data(contentsOf:url));if value.model.isProductionModel {try value.validate()};return value
    }
    func setAutomaticAISettings(_ value:AIAutomaticSettings)throws {
        try value.validate();try prepare();try write(value,to:local.appendingPathComponent("automatic-processing.json"))
    }
    // Deliver UI commands to the owner of this library, rather than asking
    // LaunchServices to choose among installed development copies with one ID.
    func requestSettings(now: Date = Date()) throws {
        try prepare()
        try write(now, to: local.appendingPathComponent("settings-request.json"))
    }
    func consumeSettingsRequest(now: Date = Date()) throws -> Bool {
        let url = local.appendingPathComponent("settings-request.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) < 1_024 else { throw AIProcessingError.invalidRequest }
        let requestedAt = try JSONDecoder().decode(Date.self, from: Data(contentsOf: url))
        try FileManager.default.removeItem(at: url)
        let age = now.timeIntervalSince(requestedAt)
        return age >= -5 && age < 30
    }
    func settingsSnapshot() throws -> LocalAISettingsSnapshot? {
        let url = local.appendingPathComponent("settings-status.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try validateSmallFile(url)
        let snapshot = try JSONDecoder().decode(LocalAISettingsSnapshot.self, from: Data(contentsOf: url))
        try snapshot.validate()
        return snapshot
    }
    func saveSettingsSnapshot(_ value: LocalAISettingsSnapshot) throws {
        try value.validate(); try prepare()
        try write(value, to: local.appendingPathComponent("settings-status.json"))
    }
    func submitSettingsCommand(action: LocalAISettingsAction, modelID: String?, now: Date = Date()) throws {
        let command = LocalAISettingsCommand(id: UUID(), action: action, modelID: modelID, createdAt: now)
        try command.validate(); try prepare()
        let directory = try settingsCommandsDirectory()
        guard try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count < 16 else { throw AIProcessingError.busy }
        try write(command, to: directory.appendingPathComponent(command.id.uuidString.lowercased() + ".json"))
    }
    func consumeSettingsCommands(now: Date = Date()) throws -> [LocalAISettingsCommand] {
        let directory = local.appendingPathComponent("SettingsCommands", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        _ = try settingsCommandsDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count <= 16 else { throw AIProcessingError.busy }
        var commands: [LocalAISettingsCommand] = []
        for url in files {
            try validateSmallFile(url)
            let command = try JSONDecoder().decode(LocalAISettingsCommand.self, from: Data(contentsOf: url))
            try command.validate()
            guard url.lastPathComponent == command.id.uuidString.lowercased() + ".json" else { throw AIProcessingError.invalidRequest }
            // A UI action is taken once. Old install/delete actions never replay on relaunch.
            try FileManager.default.removeItem(at: url)
            let age = now.timeIntervalSince(command.createdAt)
            if age >= -5 && age < 30 { commands.append(command) }
        }
        return commands.sorted { $0.createdAt < $1.createdAt }
    }
    private func settingsCommandsDirectory() throws -> URL {
        let directory = local.appendingPathComponent("SettingsCommands", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw AIProcessingError.invalidRequest }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        return directory
    }
    private func validateSmallFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) < 32_000 else { throw AIProcessingError.invalidRequest }
    }
    func artifactOwnershipURL(_ id: UUID) -> URL { local.appendingPathComponent("ArtifactOwnership/" + id.uuidString.lowercased() + ".json") }
    func registerArtifact(_ artifact: URL, for id: UUID) throws {
        guard FileManager.default.fileExists(atPath: requestURL(id).path) else { return }
        let prefix = root.standardizedFileURL.path + "/"
        guard artifact.standardizedFileURL.path.hasPrefix(prefix) else { throw AIProcessingError.invalidRequest }
        let relative = String(artifact.standardizedFileURL.path.dropFirst(prefix.count))
        guard ["LocalAI/WorkerEvents/", "LocalAI/SummaryCheckpoints/", "LocalAI/Results/"].contains(where: relative.hasPrefix),
              !relative.split(separator: "/").contains("..") else { throw AIProcessingError.invalidRequest }
        let url = artifactOwnershipURL(id), folder = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) {
            guard try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                  try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AIProcessingError.invalidRequest }
        } else { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        var files: [String] = []
        if FileManager.default.fileExists(atPath: url.path) { try validateSmallFile(url); files = try JSONDecoder().decode([String].self, from: Data(contentsOf: url)) }
        if !files.contains(relative) { files.append(relative) }
        guard files.count <= 128 else { throw AIProcessingError.invalidRequest }
        try write(files, to: url)
    }
    func requestURL(_ id: UUID) -> URL { local.appendingPathComponent("Requests/\(id.uuidString.lowercased()).json") }
    func resultURL(_ id: UUID) -> URL { local.appendingPathComponent("Results/\(id.uuidString.lowercased()).json") }
    func cancelURL(_ id: UUID) -> URL { local.appendingPathComponent("Requests/\(id.uuidString.lowercased()).cancel") }
    func submit(_ request: AIProcessingRequest, cache:LocalAIReadCache?=nil) throws {
        guard request.selectedSummaryModel.isProductionModel else { throw AIProcessingError.retiredModel }
        try request.validate(); try prepare()
        guard request.provider == .local, !FileManager.default.fileExists(atPath: requestURL(request.id).path) else { throw AIProcessingError.invalidRequest }
        // A single local operation for an audio source, regardless of format.
        let reader=cache ?? LocalAIReadCache()
        let previousRequests=try reader.requests(root:root)
        var queued=[AIProcessingRequest]()
        for previous in previousRequests {
            let stage=try reader.stage(previous,root:root)
            if stage==nil || stage?.isActive==true {queued.append(previous)}
        }
        guard queued.count<3,!queued.contains(where:{$0.audioSHA256==request.audioSHA256}) else {throw AIProcessingError.busy}
        try save(AIProcessingResult(version: 1, request: request, stage: .queued, transcript: nil, segments: [], summary: nil,
            error: nil, updatedAt: Date(), duration: nil, recognitionSeconds: nil, summarySeconds: nil))
        try write(request, to: requestURL(request.id))
    }
    func requests() throws -> [AIProcessingRequest] {
        let directory = local.appendingPathComponent("Requests")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) < 100_000 else { throw AIProcessingError.invalidRequest }
                let request = try JSONDecoder().decode(AIProcessingRequest.self, from: Data(contentsOf: url))
                try request.validate()
                guard request.provider == .local, url.lastPathComponent == requestURL(request.id).lastPathComponent else { throw AIProcessingError.invalidRequest }
                return request
            }.sorted { $0.createdAt < $1.createdAt }
    }
    func result(_ id: UUID) throws -> AIProcessingResult? {
        let url = resultURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) < 32_000_000 else { throw AIProcessingError.invalidRequest }
        let result = try JSONDecoder().decode(AIProcessingResult.self, from: Data(contentsOf: url))
        try result.validate()
        guard result.request.id == id, result.request.provider == .local else { throw AIProcessingError.invalidRequest }
        return result
    }
    func save(_ result: AIProcessingResult) throws {
        try result.validate(); try prepare()
        try write(result, to: resultURL(result.request.id))
    }
    func cancel(_ id: UUID) throws {
        try prepare()
        try Data().write(to: cancelURL(id), options: .atomic)
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Metadata checks happen only on utility actors, never from a SwiftUI body.
enum AIFileRevision {
    static func stamp(_ url:URL) -> String {
        // Foundation may return no resource identifier, and URL metadata can be
        // cached. lstat gives fresh inode + nanosecond change times for replacements.
        var value=stat()
        guard lstat(url.path,&value)==0,(value.st_mode & mode_t(S_IFMT))==mode_t(S_IFREG) else{return "missing"}
        return "\(value.st_dev)|\(value.st_ino)|\(value.st_size)|\(value.st_mtimespec.tv_sec).\(value.st_mtimespec.tv_nsec)|\(value.st_ctimespec.tv_sec).\(value.st_ctimespec.tv_nsec)"
    }
}
/// Confined to its owning actor or exporter serial queue.
final class LocalAIReadCache {
    private var manifests:[String:(String,AIProcessingRequest)]=[:]
    private var results:[String:(String,AIProcessingResult)]=[:]
    private var order=[String]()
    private var stages:[String:(String,AIProcessingStage)]=[:]
    private var costs:[String:Int]=[:]
    private var bytes=0
    private let byteLimit=24*1024*1024
    func requests(root:URL) throws -> [AIProcessingRequest] {
        let store=LocalAIFileStore(root:root),dir=root.appendingPathComponent("LocalAI/Requests")
        guard FileManager.default.fileExists(atPath:dir.path) else{return []}
        let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}
        var values=[AIProcessingRequest](),live=Set<String>()
        for url in files {
            let key=url.path,stamp=AIFileRevision.stamp(url);live.insert(key)
            if let old=manifests[key],old.0==stamp {values.append(old.1);continue}
            let attrs=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,(attrs.fileSize ?? 0)<100000 else{throw AIProcessingError.invalidRequest}
            let request=try JSONDecoder().decode(AIProcessingRequest.self,from:Data(contentsOf:url));try request.validate()
            guard request.provider == .local,url.lastPathComponent==store.requestURL(request.id).lastPathComponent else{throw AIProcessingError.invalidRequest}
            manifests[key]=(stamp,request);values.append(request)
        }
        manifests=manifests.filter{live.contains($0.key)}
        return values.sorted{$0.createdAt<$1.createdAt}
    }
    func result(_ id:UUID,root:URL) throws -> AIProcessingResult? {
        let store=LocalAIFileStore(root:root),url=store.resultURL(id),key=url.path,stamp=AIFileRevision.stamp(url)
        if let old=results[key],old.0==stamp {order.removeAll{$0==key};order.append(key);return old.1}
        guard let value=try store.result(id) else{return nil}
        if results.removeValue(forKey:key) != nil {bytes-=costs.removeValue(forKey:key) ?? 0}
        order.removeAll{$0==key};let size=max(16384,((try? url.resourceValues(forKeys:[.fileSizeKey]))?.fileSize ?? 0)*4)
        if size<=byteLimit {
            while bytes+size>byteLimit,!order.isEmpty {let oldest=order.removeFirst();if results.removeValue(forKey:oldest) != nil {bytes-=costs.removeValue(forKey:oldest) ?? 0}}
            results[key]=(stamp,value);costs[key]=size;order.append(key);bytes+=size
        }
        return value
    }
    func stage(_ request:AIProcessingRequest,root:URL)throws->AIProcessingStage? {
        struct State:Decodable {let stage:AIProcessingStage;let request:AIProcessingRequest;let version:Int}
        let url=LocalAIFileStore(root:root).resultURL(request.id)
        guard FileManager.default.fileExists(atPath:url.path) else{return nil}
        let key=url.path,stamp=AIFileRevision.stamp(url)
        if let cached=stages[key],cached.0==stamp {return cached.1}
        let flags=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard flags.isRegularFile==true,flags.isSymbolicLink != true,(flags.fileSize ?? 0)<32000000 else{throw AIProcessingError.invalidRequest}
        let state=try JSONDecoder().decode(State.self,from:Data(contentsOf:url));try state.request.validate()
        guard state.version==1,state.request==request else{throw AIProcessingError.invalidRequest}
        stages[key]=(stamp,state.stage);return state.stage
    }
    func nextRequest(root:URL) throws -> AIProcessingRequest? {
        for request in try requests(root:root) {let value=try stage(request,root:root);if value==nil || value == .queued {return request}}
        return nil
    }

}

/// A single revision per channel, including failed decodes. Reads are bounded before
/// allocation and checked again afterwards, so atomic replacements never cache a
/// payload under the wrong revision. Confined to the mailbox actor (or test queue).
struct AIRevisionFileCache<Value> {
    private var key: String?
    private var revision: String?
    private var cached: Value?
    mutating func invalidate() { key=nil;revision=nil;cached=nil }
    mutating func read(_ url:URL?,limit:Int,decode:(Data)throws->Value) -> Value? {
        guard let url else {invalidate();return nil}
        let stamp=AIFileRevision.stamp(url)
        if key==url.path,revision==stamp {return cached}
        invalidate();key=url.path;revision=stamp
        guard stamp != "missing",let flags=try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]),
              flags.isRegularFile==true,flags.isSymbolicLink != true,let size=flags.fileSize,size>=0,size<=limit,
              let handle=try? FileHandle(forReadingFrom:url) else{return nil}
        defer {try? handle.close()}
        guard let bytes=try? handle.read(upToCount:limit+1),bytes.count<=limit,
              AIFileRevision.stamp(url)==stamp else {invalidate();return nil}
        let value=try? decode(bytes)
        guard AIFileRevision.stamp(url)==stamp else {invalidate();return nil}
        cached=value;return value
    }
}
struct AIWorkerFileSnapshot {
    let revision:String
    let event:AIWorkerEvent
    let semanticData:Data?
}
struct AILibraryEventSnapshot {
    let requestID:String
    let phase:String?
    let draft:String?
}
struct AIProgressFiles {
    let result:AIProcessingResult?
    let worker:AIWorkerFileSnapshot?
    let checkpoint:AISummaryProgress?
}
struct AIWorkerPollIdentity:Equatable {
    let requestID:UUID?
    let visualOnlyID:UUID?
    let eventURL:URL?
    let checkpointURL:URL?
    func permitsPublication(current:Self,cancelled:Bool,stopped:Bool)->Bool {
        !cancelled && !stopped && self==current
    }
}
/// Timestamp-only polls must not invalidate every observer. Keep all live units,
/// phases and ETA in this comparison, even when fraction itself is unchanged.
enum AIProgressPublication {
    static func changed(_ previous:AIWorkProgress?,_ next:AIWorkProgress)->Bool {
        guard let previous else{return true}
        return previous.stage != next.stage || previous.fraction != next.fraction ||
            previous.stageFraction != next.stageFraction || previous.generatedTokens != next.generatedTokens ||
            previous.remainingSeconds != next.remainingSeconds || previous.weightedEstimate != next.weightedEstimate ||
            previous.workerPhase != next.workerPhase || previous.workerCompleted != next.workerCompleted || previous.workerTotal != next.workerTotal
    }
}

actor LocalAIMailbox {
    private let cache=LocalAIReadCache()
    private var workerCache=AIRevisionFileCache<AIWorkerFileSnapshot>()
    private var checkpointCache=AIRevisionFileCache<AISummaryProgress>()
    private var libraryCache=AIRevisionFileCache<AILibraryEventSnapshot>()
    private var measurementRevision=0
    // Compiled once, on the utility actor, not for every growing answer draft.
    private var libraryTextRegex:NSRegularExpression?
    func requests(root:URL)throws->[AIProcessingRequest] {try cache.requests(root:root)}
    func result(_ id:UUID,root:URL)throws->AIProcessingResult? {try cache.result(id,root:root)}
    func nextRequest(root:URL)throws->AIProcessingRequest? {try cache.nextRequest(root:root)}
    func progressFiles(_ id:UUID,root:URL,eventURL:URL?,checkpointURL:URL?)throws->AIProgressFiles {
        let result=try cache.result(id,root:root)
        let worker=workerCache.read(eventURL,limit:2_000_000) {bytes in
            guard var object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else {throw AIProcessingError.invalidSummary}
            let semantic=object.removeValue(forKey:"semanticDraft").flatMap {raw -> Data? in
                guard JSONSerialization.isValidJSONObject(raw) else{return nil}
                return try? JSONSerialization.data(withJSONObject:raw)
            }
            let event=try JSONDecoder().decode(AIWorkerEvent.self,from:JSONSerialization.data(withJSONObject:object))
            guard (event.draftText?.utf8.count ?? 0)<=1_000_000 else {throw AIProcessingError.invalidSummary}
            return AIWorkerFileSnapshot(revision:eventURL.map(AIFileRevision.stamp) ?? "missing",event:event,semanticData:semantic)
        }
        let checkpoint=checkpointCache.read(checkpointURL,limit:2_000_000) {try JSONDecoder().decode(AISummaryProgress.self,from:$0)}
        return AIProgressFiles(result:result,worker:worker,checkpoint:checkpoint)
    }
    func workerRevisionMatches(_ url:URL,revision:String)->Bool {AIFileRevision.stamp(url)==revision}
    func libraryEvent(_ url:URL)->AILibraryEventSnapshot? {
        if libraryTextRegex==nil {libraryTextRegex=try? NSRegularExpression(pattern:"\"text\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\")")}
        let regex=libraryTextRegex
        return libraryCache.read(url,limit:2_000_000) {bytes in
            guard let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],let id=object["requestID"] as? String else {throw AIProcessingError.invalidSummary}
            var draft:String?
            if let raw=object["draftText"] as? String {
                guard raw.utf8.count<=1_000_000 else {throw AIProcessingError.invalidSummary}
                let ns=raw as NSString
                let parts=regex?.matches(in:raw,range:NSRange(location:0,length:ns.length)).compactMap {match -> String? in
                    let encoded=ns.substring(with:match.range(at:1))
                    return (try? JSONSerialization.jsonObject(with:Data(encoded.utf8),options:.fragmentsAllowed)) as? String
                } ?? []
                if !parts.isEmpty {draft=parts.joined(separator:"\n\n")}
            }
            return AILibraryEventSnapshot(requestID:id,phase:object["phase"] as? String,draft:draft)
        }
    }
    func saveMeasurements(_ values:[AIStageMeasurement],to url:URL,revision:Int) {
        guard revision>measurementRevision else{return};measurementRevision=revision
        if let data=try? JSONEncoder().encode(values) {
            try? data.write(to:url,options:.atomic)
            try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
    }
}
