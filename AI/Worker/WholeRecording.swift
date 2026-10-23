import Foundation
import AVFoundation
import WhisperKit
import SpeakerKit
import Darwin

/// Retains an unloaded compatible WhisperKit object while the speech server remains alive.
/// `unload` is always called before another heavy model is allowed to load.
final class VectaSpeechModelCache {
    private struct Configuration: Hashable {
        let modelFolder: String
        let tokenizerFolder: URL
        let usesGPUEncoder: Bool
    }

    private var configurations: [Configuration: WhisperKit] = [:]

    func model(modelFolder: String, tokenizerFolder: URL, remainingWindows: Int) async throws -> WhisperKit {
        let requested = Configuration(modelFolder: modelFolder, tokenizerFolder: tokenizerFolder, usesGPUEncoder: VectaSpeechModelConfiguration.usesGPUEncoder(remainingWindows: remainingWindows))
        if let cached = configurations[requested] { return cached }
        await unload()
        // Bound retained objects to the two compute policies for these exact paths.
        if configurations.keys.contains(where: { $0.modelFolder != modelFolder || $0.tokenizerFolder != tokenizerFolder }) {
            configurations.removeAll()
        }
        let whisper = try await WhisperKit(VectaSpeechModelConfiguration.make(modelFolder: modelFolder, tokenizerFolder: tokenizerFolder, remainingWindows: remainingWindows))
        configurations[requested] = whisper
        return whisper
    }

    func unload() async {
        for whisper in configurations.values { await whisper.unloadModels() }
    }
}

