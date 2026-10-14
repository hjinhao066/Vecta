import AVFoundation
import Foundation
import Combine
import CryptoKit

/// Decode bounded PCM buffers. The display uses measured amplitudes, never
/// invented waveform bars, and reads user audio locally without modifying it.
enum NativeWaveform {
    static func amplitudes(at url: URL, bins: Int = 96) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, bins > 0, bins <= 512,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { return [] }
        var values = Array(repeating: Float(0), count: bins)
        var offset: Int64 = 0
        while offset < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - offset)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return [] }
            for frame in 0..<Int(buffer.frameLength) {
                let bin = min(bins - 1, Int(Double(offset + Int64(frame)) / Double(file.length) * Double(bins)))
                for channel in 0..<Int(buffer.format.channelCount) { values[bin] = max(values[bin], abs(channels[channel][frame])) }
            }
            offset += Int64(buffer.frameLength)
        }
        let peak = values.max() ?? 0
        return peak > 0 ? values.map { $0 / peak } : values
    }
}

@MainActor final class NativePlaybackState:ObservableObject {
    @Published var preparing=false
    @Published var playing=false
    @Published var progress:Double=0
    @Published var duration:Double=0
    @Published var waveform:[Float]=[]
    @Published var rate:Float=1
}
actor NativeWaveformCache {
    static let shared=NativeWaveformCache()
    func amplitudes(at url:URL,bins:Int=96)throws->[Float] {
        let v=try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey,.fileResourceIdentifierKey])
        let stamp="\(url.path)|\(bins)|\(v.fileSize ?? 0)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(String(describing:v.fileResourceIdentifier))"
        let key=SHA256.hash(data:Data(stamp.utf8)).map{String(format:"%02x",$0)}.joined()
        let folder=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("app.vecta.mac/WaveformsV1")
        let file=folder.appendingPathComponent(key+".json")
        if let bytes=try? Data(contentsOf:file),bytes.count<16000,let values=try? JSONDecoder().decode([Float].self,from:bytes),values.count==bins,values.allSatisfy({$0.isFinite && $0>=0 && $0<=1}) {return values}
        let values=try NativeWaveform.amplitudes(at:url,bins:bins);try Task.checkCancellation()
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if let data=try? JSONEncoder().encode(values) {try? data.write(to:file,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)}
        return values
    }
}
