import Foundation

/// IDs in this contract identify a version of a recording, not a local segment number.
struct AILibrarySource: Codable, Identifiable, Equatable {
    var id: String
    var recordingKey: String
    var requestID: UUID?
    var transcriptID: UUID?
    var revision: String
    var title: String
    var date: Date
    var text: String
    var segmentIDs: [Int]
    var start: Double?
    var end: Double?
}
struct AILibraryParagraph: Codable, Equatable { var text: String; var sourceIDs: [String] }
struct AILibraryAnswer: Codable, Equatable {
    var schemaVersion: Int
    var status: String
    var paragraphs: [AILibraryParagraph]
    func validated(sources: [AILibrarySource]) throws -> AILibraryAnswer {
        guard schemaVersion == 1, ["answered", "insufficient_evidence"].contains(status), paragraphs.count <= 12 else {throw AIProcessingError.invalidSummary}
        let ids=Set(sources.map(\.id))
        guard ids.count == sources.count else {throw AIProcessingError.invalidRequest}
        if status == "insufficient_evidence" {return AILibraryAnswer(schemaVersion:1,status:status,paragraphs:[])}
        guard !paragraphs.isEmpty else {throw AIProcessingError.invalidSummary}
        for p in paragraphs {
            guard !p.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,p.text.count <= 3000,
                  !p.sourceIDs.isEmpty,p.sourceIDs.count <= 12,Set(p.sourceIDs).isSubset(of:ids) else {throw AIProcessingError.invalidSummary}
        }
        return self
    }
    static func decode(_ data:Data,sources:[AILibrarySource]) throws -> AILibraryAnswer {
        guard data.count < 128_000 else {throw AIProcessingError.invalidSummary}
        // Accept a fenced JSON envelope, never recover unknown references.
        guard let s=String(data:data,encoding:.utf8),let first=s.firstIndex(of:"{"),let last=s.lastIndex(of:"}"),first <= last else {throw AIProcessingError.invalidSummary}
        return try JSONDecoder().decode(Self.self,from:Data(s[first...last].utf8)).validated(sources:sources)
    }
}
struct AILibraryDocument {
    var key:String
    var revision:String
    var sources:[AILibrarySource]
}
struct AILibraryIndexStatus {var recordings:Int;var chunks:Int;var semanticChunks:Int}

/// Shared by the UI and race tests. Invalidation precedes cancelling asynchronous work.
struct AILibrarySearchSession {
    private(set) var generation=UUID()
    private(set) var submittedQuestion=""
    mutating func submit(_ text:String) -> UUID {generation=UUID();submittedQuestion=text;return generation}
    mutating func clear() {generation=UUID();submittedQuestion=""}
    func accepts(_ id:UUID) -> Bool {generation==id && !submittedQuestion.isEmpty}
}