enum VectaSpeechPipeline {
    struct UnalignedWord: Codable { let chunk: Int; let start: Double; let end: Double; let text: String }
    /// SpeakerKit's public global API requires one contiguous PCM array.
    static func fullDiarizationPCM(_ audio: URL, duration: Double) throws -> [Float] {
        try AIAudioPolicy.validate(duration:duration)
        let asset=AVURLAsset(url:audio)
        guard let track=asset.tracks(withMediaType:.audio).first else { throw LocalAudioError.unreadable }
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsNonInterleaved:false])
        output.alwaysCopiesSampleData=false
        guard reader.canAdd(output) else { throw LocalAudioError.conversion }
        reader.add(output)
        guard reader.startReading() else { throw LocalAudioError.conversion }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var samples:[Float]=[];samples.reserveCapacity(Int(ceil(duration*16000)))
        while let sample=output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block=CMSampleBufferGetDataBuffer(sample) else { throw LocalAudioError.conversion }
            let bytes=CMBlockBufferGetDataLength(block)
            guard bytes%4==0,samples.count+bytes/4<=Int((duration+1)*16000) else { throw LocalAudioError.conversion }
            let old=samples.count;samples.append(contentsOf:repeatElement(Float(0),count:bytes/4))
            let status=samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:bytes,destination:$0.baseAddress!.advanced(by:old*4)) }
            guard status==kCMBlockBufferNoErr else { throw LocalAudioError.conversion }
        }
        guard reader.status == .completed,!samples.isEmpty,samples.allSatisfy(\.isFinite),abs(Double(samples.count)/16000-duration)<0.5 else { throw LocalAudioError.durationMismatch }
        return samples
    }
    struct SpeakerInterval: Codable { let start: Double; let end: Double; let globalID: Int }
    struct GlobalWord: Codable {
        let start: Double; let end: Double; let text: String; let chunk: Int
        var globalID: Int?; var candidates: [Int]; var uncertainty: String
        let matchConfidence: Double?; let userConfirmation: String?
    }
    struct WholeAlignment: Codable {
        let mode: String; let phase: String; let duration: Double; let complete: Bool
        let rawNonExclusiveTimeline: [SpeakerInterval]
        let words: [GlobalWord]; let unalignedWords: [UnalignedWord]
        let centroids: [String: [Float]]; let numberOfEmbeddings: Int?
    }
    static func attribution(start: Double, end: Double, timeline: [SpeakerInterval]) -> (Int?, [Int], String) {
        let candidates = Set(timeline.filter { min(end,$0.end)>max(start,$0.start) }.map(\.globalID)).sorted()
        // No winner by duration or local numbering, including words spanning a turn.
        if candidates.count == 1 { return (candidates[0], candidates, "automatic temporal correspondence; identity unconfirmed") }
        return (nil,candidates,candidates.isEmpty ? "no speech intersection" : "multiple speakers intersect word; ambiguous")
    }
    static func utterances(_ words: [GlobalWord]) -> [AISpeechSegment] {
        var result: [AISpeechSegment] = []
        for word in words where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let speaker = word.globalID.map { "Собеседник \($0 + 1)" }
            if let previous = result.last, previous.speaker == speaker,
               word.start >= previous.start, word.start - previous.end < 1.5,
               word.end - previous.start <= 30, previous.text.count + word.text.count < 1200 {
                result[result.count-1] = AISpeechSegment(id:previous.id,start:previous.start,end:max(previous.end,word.end),speaker:speaker,text:previous.text+word.text,speakerID:previous.speakerID)
            } else {
                result.append(AISpeechSegment(id:result.count,start:word.start,end:word.end,speaker:speaker,text:word.text,speakerID:word.globalID.map { String(format:"speaker_%03d",$0+1) }))
            }
        }
        return result
    }
    static func runWholeRecording(request: AIProcessingRequest, audio: URL, output: URL, duration: Double, speakers: String, tokenizer: String, whisperModel: String? = nil, modelCache: VectaSpeechModelCache? = nil, eventURL: URL? = nil) async throws {
        try AIAudioPolicy.validate(duration:duration)
        var state = AIProcessingResult(version:1,request:request,stage:.loadingRecognition,transcript:nil,segments:[],summary:nil,error:nil,updatedAt:Date(),duration:duration,recognitionSeconds:nil,summarySeconds:nil)
        var words: [GlobalWord] = [], unaligned: [UnalignedWord] = []
        var timeline: [SpeakerInterval] = [], centroids: [String:[Float]] = [:]
        var embeddingCount: Int?
        var phase="transcribing"
        struct Checkpoint: Codable {
            let version: Int; let digest: String; let duration: Double
            let completed: Int; let seconds: Double
            let words: [GlobalWord]; let unaligned: [UnalignedWord]
            var outputLanguage:String? = nil
            var decodingPolicy:String? = nil
        }
        let checkpointURL=request.speechCheckpointURL(for:output)
        var completed=0,asrSeconds=0.0
        let windows=try AIStreamingConfiguration(chunkSeconds:request.speechWindowSeconds.chunk,overlapSeconds:request.speechWindowSeconds.overlap,pauseAware:false).windows(duration:duration)
        let engineName=request.selectedSpeechEngine == .gigaam ? "GigaAM v3 (MLX)" : "Whisper"
        let checkpointValues=try? checkpointURL.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        if checkpointValues?.isRegularFile==true,checkpointValues?.isSymbolicLink != true,
           (checkpointValues?.fileSize ?? 0)<32_000_000,
           let saved=try? JSONDecoder().decode(Checkpoint.self,from:Data(contentsOf:checkpointURL)),
           saved.digest==request.audioSHA256,saved.duration==duration,
           request.acceptsSpeechCheckpoint(version:saved.version,outputLanguage:saved.outputLanguage,decodingPolicy:saved.decodingPolicy),
           saved.completed>=0,saved.completed<=windows.count,
           saved.seconds.isFinite,saved.seconds>=0,
           saved.unaligned.allSatisfy({$0.chunk>=0 && $0.chunk<saved.completed && $0.start.isFinite && $0.end.isFinite}),
           saved.words.allSatisfy({$0.chunk<saved.completed && $0.chunk>=0 && $0.start.isFinite && $0.end.isFinite && $0.start>=0 && $0.end>=$0.start && $0.end<=duration}) {
            completed=saved.completed;asrSeconds=saved.seconds;words=saved.words;unaligned=saved.unaligned
        }
        func privateWrite(_ data: Data,_ url: URL) throws {
            try data.write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
        func save(_ complete: Bool) throws {
            state.updatedAt=Date()
            try privateWrite(JSONEncoder().encode(state),output)
            try privateWrite(JSONEncoder().encode(WholeAlignment(mode:request.wantsDiarization ? "B: independent \(engineName) windows + global non-exclusive SpeakerKit" : "\(engineName) windows; diarization disabled by user",phase:phase,duration:duration,complete:complete,rawNonExclusiveTimeline:timeline,words:words,unalignedWords:unaligned,centroids:centroids,numberOfEmbeddings:embeddingCount)),output.appendingPathExtension("alignment.json"))
        }
        try save(false)
        var whisperLoad=0.0
        // GigaAM recognition runs in the MLX worker before this process starts.
        if completed < windows.count, request.selectedSpeechEngine == .gigaam { throw AIProcessingError.invalidTranscript }
        if completed < windows.count {
        let loadStart=ProcessInfo.processInfo.systemUptime
        let remainingWindows=windows.count-completed
        let modelFolder=whisperModel ?? CommandLine.arguments[3]
        let tokenizerFolder=URL(fileURLWithPath:tokenizer)
        let whisper: WhisperKit
        if let modelCache {
            whisper=try await modelCache.model(modelFolder:modelFolder,tokenizerFolder:tokenizerFolder,remainingWindows:remainingWindows)
        } else {
            whisper=try await WhisperKit(VectaSpeechModelConfiguration.make(modelFolder:modelFolder,tokenizerFolder:tokenizerFolder,remainingWindows:remainingWindows))
        }
        let setupSeconds=ProcessInfo.processInfo.systemUptime-loadStart
        let explicitLoadStart=ProcessInfo.processInfo.systemUptime
        func saveStartupTiming(_ phase:String) {
            let timings=whisper.currentTimings
            let numeric:[String:Double]=["setupSeconds":setupSeconds,"explicitLoadSeconds":ProcessInfo.processInfo.systemUptime-explicitLoadStart,
                "totalInitializationSeconds":ProcessInfo.processInfo.systemUptime-loadStart,"sdkModelLoadingSeconds":timings.modelLoading,
                "decoderLoadSeconds":timings.decoderLoadTime,"encoderLoadSeconds":timings.encoderLoadTime,"tokenizerLoadSeconds":timings.tokenizerLoadTime,
                "prewarmLoadSeconds":timings.prewarmLoadTime,
                "featureExtractorAndLoaderOverheadSeconds":max(0,timings.modelLoading-timings.decoderLoadTime-timings.encoderLoadTime-timings.tokenizerLoadTime)]
            var payload:[String:Any]=numeric.filter{$0.value.isFinite && $0.value>=0};payload["version"]=1;payload["phase"]=phase
            payload["encoderComputePolicy"]=VectaSpeechModelConfiguration.usesGPUEncoder(remainingWindows:remainingWindows) ? "cpuAndGPU":"sdkDefault"
            payload["remainingWindows"]=remainingWindows
            // Optional private diagnostics must never fail an otherwise valid recording.
            if let bytes=try? JSONSerialization.data(withJSONObject:payload,options:.sortedKeys) {
                try? privateWrite(bytes,output.appendingPathExtension("startup-metrics.json"))
            }
        }
        do {
        try Task.checkCancellation()
        try await whisper.loadModels()
        try Task.checkCancellation()
        whisperLoad=ProcessInfo.processInfo.systemUptime-loadStart
        // The SDK sets final modelLoading after its loaded callback returns.
        saveStartupTiming("loaded")
        for w in windows.dropFirst(completed) {
            try Task.checkCancellation()
            state.stage = .recognizing
            state.recognitionProgress=AIRecognitionProgress(completedChunks:w.index,totalChunks:windows.count,processedSeconds:w.coreStart,totalSeconds:duration,currentChunk:w.index+1,modelLoadSeconds:whisperLoad)
            state.recognitionProgress?.speakerScope=request.wantsDiarization ? "whole-recording automatic identity; unconfirmed" : "diarization disabled by user"
            try save(false)
            let pcm=try LocalAudioReader.readWindow(audio,start:w.start,end:w.end)
            let started=Date()
            let results=try await whisper.transcribe(audioArray:pcm.samples,decodeOptions:VectaSpeechModelConfiguration.decodingOptions(outputLanguage:request.outputLanguage))
            asrSeconds += Date().timeIntervalSince(started)
            for word in results.flatMap({$0.segments}).flatMap({$0.words ?? []}) {
                guard word.start.isFinite,word.end.isFinite,word.start>=0,word.end>=word.start else {
                    unaligned.append(UnalignedWord(chunk:w.index,start:word.start.isFinite ? Double(word.start) : -1,end:word.end.isFinite ? Double(word.end) : -1,text:word.word));continue
                }
                guard Double(word.start)<pcm.duration else {
                    unaligned.append(UnalignedWord(chunk:w.index,start:Double(word.start),end:Double(word.end),text:word.word));continue
                }
                let a=w.start+Double(word.start),b=min(w.end,w.start+Double(word.end))
                guard (a+b)/2>=w.coreStart,(a+b)/2<w.coreEnd else { continue }
                words.append(GlobalWord(start:a,end:b,text:word.word,chunk:w.index,globalID:nil,candidates:[],uncertainty:"global diarization pending",matchConfidence:nil,userConfirmation:nil))
            }
            state.recognitionProgress?.completedChunks=w.index+1
            state.recognitionProgress?.processedSeconds=w.coreEnd
            state.recognitionProgress?.currentChunk=nil
            try privateWrite(JSONEncoder().encode(Checkpoint(version:request.speechCheckpointVersion,digest:request.audioSHA256,duration:duration,completed:w.index+1,seconds:asrSeconds,words:words,unaligned:unaligned,outputLanguage:request.outputLanguage,decodingPolicy:request.speechDecodingPolicy)),checkpointURL)
            try save(false)
        }
        if let modelCache { await modelCache.unload() } else { await whisper.unloadModels() }
        } catch {
            if whisperLoad==0 {saveStartupTiming(error is CancellationError || Task.isCancelled ? "cancelled":"failed")}
            if let modelCache { await modelCache.unload() } else { await whisper.unloadModels() }
            throw error
        }
        }
        guard !words.isEmpty else { throw AIProcessingError.invalidTranscript }
        if !request.wantsDiarization {
            // Explicit conference opt-out: retain every recognized word and its
            // timing, without loading SpeakerKit or inferring a speaker identity.
            for index in words.indices { words[index].uncertainty = "speaker attribution disabled by user" }
            state.segments = utterances(words)
            state.transcript = words.map(\.text).joined() + (unaligned.isEmpty ? "" : "\n" + unaligned.map(\.text).joined())
            state.unmatchedText = unaligned.isEmpty ? nil : unaligned.map(\.text).joined()
            state.recognitionSeconds = asrSeconds
            state.stage = request.wantsSummary ? .loadingSummary : .savingTranscript; phase = "complete"
            try state.validate(); try save(true); return
        }
        // Retain one global clustering state. Never split identities by ASR window.
        // Refuse an unsafe reservation before allocating the full PCM; checkpoint survives.
        let reservation=AIAudioPolicy.diarizationReservation(duration:duration)
        var statistics=vm_statistics64_data_t()
        var count=mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status=withUnsafeMutablePointer(to:&statistics) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { host_statistics64(mach_host_self(),HOST_VM_INFO64,$0,&count) } }
        var page:vm_size_t=0
        let pageStatus=host_page_size(mach_host_self(),&page)
        let available=(UInt64(statistics.free_count)+UInt64(statistics.inactive_count)+UInt64(statistics.purgeable_count))*UInt64(page)
        guard reservation < ProcessInfo.processInfo.physicalMemory*3/4,
              status != KERN_SUCCESS || pageStatus != KERN_SUCCESS || available > reservation else { throw LocalAudioError.memoryLimit }
        phase="globalDiarization";state.stage = .diarizing;try save(false)
        let speakerLoadStart=Date()
        let speaker=try await SpeakerKit(PyannoteConfig(modelFolder:speakers,download:false,load:true,verbose:false,concurrentSegmenterWorkers:1,concurrentEmbedderWorkers:1))
        let speakerLoad=Date().timeIntervalSince(speakerLoadStart)
        do {
        let diarizationStart=Date()
        let result = try await diarize(speaker,audio:audio,duration:duration,eventURL:eventURL)
        try Task.checkCancellation()
        let diarizationSeconds=Date().timeIntervalSince(diarizationStart)
        embeddingCount=(result.timings as? PyannoteDiarizationTimings)?.numberOfEmbeddings
        timeline=try result.segments.map { s in
            guard let id=s.speaker.speakerId,s.startTime.isFinite,s.endTime.isFinite,s.startTime>=0,s.endTime>=s.startTime,Double(s.startTime)<duration else { throw AIProcessingError.invalidTranscript }
            return SpeakerInterval(start:Double(s.startTime),end:min(duration,Double(s.endTime)),globalID:id)
        }
        centroids=Dictionary(uniqueKeysWithValues:result.speakerCentroidEmbeddings.map{(String($0.key),$0.value)})
        guard !timeline.isEmpty,embeddingCount.map({$0>0}) ?? false else { throw AIProcessingError.invalidTranscript }
        phase="attributing";state.stage = .aligning;try save(false)
        // Sweep only active intervals instead of scanning the entire timeline for every word.
        let sorted=timeline.sorted {$0.start<$1.start}
        var cursor=0,active:[SpeakerInterval]=[]
        for i in words.indices.sorted(by:{words[$0].start<words[$1].start}) {
            try Task.checkCancellation()
            active.removeAll {$0.end<=words[i].start}
            while cursor<sorted.count,sorted[cursor].start<words[i].end { active.append(sorted[cursor]);cursor+=1 }
            let match=attribution(start:words[i].start,end:words[i].end,timeline:active)
            words[i].globalID=match.0;words[i].candidates=match.1;words[i].uncertainty=match.2
        }
        state.segments = utterances(words)
        state.transcript = words.map(\.text).joined() + (unaligned.isEmpty ? "" : "\n[Без надёжных таймкодов] " + unaligned.map(\.text).joined())
        state.unmatchedText = unaligned.isEmpty ? nil : unaligned.map(\.text).joined()
        state.stage = .savingTranscript
        try save(false)
        try Task.checkCancellation()
        state.recognitionSeconds=asrSeconds+diarizationSeconds
        try state.validate()
        // Preserve overlapping raw intervals, not RTTM inferred from ASR words.
        let rttm=timeline.map { String(format:"SPEAKER experiment 1 %.6f %.6f <NA> <NA> spk%d <NA> <NA>",$0.start,$0.end-$0.start,$0.globalID) }.joined(separator:"\n")+"\n"
        try privateWrite(Data(rttm.utf8),output.appendingPathExtension("rttm"))
        phase="complete"
        try Task.checkCancellation()
        state.stage = request.wantsSummary ? .loadingSummary : .savingTranscript
        try save(true)
        await speaker.unloadModels()
        let path=ProcessInfo.processInfo.environment["VECTA_ASR_PROFILE_PATH"] ?? output.appendingPathExtension("metrics.json").path
        let metrics:[String:Any]=["mode":"B","engine":request.selectedSpeechEngine.rawValue,"asrSeconds":asrSeconds,"diarizationSeconds":diarizationSeconds,"modelLoadSeconds":whisperLoad+speakerLoad,"chunks":windows.count,"numberOfEmbeddings":embeddingCount!,"numberOfSpeakers":result.speakerCount,"errors":0,"partial":false,"contentCompletenessVerified":false,"sdkInternalErrorCountAvailable":false,"unalignedWords":unaligned.count,"resolvedWords":words.filter{$0.globalID != nil}.count,"totalWords":words.count]
        if let data=try? JSONSerialization.data(withJSONObject:metrics,options:.prettyPrinted) { try? privateWrite(data,URL(fileURLWithPath:path)) }
        } catch {
            await speaker.unloadModels()
            throw error
        }
    }
    /// Scope the necessary full PCM to inference, releasing it before word alignment,
    /// JSON serialization and summary generation.
    static func diarize(_ speaker:SpeakerKit,audio:URL,duration:Double,eventURL:URL?=nil) async throws -> DiarizationResult {
        let pcm=try fullDiarizationPCM(audio,duration:duration)
        let eventURL=eventURL ?? ProcessInfo.processInfo.environment["VECTA_SPEECH_EVENT_PATH"].map {URL(fileURLWithPath:$0)}
        return try await speaker.diarize(audioArray:pcm,options:PyannoteDiarizationOptions(useExclusiveReconciliation:false),progressCallback:{ progress in
            guard let eventURL else {return}
            let event=AIWorkerEvent(phase:"diarization",completed:Int(progress.completedUnitCount),total:Int(progress.totalUnitCount),generatedTokens:0,modelLoadSeconds:nil)
            if let bytes=try? JSONEncoder().encode(event) {try? bytes.write(to:eventURL,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:eventURL.path)}
        })
    }
}
