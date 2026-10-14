import Foundation
import CryptoKit

/// Immutable expressions are reusable across saved paragraphs and UI projections.
/// Bound retained patterns; speaker names from previous libraries must not grow a cache forever.
final class AISpeakerReferencePatterns: @unchecked Sendable {
    static let shared=AISpeakerReferencePatterns()
    private struct Key:Hashable {let pattern:String;let options:UInt}
    private let lock=NSLock()
    private var values:[Key:(NSRegularExpression,UInt64)]=[:]
    private var clock:UInt64=0
    var retainedCount:Int {lock.lock();defer {lock.unlock()};return values.count}
    func expression(_ pattern:String,options:NSRegularExpression.Options=[])->NSRegularExpression? {
        let key=Key(pattern:pattern,options:options.rawValue)
        lock.lock();clock &+= 1
        if let value=values[key] {values[key]=(value.0,clock);lock.unlock();return value.0}
        lock.unlock()
        guard let expression=try? NSRegularExpression(pattern:pattern,options:options) else{return nil}
        lock.lock();defer {lock.unlock()};clock &+= 1
        if values.count>=256,values[key]==nil,let oldest=values.min(by:{$0.value.1<$1.value.1})?.key {values[oldest]=nil}
        values[key]=(expression,clock)
        return expression
    }
}

/// Admission policy, shared by import, host and speech worker. Historical results
/// remain readable; this limit applies to new audio processing, not decoding stores.
enum AIAudioPolicy {
    static let maximumDuration: Double = 21_600
    static func validate(duration: Double) throws {
        guard duration.isFinite, duration > 0, duration <= maximumDuration else { throw AIProcessingError.durationLimit }
    }
    /// Conservative reservation: PCM, SDK copies/chunks, quadratic AHC distances,
    /// embeddings and model overhead. This is an admission estimate, not a measured peak.
    static func diarizationReservation(duration: Double) -> UInt64 {
        guard duration.isFinite, duration > 0, duration <= maximumDuration else { return UInt64.max }
        // Pinned W8A16 segmenter metadata: 30s waveform, 21 sliding windows,
        // 10s/window, 1s stride, at most 3 speakers/window. SDK full redundancy
        // advances outer chunks by 21s. Reserve the dense (all voices active) case.
        let chunks: Double = max(0,ceil((duration-30)/21))+1
        let embeddings: Double = chunks * 21 * 3
        let pcmBytes: Double = duration * 16_000 * 4 * 6
        let distanceBytes: Double = embeddings * max(0,embeddings-1) * 2
        let modelBytes: Double = 2 * 1_073_741_824
        return UInt64(ceil(pcmBytes + distanceBytes + modelBytes))
    }
}

enum AIProviderID: String, Codable, CaseIterable {
    case local = "local"
    var title: String { VL.text("Локально на Mac") }
}

enum AISummaryModelID: String, Codable, CaseIterable {
    case qwen, qwen4b, qwen9b, qwen06b
    static var allCases: [Self] { [.qwen4b, .qwen9b] }
    var isProductionModel: Bool { self == .qwen4b || self == .qwen9b }
    var title: String { self == .qwen06b ? VL.text("Удалённая модель · архив") : self == .qwen9b ? VL.text("Качественная") : self == .qwen4b ? VL.text("Быстрая") : VL.text("Qwen 2B · архивная") }
    var selectionTitle:String {title + (self == .qwen9b ? " · 9B":self == .qwen4b ? " · 4B":"")}
    var description: String { self == .qwen06b ? VL.text("Эта модель больше недоступна") : self == .qwen9b ? VL.text("Для подробных саммари, анализа встреч, решений и поручений") : VL.text("Для кратких заметок и повседневных саммари") }
    var minimumMemory: UInt64 { (self == .qwen9b ? 16 : 8) * 1_073_741_824 }
    var memoryRequirement: String { VL.text("Mac с \(self == .qwen9b ? 16 : 8) ГБ объединённой памяти или больше") }
    func compatible(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool { memory >= minimumMemory }

}

/// UI snapshots contain no credentials, filesystem paths or model download URLs.
enum LocalAIModelState: String, Codable {
    case notInstalled, preparing, downloading, verifying, installed, damaged, failed, deleting
}
struct LocalAIModelSettings: Codable, Equatable {
    let id: String
    let title: String
    let variant: String
    let size: Int64
    let license: String
    let state: LocalAIModelState
    let received: Int64
    let error: String?
    var fraction: Double { size > 0 ? min(1, max(0, Double(received) / Double(size))) : 0 }
}
struct LocalAISettingsSnapshot: Codable, Equatable {
    let models: [LocalAIModelSettings]
    let summaryModel: AISummaryModelID
    let supported: Bool
    let isProcessing: Bool
    let message: String?
    let updatedAt: Date
    func validate() throws {
        let known=Set(["whisper", "speaker", "tokenizer", "qwen", "qwen4b"])
        guard (models.count == 5 && Set(models.map(\.id)) == Set(["whisper", "speaker", "tokenizer", "qwen4b", "qwen9b"]) || models.count == 5 && Set(models.map(\.id)) == known || models.count == 6 && Set(models.map(\.id)) == known.union(["qwen9b"]) || models.count == 7 && Set(models.map(\.id)) == known.union(["qwen9b", "qwen06b"])),
              models.allSatisfy({ $0.size > 0 && $0.size < 8_000_000_000 && $0.received >= 0 && $0.title.count < 200 && $0.variant.count < 200 })
        else { throw AIProcessingError.invalidRequest }
    }
}
enum LocalAISettingsAction: String, Codable {
    case selectSummaryModel, install, cancelDownload, remove, refresh
}
struct LocalAISettingsCommand: Codable, Equatable {
    let id: UUID
    let action: LocalAISettingsAction
    let modelID: String?
    let createdAt: Date
    func validate() throws {
        if action == .refresh {
            guard modelID == nil else { throw AIProcessingError.invalidRequest }
        } else {
            guard let modelID, ["whisper", "speaker", "tokenizer", "qwen", "qwen4b", "qwen9b", "qwen06b"].contains(modelID),
                  action != .selectSummaryModel || AISummaryModelID(rawValue: modelID) != nil
            else { throw AIProcessingError.invalidRequest }
        }
    }
}

/// Choosing a provider changes preferences only: no downloads or new jobs.
final class AIProcessingPreferences {
    private let defaults: UserDefaults
    private let key: String
    init(userID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "Vecta.AIProvider." + userID
    }
    var provider: AIProviderID {
        get { defaults.string(forKey: key).flatMap(AIProviderID.init(rawValue:)) ?? .local }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }
}

enum AIProcessingStage: String, Codable {
    case queued, preparingAudio, loadingRecognition, recognizing
    case diarizing, aligning, savingTranscript
    case loadingSummary, summarizing, visualizing, saving, completed, summaryFailed, failed, cancelled
    var isActive: Bool {
        switch self {
        case .completed, .summaryFailed, .failed, .cancelled: return false
        default: return true
        }
    }
    var title: String {
        switch self {
        case .queued: return VL.text("В очереди локальной обработки")
        case .preparingAudio: return VL.text("Подготовка аудио")
        case .loadingRecognition: return VL.text("Загрузка модели распознавания в память")
        case .recognizing: return VL.text("Распознавание речи на Mac")
        case .diarizing: return VL.text("Определение собеседников")
        case .aligning: return VL.text("Сопоставление слов")
        case .savingTranscript: return VL.text("Сохранение транскрипта")
        case .loadingSummary: return VL.text("Загрузка модели саммари в память")
        case .summarizing: return VL.text("Создание саммари на Mac")
        case .visualizing: return VL.text("Создание инфографики")
        case .saving: return VL.text("Сохранение результата")
        case .completed: return VL.text("Готово")
        case .summaryFailed: return VL.text("Транскрипт сохранён; саммари не создано")
        case .failed: return VL.text("Обработка не завершена")
        case .cancelled: return VL.text("Обработка отменена")
        }
    }
}

struct AISpeechSegment: Codable, Equatable {
    let id: Int
    let start: Double
    let end: Double
    /// Anonymous voice label, never an inferred real identity.
    let speaker: String?
    let text: String
    var speakerID: String? = nil
    func validate(duration: Double) throws {
        guard id >= 0, start.isFinite, end.isFinite, start >= 0,
              end >= start, end <= duration + 1, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AIProcessingError.invalidTranscript }
    }
}

struct AIActionItem: Codable, Equatable {
    let description: String
    let assignee: String?
    let deadline: String?
    let sourceSegments: [Int]
}

/// Shared policy for generated labels, display and repair of old format headings.
/// It only projects existing content; historical result envelopes remain unchanged.
enum AIRecordingTitle {
    static func validated(_ value: String) -> String? {
        guard !value.contains("\n") else { return nil }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = title.split(whereSeparator: { $0.isWhitespace })
        let lowered = title.lowercased()
        let label = lowered.trimmingCharacters(in: .punctuationCharacters)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let formatLabels: Set<String> = [
            "саммари записи", "разговор людей", "расшифровка записи",
            "подробный тематический конспект", "тематический конспект",
            "подробный конспект", "краткий конспект", "конспект записи",
            "аналитический разбор", "аналитический разбор записи",
            "подробное саммари", "краткое саммари", "краткое содержание",
            "краткое содержание записи", "итоги встречи", "обзор записи",
            "meeting summary", "recording summary", "detailed summary", "thematic summary"
        ]
        guard (2...7).contains(words.count), title.count <= 80,
              !lowered.contains("собеседник"), !lowered.contains("спикер"),
              !formatLabels.contains(label),
              !VectaSummaryInterpretation.allCases.contains(where: { $0.title.lowercased() == label }) else { return nil }
        return title
    }
    static func explicitTopics(in document: String) -> [String] {
        document.components(separatedBy: .newlines).compactMap { line in
            let heading = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#* "))
            // Only an explicit topic label supplies fallback metadata. Section
            // headings, arbitrary prose and the template name are not titles.
            guard let colon = heading.firstIndex(of: ":") else { return nil }
            let label = heading[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard ["тема", "тема записи", "topic", "recording topic"].contains(label) else { return nil }
            return validated(String(heading[heading.index(after: colon)...]))
        }
    }
}

struct AIStructuredSummary: Codable, Equatable {
    let summary: String
    let topics: [String]
    let decisions: [String]
    let tasks: [AIActionItem]
    let uncertainties: [String]
    var recordingTitle: String? = nil
    var blocks: [AISummaryBlock]? = nil
    /// Historical results retain their evidence. New source-free summaries opt in explicitly.
    var sourcePolicy: String? = nil
    /// A complete streamed body; blocks/tasks are projections of this same text.
    var textRepresentation: String? = nil
    /// Applied only to newly generated summaries; never rewrites historical results.
    var withoutSourceLinks: Self {
        Self(summary:summary,topics:topics,decisions:decisions,
             tasks:tasks.map { AIActionItem(description:$0.description,assignee:$0.assignee,deadline:$0.deadline,sourceSegments:[]) },
             uncertainties:uncertainties,recordingTitle:recordingTitle,
             blocks:blocks?.map { AISummaryBlock(id:$0.id,kind:$0.kind,title:$0.title,tokens:$0.tokens,sourceSegments:[]) },sourcePolicy:"none",textRepresentation:textRepresentation)
    }
    /// Prefer content labels to headings describing the requested output format.
    var topicTitle: String? {
        ([recordingTitle].compactMap { $0 } + topics + AIRecordingTitle.explicitTopics(in: summary))
            .compactMap(AIRecordingTitle.validated).first
    }
    func validate(segmentIDs: Set<Int>) throws {
        if let recordingTitle {
            let words = recordingTitle.split(whereSeparator: { $0.isWhitespace })
            guard (2...7).contains(words.count), recordingTitle.count <= 80, !recordingTitle.contains("\n") else { throw AIProcessingError.invalidSummary }
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (sourcePolicy == nil || sourcePolicy == "none"),(textRepresentation == nil || textRepresentation == "plain"),
              tasks.allSatisfy({ !$0.description.isEmpty && (sourcePolicy == "none" || !$0.sourceSegments.isEmpty) && Set($0.sourceSegments).isSubset(of: segmentIDs) })
        else { throw AIProcessingError.invalidSummary }
    }
}

/// Immutable per-operation selection. Changing the settings never reroutes it.
enum AIRecognitionBudget {
    /// Bound short/noisy clips while retaining the existing long-audio limit.
    static func tokens(duration: Double) -> Int {
        guard duration.isFinite, duration >= 0 else { return 512 }
        return Int(min(32_768, max(512, ceil(duration * 12 + 256))))
    }
}

struct AIProcessingRequest: Codable, Equatable {
    let version: Int
    let id: UUID
    let recordingID: String
    let audioFilename: String
    let audioSHA256: String
    let provider: AIProviderID
    let format: VectaSummaryInterpretation
    let createdAt: Date
    let summaryOnly: Bool
    let transcriptRequestID: UUID?
    var summaryModel: AISummaryModelID? = nil
    var summaryTemplate:AISummaryTemplate? = nil
    var visualEnabled:Bool? = nil
    var visualSummaryModel:AISummaryModelID? = nil
    var outputLanguage:String? = nil
    var resultLanguage:VectaLanguage {outputLanguage.flatMap(VectaLanguage.init(rawValue:)) ?? .russian}
    var speechCheckpointVersion:Int {outputLanguage == nil ? 1:2}
    var speechDecodingPolicy:String {outputLanguage == nil ? "forced-ru-v1":"automatic-v1"}
    func acceptsSpeechCheckpoint(version:Int,outputLanguage:String?,decodingPolicy:String?)->Bool {
        version==speechCheckpointVersion && outputLanguage==self.outputLanguage &&
        (decodingPolicy ?? "forced-ru-v1")==speechDecodingPolicy
    }
    func speechCheckpointURL(for output:URL)->URL {
        let name=outputLanguage == nil ? "speech-v1-"+audioSHA256 : "speech-v2-"+resultLanguage.rawValue+"-auto-"+audioSHA256
        return output.deletingLastPathComponent().appendingPathComponent(name+".json")
    }
    var selectedVisualModel:AISummaryModelID { visualSummaryModel ?? .qwen9b }
    var wantsVisual:Bool { visualEnabled ?? (selectedSummaryModel == .qwen9b) }
    var selectedSummaryModel: AISummaryModelID { summaryModel ?? .qwen }
    func validate() throws {
        if let outputLanguage, VectaLanguage(rawValue:outputLanguage)==nil {throw AIProcessingError.invalidRequest}
        if let summaryTemplate {try summaryTemplate.validate()}
        guard version == 1, !recordingID.isEmpty, recordingID.count <= 256,
              audioFilename == URL(fileURLWithPath: audioFilename).lastPathComponent,
              ["mp3", "m4a", "wav", "aiff", "aif", "caf"].contains(URL(fileURLWithPath:audioFilename).pathExtension.lowercased()), !audioFilename.contains(".."),
              audioSHA256.count == 64, audioSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
              format.isValid, summaryOnly == (transcriptRequestID != nil)
        else { throw AIProcessingError.invalidRequest }
    }
}

/// Local output and future normalized cloud output share this envelope. Legacy
/// ChatGPT markdown remains authoritative; do not fabricate parsed segments.
struct AIRecognitionProgress: Codable, Equatable {
    var completedChunks: Int
    var totalChunks: Int
    var processedSeconds: Double
    var totalSeconds: Double
    var currentChunk: Int?
    var modelLoadSeconds: Double?
    var speakerScope: String = "overlap-matched-or-fragment-local"
    var checkpointKey: String?
}

struct AIProcessingResult: Codable, Equatable {
    /// Newer semantic workers may omit the optional legacy recordingTitle.
    /// Reuse their topic title without inventing a label or starting inference.
    var recordingTopicTitle: String? {
        let candidates=[summary?.topicTitle, semanticSummary?.title, visualSummary?.title].compactMap { $0 }
        return AIStructuredSummary(summary:"",topics:candidates,decisions:[],tasks:[],uncertainties:[]).topicTitle
    }

