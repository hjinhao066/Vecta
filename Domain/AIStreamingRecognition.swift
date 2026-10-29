import Foundation
import CryptoKit

struct AIRecognitionWindow: Codable, Equatable {
    let index: Int
    let coreStart: Double
    let coreEnd: Double
    let start: Double
    let end: Double
    var duration: Double { end - start }
}
struct AIStreamingConfiguration: Codable, Equatable {
    var chunkSeconds: Double = 60
    var overlapSeconds: Double = 3
    var version: Int = 5
    var pauseAware: Bool = true
    func windows(duration: Double) throws -> [AIRecognitionWindow] {
        guard duration.isFinite, duration > 0, chunkSeconds.isFinite, (15...120).contains(chunkSeconds),
              overlapSeconds.isFinite, (0...10).contains(overlapSeconds), overlapSeconds < chunkSeconds / 2 else { throw AIProcessingError.invalidRequest }
        return (0..<Int(ceil(duration / chunkSeconds))).map { i in
            let start = Double(i) * chunkSeconds, end = min(duration, start + chunkSeconds)
            return AIRecognitionWindow(index: i, coreStart: start, coreEnd: end,
                start: max(0, start - overlapSeconds), end: min(duration, end + overlapSeconds))
        }
    }
}
struct AIRecognitionChunk: Codable, Equatable {
    let window: AIRecognitionWindow
    let segments: [AISpeechSegment]
    let inferenceSeconds: Double
    let promptTokens: Int
    let generatedTokens: Int
    let peakMLXBytes: Int
    var checksum: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    func validate() throws {
        guard window.duration > 0, inferenceSeconds.isFinite, inferenceSeconds >= 0,
              promptTokens >= 0, generatedTokens >= 0, peakMLXBytes >= 0,
              Set(segments.map(\.id)).count == segments.count else { throw AIProcessingError.invalidTranscript }
        for s in segments { try s.validate(duration: window.duration) }
    }
}

/// Atomic, checksummed chunks survive worker/application cancellation. The key
/// includes source digest, model revision and segmentation policy, not request ID.
final class AIRecognitionCheckpoint {
    struct Entry: Codable { let index: Int; let checksum: String }
    struct Manifest: Codable {
        let key: String
        let duration: Double
        let configuration: AIStreamingConfiguration
        var entries: [Entry]
        var failedIndex: Int?
        var errorCode: String?
    }
    let root: URL
    private(set) var manifest: Manifest
    init(parent: URL, audioDigest: String, modelRevision: String, duration: Double, configuration: AIStreamingConfiguration) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let policy = try encoder.encode(configuration)
        guard audioDigest.count == 64, audioDigest.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw AIProcessingError.invalidRequest }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else { throw AIProcessingError.invalidRequest }
        let key = SHA256.hash(data: Data((audioDigest + modelRevision).utf8) + policy).map { String(format: "%02x", $0) }.joined()
        root = parent.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw AIProcessingError.invalidRequest }
        let file = root.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: file.path) {
            try Self.validateFile(file)
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
            guard manifest.key == key, abs(manifest.duration - duration) < 0.01, manifest.configuration == configuration,
                  manifest.entries.map(\.index) == Array(0..<manifest.entries.count) else { throw AIProcessingError.invalidTranscript }
        } else {
            manifest = Manifest(key: key, duration: duration, configuration: configuration, entries: [])
            try saveManifest()
        }
    }
    func load(_ window: AIRecognitionWindow) throws -> AIRecognitionChunk? {
        guard let entry = manifest.entries.first(where: { $0.index == window.index }) else { return nil }
        let file = root.appendingPathComponent("chunk-\(window.index).json")
        try Self.validateFile(file)
        let chunk = try JSONDecoder().decode(AIRecognitionChunk.self, from: Data(contentsOf: file))
        try chunk.validate()
        guard chunk.window == window, chunk.checksum == entry.checksum else { throw AIProcessingError.invalidTranscript }
        return chunk
    }
    func save(_ chunk: AIRecognitionChunk) throws {
        try chunk.validate()
        guard chunk.window.index == manifest.entries.count else { throw AIProcessingError.invalidTranscript }
        let file = root.appendingPathComponent("chunk-\(chunk.window.index).json")
        try Self.write(chunk, to: file)
        manifest.entries.removeAll { $0.index == chunk.window.index }
        manifest.entries.append(Entry(index: chunk.window.index, checksum: chunk.checksum))
        manifest.failedIndex = nil; manifest.errorCode = nil
        try saveManifest()
    }
    func fail(index: Int, code: String) throws {
        manifest.failedIndex = index; manifest.errorCode = code; try saveManifest()
    }
    private func saveManifest() throws { try Self.write(manifest, to: root.appendingPathComponent("manifest.json")) }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func validateFile(_ url: URL) throws {
        let v = try url.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true, (v.fileSize ?? 0) < 32_000_000 else { throw AIProcessingError.invalidTranscript }
    }
}

