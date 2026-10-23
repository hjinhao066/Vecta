import Foundation
import AVFoundation
import MLX

/// `VectaMLX --gigaam-speech <model directory> [event file]`, request JSON on stdin.
///
/// Recognizes a whole recording with GigaAM in bounded windows and writes the same
/// resumable speech checkpoint the Speech worker writes for Whisper. The Speech
/// worker then finds a complete checkpoint and continues with global SpeakerKit
/// diarization, word attribution and transcript assembly, so every downstream
/// feature is engine-independent.
enum GigaAMSpeech {
    struct Window { let index: Int; let start: Double; let end: Double; let coreStart: Double; let coreEnd: Double }
    struct UnalignedWord: Codable { let chunk: Int; let start: Double; let end: Double; let text: String }
    struct GlobalWord: Codable {
        let start: Double; let end: Double; let text: String; let chunk: Int
        var globalID: Int?; var candidates: [Int]; var uncertainty: String
        let matchConfidence: Double?; let userConfirmation: String?
    }
    /// Mirrors `VectaSpeechPipeline.runWholeRecording`'s private checkpoint schema.
    struct Checkpoint: Codable {
        let version: Int; let digest: String; let duration: Double
        let completed: Int; let seconds: Double
        let words: [GlobalWord]; let unaligned: [UnalignedWord]
        var outputLanguage: String? = nil
        var decodingPolicy: String? = nil
    }
    enum Failure: Error { case invalidInput, audio }

    static func windows(duration: Double, chunk: Double, overlap: Double) throws -> [Window] {
        guard duration.isFinite, duration > 0, chunk.isFinite, (15...120).contains(chunk),
              overlap.isFinite, (0...10).contains(overlap), overlap < chunk / 2 else { throw Failure.invalidInput }
        return (0..<Int(ceil(duration / chunk))).map { i in
            let start = Double(i) * chunk, end = min(duration, start + chunk)
            return Window(index: i, start: max(0, start - overlap), end: min(duration, end + overlap), coreStart: start, coreEnd: end)
        }
    }

    static func duration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let value = Double(file.length) / file.processingFormat.sampleRate
        guard value.isFinite, value > 0 else { throw Failure.audio }
        return value
    }

    /// Same bounded 16 kHz mono decode the Speech worker uses for Whisper windows.
    static func readWindow(_ url: URL, start: Double, end: Double) throws -> [Float] {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 140 else { throw Failure.audio }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw Failure.audio }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16000), duration: CMTime(seconds: end - start, preferredTimescale: 16000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.audio }
        reader.add(output)
        guard reader.startReading() else { throw Failure.audio }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var samples: [Float] = []; samples.reserveCapacity(Int((end - start) * 16000))
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure.audio }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes % 4 == 0, samples.count + bytes / 4 <= Int((end - start + 1) * 16000) else { throw Failure.audio }
            let old = samples.count; samples.append(contentsOf: repeatElement(Float(0), count: bytes / 4))
            let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!.advanced(by: old * 4)) }
            guard status == kCMBlockBufferNoErr else { throw Failure.audio }
        }
        guard reader.status == .completed, !samples.isEmpty, samples.allSatisfy(\.isFinite),
              abs(Double(samples.count) / 16000 - (end - start)) < 0.5 else { throw Failure.audio }
        return samples
    }

    private static func privateWrite(_ data: Data, _ url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, arguments[1] == "--gigaam-speech" else { throw Failure.invalidInput }
        let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let events = arguments.count > 3 && !arguments[3].isEmpty ? URL(fileURLWithPath: arguments[3]) : nil
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count < 64_000,
              let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              input["mode"] as? String == "gigaam_speech",
              let audioPath = input["audio"] as? String, let checkpointPath = input["checkpoint"] as? String,
              let digest = input["digest"] as? String, digest.count == 64,
              let version = (input["checkpoint_version"] as? NSNumber)?.intValue,
              let policy = input["decoding_policy"] as? String,
              let chunk = (input["chunk_seconds"] as? NSNumber)?.doubleValue,
              let overlap = (input["overlap_seconds"] as? NSNumber)?.doubleValue else { throw Failure.invalidInput }
        let outputLanguage = input["output_language"] as? String
        let audio = URL(fileURLWithPath: audioPath), checkpointURL = URL(fileURLWithPath: checkpointPath)
        let values = try audio.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.invalidInput }
        let total = try Self.duration(audio)
        let windows = try Self.windows(duration: total, chunk: chunk, overlap: overlap)

        func event(_ phase: String, _ done: Int, _ count: Int, _ load: Double? = nil) {
            guard let events else { return }
            var value: [String: Any] = ["phase": phase, "completed": done, "total": count, "generatedTokens": 0]
            if let load { value["modelLoadSeconds"] = load }
            if let bytes = try? JSONSerialization.data(withJSONObject: value) { try? privateWrite(bytes, events) }
        }

        var completed = 0, seconds = 0.0
        var words: [GlobalWord] = [], unaligned: [UnalignedWord] = []
        let checkpointValues = try? checkpointURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        if checkpointValues?.isRegularFile == true, checkpointValues?.isSymbolicLink != true, (checkpointValues?.fileSize ?? 0) < 32_000_000,
           let saved = try? JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL)),
           saved.digest == digest, saved.duration == total, saved.version == version,
           saved.decodingPolicy == policy, saved.outputLanguage == outputLanguage,
           (0...windows.count).contains(saved.completed), saved.seconds.isFinite, saved.seconds >= 0 {
            completed = saved.completed; seconds = saved.seconds; words = saved.words; unaligned = saved.unaligned
        }
        if completed < windows.count {
            Memory.cacheLimit = 256 * 1024 * 1024
            event("loading", 0, windows.count)
            let loadStart = Date()
            let model = try GigaAMModel(directory: directory)
            let load = Date().timeIntervalSince(loadStart)
            event("recognition", completed, windows.count, load)
            for window in windows.dropFirst(completed) {
                try Task.checkCancellation()
                let samples = try readWindow(audio, start: window.start, end: window.end)
                let started = Date()
                let recognized = try model.transcribe(samples)
                seconds += Date().timeIntervalSince(started)
                let length = Double(samples.count) / 16000
                for word in recognized {
                    guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start, word.start < length else {
                        unaligned.append(UnalignedWord(chunk: window.index, start: word.start.isFinite ? word.start : -1, end: word.end.isFinite ? word.end : -1, text: word.text)); continue
                    }
                    let a = window.start + word.start, b = min(window.end, min(total, window.start + word.end))
                    guard (a + b) / 2 >= window.coreStart, (a + b) / 2 < window.coreEnd, b >= a else { continue }
                    words.append(GlobalWord(start: a, end: b, text: word.text, chunk: window.index, globalID: nil, candidates: [],
                                            uncertainty: "global diarization pending", matchConfidence: nil, userConfirmation: nil))
                }
                completed = window.index + 1
                try privateWrite(JSONEncoder().encode(Checkpoint(version: version, digest: digest, duration: total, completed: completed,
                    seconds: seconds, words: words, unaligned: unaligned, outputLanguage: outputLanguage, decodingPolicy: policy)), checkpointURL)
                event("recognition", completed, windows.count, load)
                Memory.clearCache()
            }
        } else {
            event("recognition", completed, windows.count)
        }
        let summary: [String: Any] = ["engine": "gigaam", "windows": windows.count, "words": words.count, "seconds": seconds]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: summary))
    }
}