    let version: Int
    let request: AIProcessingRequest
    var stage: AIProcessingStage
    var transcript: String?
    var segments: [AISpeechSegment]
    var summary: AIStructuredSummary?
    var error: String?
    var updatedAt: Date
    var duration: Double?
    var recognitionSeconds: Double?
    var summarySeconds: Double?
    var recognitionProgress: AIRecognitionProgress? = nil
    var summaryProgress: AISummaryProgress? = nil
    /// Incomplete streamed text is never a committed/exportable summary.
    var summaryDraft: String? = nil
    var visualSummary:AIVisualSummary? = nil
    var semanticSummary:AISemanticSummary? = nil
    var fullTextSummary:AIFullTextSummary? = nil
    var visualError:String? = nil
    var visualSeconds:Double? = nil
    var visualModel:String? = nil
    var processingProgress:AIWorkProgress? = nil
    var summarySpeakerIDs:[String]? = nil
    var unmatchedText: String? = nil
    func validate() throws {
        try request.validate()
        guard version == 1 else { throw AIProcessingError.invalidRequest }
        if let summaryDraft { guard summaryDraft.utf8.count <= 1_000_000 else { throw AIProcessingError.invalidSummary } }
        if let progress = recognitionProgress {
            guard progress.totalChunks > 0, (0...progress.totalChunks).contains(progress.completedChunks),
                  progress.processedSeconds.isFinite, progress.totalSeconds.isFinite,
                  progress.totalSeconds > 0, (0...progress.totalSeconds).contains(progress.processedSeconds),
                  duration == progress.totalSeconds,
                  progress.currentChunk.map({ (1...progress.totalChunks).contains($0) }) ?? true else { throw AIProcessingError.invalidTranscript }
            if transcript != nil {
                guard progress.completedChunks == progress.totalChunks, progress.processedSeconds == progress.totalSeconds else { throw AIProcessingError.invalidTranscript }
            }
        }
        if let duration {
            guard duration.isFinite, duration >= 0 else { throw AIProcessingError.invalidTranscript }
            for segment in segments { try segment.validate(duration: duration) }
        } else if !segments.isEmpty { throw AIProcessingError.invalidTranscript }
        guard Set(segments.map(\.id)).count == segments.count else { throw AIProcessingError.invalidTranscript }
        if let summary {
            try summary.validate(segmentIDs: Set(segments.map(\.id)))
            for block in summary.blocks ?? [] { try block.validate(segments: segments,speakerIDs:summarySpeakerIDs.map(Set.init),allowUnsourced:summary.sourcePolicy == "none") }
        }
        if let semanticSummary {try semanticSummary.validate(segments:segments,speakerIDs:summarySpeakerIDs.map(Set.init))}
        if let fullTextSummary {
            guard fullTextSummary.schemaVersion==1,Set(fullTextSummary.paragraphs.map(\.id)).count==fullTextSummary.paragraphs.count else {throw AIProcessingError.invalidSummary}
            for paragraph in fullTextSummary.paragraphs {
                guard !paragraph.id.isEmpty,Set(paragraph.sourceSegments).isSubset(of:Set(segments.map(\.id))) else {throw AIProcessingError.invalidSummary}
                for token in paragraph.tokens {guard (token.text != nil) != (token.speakerID != nil) else {throw AIProcessingError.invalidSummary}}
            }
        }
        if let visualSummary {try visualSummary.validate(segments:segments,speakerIDs:summarySpeakerIDs.map(Set.init))}
        if stage == .completed {
            guard transcript != nil, summary != nil, error == nil else { throw AIProcessingError.invalidSummary }
        }
        if stage == .summaryFailed && transcript == nil { throw AIProcessingError.invalidTranscript }
    }
}

enum AIProcessingError: Error, LocalizedError {
    case invalidRequest, invalidTranscript, invalidSummary, modelsMissing, busy, interrupted, durationLimit, retiredModel
    var errorDescription: String? {
        switch self {
        case .retiredModel: return VL.text("Архивная модель Qwen больше не выполняется. Исходное задание и результаты сохранены. Выберите MLX 4B или 9B в настройках и явно создайте новую версию саммари.")
        case .invalidRequest: return VL.text("Некорректный запрос локальной обработки.")
        case .invalidTranscript: return VL.text("Модель не вернула корректный полный транскрипт с сегментами.")
        case .invalidSummary: return VL.text("Модель не вернула корректное структурированное саммари.")
        case .durationLimit: return VL.text("Vecta поддерживает обработку аудиозаписей до 6 часов включительно. Продолжительность должна быть больше нуля.")
        case .modelsMissing: return VL.text("Для локальной обработки необходимо установить AI-модели.")
        case .busy: return VL.text("Локальная обработка уже выполняется. Дождитесь завершения или отмените её.")
        case .interrupted: return VL.text("Локальная обработка прервана. Готовый транскрипт сохранён, если распознавание было завершено.")
        }
    }
}

/// Adapters must dispatch one operation to exactly one provider. No fallback.
protocol AIProcessingProvider {
    var id: AIProviderID { get }
    func submit(_ request: AIProcessingRequest, completion: @escaping (Result<Void, Error>) -> Void)
    func cancel(requestID: UUID)
}

extension AIProcessingResult {
    /// Plain-text export of persisted speaker turns. Voice labels remain the
    /// automatic labels from this recording; unknown turns never gain an ID.
    var readableTranscript: String? {
        guard !segments.isEmpty else {
            return transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        struct Turn { let start: Double; var end: Double; let speaker: String?; var text: String }
        var turns: [Turn] = []
        for segment in segments {
            let text = segment.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !text.isEmpty else { continue }
            let label = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = label.flatMap { $0.isEmpty ? nil : $0 }
            if let last = turns.last, speaker != nil, speaker == last.speaker,
               segment.start >= last.start, segment.start - last.end <= 2,
               segment.end - last.start <= 45, last.text.count + text.count < 800 {
                let separator = text.first.map { ".,!?;:…)]}".contains($0) } == true ? "" : " "
                turns[turns.count - 1].text += separator + text
                turns[turns.count - 1].end = max(last.end, segment.end)
            } else {
                turns.append(Turn(start: segment.start, end: segment.end, speaker: speaker, text: text))
            }
        }
        var paragraphs = turns.map { turn -> String in
            let seconds = turn.start.isFinite && turn.start >= 0 ? Int(min(turn.start, Double(Int.max / 2))) : 0
            let time = seconds >= 3600
                ? String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String(format: "%02d:%02d", seconds / 60, seconds % 60)
            return "[\(time)] \(turn.speaker ?? VL.text("Собеседник не определён")):\n\(turn.text)"
        }
        if let unmatchedText, !unmatchedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            paragraphs.append(VL.text("Без надёжных таймкодов — собеседник не определён:\n") + unmatchedText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        }
        return paragraphs.isEmpty ? transcript : paragraphs.joined(separator: "\n\n")
    }
}

// Additive V2 conversation data: original inference envelopes stay immutable.
struct AISummaryToken: Codable, Equatable {
    var text: String?
    var speakerID: String?
    /// Projection-only guard for direct speech. Historical tokens omit it.
    var isVerbatim:Bool? = nil
}
struct AISummaryEvidence: Codable, Equatable {
    let segmentID:Int
    let startMs:Int
    let endMs:Int
    /// A measured point has no trustworthy duration; playback adds context.
    var timingPrecision:String?=nil
}
struct AISummaryBlock: Codable, Equatable, Identifiable {
    var id: String
    var kind: String // fact, inference, assumption
    var title: String
    var tokens: [AISummaryToken]
    var sourceSegments: [Int]
    var evidenceReferences:[AISummaryEvidence]? = nil
    func resolvingEvidence(_ segments:[AISpeechSegment]) throws -> Self {
        var copy=self
        copy.evidenceReferences=try sourceSegments.map { id in
            guard let segment=segments.first(where:{$0.id==id}),segment.start.isFinite,segment.end.isFinite,segment.start>=0,segment.end>=segment.start,segment.end<Double(Int.max)/1000 else { throw AIProcessingError.invalidSummary }
            return AISummaryEvidence(segmentID:id,startMs:Int((segment.start*1000).rounded()),endMs:Int((segment.end*1000).rounded()),timingPrecision:segment.end==segment.start ? "point":nil)
        }
        return copy
    }
    func validate(segments: [AISpeechSegment],speakerIDs:Set<String>?=nil,allowUnsourced:Bool=false) throws {
        let ids=Set(segments.map(\.id));let speakers=speakerIDs ?? Set(segments.compactMap(\.resolvedSpeakerID))
        guard ["fact","inference","assumption"].contains(kind), !tokens.isEmpty,
              tokens.contains(where:{!($0.text ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}),
              (allowUnsourced || !sourceSegments.isEmpty),Set(sourceSegments).count==sourceSegments.count,Set(sourceSegments).isSubset(of:ids),
              tokens.allSatisfy({ ($0.text != nil) != ($0.speakerID != nil) && ($0.speakerID.map { speakers.contains($0) } ?? true) }) else { throw AIProcessingError.invalidSummary }
        if let evidenceReferences {
            guard evidenceReferences == (try resolvingEvidence(segments)).evidenceReferences else { throw AIProcessingError.invalidSummary }
        }
    }
}
struct AISummaryProgress: Codable, Equatable { let phase: String; let completed: Int; let total: Int; var fraction: Double? = nil }
struct AIWordTiming: Codable, Equatable, Identifiable {
    let start: Double; let end: Double; let text: String; let globalID: Int?
    var id: String { "\(start):\(end):\(text)" }
}
struct AISpeakerAlignment: Decodable {
    let complete: Bool
    let words: [AIWordTiming]
    let centroids: [String:[Float]]
    func sample(_ id:String,result:AIProcessingResult,conversation:AIRecordingSpeakers,key:String) -> AIVoiceSample? {
        guard complete,id.hasPrefix("speaker_") else {return nil}
        // A corrected identity may include several original diarization groups.
        // Only whole groups assigned exclusively to this person are admissible;
        // a partial reassignment cannot relabel the group's original centroid.
        let grouped=Dictionary(grouping:result.segments.compactMap {segment in
            segment.resolvedSpeakerID.map {($0,segment)}
        },by:{$0.0})
        var parts:[([Float],[AISpeechSegment])]=[]
        for original in grouped.keys.sorted() {
            let source=grouped[original]!.map {$0.1}
            guard source.allSatisfy({conversation.speakerID($0)==id}) else {continue}
            guard original.hasPrefix("speaker_"),let number=Int(original.dropFirst(8)),number>0,
                  let embedding=centroids[String(number-1)],!embedding.isEmpty,
                  embedding.allSatisfy(\.isFinite),embedding.contains(where:{$0 != 0}),
                  source.allSatisfy({$0.start.isFinite && $0.end.isFinite && $0.start>=0 && $0.end>$0.start}) else {return nil}
            parts.append((embedding,source))
        }
        guard let first=parts.first else {return nil}
        let source=parts.flatMap {$0.1}.sorted {$0.id<$1.id}
        // Simultaneous original groups are not a safe single-person enrolment.
        if parts.count>1 {
            for a in source { for b in source where a.id<b.id && a.resolvedSpeakerID != b.resolvedSpeakerID {
                if min(a.end,b.end)>max(a.start,b.start) {return nil}
            }}
        }
        let embedding:[Float]
        if parts.count==1 {embedding=first.0}
        else {
            guard parts.allSatisfy({$0.0.count==first.0.count}) else {return nil}
            var aggregate=Array(repeating:0.0,count:first.0.count)
            for (vector,segments) in parts {
                let norm=sqrt(vector.reduce(0.0){$0+Double($1)*Double($1)})
                let seconds=segments.reduce(0.0){$0+$1.end-$1.start}
                guard norm.isFinite,norm>0 else {return nil}
                for index in vector.indices {aggregate[index] += Double(vector[index])/norm*seconds}
            }
            let norm=sqrt(aggregate.reduce(0.0){$0+$1*$1})
            guard norm.isFinite,norm>0 else {return nil}
            embedding=aggregate.map {Float($0/norm)}
        }
        guard let representative=source.max(by:{($0.end-$0.start)<($1.end-$1.start)}) else {return nil}
        let sample=AIVoiceSample(recordingKey:key,speakerID:id,embedding:embedding,confirmedAt:Date(),recordingID:result.request.recordingID,segmentIDs:source.map(\.id),start:representative.start,end:representative.end,speechSeconds:source.reduce(0){$0+$1.end-$1.start})
        return sample.isValid ? sample:nil
    }
}
extension AISpeechSegment {
    var resolvedSpeakerID: String? {
        if let speakerID { return speakerID }
        // Deterministic compatibility mapping only for historical anonymous labels.
        if let speaker, speaker.hasPrefix("Собеседник "), let number=Int(speaker.dropFirst("Собеседник ".count)),number>0 { return String(format:"speaker_%03d",number) }
        return speaker.map { "legacy_" + $0.data(using:.utf8)!.base64EncodedString() }
    }
}
struct AISpeakerIdentity: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var origin: String // automatic, voiceSuggestion (provisional), manual, profileConfirmed
    var profileID: UUID?
    /// Display-only match. This is not a confirmed binding or an enrolled sample.
    var suggestedProfileID:UUID? = nil
    var isVoiceConfirmed:Bool {profileID != nil && origin != "voiceSuggestion"}
    var needsVoiceConfirmation:Bool {origin=="voiceSuggestion" && suggestedProfileID != nil}
    var displayName:String {
        if origin == "voiceSuggestion" {return Self.unqualifiedSuggestion(name)}
        if origin == "automatic",name=="Собеседник" || name.range(of:"^Собеседник [0-9]+$",options:.regularExpression) != nil {
            return VL.string("Собеседник")+String(name.dropFirst("Собеседник".count))
        }
        if origin == "userUnknown",name=="Неизвестный собеседник" {return VL.string(name)}
        return name
    }
    static func unqualifiedSuggestion(_ name:String)->String {
        let expression=AISpeakerReferencePatterns.shared.expression("(?i)^возможно[,\\s]+")
        let clean=expression?.stringByReplacingMatches(in:name,range:NSRange(location:0,length:(name as NSString).length),withTemplate:"") ?? name
        return clean.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    var previousName:String? = nil
    var referenceNames:[String]? = nil // Past voice suggestions, scoped to this recording identity.
    var nameOverride:Bool? = nil
}
struct AIRecordingSpeakers: Codable, Equatable {
    var version=2
    var identities: [String:AISpeakerIdentity]=[:]
    var assignments: [String:String]=[:] // stable segment ID -> corrected voice ID
    var aliases: [String:String]? = nil
    var summaryNeedsReview=false
    var dismissedSuggestions:[String:[String]]? = nil
    static func initial(_ segments:[AISpeechSegment]) -> Self {
        var value=Self()
        for s in segments { if let id=s.resolvedSpeakerID { value.identities[id]=value.identities[id] ?? AISpeakerIdentity(id:id,name:s.speaker ?? "Собеседник",origin:"automatic",profileID:nil) } }
        return value
    }
    func speakerID(_ segment:AISpeechSegment) -> String? { assignments[String(segment.id)] ?? segment.resolvedSpeakerID }
    /// Fill diarization gaps in the projection using available word votes,
    /// then the closest recognized turn. Explicit segment assignments win.
    func resolvingUnassigned(_ segments:[AISpeechSegment],alignment:AISpeakerAlignment?) -> Self {
        var value=self
        let known=segments.filter {speakerID($0).map {identities[$0] != nil} == true && $0.start.isFinite && $0.end.isFinite && $0.end>$0.start}
        var targets=Set<String>()
        for segment in segments where speakerID(segment)==nil && segment.start.isFinite && segment.end.isFinite && segment.start>=0 && segment.end>segment.start {
            var votes=[String:Double]()
            for word in alignment?.words ?? [] {
                guard let global=word.globalID,global>=0 else {continue}
                let id=String(format:"speaker_%03d",global+1)
                let overlap=max(0,min(segment.end,word.end)-max(segment.start,word.start))
                if identities[id] != nil,overlap>0 {votes[id,default:0]+=overlap}
            }
            let voted=votes.sorted {$0.value == $1.value ? $0.key < $1.key : $0.value>$1.value}.first?.key
            let nearest=known.min {a,b in
                let da=max(0,max(a.start-segment.end,segment.start-a.end)),db=max(0,max(b.start-segment.end,segment.start-b.end))
                return da == db ? a.id<b.id:da<db
            }.flatMap {speakerID($0)}
            if let target=voted ?? nearest {value.assignments[String(segment.id)]=target;targets.insert(target)}
        }
        // An old generated generic label is resolvable only when every filled
        // gap has the same target. Distinct unknown people are never collapsed.
        if targets.count==1,let id=targets.first,var identity=value.identities[id] {
            identity.referenceNames=Array(Set((identity.referenceNames ?? [])+["Собеседник не определён","Неопределенный собеседник","Неопределённый собеседник"])).sorted()
            value.identities[id]=identity
        }
        return value
    }
    func canonicalSpeakerID(_ id:String)->String {
        var value=id;var seen=Set<String>()
        while seen.insert(value).inserted,let next=aliases?[value] {value=next}
        return value
    }
    func name(_ id:String?) -> String { id.flatMap { identities[canonicalSpeakerID($0)]?.displayName } ?? "Собеседник не определён" }
    /// Rejecting a match is a recording-local decision, not deleting a person.
    /// It never adds voice samples. The chooser can then explicitly select a
    /// different existing person or register a new one.
    mutating func rejectMatch(_ id:String,profile:UUID) throws {
        guard var identity=identities[id] else {throw AIProcessingError.invalidRequest}
        var dismissed=dismissedSuggestions ?? [:]
        dismissed[id]=Array(Set((dismissed[id] ?? [])+[profile.uuidString])).sorted()
        dismissedSuggestions=dismissed
        identity.referenceNames=Array(Set((identity.referenceNames ?? [])+[identity.name])).sorted()
        if identity.profileID==profile || identity.suggestedProfileID==profile || identity.origin=="voiceSuggestion" {
            identity.name=identity.previousName ?? "Собеседник"
            identity.profileID=nil;identity.suggestedProfileID=nil;identity.previousName=nil
            identity.nameOverride=false;identity.origin="manual"
        }
        identities[id]=identity
    }
    mutating func rename(_ id:String,to name:String) throws {
        let clean=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !clean.isEmpty,clean.count<=120,!clean.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),var identity=identities[id] else { throw AIProcessingError.invalidRequest }
        identity.referenceNames=Array(Set((identity.referenceNames ?? [])+[identity.name])).sorted()
        identity.name=clean;identity.origin="manual";identity.nameOverride=true;identities[id]=identity
    }
    mutating func markSpeakerUnknown(_ id:String,rejectedProfiles:[UUID]) throws {
        guard var identity=identities[id] else {throw AIProcessingError.invalidRequest}
        var rejected=Set(dismissedSuggestions?[id] ?? [])
        rejected.formUnion(rejectedProfiles.map(\.uuidString))
        if let profile=identity.profileID {rejected.insert(profile.uuidString)}
        var dismissed=dismissedSuggestions ?? [:];dismissed[id]=rejected.sorted();dismissedSuggestions=dismissed
        identity.referenceNames=Array(Set((identity.referenceNames ?? [])+[identity.name])).sorted()
        identity.name="Неизвестный собеседник";identity.origin="userUnknown"
        identity.profileID=nil;identity.previousName=nil;identity.nameOverride=true
        identities[id]=identity;summaryNeedsReview=true
    }
    mutating func merge(_ from:String,into target:String,segments:[AISpeechSegment]) throws {
        guard from != target,identities[from] != nil,identities[target] != nil else { throw AIProcessingError.invalidRequest }
        for s in segments where speakerID(s)==from { assignments[String(s.id)]=target }
        var links=aliases ?? [:]
        for (id,value) in links where value==from { links[id]=target }
        links[from]=target;aliases=links
        identities.removeValue(forKey:from);summaryNeedsReview=true
    }
    mutating func split(_ ids:Set<Int>,segments:[AISpeechSegment],name:String) throws {
        guard !ids.isEmpty,ids.isSubset(of:Set(segments.map(\.id))) else { throw AIProcessingError.invalidRequest }
        let id="speaker_"+UUID().uuidString.lowercased();identities[id]=AISpeakerIdentity(id:id,name:name,origin:"manual",profileID:nil)
        for s in ids { assignments[String(s)]=id };summaryNeedsReview=true
    }
    func rendered(_ result:AIProcessingResult) -> AIProcessingResult {
        var copy=result
        copy.segments=result.segments.map { s in AISpeechSegment(id:s.id,start:s.start,end:s.end,speaker:name(speakerID(s)),text:s.text,speakerID:speakerID(s)) }
        copy.summary=result.summary.map {renderedSummary($0,segments:result.segments)}
        copy.fullTextSummary=result.completeTextSummary.map {renderedFullText($0,segments:result.segments)}
        copy.semanticSummary=result.semanticSummary.map {renderedSemantic($0,segments:result.segments)}
        copy.visualSummary=result.visualSummary.map {renderedVisual($0,segments:result.segments)}
        copy.summaryDraft=result.summaryDraft.map(resolveText)
        return copy
    }
    /// Bind generated speaker references to recording identity keys before
    /// rendering. This is a transient projection, never a replace over private
    /// result files. Ambiguous names and literal quotations are left intact.
    /// Plain proper names need source attribution (or an exact person-label
    /// field); only explicit old suggestion labels can bind without it.
    func referenceTokens(_ original:String,sourceSpeakerIDs:Set<String>=[]) -> [AISummaryToken] {
        guard !original.isEmpty,!identities.isEmpty else {return [.init(text:original,speakerID:nil)]}
        let source=original as NSString
        let whole=NSRange(location:0,length:source.length)
        var matches=[(NSRange,String)]()
        let quotedPattern="```[\\s\\S]*?```|«[^»]*»|“[^”]*”|\"[^\"]*\"|`[^`]*`|(?m)^\\s*>[^\\n]*"
        let quotes=AISpeakerReferencePatterns.shared.expression(quotedPattern)?.matches(in:original,range:whole).map(\.range) ?? []
        let currentLiteralNames=identities.values.filter {$0.nameOverride == true}.flatMap {identity -> [NSRange] in
            guard let expression=AISpeakerReferencePatterns.shared.expression("(?<![\\p{L}\\p{N}_])"+NSRegularExpression.escapedPattern(for:identity.name)+"(?![\\p{L}\\p{N}_])") else{return []}
            return expression.matches(in:original,range:whole).map(\.range)
        }
        func add(_ pattern:String,_ id:String,protectCurrentNames:Bool=false,options:NSRegularExpression.Options=[.caseInsensitive]) {
            guard let expression=AISpeakerReferencePatterns.shared.expression(pattern,options:options) else{return}
            for match in expression.matches(in:original,range:whole) where !quotes.contains(where:{NSIntersectionRange($0,match.range).length>0}) {
                if protectCurrentNames,currentLiteralNames.contains(where:{NSIntersectionRange($0,match.range).length>0}) {continue}
                matches.append((match.range,canonicalSpeakerID(id)))
            }
        }
        let boundaryLeft="(?<![\\p{L}\\p{N}_])",boundaryRight="(?![\\p{L}\\p{N}_])"
        let known=Set(identities.keys).union(aliases?.keys.map {$0} ?? [])
        var numeric=[Int:Set<String>]()
        for id in known.sorted() {
            add(boundaryLeft+NSRegularExpression.escapedPattern(for:id)+boundaryRight,id,protectCurrentNames:true)
            if id.hasPrefix("speaker_"),let n=Int(id.dropFirst(8)),n>0 {numeric[n,default:[]].insert(canonicalSpeakerID(id))}
        }
        for (number,owners) in numeric where owners.count==1 {
            add(boundaryLeft+"(?:speaker|спикер|собеседник|участник)[_\\s-]*0*"+String(number)+boundaryRight,owners.first!,protectCurrentNames:true)
        }
        var labels=[String:Set<String>]()
        for identity in identities.values {
            for raw in (identity.referenceNames ?? [])+[identity.name,identity.displayName] {
                let clean=AISpeakerIdentity.unqualifiedSuggestion(raw)
                guard !clean.isEmpty,AISpeakerReferencePatterns.shared.expression("(?i)^(?:собеседник|speaker|спикер|участник)[_\\s-]*[0-9]*$")?.firstMatch(in:clean,range:NSRange(location:0,length:(clean as NSString).length))==nil,
                      !["Собеседник","Неизвестный собеседник"].contains(clean) else {continue}
                labels[clean.lowercased(),default:[]].insert(identity.id)
            }
        }
        let scope=Set(sourceSpeakerIDs.map(canonicalSpeakerID))
        for (label,owners) in labels where owners.count==1 {
            let id=owners.first!,escaped=NSRegularExpression.escapedPattern(for:label)
            // A qualified saved match is an explicit identity reference even in
            // source-free legacy summaries. Hedging is display policy only.
            add(boundaryLeft+"(?:возможно|вероятно|предположительно)[,\\s]+"+escaped+boundaryRight,id)
            add(boundaryLeft+escaped+"\\s*\\((?:вероятный|вероятная|вероятно|возможно|предположительно|не подтвержд[её]н)\\)"+boundaryRight,id)
            if original.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()==label {
                add(boundaryLeft+escaped+boundaryRight,id)
            } else if scope==[id] {
                // Attribution, not an arbitrary mention of a person in prose.
                let verbs="(?:сказал[аи]?|предложил[аи]?|отметил[аи]?|объяснил[аи]?|подтвердил[аи]?|обсудил[аи]?|считает|говорит|предлагает|планирует|отвечает|согласен|согласна|настаивает|уточнил[аи]?)"
                add(boundaryLeft+escaped+"(?=\\s+(?:"+verbs+"|[—:]))"+boundaryRight,id)
            }
        }
        // Longest nonoverlapping reference wins; never cascade newly displayed
        // names back into matching. Existing typed speaker tokens stay typed.
        var tokens=[AISummaryToken](),cursor=0
        for (range,id) in matches.sorted(by:{$0.0.location == $1.0.location ? $0.0.length>$1.0.length:$0.0.location<$1.0.location}) {
            guard range.location>=cursor,identities[id] != nil else {continue}
            if range.location>cursor {tokens.append(.init(text:source.substring(with:NSRange(location:cursor,length:range.location-cursor)),speakerID:nil))}
            tokens.append(.init(text:nil,speakerID:id));cursor=NSMaxRange(range)
        }
        if cursor<source.length {tokens.append(.init(text:source.substring(from:cursor),speakerID:nil))}
        return tokens
    }
    private func literalRender(_ tokens:[AISummaryToken])->String {
        tokens.reduce(into:"") {$0 += $1.text ?? name($1.speakerID)}
    }
    func resolveText(_ original:String) -> String {literalRender(referenceTokens(original))}
    private func renderedTokens(_ tokens:[AISummaryToken],sources:[Int]=[],segments:[AISpeechSegment]=[],attributedSpeakerID:String?=nil,literal:Bool=false)->[AISummaryToken] {
        let scope=Set(segments.filter {sources.contains($0.id)}.compactMap(speakerID)).union(attributedSpeakerID.map {[$0]} ?? [])
        return tokens.flatMap {token -> [AISummaryToken] in
            if let id=token.speakerID {return [.init(text:nil,speakerID:canonicalSpeakerID(id))]}
            if literal || token.isVerbatim == true {var copy=token;copy.isVerbatim=true;return [copy]}
            return referenceTokens(token.text ?? "",sourceSpeakerIDs:scope)
        }
    }
    private func renderedSummary(_ summary:AIStructuredSummary,segments:[AISpeechSegment]=[])->AIStructuredSummary {
        var copy=AIStructuredSummary(summary:resolveText(summary.summary),topics:summary.topics.map(resolveText),decisions:summary.decisions.map(resolveText),tasks:summary.tasks.map {
            AIActionItem(description:resolveText($0.description),assignee:$0.assignee.map(resolveText),deadline:$0.deadline,sourceSegments:$0.sourceSegments)
        },uncertainties:summary.uncertainties.map(resolveText),recordingTitle:summary.recordingTitle.map(resolveText),sourcePolicy:summary.sourcePolicy,textRepresentation:summary.textRepresentation)
        copy.blocks=summary.blocks?.map {block in var value=block;value.title=resolveText(block.title);value.tokens=renderedTokens(block.tokens,sources:block.sourceSegments,segments:segments);return value}
        return copy
    }
    func renderedFullText(_ document:AIFullTextSummary)->AIFullTextSummary {renderedFullText(document,segments:[])}
    func renderedFullText(_ document:AIFullTextSummary,segments:[AISpeechSegment])->AIFullTextSummary {
        .init(schemaVersion:document.schemaVersion,paragraphs:document.paragraphs.map {
            .init(id:$0.id,heading:$0.heading.map(resolveText),tokens:renderedTokens($0.tokens,sources:$0.sourceSegments,segments:segments),sourceSegments:$0.sourceSegments)
        })
    }
    func renderedSemantic(_ document:AISemanticSummary)->AISemanticSummary {renderedSemantic(document,segments:[])}
    func renderedSemantic(_ document:AISemanticSummary,segments:[AISpeechSegment])->AISemanticSummary {
        .init(schemaVersion:document.schemaVersion,title:resolveText(document.title),entries:document.entries.map {
            .init(id:$0.id,kind:$0.kind,title:resolveText($0.title),tokens:renderedTokens($0.tokens,sources:$0.sourceSegments,segments:segments,attributedSpeakerID:$0.speakerID,literal:$0.kind == .quote),sourceSegments:$0.sourceSegments,role:$0.role,value:$0.value,number:$0.number,unit:$0.unit,speakerID:$0.speakerID.map(canonicalSpeakerID),date:$0.date,deadline:$0.deadline)
        },subtitle:document.subtitle.map(resolveText),sourcePolicy:document.sourcePolicy)
    }
    func renderedVisual(_ report:AIVisualSummary)->AIVisualSummary {renderedVisual(report,segments:[])}
    func renderedVisual(_ report:AIVisualSummary,segments:[AISpeechSegment])->AIVisualSummary {
        .init(schemaVersion:report.schemaVersion,title:resolveText(report.title),theme:report.theme,blocks:report.blocks.map {block in
            .init(id:block.id,type:block.type,title:resolveText(block.title),items:block.items.map {
                .init(title:resolveText($0.title),tokens:renderedTokens($0.tokens,sources:$0.sourceSegments,segments:segments,attributedSpeakerID:$0.speakerID,literal:block.type == .quotes),sourceSegments:$0.sourceSegments,value:$0.value,number:$0.number,unit:$0.unit,speakerID:$0.speakerID.map(canonicalSpeakerID),date:$0.date,deadline:$0.deadline)
            },layout:block.layout,role:block.role,chartKind:block.chartKind,edges:block.edges?.map {
                .init(from:$0.from,to:$0.to,label:resolveText($0.label),sourceSegments:$0.sourceSegments)
            })
        },subtitle:report.subtitle.map(resolveText),category:report.category.map(resolveText),layout:report.layout,nativeStyle:report.nativeStyle,sourcePolicy:report.sourcePolicy)
    }
    func render(_ tokens:[AISummaryToken]) -> String {
        // Typed references are the authority. Do not reinterpret displayed
        // names or literal token runs on a second render.
        renderedTokens(tokens).reduce(into: "") { output,token in
            let value=token.text ?? name(token.speakerID)
            if let left=output.last,let right=value.first,
               (left.isLetter || left.isNumber || ".!?".contains(left)),
               (right.isLetter || right.isNumber) { output.append(" ") }
            output.append(value)
        }
    }
}
struct AIVoiceSample: Codable, Equatable {
    let recordingKey:String
    let speakerID:String
    let embedding:[Float]
    let confirmedAt:Date
    var recordingID:String? = nil
    var recordingTitle:String? = nil
    var segmentIDs:[Int]? = nil
    var start:Double? = nil
    var end:Double? = nil
    var embeddingSpace:String? = nil // nil: historical extractor provenance unknown
    var speechSeconds:Double? = nil
    func isSameSource(as other:AIVoiceSample) -> Bool {
        guard speakerID == other.speakerID else { return false }
        if let recordingID, let otherID=other.recordingID { return recordingID == otherID }
        return recordingKey == other.recordingKey
    }
    func isCovered(by other:AIVoiceSample) -> Bool {
        if isSameSource(as:other) {return true}
        let sameRecording:Bool
        if let recordingID,let otherID=other.recordingID {sameRecording=recordingID==otherID}
        else {sameRecording=recordingKey==other.recordingKey}
        guard sameRecording,let ids=segmentIDs,!ids.isEmpty,
              let otherIDs=other.segmentIDs,!otherIDs.isEmpty else {return false}
        return Set(ids).isSubset(of:Set(otherIDs))
    }
    var dimension:Int {embedding.count}
    var isValid:Bool { !embedding.isEmpty && embedding.allSatisfy(\.isFinite) && embedding.contains{$0 != 0} }
}
struct AIVoiceProfile: Codable, Equatable, Identifiable {
    let id:UUID
    var name:String
    var samples:[AIVoiceSample]
    var retiredAt:Date? = nil // Name tombstone: no embeddings; preserves historical display names.
}
/// Value-only chooser policy. Selecting/searching/cancelling never modifies
/// the voice library. New-person registration cannot reuse a previous binding.
struct AISpeakerChooserState:Equatable {
    enum Route {case existingPerson,newPerson}
    struct Choice:Equatable {let name:String;let profileID:UUID?;let remember:Bool}
    var route:Route = .existingPerson
    var selectedProfileID:UUID?
    var name=""
    var search=""
    var remember=false
    var rejectedProfileIDs=Set<UUID>()
    private(set) var pendingVoiceDeletion:UUID?
    func people(in voices:AIVoiceLibrary)->[AIVoiceProfile] {
        let query=search.trimmingCharacters(in:.whitespacesAndNewlines)
        return voices.activeProfiles.filter {!rejectedProfileIDs.contains(voices.canonical($0.id)) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))}
            .sorted {$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
    mutating func select(_ id:UUID,in voices:AIVoiceLibrary) {
        guard voices.activeProfiles.contains(where:{$0.id==voices.canonical(id)}),!rejectedProfileIDs.contains(voices.canonical(id)) else{return}
        route = .existingPerson;selectedProfileID=voices.canonical(id);remember=false
    }
    mutating func registerNewPerson() {route = .newPerson;selectedProfileID=nil;remember=false;name=""}
    func choice(in voices:AIVoiceLibrary,sampleAvailable:Bool)->Choice? {
        switch route {
        case .existingPerson:
            guard let id=selectedProfileID,!rejectedProfileIDs.contains(voices.canonical(id)),let person=voices.activeProfiles.first(where:{$0.id==voices.canonical(id)}) else{return nil}
            return Choice(name:person.name,profileID:person.id,remember:false)
        case .newPerson:
            let clean=name.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !clean.isEmpty,clean.count<=120,!clean.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),!remember || sampleAvailable else{return nil}
            return Choice(name:clean,profileID:nil,remember:remember)
        }
    }
    mutating func requestVoiceDeletion(_ id:UUID,in voices:AIVoiceLibrary) {
        guard voices.activeProfiles.contains(where:{$0.id==voices.canonical(id)}) else{return}
        pendingVoiceDeletion=voices.canonical(id)
    }
    mutating func cancelVoiceDeletion() {pendingVoiceDeletion=nil}
    /// Consumed only by the separate destructive confirmation button.
    mutating func confirmedVoiceDeletion(in voices:AIVoiceLibrary)->UUID? {
        defer {pendingVoiceDeletion=nil}
        guard let id=pendingVoiceDeletion,voices.activeProfiles.contains(where:{$0.id==id}) else{return nil}
        if selectedProfileID==id {selectedProfileID=nil}
        return id
    }
}

struct AIVoiceLibrary: Codable, Equatable {
    var version=1
    var recognitionEnabled=false // Explicit opt-in; never silently enabled.
    var profiles:[AIVoiceProfile]=[]
    var aliases:[String:String]? = nil
    var activeProfiles:[AIVoiceProfile] {profiles.filter {$0.retiredAt==nil}}
    mutating func forget(_ id:UUID) throws {
        guard let i=profiles.firstIndex(where:{$0.id==canonical(id) && $0.retiredAt==nil}) else {throw AIProcessingError.invalidRequest}
        profiles[i].samples=[];profiles[i].retiredAt=Date()
    }
    func probable(_ sample:AIVoiceSample,rejected:Set<String>=[]) -> AIVoiceProfile? {
        let canonicalRejections=Set(rejected.compactMap(UUID.init(uuidString:)).map {canonical($0).uuidString})
        let ranked=ranked(sample).filter {!canonicalRejections.contains($0.0.uuidString)}
        // User preference: always propose the closest compatible saved voice.
        // It remains a suggestion until an explicit user confirmation.
        guard let first=ranked.first else {return nil}
        return activeProfiles.first {$0.id==first.0}
    }
    func resolving(_ recording:AIRecordingSpeakers,result:AIProcessingResult,alignment:AISpeakerAlignment?,key:String) -> AIRecordingSpeakers {
        var value=recording.resolvingUnassigned(result.segments,alignment:alignment)
        for (id,var identity) in value.identities {
            if identity.nameOverride != true,let profile=identity.profileID,
               let person=profiles.first(where:{$0.id==canonical(profile)}) {identity.name=person.name}
            else if recognitionEnabled,identity.profileID==nil,["automatic","voiceSuggestion"].contains(identity.origin),let alignment,
                    let sample=alignment.sample(id,result:result,conversation:recording,key:key),
                    let person=probable(sample,rejected:Set(recording.dismissedSuggestions?[id] ?? [])) {
                identity.referenceNames=Array(Set((identity.referenceNames ?? [])+[identity.name,"Возможно, "+person.name])).sorted()
                identity.name=person.name;identity.origin="voiceSuggestion";identity.suggestedProfileID=person.id
            }
            value.identities[id]=identity
        }
        return value
    }
    func mergeNeedsConfirmation(source:AISpeakerIdentity,destination:AISpeakerIdentity) -> Bool {
        guard let from=(source.profileID ?? source.suggestedProfileID).map(canonical),
              let into=(destination.profileID ?? destination.suggestedProfileID).map(canonical) else {return false}
        return from != into
    }
    /// An explicit recording merge chooses the destination person, not a global
    /// profile merge. Only this recording's acoustic evidence is reassigned.
    mutating func mergeSpeakers(_ from:String,into target:String,recording:AIRecordingSpeakers,
                               result:AIProcessingResult,alignment:AISpeakerAlignment,key:String,
                               title:String?=nil,allowProfileChange:Bool=false) throws -> AIRecordingSpeakers {
        let resolved=resolving(recording,result:result,alignment:alignment,key:key)
        guard from != target,let source=resolved.identities[from],let destination=resolved.identities[target] else {throw AIProcessingError.invalidRequest}
        guard allowProfileChange || !mergeNeedsConfirmation(source:source,destination:destination) else {throw AIProcessingError.invalidRequest}
        let chosen=destination.profileID ?? destination.suggestedProfileID ?? (destination.origin=="userUnknown" ? nil:source.profileID ?? source.suggestedProfileID)
        var merged=recording
        try merged.merge(from,into:target,segments:result.segments)
        guard let chosen else {return merged}
        let personID=canonical(chosen)
        guard let person=activeProfiles.first(where:{$0.id==personID}),var identity=merged.identities[target] else {throw AIProcessingError.invalidRequest}
        let turns=result.segments.filter {merged.speakerID($0)==target}
        let others=result.segments.filter {segment in
            guard let id=merged.speakerID(segment),id != target else {return false}
            return merged.identities[id]?.profileID.map(canonical)==personID
        }
        // Joining simultaneous distinct voices cannot enroll a single person.
        guard !turns.contains(where:{a in
            turns.contains {b in a.id != b.id && a.resolvedSpeakerID != b.resolvedSpeakerID && min(a.end,b.end)>max(a.start,b.start)} ||
            others.contains {b in min(a.end,b.end)>max(a.start,b.start)}
        }) else {throw AIProcessingError.invalidRequest}
        identity.referenceNames=Array(Set((identity.referenceNames ?? [])+(source.referenceNames ?? [])+[source.name,destination.name])).sorted()
        if identity.profileID==nil {identity.previousName=identity.name}
        identity.profileID=personID;identity.suggestedProfileID=nil
        if identity.nameOverride != true {identity.name=person.name;identity.nameOverride=false;identity.origin="profileConfirmed"}
        else {identity.origin="manual"}
        merged.identities[target]=identity
        var people=self
        func belongs(_ sample:AIVoiceSample)->Bool {
            let sameRecording=sample.recordingID.map {$0==result.request.recordingID} ?? (sample.recordingKey==key)
            guard sameRecording,merged.canonicalSpeakerID(sample.speakerID)==target else {return false}
            if let ids=sample.segmentIDs,!ids.isEmpty {return Set(ids).isSubset(of:Set(turns.map(\.id)))}
            let original=result.segments.filter {$0.resolvedSpeakerID==sample.speakerID}
            return !original.isEmpty && original.allSatisfy {merged.speakerID($0)==target}
        }
        if var sample=alignment.sample(target,result:result,conversation:merged,key:key) {
            sample.recordingTitle=title
            let covered=Set(sample.segmentIDs ?? [])
            for index in people.profiles.indices {people.profiles[index].samples.removeAll {old in
                guard belongs(old) else {return false}
                if let ids=old.segmentIDs,!ids.isEmpty {return Set(ids).isSubset(of:covered)}
                let original=result.segments.filter {$0.resolvedSpeakerID==old.speakerID}
                return !original.isEmpty && original.allSatisfy {covered.contains($0.id)}
            }}
            _=try people.remember(name:person.name,sample:sample,profileID:personID)
        } else {
            // Keep already confirmed embeddings when alignment is unavailable;
            // do not synthesize a centroid or discard their source provenance.
            let existing=people.activeProfiles.flatMap(\.samples).filter(belongs)
            for sample in existing {_=try people.remember(name:person.name,sample:sample,profileID:personID)}
        }
        self=people
        return merged
    }
    mutating func retire(_ id:UUID) throws {
        guard let i=profiles.firstIndex(where:{$0.id==canonical(id)}) else {throw AIProcessingError.invalidRequest}
        profiles[i].samples=[];profiles[i].retiredAt=Date()
    }
    mutating func merge(_ from:UUID,into target:UUID) throws {
        guard from != target,let a=profiles.firstIndex(where:{$0.id==from}),let b=profiles.firstIndex(where:{$0.id==target}) else { throw AIProcessingError.invalidRequest }
        profiles[b].samples += profiles[a].samples;profiles.remove(at:a)
        var links=aliases ?? [:]
        for (id,value) in links where value==from.uuidString { links[id]=target.uuidString }
        links[from.uuidString]=target.uuidString;aliases=links
    }
    @discardableResult mutating func separate(_ profile:UUID,sample:Int,name:String) throws -> UUID {
        guard let p=profiles.firstIndex(where:{$0.id==profile}),profiles[p].samples.indices.contains(sample) else { throw AIProcessingError.invalidRequest }
        let value=profiles[p].samples.remove(at:sample),id=UUID();profiles.append(AIVoiceProfile(id:id,name:name,samples:[value]));return id
    }
    func canonical(_ id:UUID) -> UUID {
        var current=id;var seen=Set<UUID>()
        while seen.insert(current).inserted,let next=aliases?[current.uuidString],let value=UUID(uuidString:next) {current=value}
        return current
    }
    mutating func remember(name:String,sample:AIVoiceSample,profileID:UUID?=nil,forceNewProfile:Bool=false) throws -> UUID {
        let clean=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard sample.isValid,!clean.isEmpty,clean.count<=120,!clean.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {throw AIProcessingError.invalidRequest}
        // Repeated saving of this source updates the existing sample, not a new person.
        let existing=profiles.firstIndex { profile in profile.samples.contains {$0.isSameSource(as:sample)} }
        let chosen:Int?
        if let profileID {
            guard let i=profiles.firstIndex(where:{$0.id==canonical(profileID) && $0.retiredAt==nil}) else {throw AIProcessingError.invalidRequest}
            chosen=i
        } else {chosen=forceNewProfile ? nil:existing}
        // A new-person decision must not silently retain the rejected source
        // owner. Default repeat-saving behavior remains deduplicating.
        // An explicitly moved source belongs to exactly one saved profile.
        for i in profiles.indices {profiles[i].samples.removeAll {$0.isCovered(by:sample)}}
        if let index=chosen {
            profiles[index].samples.removeAll {$0.isSameSource(as:sample)}
            profiles[index].samples.append(sample)
            return profiles[index].id
        }
        let id=UUID();profiles.append(AIVoiceProfile(id:id,name:clean,samples:[sample]));return id
    }
    func ranked(_ sample:AIVoiceSample) -> [(UUID,Double)] {
        guard sample.isValid else{return []}
        var compatible=self
        compatible.profiles=activeProfiles.map {profile in
            var p=profile;p.samples=p.samples.filter {$0.embeddingSpace==sample.embeddingSpace};return p
        }
        return compatible.suggestions(sample.embedding)
    }
    func suggestions(_ embedding:[Float]) -> [(UUID,Double)] {
        guard recognitionEnabled else { return [] }
        return activeProfiles.compactMap { profile in
            let distances=profile.samples.compactMap { sample -> Double? in
                guard sample.isValid,embedding.allSatisfy(\.isFinite),sample.embedding.count==embedding.count,!embedding.isEmpty else { return nil }
                let dot=zip(embedding,sample.embedding).reduce(0.0){$0+Double($1.0)*Double($1.1)}
                let a=embedding.reduce(0.0){$0+Double($1)*Double($1)},b=sample.embedding.reduce(0.0){$0+Double($1)*Double($1)}
                guard a>0,b>0 else { return nil };let d=1-dot/sqrt(a*b);return d.isFinite ? d:nil
            }
            // Average the three closest independent confirmed recordings.
            // A lone accidental match cannot outweigh the rest of the profile;
            // additional acoustic examples participate in the actual score.
            let support=Array(distances.sorted().prefix(3))
            return support.isEmpty ? nil:(profile.id,support.reduce(0,+)/Double(support.count))
        }.sorted{$0.1 == $1.1 ? $0.0.uuidString < $1.0.uuidString : $0.1<$1.1}
        // Ranking only: no uncalibrated automatic identity assignment.
    }
}
/// Private, additive overlays. Atomic replace makes migrations/retries idempotent;
/// callers never rewrite an original result, audio or transcript.
final class AIConversationStore {
    let root:URL
    init(root:URL) { self.root=root.appendingPathComponent("ConversationV2",isDirectory:true) }
    func recording(_ key:String,segments:[AISpeechSegment]) throws -> AIRecordingSpeakers {
        try recover()
        let file=try recordingURL(key)
        var value=FileManager.default.fileExists(atPath:file.path) ? try JSONDecoder().decode(AIRecordingSpeakers.self,from:Data(contentsOf:file)) : .initial(segments)
        guard value.version==2 else { throw AIProcessingError.invalidRequest }
        for (id,identity) in AIRecordingSpeakers.initial(segments).identities where value.identities[id]==nil && value.aliases?[id]==nil { value.identities[id]=identity }
        return value
    }
    func save(_ value:AIRecordingSpeakers,key:String) throws { try recover();try write(value,to:recordingURL(key)) }
    func voices() throws -> AIVoiceLibrary {
        try recover()
        let file=root.appendingPathComponent("voices.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return AIVoiceLibrary() }
        let value=try JSONDecoder().decode(AIVoiceLibrary.self,from:Data(contentsOf:file));guard value.version==1 else { throw AIProcessingError.invalidRequest };return value
    }
    func save(_ voices:AIVoiceLibrary) throws { try recover();try write(voices,to:root.appendingPathComponent("voices.json")) }
    struct PendingVoiceEdit:Codable {let key:String;let recording:AIRecordingSpeakers;let voices:AIVoiceLibrary}
    func saveTogether(_ recording:AIRecordingSpeakers,key:String,voices:AIVoiceLibrary) throws {
        try recover();_ = try recordingURL(key)
        try write(PendingVoiceEdit(key:key,recording:recording,voices:voices),to:root.appendingPathComponent("pending-voice-edit.json"))
        try recover()
    }
    private func recover() throws {
        let journal=root.appendingPathComponent("pending-voice-edit.json")
        guard FileManager.default.fileExists(atPath:journal.path) else{return}
        let attrs=try journal.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard attrs.isRegularFile==true,attrs.isSymbolicLink != true else{throw AIProcessingError.invalidRequest}
        let edit=try JSONDecoder().decode(PendingVoiceEdit.self,from:Data(contentsOf:journal))
        guard edit.recording.version==2,edit.voices.version==1 else{throw AIProcessingError.invalidRequest}
        try write(edit.voices,to:root.appendingPathComponent("voices.json"))
        try write(edit.recording,to:recordingURL(edit.key))
        try FileManager.default.removeItem(at:journal)
    }
    private func recordingURL(_ key:String) throws -> URL {
        guard key.count==64,key.allSatisfy({"0123456789abcdef".contains($0)}) else { throw AIProcessingError.invalidRequest }
        return root.appendingPathComponent(key+".json")
    }
    private func write<T:Encodable>(_ value:T,to url:URL) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let r=try root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard r.isDirectory==true,r.isSymbolicLink != true else { throw AIProcessingError.invalidRequest }
        if FileManager.default.fileExists(atPath:url.path) { let f=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]);guard f.isRegularFile==true,f.isSymbolicLink != true else { throw AIProcessingError.invalidRequest } }
        try JSONEncoder().encode(value).write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}
struct AIAudioExcerpt: Equatable {
    let start:Double;let end:Double
    init?(start:Double,end:Double,duration:Double,before:Double=0.3,after:Double=0.5,minimum:Double=1.2) {
        guard start.isFinite,end.isFinite,duration.isFinite,start>=0,end>=start,duration>0,start<duration else { return nil }
        self.start=max(0,start-before);self.end=min(duration,max(end+after,self.start+minimum))
    }
}

/// Additive, private conversation history. Original ASR/results remain immutable.
struct AIChatMessage: Codable, Identifiable {
    var id=UUID()
    let role:String
    let text:String
    var blocks:[AISummaryBlock]=[]
    var createdAt=Date()
    var error:String?
}
struct AIChatHistory:Codable {
    var version=1
    var messages:[AIChatMessage]=[]
}
struct AIChatStore {
    let root:URL
    private func url(_ key:String)throws->URL {
        guard key.count==64,key.allSatisfy({"0123456789abcdef".contains($0)}) else {throw AIProcessingError.invalidRequest}
        return root.appendingPathComponent("LocalAI/AssistantV1",isDirectory:true).appendingPathComponent(key+".json")
    }
    func load(_ key:String)throws->AIChatHistory {
        let file=try url(key)
        guard FileManager.default.fileExists(atPath:file.path) else {return AIChatHistory()}
        let flags=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]);guard flags.isRegularFile==true,flags.isSymbolicLink != true else {throw AIProcessingError.invalidRequest}
        let value=try JSONDecoder().decode(AIChatHistory.self,from:Data(contentsOf:file))
        guard value.version==1 else {throw AIProcessingError.invalidRequest};return value
    }
    func save(_ value:AIChatHistory,key:String)throws {
        let file=try url(key),directory=file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let flags=try directory.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard flags.isDirectory==true,flags.isSymbolicLink != true else {throw AIProcessingError.invalidRequest}
        if FileManager.default.fileExists(atPath:file.path) {let f=try file.resourceValues(forKeys:[.isSymbolicLinkKey]);guard f.isSymbolicLink != true else {throw AIProcessingError.invalidRequest}}
        try JSONEncoder().encode(value).write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}
