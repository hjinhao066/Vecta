import Foundation

/// Export choices describe saved content, never an inference request.
enum NativeExportKind: CaseIterable {
    case transcript, summary, visualSummary, fullReport, fullReportWithTranscript
}

/// Value-only snapshot captured before dismissing the sheet or opening a save panel.
/// Source selection is retained for identity checks; it is not included in the file.
struct NativeExportContext {
    struct Source: Equatable {
        let recordingID: String
        let requestID: UUID
        let audioSHA256: String
        let selectionSerialNumber: String?
        let selectionSessionID: Int?
    }
    let result: AIProcessingResult
    let speakers: AIRecordingSpeakers
    let title: String
    let date: Date?
    let duration: Double?
    let source: Source

    init(result: AIProcessingResult, speakers: AIRecordingSpeakers, title: String,
         date: Date?, duration: Double?, selectionSerialNumber: String? = nil, selectionSessionID: Int? = nil) {
        self.result = result
        self.speakers = speakers
        let resolvedTitle = speakers.resolveText(title).trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = resolvedTitle.isEmpty ? VL.text("Запись") : resolvedTitle
        self.date = date
        self.duration = duration
        source = Source(recordingID: result.request.recordingID, requestID: result.request.id,
                        audioSHA256: result.request.audioSHA256, selectionSerialNumber: selectionSerialNumber,
                        selectionSessionID: selectionSessionID)
    }

    func projection(_ kind: NativeExportKind) -> NativeExportProjection? {
        NativeExportProjection(context: self, kind: kind)
    }
}

/// The same projection drives TXT content and the native PDF writer's appendices.
/// Nil means unavailable: a title, draft, or empty report alone is not exportable.
struct NativeExportProjection {
    let context: NativeExportContext
    let kind: NativeExportKind
    let visual: AIVisualSummary?
    let fullText: AIFullTextSummary?
    let textSummary: String?
    let transcript: String?
    let segments: [AISpeechSegment]
    let body: String
    let titledBody: String

    init?(context: NativeExportContext, kind: NativeExportKind) {
        let document = AISummaryExportDocument(result: context.result, speakers: context.speakers,
                                              style: .editorial, title: context.title)
        let display = context.speakers.rendered(context.result)
        let savedTranscript = display.readableTranscript ?? ""
        let savedSummary = document.textSummary
        let hasTranscript = Self.hasText(savedTranscript)
        let hasSummary = document.fullText?.paragraphs.contains {
            Self.hasText(context.speakers.render($0.tokens))
        } == true
        let hasVisual = document.visual?.blocks.contains { block in
            block.items.contains { item in
                Self.hasText(context.speakers.render(item.tokens)) || Self.hasText(item.value ?? "")
            }
        } == true
        let visual: AIVisualSummary?
        let fullText: AIFullTextSummary?
        let textSummary: String?
        let transcript: String?
        let body: String
        switch kind {
        case .transcript:
            guard hasTranscript else { return nil }
            visual = nil; fullText = nil; textSummary = nil; transcript = savedTranscript
            body = savedTranscript
        case .summary:
            guard hasSummary else { return nil }
            visual = nil; fullText = document.fullText; textSummary = savedSummary; transcript = nil
            body = savedSummary
        case .visualSummary:
            guard hasVisual else { return nil }
            visual = document.visual; fullText = nil; textSummary = nil; transcript = nil
            body = document.visualText
        case .fullReport, .fullReportWithTranscript:
            guard hasVisual, hasSummary, kind != .fullReportWithTranscript || hasTranscript else { return nil }
            visual = document.visual; fullText = document.fullText; textSummary = savedSummary
            transcript = kind == .fullReportWithTranscript ? savedTranscript : nil
            body = document.visualText + VL.text("\n\nТекстовое саммари\n\n") + savedSummary
                + (transcript.map { VL.text("\n\nРасшифровка\n\n") + $0 } ?? "")
        }
        guard Self.hasText(body) else { return nil }
        self.context = context; self.kind = kind; self.visual = visual; self.fullText = fullText
        self.textSummary = textSummary; self.transcript = transcript; self.segments = document.segments
        self.body = body
        titledBody = AITextDocument(body).parts.first?.text == context.title ? body : context.title + "\n\n" + body
    }

    private static func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