/// Match labels only where both windows observe the same overlapping utterance.
/// Historical window assembler: no vocal fingerprint is available here. Unmatched voices stay explicitly
/// scoped to a fragment, rather than falsely claiming global speaker identity.
/// Only overlapping acoustic time with matching words can link labels. Unmatched
/// labels remain scoped to a fragment: no unsupported global identity is invented.
struct AITranscriptAssembler {
    private(set) var segments: [AISpeechSegment] = []
    private var priorOverlap: [AISpeechSegment] = []
    private var lastIndex = -1
    mutating func append(_ chunk: AIRecognitionChunk, overlap: Double = 3) throws {
        try chunk.validate()
        guard chunk.window.index == lastIndex + 1 else { throw AIProcessingError.invalidTranscript }
        let current = chunk.segments.map { s in
            AISpeechSegment(id: s.id, start: s.start + chunk.window.start, end: s.end + chunk.window.start, speaker: s.speaker, text: s.text)
        }
        var votes: [String: Set<String>] = [:]
        for s in current where s.start < chunk.window.coreStart + overlap {
            guard let voice = s.speaker else { continue }
            for p in priorOverlap where Self.intersects(p,s) {
                let a = Self.words(p.text), b = Self.words(s.text)
                if (a == b && !a.isEmpty) || Self.sharedBoundary(a,b) >= 3 {
                    if let oldVoice = p.speaker { votes[voice, default: []].insert(oldVoice) }
                }
            }
        }
        var mapping: [String:String] = [:]
        for (voice, matches) in votes where matches.count == 1 {
            let target = matches.first!
            if votes.filter({ $0.value.contains(target) }).count == 1 { mapping[voice] = target }
        }
        func label(_ speaker: String?) -> String? {
            speaker.map { mapping[$0] ?? "\($0) · chunk \(chunk.window.index + 1)" }
        }
        for s in current {
            // Preserve complete boundary-crossing utterances. Never discard an
            // entire phrase merely because its midpoint falls in another core.
            guard s.end > chunk.window.coreStart, s.start < chunk.window.coreEnd else { continue }
            var text = s.text
            var duplicate = false
            for p in segments.suffix(24) where Self.intersects(p,s) {
                let a = Self.words(p.text), b = Self.words(text)
                if a == b || (!b.isEmpty && Self.contains(a,b)) { duplicate = true; break }
                let count = Self.sharedBoundary(a,b)
                if count >= 2 {
                    // Keep original punctuation/words for the retained suffix.
                    let matches = Self.wordExpression.matches(in:text,range:NSRange(text.startIndex...,in:text))
                    if matches.count >= count, let range = Range(matches[count-1].range,in:text) {
                        text = String(text[range.upperBound...]).trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters))
                    }
                }
            }
            if !duplicate && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(AISpeechSegment(id:segments.count,start:s.start,end:s.end,speaker:label(s.speaker),text:text))
            }
        }
        priorOverlap = current.filter { $0.end > chunk.window.coreEnd - overlap }.map { s in
            AISpeechSegment(id:s.id,start:s.start,end:s.end,speaker:label(s.speaker),text:s.text)
        }
        lastIndex = chunk.window.index
    }
    var orderedSegments: [AISpeechSegment] {
        segments.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }.enumerated().map { i,s in
            AISpeechSegment(id:i,start:s.start,end:s.end,speaker:s.speaker,text:s.text)
        }
    }
    private static let wordExpression = try! NSRegularExpression(pattern:"[\\p{L}\\p{N}]+")
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    private static func intersects(_ a: AISpeechSegment,_ b: AISpeechSegment) -> Bool {
        min(a.end,b.end) > max(a.start,b.start)
    }
    private static func contains(_ a:[String],_ b:[String]) -> Bool {
        guard b.count <= a.count, !b.isEmpty else { return false }
        return (0...(a.count-b.count)).contains { Array(a[$0..<($0+b.count)]) == b }
    }
    private static func sharedBoundary(_ a:[String],_ b:[String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        for count in stride(from:min(a.count,b.count),through:1,by:-1) {
            if Array(a.suffix(count)) == Array(b.prefix(count)) { return count }
        }
        return 0
    }
}

/// Historical decoders can emit a complete timestamp/speaker interval with no spoken text on
/// a quiet window. The upstream parser returns this marker string as plain text.
/// Accept only fully structured empty intervals within the input window.
enum AIEmptySpeechOutput {
    static func isEmptyInterval(_ raw: String, duration: Double) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, duration.isFinite, duration > 0 else { return false }
        let pattern = #"\[(\d+(?:\.\d+)?)\]\[S\d+\]\s*\[(\d+(?:\.\d+)?)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return false }
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text),
                  text[cursor..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text),
                  let start = Double(text[a]), let end = Double(text[b]), start.isFinite, end.isFinite,
                  start >= 0, end >= start, end <= duration + 1 else { return false }
            cursor = range.upperBound
        }
        return text[cursor...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