enum AITranscriptRetrieval {
    /// Local lexical retrieval: bounded utterances, not an unbounded full transcript.
    /// Unicode matching is deliberately not advertised as Russian morphology.
    static func select(_ segments:[AISpeechSegment],question:String,characterBudget:Int)->[AISpeechSegment] {
        let words=question.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber}).map(String.init).filter{$0.count>2}
        let end=question.lowercased().contains("конц")
        let ranked=segments.enumerated().sorted { a,b in
            let sa=words.filter{(a.element.text+" "+(a.element.speaker ?? "")).lowercased().contains($0)}.count
            let sb=words.filter{(b.element.text+" "+(b.element.speaker ?? "")).lowercased().contains($0)}.count
            if sa != sb {return sa>sb};return end ? a.offset>b.offset:a.offset<b.offset
        }
        var selected=[AISpeechSegment](),used=0
        for (_,segment) in ranked {
            let cost=segment.text.count+160
            if cost<=characterBudget-used {selected.append(segment);used+=cost}
            if selected.count>=32 {break}
        }
        return selected.sorted{$0.start<$1.start}
    }
}

enum AIVisualBlockType:String,Codable,CaseIterable {case hero,keyPoints,timeline,decisions,tasks,comparison,risks,openQuestions,quotes,statistics,processFlow,conceptMap,decisionMatrix,takeaway,chart}
struct AIVisualItem:Codable,Equatable {
    let title:String
    let tokens:[AISummaryToken]
    let sourceSegments:[Int]
    var value:String?=nil
    var number:Double?=nil
    var unit:String?=nil
    var speakerID:String?=nil
    var date:String?=nil
    var deadline:String?=nil
}
enum AIVisualRole:String,Codable {case fact,position,interpretation,hypothesis}
enum AIVisualLayout:String,Codable {case editorial,bento,comparison,chronological}
enum AIVisualSize:String,Codable {case wide,half,compact}
enum AIVisualChart:String,Codable {case bar,horizontal,line,donut,distribution}
struct AIVisualEdge:Codable,Equatable {
    let from:Int
    let to:Int
    let label:String
    let sourceSegments:[Int]
}
struct AIVisualBlock:Codable,Equatable,Identifiable {
    let id:String
    let type:AIVisualBlockType
    let title:String
    let items:[AIVisualItem]
    var layout:AIVisualSize?=nil
    var role:AIVisualRole?=nil
    var chartKind:AIVisualChart?=nil
    var edges:[AIVisualEdge]?=nil
}
struct AIVisualSummary:Codable,Equatable {
    let schemaVersion:Int
    let title:String
    let theme:String
    let blocks:[AIVisualBlock]
    var subtitle:String?=nil
    var category:String?=nil
    var layout:AIVisualLayout?=nil
    var nativeStyle:AIVisualStyle?=nil
    var sourcePolicy:String?=nil
    static func decodeValidated(_ data:Data,segments:[AISpeechSegment])throws->Self {
        guard data.count<=256000,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(root.keys).isSubset(of:["schemaVersion","title","theme","blocks","subtitle","category","layout","sourcePolicy"]),Set(["schemaVersion","title","theme","blocks"]).isSubset(of:Set(root.keys)),let blocks=root["blocks"] as? [[String:Any]],blocks.count<=10 else {throw AIProcessingError.invalidSummary}
        for block in blocks {
            guard Set(block.keys).isSubset(of:["id","type","title","items","layout","role","chartKind","edges"]),Set(["id","type","title","items"]).isSubset(of:Set(block.keys)),let items=block["items"] as? [[String:Any]],items.count<=12 else {throw AIProcessingError.invalidSummary}
            if let edges=block["edges"] as? [[String:Any]] {for edge in edges {guard Set(edge.keys)==Set(["from","to","label","sourceSegments"]) else {throw AIProcessingError.invalidSummary}}}
            for item in items {
                guard Set(item.keys).isSubset(of:["title","tokens","sourceSegments","value","number","unit","speakerID","date","deadline"]),Set(["title","tokens","sourceSegments"]).isSubset(of:Set(item.keys)),let tokens=item["tokens"] as? [[String:Any]],tokens.count<=24 else {throw AIProcessingError.invalidSummary}
                for token in tokens {
                    guard Set(token.keys).isSubset(of:["type","text","speakerID"]) else {throw AIProcessingError.invalidSummary}
                    if let type=token["type"] as? String {
                        let text=token["text"] as? String,speaker=token["speakerID"] as? String
                        guard (type=="text" && text != nil && speaker==nil) || (type=="speaker" && text==nil && speaker != nil) else {throw AIProcessingError.invalidSummary}
                    } else if token["type"] != nil {throw AIProcessingError.invalidSummary}
                }
            }
        }
        let value=try JSONDecoder().decode(Self.self,from:data);try value.validate(segments:segments);return value
    }
    func validate(segments:[AISpeechSegment],speakerIDs:Set<String>?=nil)throws {
        guard (sourcePolicy == nil || sourcePolicy == "none"),(1...3).contains(schemaVersion),theme=="editorial",!title.isEmpty,title.count<=160,(1...(schemaVersion==3 ? 64:10)).contains(blocks.count),Set(blocks.map(\.id)).count==blocks.count else {throw AIProcessingError.invalidSummary}
        guard Set(segments.map(\.id)).count==segments.count,
              segments.allSatisfy({$0.start.isFinite && $0.end.isFinite && $0.start>=0 && $0.end>=$0.start && $0.end<Double(Int.max)/1000}) else {throw AIProcessingError.invalidSummary}
        guard (subtitle?.count ?? 0)<=400,(category?.count ?? 0)<=80 else {throw AIProcessingError.invalidSummary}
        if schemaVersion==2 {
            guard layout != nil,category?.isEmpty == false,subtitle != nil,blocks.first?.type == .hero,
                  blocks.filter({$0.type == .hero}).count==1 else {throw AIProcessingError.invalidSummary}
            let fingerprints=blocks.flatMap(\.items).map {$0.tokens.compactMap(\.text).joined().folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"ru_RU")).trimmingCharacters(in:.whitespacesAndNewlines)}
            guard Set(fingerprints.filter({!$0.isEmpty})).count==fingerprints.filter({!$0.isEmpty}).count else {throw AIProcessingError.invalidSummary}
        }
        for block in blocks {
            if schemaVersion==2 {guard block.layout != nil,block.role != nil else {throw AIProcessingError.invalidSummary}}
            if block.type == .chart {guard block.chartKind != nil,block.items.count>=2,Set(block.items.compactMap(\.unit)).count==1,block.items.allSatisfy({$0.number != nil && $0.unit != nil}) else {throw AIProcessingError.invalidSummary}}
            if block.type == .processFlow || block.type == .conceptMap {
                guard block.items.count>=2,let edges=block.edges,!edges.isEmpty,edges.count<=16 else {throw AIProcessingError.invalidSummary}
                for edge in edges {
                    guard block.items.indices.contains(edge.from),block.items.indices.contains(edge.to),edge.from != edge.to,edge.label.count<=80 else {throw AIProcessingError.invalidSummary}
                    try AISummaryBlock(id:block.id,kind:"inference",title:edge.label,tokens:[AISummaryToken(text:edge.label.isEmpty ? VL.text("Связь"):edge.label,speakerID:nil)],sourceSegments:edge.sourceSegments).validate(segments:segments,speakerIDs:speakerIDs,allowUnsourced:sourcePolicy == "none")
                }
            } else if !(block.edges ?? []).isEmpty {throw AIProcessingError.invalidSummary}
            guard !block.id.isEmpty,block.id.count<=80,!block.title.isEmpty,block.title.count<=160,(1...12).contains(block.items.count) else {throw AIProcessingError.invalidSummary}
            if block.type == .chart && [.donut,.distribution].contains(block.chartKind!) {
                let common=block.items.map {Set($0.sourceSegments)}.reduce(Set(segments.map(\.id))) {$0.intersection($1)}
                let total=block.items.reduce(0) {$0+($1.number ?? 0)}
                guard segments.contains(where:{segment in
                    (sourcePolicy == "none" || common.contains(segment.id)) && AIVisualNumbers.values(segment.text).contains(total) && ["всего","из них","распредел","доля","часть"].contains(where:{term in segment.text.localizedCaseInsensitiveContains(term)})
                }) else {throw AIProcessingError.invalidSummary}
            }
            for item in block.items {
                guard item.title.count<=240,item.tokens.count<=24,item.tokens.compactMap(\.text).joined().count<=1800 else {throw AIProcessingError.invalidSummary}
                let evidence=AISummaryBlock(id:block.id,kind:"fact",title:item.title,tokens:item.tokens,sourceSegments:item.sourceSegments)
                try evidence.validate(segments:segments,speakerIDs:speakerIDs,allowUnsourced:sourcePolicy == "none")
                if let value=item.value {
                    guard [.statistics,.comparison,.chart].contains(block.type),value.count<=80,!value.isEmpty,
                          value.contains(where:{$0.isNumber}),
                          segments.filter({sourcePolicy == "none" || item.sourceSegments.contains($0.id)}).contains(where:{$0.text.contains(value)}) else {throw AIProcessingError.invalidSummary}
                }
                let sources=segments.filter({sourcePolicy == "none" || item.sourceSegments.contains($0.id)})
                if let number=item.number {
                    guard number.isFinite,let literal=item.value,let unit=item.unit,
                          AIVisualNumbers.number(literal)==number,
                          sources.contains(where:{
                              let literalMatches = AIVisualNumbers.values($0.text).contains { abs($0-number) < 0.000001 }
                              let unitMatches = AIVisualNumbers.hasUnit(unit,in:literal) || (unit=="count" && AIVisualNumbers.hasUnit(unit,in:$0.text))
                              return literalMatches && unitMatches
                          }) else {throw AIProcessingError.invalidSummary}
                } else if item.unit != nil {throw AIProcessingError.invalidSummary}
                if let speaker=item.speakerID {guard (speakerIDs ?? Set(segments.compactMap(\.speakerID))).contains(speaker),sources.contains(where:{$0.speakerID==speaker}) else {throw AIProcessingError.invalidSummary}}
                for literal in [item.date,item.deadline].compactMap({$0}) {guard !literal.isEmpty,literal.count<=80,sources.contains(where:{$0.text.localizedCaseInsensitiveContains(literal)}) else {throw AIProcessingError.invalidSummary}}
                if block.type == .chart && block.chartKind == .line {guard item.date != nil else {throw AIProcessingError.invalidSummary}}
                if block.type == .chart && [.bar,.horizontal,.line].contains(block.chartKind!) {guard item.number!>=0 else {throw AIProcessingError.invalidSummary}}
                if block.type == .chart && [.donut,.distribution].contains(block.chartKind!) {guard item.number!>=0,block.items.reduce(0,{$0+($1.number ?? 0)})>0 else {throw AIProcessingError.invalidSummary}}
                if block.type == .quotes {
                    let quote=item.tokens.compactMap(\.text).joined()
                    guard !quote.isEmpty,item.tokens.allSatisfy({$0.speakerID==nil}),segments.filter({sourcePolicy == "none" || item.sourceSegments.contains($0.id)}).contains(where:{$0.text.contains(quote)}) else {throw AIProcessingError.invalidSummary}
                }
            }
        }
    }
}

