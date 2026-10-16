import CryptoKit
import Foundation

/// Deletes only files with an exact recording/request identity in an authorized
/// processing folder. Never follows links, traverses models or calls transport.
/// Requests are deleted last so an interrupted purge can be planned again.
enum NativeRecordingPurge {
    static func processingFiles(root: URL, filenames: Set<String>) throws {
        let manager = FileManager.default
        let store = LocalAIFileStore(root: root)
        let allRequests = try store.requests()
        let requests = allRequests.filter { filenames.contains($0.audioFilename) }
        let remaining = allRequests.filter { !filenames.contains($0.audioFilename) }
        let conversationStore = AIConversationStore(root: root)
        let pendingEdit = root.appendingPathComponent("ConversationV2/pending-voice-edit.json")
        if manager.fileExists(atPath: pendingEdit.path) {
            try validate(pendingEdit, under: root); _ = try conversationStore.voices()
        }
        for request in requests {
            let result = try store.result(request.id)
            guard result != nil, result?.stage.isActive != true else { throw AIProcessingError.busy }
        }
        var files = Set<URL>(), manifests = Set<URL>(), keys = Set<String>()
        func children(_ relative: String) throws -> [URL] {
            let folder = root.appendingPathComponent(relative, isDirectory: true)
            guard manager.fileExists(atPath: folder.path) else { return [] }
            try validate(folder, under: root, directory: true)
            return try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        }
        let inbox = try children("Inbox")
        for filename in filenames {
            guard URL(fileURLWithPath: filename).lastPathComponent == filename else { throw AIProcessingError.invalidRequest }
            let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            for file in inbox where file.lastPathComponent == filename || file.lastPathComponent == stem + ".request.json" ||
                (file.lastPathComponent.hasPrefix(stem + ".") && file.lastPathComponent.hasSuffix(".request.json")) {
                files.insert(file)
            }
        }
        func registeredArtifacts(_ request: AIProcessingRequest) throws -> [URL] {
            let file = store.artifactOwnershipURL(request.id)
            guard manager.fileExists(atPath: file.path) else { return [] }
            try validate(file, under: root)
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 65_536 else { throw AIProcessingError.invalidRequest }
            let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: file))
            guard paths.count <= 128 else { throw AIProcessingError.invalidRequest }
            return try paths.map { path in
                guard ["LocalAI/WorkerEvents/", "LocalAI/SummaryCheckpoints/", "LocalAI/Results/"].contains(where: path.hasPrefix),
                      !path.split(separator: "/").contains(".."), !path.hasPrefix("/") else { throw AIProcessingError.invalidRequest }
                return root.appendingPathComponent(path).standardizedFileURL
            }
        }
        var retainedArtifacts = Set(remaining.map { $0.speechCheckpointURL(for: store.resultURL($0.id)) })
        for request in remaining { retainedArtifacts.formUnion(try registeredArtifacts(request)) }
        for request in requests {
            let owned = try registeredArtifacts(request) + [request.speechCheckpointURL(for: store.resultURL(request.id))]
            files.formUnion(owned.filter { !retainedArtifacts.contains($0) })
            manifests.insert(store.artifactOwnershipURL(request.id))
        }
        let results = try children("LocalAI/Results")
        let requestFiles = try children("LocalAI/Requests")
        for request in requests {
            let id = request.id.uuidString.lowercased()
            files.formUnion(results.filter { $0.lastPathComponent.hasPrefix(id + ".") })
            manifests.formUnion(requestFiles.filter { $0.lastPathComponent.hasPrefix(id + ".") })
            let key = SHA256.hash(data: Data((request.audioSHA256 + (request.transcriptRequestID ?? request.id).uuidString).utf8)).map { String(format: "%02x", $0) }.joined()
            keys.insert(key)
            files.insert(root.appendingPathComponent("ConversationV2/" + key + ".json"))
            files.insert(root.appendingPathComponent("LocalAI/AssistantV1/" + key + ".json"))
        }
        for file in try children("Results") where file.pathExtension == "json" {
            try validate(file, under: root)
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 64 * 1024 else { continue }
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                  let filename = object["filename"] as? String, filenames.contains(filename) else { continue }
            files.insert(file)
            if let id = object["id"] as? String, id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }),
               file.lastPathComponent == id + ".json", object["response_filename"] as? String == id + ".md" {
                files.insert(file.deletingLastPathComponent().appendingPathComponent(id + ".md"))
            }
        }
        let existing = files.union(manifests).filter { manager.fileExists(atPath: $0.path) }
        for file in existing { try validate(file, under: root) }
        // Shared voice profiles and user templates survive; only references
        // belonging to this recording are removed from their additive overlays.
        let voicesURL = root.appendingPathComponent("ConversationV2/voices.json")
        if manager.fileExists(atPath: voicesURL.path) {
            try validate(voicesURL, under: root)
            let conversations = AIConversationStore(root: root)
            var voices = try conversations.voices()
            let ids = Set(requests.map(\.recordingID))
            for index in voices.profiles.indices {
                voices.profiles[index].samples.removeAll { keys.contains($0.recordingKey) || $0.recordingID.map(ids.contains) == true }
            }
            try conversations.save(voices)
        }
        let workspace = AIWorkspaceStore(root: root)
        if manager.fileExists(atPath: workspace.url.path) {
            try validate(workspace.url, under: root)
            var value = try workspace.load()
            let ids = Set(requests.map(\.id))
            value.tasks?.removeAll { ids.contains($0.requestID) }
            try workspace.save(value)
        }
        for file in files.sorted(by: { $0.path < $1.path }) where manager.fileExists(atPath: file.path) {
            try validate(file, under: root); try manager.removeItem(at: file)
        }
        for file in manifests where manager.fileExists(atPath: file.path) {
            try validate(file, under: root); try manager.removeItem(at: file)
        }
    }
    static func validate(_ url: URL, under root: URL, directory: Bool = false) throws {
        let root = root.standardizedFileURL, url = url.standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw AIProcessingError.invalidRequest }
        var parent = root
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw AIProcessingError.invalidRequest }
        let parts = url.path.dropFirst(root.path.count + 1).split(separator: "/")
        for part in parts.dropLast() {
            parent.appendPathComponent(String(part))
            let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw AIProcessingError.invalidRequest }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, directory ? values.isDirectory == true : values.isRegularFile == true else { throw AIProcessingError.invalidRequest }
    }
}
