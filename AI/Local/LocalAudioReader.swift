import AVFoundation
import Foundation

struct LocalPCMRecording {
    let samples: [Float]
    let sampleRate: Int
    var duration: Double { Double(samples.count) / Double(sampleRate) }
}

enum LocalAudioError: Error, LocalizedError {
    case unreadable, contextLimit, memoryLimit, conversion, durationMismatch
    var errorDescription: String? {
        switch self {
        case .unreadable: return VL.text("Не удалось прочитать аудиозапись. Файл повреждён или формат не поддерживается.")
        case .contextLimit: return VL.text("Запись превышает контекст локальной модели. Она не будет обрезана или отправлена в облако.")
        case .memoryLimit: return VL.text("Недостаточно памяти для безопасной локальной обработки этой записи.")
        case .durationMismatch: return VL.text("Декодированная длительность не совпадает с аудиофайлом. Обработка остановлена, чтобы не потерять часть записи.")
        case .conversion: return VL.text("Не удалось подготовить моно-аудио для распознавания.")
        }
    }
}

enum LocalAudioReader {}

extension LocalAudioReader {
    static func duration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let value = Double(file.length) / file.processingFormat.sampleRate
        guard value.isFinite, value > 0 else { throw LocalAudioError.unreadable }
        return value
    }
    /// Decode only a bounded window. AVAssetReader seeks through compressed
    /// input without retaining the rest of the decoded recording in RAM.
    static func readWindow(_ url: URL, start: Double, end: Double) throws -> LocalPCMRecording {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end-start <= 140 else { throw LocalAudioError.contextLimit }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw LocalAudioError.unreadable }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds:start,preferredTimescale:16000), duration:CMTime(seconds:end-start,preferredTimescale:16000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey:kAudioFormatLinearPCM, AVSampleRateKey:16000, AVNumberOfChannelsKey:1, AVLinearPCMBitDepthKey:32, AVLinearPCMIsFloatKey:true, AVLinearPCMIsBigEndianKey:false, AVLinearPCMIsNonInterleaved:false])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw LocalAudioError.conversion }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var samples:[Float] = []; samples.reserveCapacity(Int((end-start)*16000))
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw LocalAudioError.conversion }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes % 4 == 0, samples.count + bytes/4 <= Int((end-start+1)*16000) else { throw LocalAudioError.conversion }
            let old = samples.count; samples.append(contentsOf: repeatElement(Float(0),count:bytes/4))
            let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:bytes,destination:$0.baseAddress!.advanced(by:old*4)) }
            guard status == kCMBlockBufferNoErr else { throw LocalAudioError.conversion }
        }
        guard reader.status == .completed, !samples.isEmpty, samples.allSatisfy(\.isFinite),
              abs(Double(samples.count)/16000-(end-start)) < 0.5 else { throw LocalAudioError.durationMismatch }
        return LocalPCMRecording(samples:samples,sampleRate:16000)
    }
}


extension LocalAudioReader {
    /// Energy-based pause placement, not a claim of model/VAD classification.
    /// Targets are adjusted by at most four seconds to a >=0.5 s quiet interval.
    static func windows(_ url: URL, duration: Double, configuration: AIStreamingConfiguration) throws -> [AIRecognitionWindow] {
        let fixed = try configuration.windows(duration:duration)
        guard configuration.pauseAware, fixed.count > 1 else { return fixed }
        var result:[AIRecognitionWindow] = []
        var start = 0.0
        while start < duration {
            let target = min(duration,start + configuration.chunkSeconds)
            var end = target
            if target < duration {
                let searchStart = max(start,target - 4)
                let pcm = try readWindow(url,start:searchStart,end:target)
                let bin = 1600 //100 ms at16kHz
                let bins = stride(from:0,to:pcm.samples.count,by:bin).map { offset -> Double in
                    let stop = min(pcm.samples.count,offset+bin)
                    let sum = pcm.samples[offset..<stop].reduce(0.0) { $0 + Double($1)*Double($1) }
                    return sqrt(sum/Double(stop-offset))
                }
                let threshold = max(0.0005,min(0.004,(bins.max() ?? 0)*0.02))
                var quiet = 0
                for (index,rms) in bins.enumerated() {
                    quiet = rms < threshold ? quiet+1 : 0
                    if quiet >= 5 { end = searchStart + Double(index-2)*0.1 }
                }
                if end <= start { end = target }
            }
            result.append(AIRecognitionWindow(index:result.count,coreStart:start,coreEnd:end,
                start:max(0,start-configuration.overlapSeconds),end:min(duration,end+configuration.overlapSeconds)))
            start = end
        }
        return result
    }
}