struct AISummaryTemplate:Codable,Equatable,Identifiable {
    let id:String
    var title:String
    var prompt:String
    func validate()throws {guard !id.isEmpty,id.count<=80,!title.isEmpty,title.count<=120,!prompt.isEmpty,prompt.count<=6000 else {throw AIProcessingError.invalidRequest}}
    var displayTitle:String {Self.defaults.contains(where:{$0.id==id && $0.title==title}) ? VL.string(title):title}
    func localizedPrompt(in language:VectaLanguage)->String {
        Self.defaults.contains(where:{$0==self}) ? VL.string(prompt,in:language):prompt
    }
    static var defaults:[Self] {
        [("meeting","Совещание","Повестка, обсуждения, принятые решения, поручения, открытые вопросы."),
         ("interview","Интервью","Темы и вопросы интервью, позиции отвечающего, аргументы и выводы."),
         ("lecture","Лекция","Последовательность объяснения, понятия, примеры, аргументы и итог."),
         ("negotiation","Переговоры","Позиции сторон, предложения, согласованные условия и нерешённые вопросы."),
         ("brainstorm","Мозговой штурм","Проблема, предложенные идеи, аргументы, выбранные направления. Не выдавай идею за решение."),
         ("diary","Личный дневник","События, мысли, переживания и планы автора, без диагнозов и выдуманных событий."),
         ("technical","Техническое обсуждение","Проблема, ограничения, варианты, технические аргументы, решения и проверки.")].map {Self(id:$0.0,title:$0.1,prompt:$0.2)}
    }
}
struct AIWorkspace:Codable {
    var version=1
    var templates=AISummaryTemplate.defaults
    var tasks:[AILibraryTask]?=nil
    var deletedTaskIDs:[String]?=nil
    mutating func importTasks(_ summary:AIStructuredSummary,recordingID:String,requestID:UUID,conversationKey:String,speakers:AIRecordingSpeakers) {
        var values=tasks ?? []
        for item in summary.tasks {
            let normalized=item.description.lowercased().split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
            let id=SHA256.hash(data:Data((recordingID+"|"+normalized).utf8)).map{String(format:"%02x",$0)}.joined()
            guard !values.contains(where:{$0.id==id}),!(deletedTaskIDs ?? []).contains(id) else {continue}
            let owner=item.assignee.flatMap {name in speakers.identities.values.first(where:{$0.name==name})?.id}
            values.append(AILibraryTask(id:id,title:item.description,details:"",assignee:item.assignee,ownerSpeakerID:owner,deadline:item.deadline,status:"open",recordingID:recordingID,requestID:requestID,conversationKey:conversationKey,sourceSegments:item.sourceSegments,createdAt:Date(),manuallyEdited:false))
        }
        tasks=values
    }
    mutating func deleteTask(_ id:String) {tasks?.removeAll{$0.id==id};if !(deletedTaskIDs ?? []).contains(id) {deletedTaskIDs=(deletedTaskIDs ?? [])+[id]}}
}
struct AILibraryTask:Codable,Equatable,Identifiable {
    let id:String
    var title:String
    var details:String
    var assignee:String?
    var ownerSpeakerID:String?
    var deadline:String?
    var status:String
    let recordingID:String
    let requestID:UUID
    let conversationKey:String
    let sourceSegments:[Int]
    let createdAt:Date
    var manuallyEdited:Bool
}
struct AIWorkspaceStore {
    let root:URL
    var url:URL {root.appendingPathComponent("LocalAI/WorkspaceV1/catalog.json")}
    func load()throws->AIWorkspace {
        guard FileManager.default.fileExists(atPath:url.path) else{return AIWorkspace()}
        let flags=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]);guard flags.isRegularFile==true,flags.isSymbolicLink != true else {throw AIProcessingError.invalidRequest}
        let value=try JSONDecoder().decode(AIWorkspace.self,from:Data(contentsOf:url));try validate(value);return value
    }
    private func validate(_ value:AIWorkspace)throws {
        guard value.version==1,Set(value.templates.map(\.id)).count==value.templates.count,value.templates.count<=100 else {throw AIProcessingError.invalidRequest}
        for template in value.templates {try template.validate()}
        let tasks=value.tasks ?? []
        guard tasks.count<=10000,Set(tasks.map(\.id)).count==tasks.count,tasks.allSatisfy({!$0.title.isEmpty && $0.title.count<=3000 && $0.details.count<=6000 && ["open","done","cancelled"].contains($0.status)}) else {throw AIProcessingError.invalidRequest}
    }
    func save(_ value:AIWorkspace)throws {
        try validate(value);let dir=url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let flags=try dir.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard flags.isDirectory==true,flags.isSymbolicLink != true else {throw AIProcessingError.invalidRequest}
        if FileManager.default.fileExists(atPath:url.path),try url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink==true {throw AIProcessingError.invalidRequest}
        try JSONEncoder().encode(value).write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}

