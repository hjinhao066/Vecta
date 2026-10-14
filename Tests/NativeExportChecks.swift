import Foundation

/// Synthetic, in-memory regression checks. No panels, user exports, recordings,
/// models, Keychain, device connections, or inference are used.
enum NativeExportChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    static func run() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            guard condition() else { throw Failure(description: message) }
        }
        let captured = fixture(tag: "ALPHA")
        let transcript = captured.projection(.transcript)!
        let summary = captured.projection(.summary)!
        let visual = captured.projection(.visualSummary)!
        let full = captured.projection(.fullReport)!
        let withTranscript = captured.projection(.fullReportWithTranscript)!
        try check(transcript.body.contains("TRANSCRIPT_ALPHA"), "Transcript contains saved speech")
        try check(!transcript.body.contains("SUMMARY_ALPHA") && !transcript.body.contains("VISUAL_ALPHA"), "Transcript projection is independent")
        try check(summary.body.contains("SUMMARY_ALPHA"), "Summary contains committed full text")
        try check(!summary.body.contains("TRANSCRIPT_ALPHA") && !summary.body.contains("VISUAL_ALPHA"), "Summary projection is independent")
        try check(visual.body.contains("VISUAL_ALPHA"), "Visual contains semantic content")
        try check(!visual.body.contains("SUMMARY_ALPHA") && !visual.body.contains("TRANSCRIPT_ALPHA"), "Infographic must not include summary/transcript")
        try check(visual.fullText == nil && visual.textSummary == nil && visual.transcript == nil, "Visual PDF receives no appendices")
        try check(full.body.contains("VISUAL_ALPHA") && full.body.contains("SUMMARY_ALPHA") && !full.body.contains("TRANSCRIPT_ALPHA"), "Full report includes exactly visual and summary")
        try check(full.fullText != nil && full.textSummary != nil && full.transcript == nil, "Full-report PDF receives only saved summary appendix")
        try check(withTranscript.body.contains("VISUAL_ALPHA") && withTranscript.body.contains("SUMMARY_ALPHA") && withTranscript.body.contains("TRANSCRIPT_ALPHA"), "Full report with transcript includes all sections")
        try check(withTranscript.transcript != nil, "Transcript appendix is explicitly requested")
        try check(summary.visual == nil && transcript.visual == nil, "Text-only PDFs do not receive visual content")
        for projection in [transcript, summary, visual, full, withTranscript] {
            try check(projection.body.contains("PERSON_ALPHA"), "Every projection uses captured speaker labels")
            try check(!projection.body.contains("PERSON_BETA"), "Never borrow another recording's speaker")
            try check(projection.context.title == "TITLE_ALPHA", "Captured title is retained")
        }
        try check(transcript.body.contains("literal speaker_001 TRANSCRIPT_ALPHA"), "Raw speech is never name-substituted")
        try check(visual.body.contains("literal speaker_001 QUOTE_ALPHA"), "Direct quotes remain literal in semantic export")
        try check(visual.visual?.blocks.flatMap(\.items).contains { $0.sourceSegments == [17] && $0.tokens.contains { $0.speakerID == "speaker_001" } } == true, "Semantic speaker tokens and source IDs survive projection")
        try check(visual.segments.first?.speaker == "PERSON_ALPHA" && visual.segments.first?.id == 17, "Evidence speaker and stable segment ID use captured context")

        // Mutate all live-like values after capture: the immutable value must not change.
        var liveResult = captured.result
        var liveSpeakers = captured.speakers
        liveResult = fixture(tag: "BETA").result
        try liveSpeakers.rename("speaker_001", to: "PERSON_BETA")
        let later = NativeExportContext(result: liveResult, speakers: liveSpeakers, title: "TITLE_BETA",
                                       date: Date(timeIntervalSince1970: 9000), duration: 999,
                                       selectionSerialNumber: "SERIAL_BETA", selectionSessionID: 9000)
        try check(later.projection(.fullReportWithTranscript)!.body.contains("SUMMARY_BETA"), "Mutation fixture actually changes live content")
        try check(captured.projection(.fullReportWithTranscript)!.body == withTranscript.body, "Deferred projection is unaffected by live mutations")
        try check(captured.date == Date(timeIntervalSince1970: 1000) && captured.duration == 42, "Date and duration remain captured")
        try check(captured.source.recordingID == "recording-ALPHA" && captured.source.selectionSerialNumber == "SERIAL_ALPHA" && captured.source.selectionSessionID == 1000, "Source selection remains captured")
        try check(!withTranscript.titledBody.contains("BETA"), "Saved output contains no foreign recording context")

        var empty = captured.result
        empty.stage = .summarizing; empty.transcript = " \n "; empty.segments = []
        empty.summary = nil; empty.fullTextSummary = nil; empty.semanticSummary = nil; empty.visualSummary = nil
        empty.summaryDraft = "DRAFT_ONLY_SENTINEL"
        let unavailable = NativeExportContext(result: empty, speakers: captured.speakers, title: "TITLE_ONLY",
                                             date: nil, duration: nil)
        for kind in NativeExportKind.allCases {
            try check(unavailable.projection(kind) == nil, "Draft/title/whitespace is unavailable for \(kind)")
        }
        empty.transcript = captured.result.transcript; empty.segments = captured.result.segments
        let progress = NativeExportContext(result: empty, speakers: captured.speakers, title: "TITLE_ONLY", date: nil, duration: nil)
        try check(progress.projection(.transcript) != nil && progress.projection(.summary) == nil, "Saved transcript remains exportable during summary progress")
        try check(captured.projection(.summary) != nil, "Completed snapshot remains exportable after live result changes")

        empty.fullTextSummary = .init(schemaVersion: 1, paragraphs: [.init(id: "empty", heading: "HEADING_ONLY", tokens: [.init(text: " \n ", speakerID: nil)], sourceSegments: [])])
        empty.visualSummary = .init(schemaVersion: 3, title: "EMPTY_VISUAL_TITLE", theme: "editorial", blocks: [])
        let headingOnly = NativeExportContext(result: empty, speakers: captured.speakers, title: "TITLE_ONLY", date: nil, duration: nil)
        try check(headingOnly.projection(.summary) == nil && headingOnly.projection(.visualSummary) == nil && headingOnly.projection(.fullReport) == nil, "Heading-only/empty visual cannot be saved")
        var visualOnlyResult = captured.result
        visualOnlyResult.fullTextSummary = nil; visualOnlyResult.summary = nil
        let visualOnly = NativeExportContext(result: visualOnlyResult, speakers: captured.speakers, title: "TITLE_ONLY", date: nil, duration: nil)
        try check(visualOnly.projection(.visualSummary) != nil && visualOnly.projection(.fullReport) == nil, "Visual-only saved result does not masquerade as full report")
        var noTranscriptResult = captured.result
        noTranscriptResult.transcript = nil; noTranscriptResult.segments = []
        let noTranscript = NativeExportContext(result: noTranscriptResult, speakers: captured.speakers, title: "TITLE_ONLY", date: nil, duration: nil)
        try check(noTranscript.projection(.fullReport) != nil && noTranscript.projection(.fullReportWithTranscript) == nil, "Report with transcript requires saved speech")
        let legacy = fixture(tag: "LEGACY", semantic: false)
        try check(legacy.projection(.visualSummary)!.body.contains("VISUAL_LEGACY"), "Legacy visual fallback remains available")
        try check(legacy.projection(.visualSummary)!.body.contains("literal speaker_001 QUOTE_LEGACY"), "Direct quotes remain literal in legacy export")
        try check(legacy.projection(.fullReport)!.body.contains("SUMMARY_LEGACY"), "Legacy summary remains independent from visual")
        print("PASS \(assertions) synthetic export projection/snapshot checks (in-memory; no user file writes)")
    }

    static func fixture(tag: String, semantic: Bool = true) -> NativeExportContext {
        let segment = AISpeechSegment(id: 17, start: 5, end: 12, speaker: "Собеседник 1",
            text: "literal speaker_001 TRANSCRIPT_" + tag, speakerID: "speaker_001")
        var speakers = AIRecordingSpeakers.initial([segment])
        speakers.identities["speaker_001"] = AISpeakerIdentity(id: "speaker_001", name: "PERSON_" + tag, origin: "manual", profileID: nil)
        let request = AIProcessingRequest(version: 1, id: UUID(), recordingID: "recording-" + tag,
            audioFilename: "recording-" + tag + ".mp3", audioSHA256: String(repeating: "a", count: 64),
            provider: .local, format: .standard, createdAt: Date(timeIntervalSince1970: 1500),
            summaryOnly: false, transcriptRequestID: nil)
        var result = AIProcessingResult(version: 1, request: request, stage: .completed,
            transcript: "TRANSCRIPT_" + tag, segments: [segment], summary: nil, error: nil,
            updatedAt: Date(timeIntervalSince1970: 2000), duration: 42, recognitionSeconds: nil, summarySeconds: nil)
        result.fullTextSummary = .init(schemaVersion: 1, paragraphs: [.init(id: "summary", heading: "Saved analysis",
            tokens: [.init(text: "SUMMARY_" + tag, speakerID: nil), .init(text: nil, speakerID: "speaker_001")], sourceSegments: [17])])
        let tokens: [AISummaryToken] = [.init(text: "VISUAL_" + tag, speakerID: nil), .init(text: nil, speakerID: "speaker_001")]
        if semantic {
            result.semanticSummary = .init(schemaVersion: 1, title: "VISUAL_TITLE_" + tag,
                entries: [.init(id: "insight", kind: .insight, title: "Saved insight", tokens: tokens, sourceSegments: [17], speakerID: "speaker_001"),
                          .init(id: "quote", kind: .quote, title: "Direct speech", tokens: [.init(text: "literal speaker_001 QUOTE_" + tag, speakerID: nil)], sourceSegments: [17], speakerID: "speaker_001")])
        } else {
            result.visualSummary = .init(schemaVersion: 3, title: "VISUAL_TITLE_" + tag, theme: "editorial",
                blocks: [.init(id: "insight", type: .keyPoints, title: "Saved insight", items: [.init(title: "Evidence", tokens: tokens, sourceSegments: [17], speakerID: "speaker_001")]),
                         .init(id: "quote", type: .quotes, title: "Direct speech", items: [.init(title: "Evidence", tokens: [.init(text: "literal speaker_001 QUOTE_" + tag, speakerID: nil)], sourceSegments: [17], speakerID: "speaker_001")])])
        }
        return NativeExportContext(result: result, speakers: speakers, title: "TITLE_" + tag,
            date: Date(timeIntervalSince1970: 1000), duration: 42,
            selectionSerialNumber: "SERIAL_" + tag, selectionSessionID: 1000)
    }
}
