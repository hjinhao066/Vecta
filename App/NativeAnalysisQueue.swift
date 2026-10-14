import Foundation
import CryptoKit

enum NativePostSyncPolicy {
    static func format(in formats:[VectaSummaryInterpretation])->VectaSummaryInterpretation {
        formats.first {$0.id == "detailed"} ?? .detailed
    }
    static func targets(manual: Bool, automaticSummary: Bool, local: [NativeRecordingIdentity], downloaded: [NativeRecordingIdentity]) -> [NativeRecordingIdentity] {
        (manual || automaticSummary) ? downloaded : []
    }
}

enum NativeAnalysisDecision: Equatable {
    case complete, waiting, full, summaryOnly(UUID)
}

enum NativeAnalysisPolicy {
    static func decision(history: [AIProcessingResult], legacyTranscript: String?, legacySummary: Bool) -> NativeAnalysisDecision {
        let hasTranscript = history.contains { !($0.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !(legacyTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSummary = legacySummary || history.contains { !($0.summary?.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if hasTranscript && hasSummary { return .complete }
        if history.contains(where: { $0.stage.isActive }) { return .waiting }
        if let source = history.first(where: { !($0.transcript ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) {
            return .summaryOnly(source.request.id)
        }
        return .full
    }
}

/// Durable serial queue. It submits one operation to the existing AI mailbox
/// at a time, and remembers in-flight IDs across application restarts.
final class NativeAnalysisQueue {
    struct Job: Codable, Equatable {
        let identity: NativeRecordingIdentity
        var requestID: UUID?
        var settings:AIAutomaticSettings? = nil
        var batchTotal:Int? = nil
        var completedBefore:Int? = nil
        var failedBefore:Int? = nil
    }
    private let url: URL
    private(set) var jobs: [Job]
    private struct LegacyClaim: Codable {
        let version: Int
        let destination: String
        let snapshot: String
        let complete: Bool
    }
    static func scopedURL(processingRoot: URL) -> URL {
        processingRoot.appendingPathComponent("LocalAI/native-analysis-queue.json")
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private var destinationKey: String { Self.digest(Data(url.resolvingSymlinksInPath().standardizedFileURL.path.utf8)) }
    private static func readRegular(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) < 2_000_000 else { throw AIProcessingError.invalidRequest }
        return try Data(contentsOf: url)
    }
    /// Historical global work remains untouched. Recovery is an explicit action,
    /// never an implicit import into whichever library happens to be opened.
    func hasUnclaimedLegacySnapshot(at source: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        let inherited = try NativeAnalysisQueue(url: source)
        guard !inherited.jobs.isEmpty else { return false }
        let marker = source.appendingPathExtension("restored")
        guard FileManager.default.fileExists(atPath: marker.path) else { return true }
        let claim = try JSONDecoder().decode(LegacyClaim.self, from: Self.readRegular(marker))
        guard claim.version == 1 else { throw AIProcessingError.invalidRequest }
        let snapshot = Self.digest(try Self.readRegular(source))
        if claim.snapshot != snapshot { return claim.complete }
        return !claim.complete && claim.destination == destinationKey
    }
    func restoreLegacySnapshot(at source: URL, expected: [Job]) throws {
        guard source.standardizedFileURL != url.standardizedFileURL else { throw AIProcessingError.invalidRequest }
        let bytes = try Self.readRegular(source)
        let inherited = try NativeAnalysisQueue(url: source)
        guard inherited.jobs == expected, !expected.isEmpty, jobs.isEmpty || jobs == expected else { throw AIProcessingError.invalidRequest }
        let marker = source.appendingPathExtension("restored")
        let snapshot = Self.digest(bytes)
        if FileManager.default.fileExists(atPath: marker.path) {
            let previous = try JSONDecoder().decode(LegacyClaim.self, from: Self.readRegular(marker))
            guard previous.version == 1 else { throw AIProcessingError.invalidRequest }
            if previous.snapshot == snapshot {
                guard !previous.complete, previous.destination == destinationKey else { throw AIProcessingError.invalidRequest }
            } else {
                guard previous.complete else { throw AIProcessingError.invalidRequest }
                let backup = marker.appendingPathExtension(UUID().uuidString + ".backup")
                try FileManager.default.copyItem(at: marker, to: backup)
            }
        }
        guard try Self.readRegular(source) == bytes else { throw AIProcessingError.invalidRequest }
        let prepared = LegacyClaim(version: 1, destination: destinationKey, snapshot: snapshot, complete: false)
        try JSONEncoder().encode(prepared).write(to: marker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        try save(expected)
        let committed = LegacyClaim(version: 1, destination: destinationKey, snapshot: snapshot, complete: true)
        try JSONEncoder().encode(committed).write(to: marker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) < 2_000_000 else { throw AIProcessingError.invalidRequest }
            jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: url))
            guard jobs.count <= 5000, Set(jobs.map(\.identity)).count == jobs.count,
                  jobs.allSatisfy({ $0.identity.sessionID > 0 && VectaDeviceModel(serialNumber: $0.identity.serialNumber) != nil })
            else { throw AIProcessingError.invalidRequest }
            for job in jobs {
                try job.settings?.validate()
                let completed=job.completedBefore ?? 0,failed=job.failedBefore ?? 0,total=job.batchTotal ?? jobs.count
                guard completed>=0,failed>=0,failed<=completed,total>=completed+jobs.count,total<=100000 else {throw AIProcessingError.invalidRequest}
            }
        } else { jobs = [] }
    }
    func append(_ identities: [NativeRecordingIdentity],settings:AIAutomaticSettings? = nil) throws {
        try settings?.validate()
        var next = jobs
        for identity in identities where !next.contains(where: { $0.identity == identity }) {
            guard identity.sessionID > 0, VectaDeviceModel(serialNumber: identity.serialNumber) != nil, next.count < 5000 else { throw AIProcessingError.invalidRequest }
            next.append(Job(identity: identity, requestID: nil,settings:settings))
        }
        let added=next.count-jobs.count
        if added>0 {
            let completed=jobs.first?.completedBefore ?? 0,failed=jobs.first?.failedBefore ?? 0
            let total=(jobs.first?.batchTotal ?? jobs.count)+added
            for index in next.indices {next[index].batchTotal=total;next[index].completedBefore=completed;next[index].failedBefore=failed}
        }
        try save(next)
    }
    func attach(_ id: UUID, to identity: NativeRecordingIdentity) throws {
        guard let index = jobs.firstIndex(where: { $0.identity == identity }) else { throw AIProcessingError.invalidRequest }
        var next = jobs; next[index].requestID = id; try save(next)
    }
    func remove(_ identity: NativeRecordingIdentity,failed:Bool=false) throws {
        guard jobs.contains(where:{$0.identity==identity}) else {return}
        var next=jobs.filter {$0.identity != identity}
        let total=jobs.first?.batchTotal ?? jobs.count
        for index in next.indices {next[index].batchTotal=total;next[index].completedBefore=(jobs.first?.completedBefore ?? 0)+1;next[index].failedBefore=(jobs.first?.failedBefore ?? 0)+(failed ? 1:0)}
        try save(next)
    }
    private func save(_ next: [Job]) throws {
        guard next.count <= 5000, Set(next.map(\.identity)).count == next.count else { throw AIProcessingError.invalidRequest }
        for job in next {
            try job.settings?.validate()
            let completed=job.completedBefore ?? 0,failed=job.failedBefore ?? 0,total=job.batchTotal ?? next.count
            guard job.identity.sessionID > 0, VectaDeviceModel(serialNumber: job.identity.serialNumber) != nil,
                  completed>=0,failed>=0,failed<=completed,total>=completed+next.count,total<=100000 else { throw AIProcessingError.invalidRequest }
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parent.isDirectory == true, parent.isSymbolicLink != true else { throw AIProcessingError.invalidRequest }
        if FileManager.default.fileExists(atPath: url.path) { _ = try Self.readRegular(url) }
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        jobs = next
    }
}