/// Token conjunction and partial Unicode matching. No morphology or external index.
enum AILocalTextSearch {
    static func matches(_ text:String,query:String)->Bool {
        let normalized=text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"ru_RU"))
        let words=query.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"ru_RU")).split(whereSeparator:{$0.isWhitespace})
        return !words.isEmpty && words.allSatisfy {normalized.contains($0)}
    }
}

/// Independent defaults for new post-sync jobs; legacy requests retain their behavior.
struct AIAutomaticSettings:Codable,Equatable {
    var model:AISummaryModelID = .qwen4b
    var visual:Bool = true
    var summaryRecipeID:String = "format:analytical"
    init(model:AISummaryModelID = .qwen4b,visual:Bool = true,summaryRecipeID:String = "format:analytical") {
        self.model=model;self.visual=visual;self.summaryRecipeID=summaryRecipeID
    }
    private enum CodingKeys:String,CodingKey {case model,visual,summaryRecipeID}
    init(from decoder:Decoder)throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        model=try values.decodeIfPresent(AISummaryModelID.self,forKey:.model) ?? .qwen4b
        visual=try values.decodeIfPresent(Bool.self,forKey:.visual) ?? true
        summaryRecipeID=try values.decodeIfPresent(String.self,forKey:.summaryRecipeID) ?? "format:analytical"
    }
    func validate()throws {guard AISummaryModelID.allCases.contains(model) else {throw AIProcessingError.invalidRequest}}
}

/// Accept completed speech across worker schema revisions without changing the
/// submitted request. Unreliable timing loses attribution, never spoken text.
enum AISpeechResultAcceptance {
    static func accept(_ response:AIProcessingResult,request expected:AIProcessingRequest,duration:Double)throws -> AIProcessingResult {
        try expected.validate()
        var echoed=response.request
        // Older speech workers do not know summary-only presentation metadata.
        // Supplied values still have to match; audio/job/format identity is exact.
        if echoed.summaryTemplate == nil {echoed.summaryTemplate=expected.summaryTemplate}
        if echoed.visualEnabled == nil {echoed.visualEnabled=expected.visualEnabled}
        if echoed.visualSummaryModel == nil {echoed.visualSummaryModel=expected.visualSummaryModel}
        guard echoed == expected,!expected.summaryOnly,response.error == nil,
              [.savingTranscript,.loadingSummary].contains(response.stage),
              duration.isFinite,duration>0,let measured=response.duration,abs(measured-duration)<0.001,
              response.summary == nil,response.semanticSummary == nil,response.visualSummary == nil else {throw AIProcessingError.invalidTranscript}
        if let progress=response.recognitionProgress {
            guard progress.completedChunks == progress.totalChunks,progress.processedSeconds == progress.totalSeconds else {throw AIProcessingError.invalidTranscript}
        }
        var value=response
        var untimed=[String](),segments=[AISpeechSegment]()
        let renumber=Set(value.segments.map(\.id)).count != value.segments.count || value.segments.contains {$0.id<0}
        for segment in value.segments {
            let text=segment.text.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !text.isEmpty else {continue}
            guard segment.start.isFinite,segment.end.isFinite,segment.start>=0,segment.end>=segment.start,segment.end<=duration+1 else {
                untimed.append(segment.text);continue
            }
            let speaker=segment.speaker.flatMap {$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil:$0}
            let speakerID=segment.speakerID.flatMap {$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil:$0}
            segments.append(AISpeechSegment(id:renumber ? segments.count:segment.id,start:segment.start,end:segment.end,speaker:speaker,text:segment.text,speakerID:speakerID))
        }
        let existingUntimed=value.unmatchedText?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        if !existingUntimed.isEmpty {untimed.insert(existingUntimed,at:0)}
        value.segments=segments
        let original=value.transcript?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        if original.isEmpty {value.transcript=(segments.map(\.text)+untimed).joined(separator:"\n")}
        guard let transcript=value.transcript,!transcript.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw AIProcessingError.invalidTranscript}
        value.unmatchedText=segments.isEmpty ? transcript:(untimed.isEmpty ? nil:untimed.joined(separator:"\n"))
        // Copy the exact host-owned snapshot into the new result, keeping every
        // additive response field. Historical request files are never rewritten.
        guard var payload=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as? [String:Any] else {throw AIProcessingError.invalidTranscript}
        payload["request"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(expected))
        let accepted=try JSONDecoder().decode(AIProcessingResult.self,from:JSONSerialization.data(withJSONObject:payload))
        try accepted.validate();return accepted
    }
}

/// Only literal numeric claims are accepted. No model-supplied arithmetic or coordinates.
enum AIVisualNumbers {
    static func number(_ text:String)->Double? {values(text).first}
    static func values(_ text:String)->[Double] {
        let expression=try! NSRegularExpression(pattern:"[-−]?[0-9]+(?:[ \u{00A0}\u{202F}][0-9]{3})*(?:[.,][0-9]+)?")
        let value=text as NSString
        return expression.matches(in:text,range:NSRange(location:0,length:value.length)).compactMap {match in
            let number=value.substring(with:match.range).replacingOccurrences(of:" ",with:"").replacingOccurrences(of:"\u{00A0}",with:"").replacingOccurrences(of:"\u{202F}",with:"").replacingOccurrences(of:"−",with:"-").replacingOccurrences(of:",",with:".")
            return Double(number)
        }
    }
    static func hasUnit(_ unit:String,in text:String)->Bool {
        let aliases:[String:[String]]=["RUB":["₽","руб"],"%": ["%","процент"],"count":["штук","участник","задач","запис","человек","вариант"],"min":["мин"],"sec":["сек"],"USD":["$","доллар"],"EUR":["€","евро"]]
        return aliases[unit]?.contains(where:{text.localizedCaseInsensitiveContains($0)}) ?? false
    }
}
/// Shared ordering/grouping plan for native screen and print; no generated coordinates.
enum AIVisualLayoutPlan {
    static func share(_ block:AIVisualBlock,in row:[AIVisualBlock])->Double {
        guard row.count==2 else {return 1}
        let compact=row.filter {$0.layout == .compact}.count
        return compact==1 ? (block.layout == .compact ? 0.34:0.66):0.5
    }
    static func rows(_ report:AIVisualSummary,wide:Bool)->[[AIVisualBlock]] {
        var rows=[[AIVisualBlock]](),pending=[AIVisualBlock]()
        for block in report.blocks {
            let full = !wide || (block.type == .hero && block.layout != .half) || [.chart,.processFlow,.conceptMap,.decisionMatrix].contains(block.type) || block.layout == .wide || report.layout == .chronological
            if full {if !pending.isEmpty {rows.append(pending);pending=[]};rows.append([block])}
            else {pending.append(block);if pending.count==2 {rows.append(pending);pending=[]}}
        }
        if !pending.isEmpty {rows.append(pending)}
        return rows
    }
}


/// Content-free event measurements. Never stores audio, prompts, names, or embeddings.
struct AIStageMeasurement:Codable,Equatable {
    let stage:String
    let model:String
    let inputBucket:Int
    let deviceMemoryGB:Int
    let seconds:Double
    let recordedAt:Date
}
struct AIWorkerEvent:Codable,Equatable {
    let phase:String
    let completed:Int
    let total:Int?
    let generatedTokens:Int
    let modelLoadSeconds:Double?
    /// Private local IPC only; not included in stage-measurement telemetry.
    var draftText:String? = nil
    var semanticDraft:AISemanticSummary? = nil
}
struct AIWorkProgress:Codable,Equatable {
    let stage:AIProcessingStage
    let fraction:Double
    let stageFraction:Double?
    let generatedTokens:Int?
    let remainingSeconds:Double?
    let weightedEstimate:Bool
    let updatedAt:Date
    var workerPhase:String?=nil
    var workerCompleted:Int?=nil
    var workerTotal:Int?=nil
}
/// Overall percentage counts completed stages and real, bounded stage units.
/// Unknown-length token generation is indeterminate; elapsed time is never progress.
struct AIProgressPlan {
    let stages:[AIProcessingStage]
    let weights:[Double]
    let calibrated:Bool
    init(result:AIProcessingResult,visualOnly:Bool=false,history:[AIStageMeasurement]=[],memoryGB:Int=Int(ProcessInfo.processInfo.physicalMemory/1_073_741_824)) {
        stages=visualOnly ? [.visualizing,.saving]:result.request.summaryOnly ? [.loadingSummary,.summarizing]+(result.request.wantsVisual ? [.visualizing]:[])+[.saving]:[.preparingAudio,.loadingRecognition,.recognizing,.diarizing,.aligning,.savingTranscript,.loadingSummary,.summarizing]+(result.request.wantsVisual ? [.visualizing]:[])+[.saving]
        let duration=max(1,result.duration ?? 60),characters=max(200,result.segments.isEmpty ? Int(duration*15):result.segments.reduce(0){$0+$1.text.count})
        var values=[Double](),known=true
        for stage in stages {
            let model=Self.model(stage,result:result),bucket=Self.bucket(stage,result:result)
            let samples=history.filter {$0.stage==stage.rawValue && $0.model==model && $0.inputBucket==bucket && $0.deviceMemoryGB==memoryGB && $0.seconds.isFinite && $0.seconds>0}.suffix(8).map(\.seconds).sorted()
            if samples.count>=3 {values.append(samples[samples.count/2])}
            else {
                // Fast persistence/alignment stages may complete between host polls.
                // Their small approximate overhead must not permanently disable ETA.
                if [.loadingRecognition,.recognizing,.diarizing,.loadingSummary,.summarizing,.visualizing].contains(stage) {known=false}
                switch stage {
                case .recognizing:values.append(duration*0.12)
                case .diarizing:values.append(duration*0.07)
                case .summarizing:values.append(Double(characters)/200*(model=="qwen9b" ? 2:1))
                case .visualizing:values.append(Double(characters)/400+20)
                case .loadingRecognition,.loadingSummary:values.append(4)
                default:values.append(1)
                }
            }
        }
        weights=values;calibrated=known
    }
    static func model(_ stage:AIProcessingStage,result:AIProcessingResult)->String {
        switch stage {case .loadingSummary,.summarizing:return result.request.selectedSummaryModel.rawValue;case .visualizing:return result.visualModel ?? result.request.selectedVisualModel.rawValue;case .diarizing:return "speaker";default:return "whisper"}
    }
    static func bucket(_ stage:AIProcessingStage,result:AIProcessingResult)->Int {
        let size:[Double]=[60,600,1800,3600,7200,14400,21600]
        let input=[AIProcessingStage.summarizing,.visualizing,.loadingSummary].contains(stage) ? Double(result.segments.reduce(0){$0+$1.text.count})/15:result.duration ?? 60
        return size.firstIndex(where:{input<=$0}) ?? size.count
    }
    func snapshot(_ result:AIProcessingResult,event:AIWorkerEvent?=nil,previous:AIWorkProgress?=nil,now:Date=Date(),stageStartedAt:Date?=nil)->AIWorkProgress {
        let index=stages.firstIndex(of:result.stage)
        var units:Double?=nil
        if result.stage == .recognizing,let p=result.recognitionProgress,p.totalSeconds>0 {units=min(1,max(0,p.processedSeconds/p.totalSeconds))}
        if result.stage == .diarizing,event?.phase=="diarization",let total=event?.total,total>0,let completed=event?.completed {units=min(1,max(0,Double(completed)/Double(total)))}
        if result.stage == .summarizing,let p=result.summaryProgress {
            if let fraction=p.fraction {units=min(1,max(0,fraction))}
            else if p.phase=="facts",p.total>0 {units=min(0.55,Double(p.completed)/Double(p.total)*0.55)}
            else if p.phase=="reduce" {units=0.55}
            else if p.phase=="final" {units=0.9}
            else if p.phase=="complete" {units=1}
        }
        let completed=index.map {weights.prefix($0).reduce(0,+)} ?? 0
        let current=index.map {weights[$0]*(units ?? 0)} ?? 0
        let calculated=(completed+current)/max(1,weights.reduce(0,+))
        // A terminal pipeline is finished even when optional visual generation failed.
        // The visual error remains separate; 100% does not assert successful AI quality.
        let success=result.stage == .completed
        let fraction=success ? 1:min(0.99,max(previous?.fraction ?? 0,calculated))
        // Remaining-time prediction is deliberately disabled; stage measurements
        // still inform the relative work weights. No clock-driven progress.
        let eta:Double?=nil
        return AIWorkProgress(stage:result.stage,fraction:fraction,stageFraction:units,generatedTokens:event?.generatedTokens,remainingSeconds:eta,weightedEstimate:!calibrated,updatedAt:now,workerPhase:result.stage == .summarizing ? (result.summaryProgress?.phase ?? event?.phase):event?.phase,workerCompleted:event?.completed,workerTotal:event?.total)
    }
}

/// Suppresses only literal visual repetition. Does not guess semantic equivalence.
enum AIVisualEditorial {
    /// Presentation-only consolidation. Different roles and numeric claims stay
    /// separate; equal headings retain every distinct literal paragraph.
    static func refined(_ report: AIVisualSummary) -> AIVisualSummary {
        func key(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let metadata: Set<String> = ["speakerid", "speaker_id", "sourcesegments", "source_segments", "tokens", "schemaversion", "text", "speaker", "null"]
        var output = [AIVisualBlock](), positions = [String: Int]()
        for block in report.blocks {
            let items = block.items.filter { item in
                let text = key(item.tokens.map { $0.text ?? $0.speakerID ?? "" }.joined())
                return !text.isEmpty && !metadata.contains(text)
            }
            guard !items.isEmpty else { continue }
            let heading = key(block.title) + "|" + (block.role?.rawValue ?? "fact")
            let graph = block.edges != nil || [.chart, .processFlow, .conceptMap].contains(block.type)
            if !graph, let index = positions[heading], output[index].type != .statistics, block.type != .statistics, output[index].items.count + items.count <= 12 {
                let previous = output[index]
                var unique = previous.items
                for item in items where !unique.contains(where: {
                    key($0.tokens.map { $0.text ?? $0.speakerID ?? "" }.joined()) == key(item.tokens.map { $0.text ?? $0.speakerID ?? "" }.joined()) &&
                    $0.value == item.value && $0.speakerID == item.speakerID && $0.date == item.date && $0.deadline == item.deadline
                }) { unique.append(item) }
                output[index] = AIVisualBlock(id: previous.id, type: previous.type, title: previous.title, items: unique,
                    layout: previous.layout, role: previous.role, chartKind: previous.chartKind, edges: previous.edges)
            } else {
                positions[heading] = output.count
                output.append(AIVisualBlock(id: block.id, type: block.type, title: block.title, items: items,
                    layout: block.layout, role: block.role, chartKind: block.chartKind, edges: block.edges))
            }
        }
        if output.first?.type == .hero {
            let first=output[0]
            output[0]=AIVisualBlock(id:first.id,type:first.type,title:first.title,items:first.items,layout:output.count>1 ? .half:.wide,role:first.role,chartKind:first.chartKind,edges:first.edges)
            if output.count>1,output[1].items.map({$0.tokens.compactMap(\.text).joined()}).joined().count<240 {
                let side=output[1]
                output[1]=AIVisualBlock(id:side.id,type:side.type,title:side.title,items:side.items,layout:.compact,role:side.role,chartKind:side.chartKind,edges:side.edges)
            }
        }
        let result = AIVisualSummary(schemaVersion: report.schemaVersion, title: report.title, theme: report.theme, blocks: output,
            subtitle: report.subtitle, category: report.category, layout: report.layout, nativeStyle: report.nativeStyle, sourcePolicy: report.sourcePolicy)
        return result
    }
    static func preview(_ text:String)->(main:String,detail:String?) {
        guard text.count>380,let boundary=text.range(of:"[.!?]\\s+(?=[А-ЯA-Z])",options:.regularExpression) else {return (text,nil)}
        let main=String(text[..<boundary.upperBound]).trimmingCharacters(in:.whitespacesAndNewlines)
        let detail=String(text[boundary.upperBound...])
        guard main.count>=60,detail.count>=60 else {return (text,nil)}
        return (main,detail)
    }
    static func narrative(_ text:String)->(main:String,detail:String?) {
        // A literal final sentence can be a supporting row, never a new claim.
        guard text.count>140,let range=text.range(of:"[.!?]\\s+(?=[А-ЯA-Z])",options:[.regularExpression,.backwards]) else {return (text,nil)}
        let detail=String(text[range.upperBound...])
        guard detail.count>=45,detail.count<=220 else {return (text,nil)}
        let main=String(text[..<range.upperBound]).trimmingCharacters(in:.whitespacesAndNewlines)
        return (main,detail)
    }
    static func normalized(_ text:String)->String {
        text.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber}).joined(separator:" ")
    }
    static func caption(_ text:String,title:String)->String? {
        normalized(text)==normalized(title) ? nil:text
    }
}


/// Versioned content, independent of SwiftUI and of the compact visual analysis.
struct AIFullTextParagraph:Codable,Equatable,Identifiable {
    let id:String
    let heading:String?
    let tokens:[AISummaryToken]
    let sourceSegments:[Int]
}
struct AIFullTextSummary:Codable,Equatable {
    let schemaVersion:Int
    let paragraphs:[AIFullTextParagraph]
    static func preserving(_ summary:AIStructuredSummary)->Self {
        var parts=[AIFullTextParagraph]()
        func add(_ id:String,_ heading:String?,_ text:String,_ sources:[Int]=[]) {
            if !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {parts.append(.init(id:id,heading:heading,tokens:[AISummaryToken(text:text,speakerID:nil)],sourceSegments:sources))}
        }
        let bodyParts=AITextDocument(summary.summary).parts
        var bodyTokens=[AISummaryToken]()
        for (index,part) in bodyParts.enumerated() {
            if index>0 {bodyTokens.append(.init(text:"\n\n",speakerID:nil))}
            bodyTokens.append(.init(text:part.markdown,speakerID:nil,isVerbatim:part.kind == .quote || part.kind == .code ? true:nil))
        }
        if !bodyTokens.isEmpty {parts.append(.init(id:"full",heading:nil,tokens:bodyTokens,sourceSegments:[]))}
        if summary.textRepresentation == "plain" {return Self(schemaVersion:1,paragraphs:parts)}
        for (index,block) in (summary.blocks ?? []).enumerated() {
            // Stable references and literal anonymous labels resolve at display time.
            parts.append(.init(id:"block-\(index)",heading:block.title,tokens:block.tokens,sourceSegments:block.sourceSegments))
        }
        if !summary.topics.isEmpty {add("topics",VL.text("Темы"),summary.topics.enumerated().map {"\($0.offset+1). \($0.element)"}.joined(separator:"\n"))}
        if !summary.decisions.isEmpty {add("decisions",VL.text("Решения"),summary.decisions.map {"• "+$0}.joined(separator:"\n"))}
        for (index,task) in summary.tasks.enumerated() {
            var text="• "+task.description
            if let name=task.assignee {text += VL.text("\nОтветственный: ")+name}
            if let deadline=task.deadline {text += VL.text("\nСрок: ")+deadline}
            add("task-\(index)",index==0 ? VL.text("Поручения"):nil,text,task.sourceSegments)
        }
        if !summary.uncertainties.isEmpty {add("uncertainties",VL.text("Открытые вопросы"),summary.uncertainties.map {"• "+$0}.joined(separator:"\n"))}
        return Self(schemaVersion:1,paragraphs:parts)
    }
    func rendered(speakers:AIRecordingSpeakers)->String {
        paragraphs.map {part in [part.heading.map(speakers.resolveText),speakers.render(part.tokens)].compactMap {$0}.filter {!$0.isEmpty}.joined(separator:"\n")}.joined(separator:"\n\n")
    }
}
extension AIProcessingResult {
    var completeTextSummary:AIFullTextSummary? {fullTextSummary ?? summary.map(AIFullTextSummary.preserving)}
}

/// Meaning only: the model never sees the renderer registry or layout styles.
enum AISemanticKind:String,Codable,CaseIterable {
    case insight,decision,task,metric,event,participant,quote,comparison,risk,question,process,conclusion
    var blockType:AIVisualBlockType {
        switch self {case .insight:return .keyPoints;case .decision:return .decisions;case .task:return .tasks;case .metric:return .statistics;case .event:return .timeline;case .participant:return .keyPoints;case .quote:return .quotes;case .comparison:return .comparison;case .risk:return .risks;case .question:return .openQuestions;case .process:return .timeline;case .conclusion:return .takeaway}
    }
    var title:String {
        switch self {case .insight:return VL.text("Главные мысли");case .decision:return VL.text("Решения");case .task:return VL.text("Поручения");case .metric:return VL.text("В цифрах");case .event:return VL.text("Ход обсуждения");case .participant:return VL.text("Участники");case .quote:return VL.text("Прямая речь");case .comparison:return VL.text("Сравнение");case .risk:return VL.text("Риски");case .question:return VL.text("Открытые вопросы");case .process:return VL.text("Этапы");case .conclusion:return VL.text("Итог")}
    }
}
struct AISemanticEntry:Codable,Equatable,Identifiable {
    let id:String
    let kind:AISemanticKind
    let title:String
    let tokens:[AISummaryToken]
    let sourceSegments:[Int]
    var role:AIVisualRole?=nil
    var value:String?=nil
    var number:Double?=nil
    var unit:String?=nil
    var speakerID:String?=nil
    var date:String?=nil
    var deadline:String?=nil
    var item:AIVisualItem {.init(title:title,tokens:tokens,sourceSegments:sourceSegments,value:value,number:number,unit:unit,speakerID:speakerID,date:date,deadline:deadline)}
}
/// Syntax repair at the model boundary. Strings and escaped punctuation stay literal.
/// No missing text, numbers, identities or evidence are synthesized.
enum AISemanticModelJSON {
    /// Last-resort extraction keeps literal model text, including an unfinished
    /// final string. It does not complete words or expose JSON/metadata as prose.
    static func readableFragments(_ input:String)->[[String:Any]] {
        let chars=Array(input);var index=0,rows=[[String:Any]](),heading:String?
        let content:Set<String>=["text","body","content","description","summary"]
        func readString(_ start:Int)->(String,Int) {
            var end=start+1,escaped=false
            while end<chars.count {
                let c=chars[end]
                if !escaped && c=="\"" {break}
                if escaped {escaped=false} else if c=="\\" {escaped=true}
                end+=1
            }
            var literal=String(chars[start..<min(end+1,chars.count)])
            if end==chars.count {
                // Discard an unfinished escape, retaining the preceding text.
                if escaped {literal.removeLast()}
                literal += "\""
            }
            literal=literal.replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r").replacingOccurrences(of:"\t",with:"\\t")
            let decoded=(try? JSONSerialization.jsonObject(with:Data(literal.utf8),options:.fragmentsAllowed)) as? String
            return (decoded ?? "",min(end+1,chars.count))
        }
        while index<chars.count,rows.count<64 {
            guard chars[index]=="\"" else {index+=1;continue}
            let (key,next)=readString(index);index=next
            while index<chars.count && chars[index].isWhitespace {index+=1}
            guard index<chars.count,chars[index]==":" else {continue}
            index+=1
            while index<chars.count && chars[index].isWhitespace {index+=1}
            guard index<chars.count,chars[index]=="\"" else {continue}
            let (value,end)=readString(index);index=end
            let text=value.trimmingCharacters(in:.whitespacesAndNewlines)
            if ["title","heading","label"].contains(key),!text.isEmpty {heading=text}
            if content.contains(key),!text.isEmpty {
                rows.append(["title":heading ?? "Содержание ответа","text":text,"role":"interpretation"]);heading=nil
            }
        }
        return rows
    }
    private static func fallback(_ text:String)throws->Any {
        let fragments=readableFragments(text)
        guard !fragments.isEmpty else {throw AIProcessingError.invalidSummary}
        return ["title":"Обзор записи","entries":fragments] as [String:Any]
    }
    static func recover(_ input:String)throws->Any {
        var text=input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,text.utf8.count<=256000 else {throw AIProcessingError.invalidSummary}
        text=text.replacingOccurrences(of:"^```(?:json)?\\s*",with:"",options:.regularExpression)
        text=text.replacingOccurrences(of:"\\s*```$",with:"",options:.regularExpression)
        if let data=text.data(using:.utf8),let object=try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed),!(object is String) {return object}
        if let start=text.firstIndex(where:{$0=="{" || $0=="["}) {
            text=String(text[start...])
            // Outside a JSON string, a trailing comma is presentation noise.
            let chars=Array(text);var output="",stack=[Character](),quoted=false,escaped=false,complete:String?
            for i in chars.indices {
                let char=chars[i]
                if quoted {
                    output.append(char)
                    if escaped {escaped=false} else if char=="\\" {escaped=true} else if char=="\"" {quoted=false}
                    continue
                }
                if char=="\"" {quoted=true;output.append(char);continue}
                if char=="," {
                    let next=chars[(i+1)...].first(where:{!$0.isWhitespace})
                    if next=="}" || next=="]" {continue}
                }
                if char=="{" || char=="[" {stack.append(char)}
                if char=="}" || char=="]" {
                    guard stack.last == (char=="}" ? "{":"[") else {return try fallback(text)}
                    stack.removeLast()
                }
                output.append(char)
                if stack.isEmpty {complete=output;break}
            }
            // Missing closing brackets can be reconstructed only outside strings.
            guard !quoted else {return try fallback(text)}
            if complete==nil {output += stack.reversed().map {$0=="{" ? "}":"]"}.joined()}
            guard let data=(complete ?? output).data(using:.utf8),let object=try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed) else {return try fallback(text)}
            return object
        }
        // Plain prose is still usable model content, explicitly labelled as interpretation.
        return ["title":"Обзор записи","entries":[["title":"Содержание ответа","text":text,"kind":"insight","role":"interpretation"]]] as [String:Any]
    }
}
struct AISemanticSummary:Codable,Equatable {
    let schemaVersion:Int
    let title:String
    let entries:[AISemanticEntry]
    var subtitle:String?=nil
    var sourcePolicy:String?=nil
    static func decodeValidated(_ data:Data,segments:[AISpeechSegment])throws->Self {
        guard data.count<=256000,let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(object.keys).isSubset(of:["schemaVersion","title","entries","subtitle","sourcePolicy"]),Set(["schemaVersion","title","entries"]).isSubset(of:Set(object.keys)),let entries=object["entries"] as? [[String:Any]],entries.count<=64 else {throw AIProcessingError.invalidSummary}
        let allowed:Set<String>=["id","kind","title","tokens","sourceSegments","role","value","number","unit","speakerID","date","deadline"]
        var normalized=object,normalizedEntries=[[String:Any]]()
        for entry in entries {
            guard Set(entry.keys).isSubset(of:allowed),let tokens=entry["tokens"] as? [[String:Any]] else {throw AIProcessingError.invalidSummary}
            for token in tokens {
                guard Set(token.keys).isSubset(of:["type","text","speakerID"]),
                      (token["text"] as? String != nil) != (token["speakerID"] as? String != nil),
                      token["type"] == nil || (token["type"] as? String == (token["text"] == nil ? "speaker":"text")) else {throw AIProcessingError.invalidSummary}
            }
            var copy=entry
            // Empty optional metadata is absence, never evidence of a fact.
            // Required content and non-empty invalid claims remain errors.
            for key in ["value","speakerID","date","deadline"] where (copy[key] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == true {copy.removeValue(forKey:key)}
            normalizedEntries.append(copy)
        }
        normalized["entries"]=normalizedEntries
        let value=try JSONDecoder().decode(Self.self,from:JSONSerialization.data(withJSONObject:normalized));try value.validate(segments:segments);return value
    }
    /// Recovery is confined to the model boundary; persisted schemas stay strict.
    /// Repairs formatting, never verifies the truth of prose generated by a model.
    static func decodeModelResponse(_ data:Data,segments:[AISpeechSegment],fallbackText:String?=nil)throws->Self {
        do {return try decodeRecoveredModelResponse(data,segments:segments)}
        catch AIProcessingError.invalidSummary {
            guard let fallbackText,!fallbackText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw AIProcessingError.invalidSummary}
            let object:[String:Any]=["title":"Обзор записи","subtitle":"Обзор из текстового саммари","entries":[["title":"Главное из записи","text":fallbackText,"role":"interpretation"]]]
            return try decodeRecoveredModelResponse(JSONSerialization.data(withJSONObject:object),segments:segments)
        }
    }
    private static func decodeRecoveredModelResponse(_ data:Data,segments:[AISpeechSegment])throws->Self {
        guard data.count<=256000 else {throw AIProcessingError.invalidSummary}
        var raw=(try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)) ?? (String(data:data,encoding:.utf8) ?? "")
        if let envelope=raw as? [String:Any],let text=envelope["modelResponse"] as? String {raw=text}
        if let text=raw as? String {raw=try AISemanticModelJSON.recover(text)}
        if let list=raw as? [Any] {raw=["entries":list]}
        guard var root=raw as? [String:Any] else {throw AIProcessingError.invalidSummary}
        for key in ["semantic","summary","report"] {
            if let nested=root[key] as? [String:Any] {root=nested;break}
            if let text=root[key] as? String {
                if let nested=try AISemanticModelJSON.recover(text) as? [String:Any] {root=nested;break}
            }
        }
        func string(_ object:[String:Any],_ keys:[String])->String? {
            for key in keys {if let text=object[key] as? String,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {return text.trimmingCharacters(in:.whitespacesAndNewlines)}}
            return nil
        }
        var rows:[[String:Any]]=[]
        for key in ["entries","cards","blocks","sections"] {
            if let list=root[key] as? [Any] {
                for value in list {
                    if let text=value as? String {rows.append(["text":text])}
                    else if let card=value as? [String:Any] {
                        if let items=card["items"] as? [[String:Any]],!items.isEmpty {
                            for item in items {var merged=card;merged.removeValue(forKey:"items");merged.merge(item,uniquingKeysWith:{$1});rows.append(merged)}
                        } else {rows.append(card)}
                    } // Skip unusable members, preserving neighbouring cards.
                }
                break
            }
        }
        if rows.isEmpty,let text=string(root,["text","body","content","description"]) {rows=[["text":text,"title":string(root,["title","heading"]) ?? "Обзор записи","role":"interpretation"]]}
        if rows.isEmpty {
            // Unknown envelopes can still contain recognizable content fields.
            rows=AISemanticModelJSON.readableFragments(String(data:data,encoding:.utf8) ?? "")
        }
        guard !rows.isEmpty else {throw AIProcessingError.invalidSummary}
        rows=Array(rows.prefix(64))
        let speakerIDs=Set(segments.compactMap(\.speakerID))
        let aliases=["keyPoints":"insight","key_points":"insight","fact":"insight","takeaway":"conclusion","statistics":"metric","timeline":"event","decisions":"decision","tasks":"task","risks":"risk","openQuestions":"question","quotes":"quote"]
        var output=[AISemanticEntry]()
        for (index,row) in rows.enumerated() {
            let rawKind=string(row,["kind","type"]) ?? "insight"
            var kind=AISemanticKind(rawValue:aliases[rawKind] ?? rawKind) ?? .insight
            let rawRole=string(row,["role"])
            if rawRole == "question",kind == .insight {kind = .question}
            let roleAliases=["inference":"interpretation","assumption":"hypothesis","proposal":"position","opinion":"position","question":"hypothesis"]
            let role=rawRole.map {AIVisualRole(rawValue:roleAliases[$0] ?? $0) ?? .hypothesis} ?? (AISemanticKind(rawValue:aliases[rawKind] ?? rawKind) == nil ? .hypothesis:.fact)
            var tokens=[AISummaryToken]()
            if let list=row["tokens"] as? [Any] {
                for token in list {
                    if let text=token as? String {tokens.append(.init(text:text,speakerID:nil))}
                    else if let object=token as? [String:Any] {
                        if let text=(object["text"] as? String) ?? (object["content"] as? String),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {tokens.append(.init(text:text,speakerID:nil))}
                        else if let id=string(object,["speakerID","speaker_id"]) {tokens.append(speakerIDs.contains(id) ? .init(text:nil,speakerID:id):.init(text:"Участник",speakerID:nil))}
                    } // Invalid tokens cannot poison readable text tokens.
                }
            } else if let text=string(row,["text","body","content","description","summary"]) {tokens=[.init(text:text,speakerID:nil)]}
            else if let bullets=row["bullets"] as? [String] {tokens=[.init(text:bullets.map {"• "+$0}.joined(separator:"\n"),speakerID:nil)]}
            // Adjacent complete sentences need separation; preserve deliberate
            // whitespace and fragments, including spaces around rename tokens.
            for i in tokens.indices where i>0 {
                guard let text=tokens[i].text,let first=text.first,!first.isWhitespace else {continue}
                let previous=tokens[i-1]
                let sentenceEnd=previous.text?.last.map {".!?…".contains($0)} ?? false
                if first.isLetter && (sentenceEnd || previous.speakerID != nil || previous.text == "Участник") {tokens[i] = .init(text:" "+text,speakerID:nil)}
            }
            let title=string(row,["title","heading","label"]) ?? kind.title
            if tokens.isEmpty,let text=string(row,["text","body","content","description","summary"]) {tokens=[.init(text:text,speakerID:nil)]}
            if tokens.isEmpty {
                guard let heading=string(row,["title","heading","label"]) else {continue}
                tokens=[.init(text:heading,speakerID:nil)]
            }
            if tokens.count == 1,
               let stub=tokens[0].text?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased(),
               ["speakerid","speaker_id","text","speaker","null","sourcesegments","tokens"].contains(stub) {continue}
            // Long content becomes continuation cards rather than being discarded.
            if title.count>160 {tokens.insert(.init(text:title+"\n",speakerID:nil),at:0)}
            var groups=[[AISummaryToken]](),group=[AISummaryToken](),length=0
            for token in tokens {
                if let text=token.text {
                    var rest=text[...]
                    while !rest.isEmpty {
                        if length>=1500 || group.count>=20 {groups.append(group);group=[];length=0}
                        let part=String(rest.prefix(1500-length));rest=rest.dropFirst(part.count)
                        group.append(.init(text:part,speakerID:nil));length+=part.count
                    }
                } else {
                    if group.count>=20 {groups.append(group);group=[];length=0}
                    group.append(token)
                }
            }
            if !group.isEmpty {groups.append(group)}
            for (part,tokens) in groups.enumerated() {
                guard output.count<64 else {break}
                var entry=AISemanticEntry(id:"model-\(index)-\(part)",kind:kind,title:String(title.prefix(160)),tokens:tokens,sourceSegments:[],role:role)
                let body=tokens.compactMap(\.text).joined()
                if entry.kind == .quote && !segments.contains(where:{$0.text.contains(body)}) {entry=AISemanticEntry(id:entry.id,kind:.insight,title:entry.title,tokens:tokens,sourceSegments:[],role:.interpretation)}
                if part==0 {
                    if let value=string(row,["value"]),value.count<=80,value.contains(where:{$0.isNumber}),[AISemanticKind.metric,.comparison].contains(entry.kind),segments.contains(where:{$0.text.contains(value)}) {entry.value=value}
                    if entry.value != nil,let unit=string(row,["unit"]),let number=(row["number"] as? NSNumber)?.doubleValue ?? (row["number"] as? String).flatMap({AIVisualNumbers.number($0)}),number.isFinite {
                        var candidate=entry;candidate.number=number;candidate.unit=unit
                        if (try? Self(schemaVersion:1,title:"Обзор",entries:[candidate],sourcePolicy:"none").validate(segments:segments)) != nil {entry=candidate}
                    }
                    if let id=string(row,["speakerID","speaker_id"]),speakerIDs.contains(id) {entry.speakerID=id}
                    for key in ["date","deadline"] {if let value=string(row,[key]),value.count<=80,segments.contains(where:{$0.text.localizedCaseInsensitiveContains(value)}) {if key=="date" {entry.date=value} else {entry.deadline=value}}}
                }
                if entry.kind == .metric && entry.value == nil {entry=AISemanticEntry(id:entry.id,kind:.insight,title:entry.title,tokens:tokens,sourceSegments:[],role:.interpretation)}
                output.append(entry)
            }
        }
        let heading=string(root,["title","heading","name"]) ?? "Обзор записи"
        let subtitle=string(root,["subtitle","description"])
        let result=Self(schemaVersion:1,title:String(heading.prefix(160)),entries:output,subtitle:subtitle.map {String($0.prefix(400))},sourcePolicy:"none")
        try result.validate(segments:segments)
        return result
    }
    func validate(segments:[AISpeechSegment],speakerIDs:Set<String>?=nil)throws {
        guard (sourcePolicy == nil || sourcePolicy == "none"),schemaVersion==1,!title.isEmpty,title.count<=160,(subtitle?.count ?? 0)<=400,(1...64).contains(entries.count),Set(entries.map(\.id)).count==entries.count else {throw AIProcessingError.invalidSummary}
        for entry in entries {
            let block=AIVisualBlock(id:entry.id,type:entry.kind.blockType,title:entry.title,items:[entry.item])
            try AIVisualSummary(schemaVersion:1,title:title,theme:"editorial",blocks:[block],sourcePolicy:sourcePolicy).validate(segments:segments,speakerIDs:speakerIDs ?? Set(segments.compactMap(\.resolvedSpeakerID)))
        }
    }
    var withoutSourceLinks:Self {
        Self(schemaVersion:schemaVersion,title:title,entries:entries.map {
            AISemanticEntry(id:$0.id,kind:$0.kind,title:$0.title,tokens:$0.tokens,sourceSegments:[],role:$0.role,value:$0.value,number:$0.number,unit:$0.unit,speakerID:$0.speakerID,date:$0.date,deadline:$0.deadline)
        },subtitle:subtitle,sourcePolicy:"none")
    }
    /// Exact content duplicates only. Semantic similarity is not asserted.
    var deduplicatedEntries:[AISemanticEntry] {
        var positions=[String:Int](),output=[AISemanticEntry]()
        for entry in entries {
            let key=entry.tokens.map {($0.text ?? "")+($0.speakerID ?? "")}.joined().folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"ru_RU"))+"|"+(entry.value ?? "")+"|"+(entry.speakerID ?? "")+"|"+(entry.deadline ?? "")+"|"+(entry.date ?? "")+"|"+entry.kind.rawValue+"|"+(entry.role?.rawValue ?? "fact")
            if let index=positions[key] {
                let previous=output[index]
                output[index]=AISemanticEntry(id:previous.id,kind:previous.kind,title:previous.title,tokens:previous.tokens,sourceSegments:Array(Set(previous.sourceSegments+entry.sourceSegments)).sorted(),role:previous.role,value:previous.value,number:previous.number,unit:previous.unit,speakerID:previous.speakerID,date:previous.date,deadline:previous.deadline)
            } else {positions[key]=output.count;output.append(entry)}
        }
        return output
    }

    func visual(style:AIVisualStyle)->AIVisualSummary {
        let source=deduplicatedEntries
        // Unexpected but readable families still need a dominant opening card.
        // Projection changes presentation only; the semantic kind stays intact.
        let lead=source.first(where: {$0.kind == .insight || $0.kind == .decision}) ?? source.first(where:{$0.kind != .metric}) ?? source.first
        let featuredMetric=source.first(where: {$0.id != lead?.id && $0.kind == .metric && $0.value != nil})
        let featuredStatus=featuredMetric == nil ? source.first(where: {$0.id != lead?.id && ($0.kind == .conclusion || $0.kind == .decision || $0.kind == .question)}):nil
        // A report with no metrics or accepted verdict can still highlight a
        // second source-backed proposal, without turning it into a decision.
        let featured=featuredMetric ?? featuredStatus ?? source.first(where: {$0.kind == .insight && $0.id != lead?.id})
        let compactStyle=style == .minimal || style == .presentation
        var blocks=[AIVisualBlock]()
        if let lead {
            blocks.append(.init(id:"hero",type:lead.kind == .metric ? .statistics:.hero,title:lead.title,items:[lead.item],layout:featured == nil || compactStyle ? .wide:.half,role:lead.role ?? .fact))
            if let featured {
                blocks.append(.init(id:"featured-side",type:featured.kind.blockType,title:featured.title,items:[featured.item],layout:compactStyle || featured.tokens.compactMap(\.text).joined().count>700 ? .wide:(featured.value != nil || featured.tokens.compactMap(\.text).joined().count<240 ? .compact:.half),role:featured.role ?? .fact))
            }
        }
        let promoted=Set([lead?.id,lead == nil ? nil:featured?.id].compactMap {$0})
        for kind in AISemanticKind.allCases {
            for role in [AIVisualRole.fact,.position,.interpretation,.hypothesis] {
                let entries=source.filter {$0.kind==kind && ($0.role ?? .fact)==role && !promoted.contains($0.id)}
                var offset=0
                while offset<entries.count {
                    var end=offset+1,characters=entries[offset].tokens.compactMap(\.text).joined().count
                    while ![AISemanticKind.insight,.task,.decision,.risk,.question].contains(kind),end<entries.count,end-offset<3 {
                        let next=entries[end].tokens.compactMap(\.text).joined().count
                        if characters+next>950 {break}
                        characters+=next;end+=1
                    }
                    let slice=Array(entries[offset..<end])
                    defer {offset=end}
                    let long=slice.reduce(0) {$0+$1.tokens.compactMap(\.text).joined().count}>1100
                    let size:AIVisualSize = compactStyle || long || kind == .conclusion ? .wide:.half
                    let heading=slice.count == 1 ? (slice.first?.title ?? kind.title):kind.title
                    blocks.append(.init(id:"\(kind.rawValue)-\(role.rawValue)-\(offset)",type:kind.blockType,title:heading,items:slice.map(\.item),layout:size,role:role))
                }
            }
        }
        return AIVisualEditorial.refined(AIVisualSummary(schemaVersion:3,title:title,theme:"editorial",blocks:blocks,subtitle:subtitle,category:"Обзор записи",layout:style == .dashboard ? .bento:.editorial,nativeStyle:style,sourcePolicy:sourcePolicy))
    }
}
enum AIVisualStyle:String,Codable,CaseIterable {
    case editorial,dashboard,minimal,presentation
    var title:String {rawValue.prefix(1).uppercased()+rawValue.dropFirst()}
}

/// Removes only recognized Markdown presentation syntax, retaining all content.
enum AIExportText {
    /// Keep the library name verbatim except filesystem-invalid characters and
    /// path traversal. Bound UTF-8 bytes without splitting a Unicode character.
    static func filename(title:String,pdf:Bool)->String {
        let safe=title.unicodeScalars.map { scalar -> String in
            if scalar == "/" || scalar == ":" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            return String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var stem=""
        for character in safe {
            guard stem.utf8.count + String(character).utf8.count <= 240 else { break }
            stem.append(character)
        }
        if stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { stem=VL.text("Запись") }
        return stem + (pdf ? ".pdf" : ".txt")
    }

    static func plain(_ text:String)->String {
        var value=text.replacingOccurrences(of:"(?m)^#{1,6} +",with:"",options:.regularExpression)
        value=value.replacingOccurrences(of:"\\*\\*([^\\n]+?)\\*\\*",with:"$1",options:.regularExpression)
        value=value.replacingOccurrences(of:"(?m)^[-*] +",with:"• ",options:.regularExpression)
        value=value.replacingOccurrences(of:"(?m)^> ?",with:"",options:.regularExpression)
        value=value.replacingOccurrences(of:"\\[([^\\]]+)\\]\\([^)]*\\)",with:"$1",options:.regularExpression)
        value=value.replacingOccurrences(of:"(?m)^```[^\\n]*$",with:"",options:.regularExpression)
        value=value.replacingOccurrences(of:"`([^`]+)`",with:"$1",options:.regularExpression)
        return value
    }
}

/// Declarative native capabilities, not an LLM prompt. Counts describe real
/// rendering paths; do not inflate them with aliases or unused catalogue IDs.
enum AIVisualComponentVariant:String,Codable,CaseIterable {case stack,columns,matrix,numbered,timeline,featured,compact,sourceRail,tiles,threeColumns,horizontal,split,poster,alternating,verdict}
struct AIVisualComponentDescriptor:Equatable,Identifiable {
    let type:AIVisualBlockType
    let variant:AIVisualComponentVariant
    var id:String {type.rawValue+"."+variant.rawValue}
    var family:String {type.rawValue}
    var requiredFields:[String] {["title","items.tokens","items.sourceSegments"]}
    var optionalFields:[String] {["value","number","unit","speakerID","date","deadline"]}
    var maximumItems:Int {12}
    var fallbackID:String {type.rawValue+".stack"}
    func supports(_ block:AIVisualBlock,wide:Bool)->Bool {
        guard block.type==type,!block.items.isEmpty,block.items.count<=maximumItems else {return false}
        if variant == .stack {return true}
        if variant == .verdict {return [.decisions,.takeaway,.openQuestions].contains(type) && block.items.count==1 && block.items[0].tokens.compactMap(\.text).joined().count<600}
        return wide && block.items.count>=2 && ![AIVisualBlockType.chart,.processFlow,.conceptMap,.hero].contains(type) && block.items.allSatisfy {$0.tokens.compactMap(\.text).joined().count<600}
    }
}
enum AIVisualComponentRegistry {
    static var components:[AIVisualComponentDescriptor] {
        AIVisualBlockType.allCases.flatMap {type in
            let variants:[AIVisualComponentVariant] = [AIVisualBlockType.chart,.processFlow,.conceptMap,.hero].contains(type) ? [.stack]:AIVisualComponentVariant.allCases.filter {$0 != .verdict || [.decisions,.takeaway,.openQuestions].contains(type)}
            return variants.map {AIVisualComponentDescriptor(type:type,variant:$0)}
        }
    }
    static func select(_ block:AIVisualBlock,style:AIVisualStyle,wide:Bool)->AIVisualComponentDescriptor {
        let preferred:AIVisualComponentVariant
        if block.id == "featured-side",AIVisualComponentDescriptor(type:block.type,variant:.verdict).supports(block,wide:wide) {preferred = .verdict}
        else if style == .presentation {preferred = block.items.count==2 ? .split:.poster}
        else if style == .minimal {preferred = block.items.count>=3 ? .matrix:.compact}
        else if style == .dashboard {preferred = block.items.count>=6 ? .threeColumns:.tiles}
        else if block.items.contains(where:{$0.date != nil || $0.deadline != nil}) {preferred = .timeline}
        else if block.type == .quotes {preferred = .sourceRail}
        else if block.items.count>=5 {preferred = .numbered}
        else if block.items.count==2 {preferred = .featured}
        else {preferred = .stack}
        let candidate=AIVisualComponentDescriptor(type:block.type,variant:preferred)
        return candidate.supports(block,wide:wide) ? candidate:.init(type:block.type,variant:.stack)
    }
}

/// Read-only common export projection. It cannot invoke workers or mutate data.
struct AISummaryExportDocument {
    let title:String
    let visual:AIVisualSummary?
    let fullText:AIFullTextSummary?
    let segments:[AISpeechSegment]
    let speakers:AIRecordingSpeakers
    init(result:AIProcessingResult,speakers:AIRecordingSpeakers,style:AIVisualStyle,title:String) {
        let display=speakers.rendered(result)
        self.title=speakers.resolveText(title);self.speakers=speakers;self.segments=display.segments
        visual=display.semanticSummary?.visual(style:style) ?? display.visualSummary
        fullText=display.completeTextSummary
    }
    var textSummary:String {fullText?.rendered(speakers:speakers) ?? ""}
    var visualText:String {
        guard let visual else {return ""}
        return ([visual.title]+visual.blocks.map {block in
            let role=block.role == .hypothesis ? VL.text("Гипотеза · требует проверки"):block.role == .interpretation ? VL.text("Интерпретация модели"):block.role == .position ? VL.text("Позиция участника"):""
            let items=block.items.map {item in
                let metadata=[item.value,item.speakerID.map(speakers.name),item.date,item.deadline].compactMap {$0}.joined(separator:" · ")
                return [item.title,metadata,speakers.render(item.tokens)].filter {!$0.isEmpty}.joined(separator:"\n")
            }.joined(separator:"\n\n")
            let edges=(block.edges ?? []).map {edge in
                return edge.label
            }.joined(separator:"\n")
            return [block.title,role,items,edges].filter {!$0.isEmpty}.joined(separator:"\n")
        }).joined(separator:"\n\n")
    }
}


/// Model output is untrusted transport. Recover literal content first, then
/// produce a canonical, source-free document. Persisted validation stays strict.
enum AITextSummaryRecovery {
    struct Response { let summary:AIStructuredSummary; let seconds:Double }
    static func decode(_ data:Data,speakerIDs:Set<String>?=nil)throws->Response {
        guard data.count<=2_000_000 else {throw AIProcessingError.invalidSummary}
        let envelope=try JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)
        let root=envelope as? [String:Any]
        let payload=root?["modelResponse"] ?? root?["summary"] ?? envelope
        let body=readable(payload,speakerIDs:speakerIDs)
        guard !body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw AIProcessingError.invalidSummary}
        let object=payload as? [String:Any]
        let title=(object?["recordingTitle"] as? String).flatMap(AIRecordingTitle.validated)
            ?? AIRecordingTitle.explicitTopics(in: body).first
        let tasks=(object?["tasks"] as? [Any] ?? []).compactMap { value -> AIActionItem? in
            guard let row=value as? [String:Any],let description=row["description"] as? String,!description.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return nil}
            return .init(description:description,assignee:row["assignee"] as? String,deadline:row["deadline"] as? String,sourceSegments:[])
        }
        let blocks=AITextDocument(body).parts.enumerated().map { index,part in
            AISummaryBlock(id:"text-\(index)",kind:"inference",title:"",tokens:[.init(text:part.markdown,speakerID:nil)],sourceSegments:[])
        }
        let summary=AIStructuredSummary(summary:AITextDocument(body).markdown,topics:[],decisions:[],tasks:tasks,uncertainties:[],recordingTitle:title,blocks:blocks,sourcePolicy:"none",textRepresentation:"plain")
        try summary.validate(segmentIDs:[])
        let seconds=(root?["seconds"] as? Double) ?? 0
        return Response(summary:summary,seconds:seconds.isFinite && seconds>=0 ? seconds:0)
    }
    static func readable(_ value:Any,speakerIDs:Set<String>?=nil,depth:Int=0)->String {
        guard depth<16 else {return ""}
        if let text=value as? String {
            let clean=text.trimmingCharacters(in:.whitespacesAndNewlines)
            // A Markdown link or a bracketed note is ordinary prose, not JSON.
            let jsonArray=clean.range(of:"^\\[\\s*(?:[\\[\\{\"\\]0-9-]|true\\b|false\\b|null\\b)",options:.regularExpression) != nil
            if clean.hasPrefix("{") || jsonArray || clean.hasPrefix("```json") {
                if let recovered=try? AISemanticModelJSON.recover(clean) {return readable(recovered,speakerIDs:speakerIDs,depth:depth+1)}
                return AISemanticModelJSON.readableFragments(clean).compactMap {$0["text"] as? String}.joined(separator:"\n\n")
            }
            return clean
        }
        if let rows=value as? [Any] {return rows.map {readable($0,speakerIDs:speakerIDs,depth:depth+1)}.filter {!$0.isEmpty}.joined(separator:"\n\n")}
        guard let row=value as? [String:Any] else {return ""}
        if row.keys.allSatisfy({["result","output","data","response","report","document","payload","seconds","version"].contains($0)}),let nested=["result","output","data","response","report","document","payload"].compactMap({row[$0]}).first {return readable(nested,speakerIDs:speakerIDs,depth:depth+1)}
        if let raw=row["modelResponse"] {return readable(raw,speakerIDs:speakerIDs,depth:depth+1)}
        if row["textRepresentation"] as? String == "plain",let text=row["summary"] as? String {return readable(text,speakerIDs:speakerIDs,depth:depth+1)}
        var parts=[String]()
        let heading=["heading","title","label"].compactMap {row[$0] as? String}.first
        for key in ["summary","text","body","content","description"] {
            if let v=row[key] {let text=readable(v,speakerIDs:speakerIDs,depth:depth+1);if !text.isEmpty {parts.append(text);break}}
        }
        if parts.isEmpty,let tokens=row["tokens"] as? [[String:Any]] {
            let text=tokens.compactMap {token -> String? in
                if let text=token["text"] as? String {return text}
                guard let id=token["speakerID"] as? String else {return nil}
                return speakerIDs.map {$0.contains(id) ? id:VL.text("Участник")} ?? id
            }.joined(separator:" ")
            if !text.isEmpty {parts.append(text)}
        }
        for key in ["sections","blocks","paragraphs","entries","items"] {
            if let rows=row[key] as? [Any] {parts += rows.map {readable($0,speakerIDs:speakerIDs,depth:depth+1)}.filter {!$0.isEmpty};break}
        }
        for (key,label) in [("topics",VL.text("Темы")),("decisions",VL.text("Решения")),("tasks",VL.text("Задачи")),("uncertainties",VL.text("Открытые вопросы"))] {
            let values=(row[key] as? [Any] ?? []).map {readable($0,speakerIDs:speakerIDs,depth:depth+1)}.filter {!$0.isEmpty}
            if !values.isEmpty {parts.append("## "+label+"\n"+values.map {"- "+$0}.joined(separator:"\n"))}
        }
        // Exact repeats are common in compatibility blocks. Keep the first
        // occurrence only; never merge merely similar factual statements.
        var seen=Set<String>()
        parts=parts.filter {seen.insert($0.trimmingCharacters(in:.whitespacesAndNewlines)).inserted}
        if let heading,!parts.isEmpty,!heading.isEmpty {parts.insert("## "+heading,at:0)}
        return parts.joined(separator:"\n\n")
    }
}

/// Shared presentation plan for native streaming, saved text and export.
/// Unmarked headings require a short standalone line followed by body text;
/// ordinary short sentences and list rows retain their original role.
struct AITextDocument {
    enum Kind {case heading,paragraph,list,quote,table,code}
    struct Part {let kind:Kind;let text:String
        var markdown:String {kind == .heading ? "## "+text:kind == .code ? "```\n"+text+"\n```":text}
        var displayText:String {
            guard kind == .list else {return text}
            return text.replacingOccurrences(of:"(?m)^([ \\t]*)[-*•] +",with:"$1• ",options:.regularExpression)
        }
    }
    let parts:[Part]
    init(_ raw:String) {
        let text=AITextSummaryRecovery.readable(raw).replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        let lines=text.components(separatedBy:"\n")
        var output=[Part](),pending=[String](),pendingKind=Kind.paragraph,inCode=false
        func flush() {if !pending.isEmpty {output.append(.init(kind:pendingKind,text:pending.joined(separator:"\n")));pending=[]}}
        for (index,line) in lines.enumerated() {
            let clean=line.trimmingCharacters(in:.whitespaces)
            if clean.hasPrefix("```") {flush();inCode.toggle();pendingKind = .code;continue}
            if inCode {pending.append(line);continue}
            if clean.isEmpty {flush();continue}
            let explicit=clean.range(of:"^#{1,6}\\s+",options:.regularExpression)
            let bold=clean.hasPrefix("**") && clean.hasSuffix("**") && clean.count>4
            let next=index+1<lines.count ? lines[index+1].trimmingCharacters(in:.whitespaces):""
            let short=clean.count<=100 && clean.split(whereSeparator:{$0.isWhitespace}).count<=12
            let unmarked=short && next.count>100 && !clean.contains("|") && !clean.hasSuffix(".") && !clean.hasSuffix("!") && !clean.hasSuffix("?") && clean.range(of:"^(?:[-*•>] |[0-9]+[.)] )",options:.regularExpression)==nil
            if explicit != nil || bold || unmarked {
                flush()
                let heading=explicit.map {String(clean[$0.upperBound...])} ?? (bold ? String(clean.dropFirst(2).dropLast(2)):clean)
                output.append(.init(kind:.heading,text:heading));continue
            }
            let kind:Kind=clean.hasPrefix("|") ? .table:clean.hasPrefix(">") ? .quote:clean.range(of:"^(?:[-*•] |[0-9]+[.)] )",options:.regularExpression) != nil ? .list:.paragraph
            if kind != pendingKind {flush();pendingKind=kind}
            pending.append(line)
        }
        flush();parts=output
    }
    var markdown:String {parts.map(\.markdown).joined(separator:"\n\n")}
}

/// Distinct line symbols are allocated across the whole document, with topic
/// preferences. Platform callers supply supported names. Exhaustion omits an
/// ornament instead of repeating it or hiding any content.
enum AIVisualIconCatalog {
    static let families: [(String, [String])] = [
        ("голос речь аудио запись звук", ["waveform", "mic", "ear", "headphones", "speaker.wave.2", "waveform.path", "record.circle", "music.mic"]),
        ("модель интеллект анализ мысль психология", ["brain", "brain.head.profile", "lightbulb", "sparkle", "cpu", "head.profile", "eye", "wand.and.stars"]),
        ("задач решен действ план договор удал откат пропуск добав", ["checklist", "checkmark.seal", "checkmark.circle", "flag", "target", "calendar.badge.clock", "arrow.right.circle", "bolt"]),
        ("риск проблем огранич ловушк противореч", ["exclamationmark.triangle", "shield", "hand.raised", "exclamationmark.circle", "lock", "stop.circle", "bell", "shield.lefthalf.filled"]),
        ("цена ценовой стоим деньг оплат бюджет рынок", ["banknote", "creditcard", "rublesign.circle", "dollarsign.circle", "cart", "bag", "chart.line.uptrend.xyaxis", "building.columns"]),
        ("опрос вопрос выбор вариант ответ", ["questionmark.bubble", "questionmark.circle", "bubble.left", "text.bubble", "checkmark.bubble", "arrow.triangle.branch", "slider.horizontal.3", "rectangle.and.pencil.and.ellipsis"]),
        ("данн память файл сервис облак", ["externaldrive", "tray.full", "doc", "folder", "cloud", "server.rack", "archivebox", "internaldrive"]),
        ("структур сегмент организац групп команда", ["square.grid.2x2", "rectangle.3.group", "person.2", "person.3", "building.2", "network", "square.stack.3d.up", "square.split.2x2"]),
        ("диплом образован обучен знан экзамен", ["graduationcap", "book", "books.vertical", "pencil", "studentdesk", "bookmark", "doc.text", "character.book.closed"]),
        ("время срок скорост этап процесс", ["clock", "timer", "hourglass", "calendar", "stopwatch", "arrow.triangle.2.circlepath", "speedometer", "gauge"]),
        ("город среда метафор путь направлен", ["mappin.and.ellipse", "map", "location", "signpost.right", "globe", "leaf", "sun.max", "mountain.2"]),
        ("границ ценност уверен эмоц сотруд", ["heart", "hands.sparkles", "person.crop.circle", "face.smiling", "hand.thumbsup", "figure.stand", "arrow.up.right", "scope"]),
        ("итог вывод суть тезис идея", ["lightbulb.max", "quote.opening", "seal", "star", "rosette", "text.alignleft", "list.bullet", "text.justify"]),
        ("сравнен числ метрик статист баланс", ["chart.bar", "chart.pie", "chart.xyaxis.line", "equal.circle", "rectangle.split.2x1", "tablecells", "percent", "plus.forwardslash.minus"]),
        ("устрой аппарат техник продукт", ["watch.analog", "iphone", "desktopcomputer", "laptopcomputer", "battery.100", "wifi", "antenna.radiowaves.left.and.right", "gearshape"]),
        ("обмен связь экспорт помощь инструмент", ["paperplane", "link", "square.and.arrow.up", "wrench.and.screwdriver", "magnifyingglass", "envelope", "paperclip", "shippingbox"])
    ]
    static let symbols: [String] = families.flatMap { $0.1 }
    static func preferred(_ text: String) -> [String] {
        let text = text.lowercased()
        let matching = families.filter { $0.0.split(separator: " ").contains { text.contains($0) } }.flatMap { $0.1 }
        let neutral = families[12].1
        return matching + neutral.filter { !matching.contains($0) } + symbols.filter { !matching.contains($0) && !neutral.contains($0) }
    }
    static func allocate(_ report: AIVisualSummary, supported: Set<String>) -> [String: String] {
        var used = Set<String>(), result = [String: String]()
        func assign(_ key: String, _ text: String, _ permitsCheckmark: Bool) {
            guard let symbol = preferred(text).first(where: { supported.contains($0) && !used.contains($0) && (permitsCheckmark || !$0.hasPrefix("checkmark")) }) else { return }
            result[key] = symbol; used.insert(symbol)
        }
        for block in report.blocks { assign(block.id, block.title, block.type == .decisions && (block.role ?? .fact) == .fact) }
        for block in report.blocks {
            for (index, item) in block.items.enumerated() { assign(block.id + ":item:" + String(index), item.title + " " + item.tokens.compactMap(\.text).joined(), block.type == .decisions && (block.role ?? .fact) == .fact) }
        }
        return result
    }
}

/// Shared, light editorial palette. Identity is stable and distinct per panel;
/// the first five colors reproduce the supplied reference families.
enum AIVisualEditorialPalette {
    struct RGB: Equatable { let red: Double; let green: Double; let blue: Double }
    static let reference: [RGB] = [
        .init(red:0.925,green:0.965,blue:0.980),.init(red:0.812,green:0.898,blue:0.933),
        .init(red:0.925,green:0.977,blue:0.965),.init(red:0.980,green:0.970,blue:0.923),
        .init(red:0.982,green:0.925,blue:0.937),.init(red:0.925,green:0.937,blue:0.980),
        .init(red:0.875,green:0.937,blue:0.805),.init(red:0.957,green:0.927,blue:0.980),
        .init(red:0.980,green:0.947,blue:0.895),.init(red:0.923,green:0.965,blue:0.925),
        .init(red:0.953,green:0.933,blue:0.903),.init(red:0.950,green:0.942,blue:0.968)]
    static func color(_ index: Int, psychological: Bool = false) -> RGB {
        let order = psychological ? [4,5,0,6,3,1,2,7,8,9,10,11] : Array(0..<12)
        if order.indices.contains(index) { return reference[order[index]] }
        let hue=(Double(index)*0.38196601125).truncatingRemainder(dividingBy:1)*6
        let c=0.06+Double(index)*0.0002, x=c*(1-abs(hue.truncatingRemainder(dividingBy:2)-1)),m=0.978-c
        let part: (Double,Double,Double)
        switch Int(hue) {case 0:part=(c,x,0);case 1:part=(x,c,0);case 2:part=(0,c,x);case 3:part=(0,x,c);case 4:part=(x,0,c);default:part=(c,0,x)}
        return RGB(red:part.0+m,green:part.1+m,blue:part.2+m)
    }
}
