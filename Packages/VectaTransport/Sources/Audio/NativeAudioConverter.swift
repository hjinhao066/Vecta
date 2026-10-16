import CNativeAudio
import Darwin
import Foundation
import NotePinTransport

public struct NativeAudioConversion: Equatable {
    public let outputURL: URL
    public let duration: Double
    public let decodedSamples: Int64
    public let sampleRate: Int
    public let channels: Int
    public let concealedPackets: Int
    public var recorderHighlightSeconds: [Double]? = nil
}

/// Native Opus -> PCM -> MP3, statically linked to pinned libopus and LAME.
/// No SDK, external executable or platform encoder is used. Never overwrites a
/// user file. Call off the main queue. Transport must verify full source size.
public enum NativeAudioConverter {
    /// Normalizes an imported Ogg for AVFoundation playback and speech decoding.
    /// The caller retains the original separately. No file is overwritten.
    public static func convertImportedOgg(rawURL:URL,outputURL:URL,maximumDuration:Double=21600)throws->NativeAudioConversion {
        let info=try ImportedOggInfo.inspect(rawURL,maximumDuration:maximumDuration)
        if info.opus {return try convert(rawURL:rawURL,outputURL:outputURL,channels:info.channels,expectedDuration:info.duration)}
        var channels:Int32=0,rate:Int32=0,frames:Int64=0,code:Int32=0
        guard let reader=op_vorbis_open(rawURL.path,&channels,&rate,&frames) else {throw NativeAudioError.malformedOgg}
        defer {op_vorbis_close(reader)}
        guard channels==info.channels,rate==info.sampleRate,frames==info.frames else {throw NativeAudioError.incompleteAudio}
        guard let codec=op_audio_encoder_create(channels,rate,&code) else {throw NativeAudioError.codecFailure(code)}
        defer {op_audio_destroy(codec)}
        let output=try PrivateAudioFile(beside:outputURL,suffix:"mp3")
        var pcm=[Int16](repeating:0,count:8192*Int(channels)),encoded=[UInt8](repeating:0,count:32768),written:Int64=0
        while true {
            try Task.checkCancellation()
            let count=op_vorbis_read(reader,&pcm,8192)
            guard count>=0 else {throw NativeAudioError.malformedOgg}
            if count==0 {break}
            written+=Int64(count);guard written<=frames else {throw NativeAudioError.incompleteAudio}
            let n=op_audio_mp3(codec,pcm,count,&encoded,Int32(encoded.count))
            guard n>=0 else {throw NativeAudioError.codecFailure(n)}
            try output.handle.write(contentsOf:Data(encoded.prefix(Int(n))))
        }
        guard written==frames else {throw NativeAudioError.incompleteAudio}
        let n=op_audio_flush(codec,&encoded,Int32(encoded.count));guard n>=0 else {throw NativeAudioError.codecFailure(n)}
        try output.handle.write(contentsOf:Data(encoded.prefix(Int(n))))
        try output.handle.synchronize();try output.handle.close();try Task.checkCancellation()
        guard link(output.url.path,outputURL.path)==0 else {
            if errno==EEXIST {throw NativeAudioError.outputExists}
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))
        }
        return .init(outputURL:outputURL,duration:info.duration,decodedSamples:written,sampleRate:Int(rate),channels:Int(channels),concealedPackets:0)
    }
    public static func convert(rawURL: URL, outputURL: URL, channels: Int,
                               expectedDuration: Double? = nil,
                               privateKey: PartnerRSAKey? = nil,
                               contentDecryptor: ((Data) throws -> Data)? = nil,
                               recoverDamagedRecorderPackets: Bool = false,
                               readRecorderHighlights: Bool = false) throws -> NativeAudioConversion {
        guard channels == 1 || channels == 2 else { throw NativeAudioError.unsupportedChannels }
        guard rawURL.isFileURL, outputURL.isFileURL, rawURL != outputURL else { throw NativeAudioError.invalidHeader }
        let raw = try FileHandle(forReadingFrom: rawURL)
        defer { try? raw.close() }
        let prefix = try raw.read(upToCount: 512) ?? Data()
        try raw.seek(toOffset: 0)
        var prepared: URL?
        defer { if let prepared { try? FileManager.default.removeItem(at: prepared) } }
        var input = raw
        var highlightFormat = false
        if EncryptedAudioHeader.isEncrypted(prefix) || contentDecryptor != nil {
            // Modern file AEAD has one whole-file tag. Bound the read before
            // loading it; reject giant/unbounded data rather than allocate it.
            let size = try raw.seekToEnd(); try raw.seek(toOffset: 0)
            guard size <= 536_870_912 else { throw NativeAudioError.incompleteAudio }
            let all = try raw.readToEnd() ?? Data()
            guard all.count == size else { throw NativeAudioError.incompleteAudio }
            let bytes: Data
            if EncryptedAudioHeader.isEncrypted(prefix) {
                guard let privateKey else { throw NativeAudioError.encryptedFileRequiresKey }
                let header = try EncryptedAudioHeader(data: prefix)
                highlightFormat = readRecorderHighlights && RecorderHighlightFrames.supports(header)
                guard header.channels == channels else { throw NativeAudioError.invalidHeader }
                bytes = try header.decrypt(Data(all.dropFirst(512)), privateKey: privateKey)
            } else { bytes = try contentDecryptor!(all) }
            let temporary = try PrivateAudioFile(beside: outputURL, suffix: "prepared")
            try temporary.handle.write(contentsOf: bytes); try temporary.handle.close()
            prepared = temporary.url; temporary.keep = true
            input = try FileHandle(forReadingFrom: temporary.url)
        }
        defer { if prepared != nil { try? input.close() } }
        let start = try input.read(upToCount: 4) ?? Data(); try input.seek(toOffset: 0)
        let ogg = start == Data("OggS".utf8)
        let reader = ogg ? try OggOpusReader(input: input) : nil
        guard reader?.channelCount == nil || reader?.channelCount == channels else { throw NativeAudioError.unsupportedChannels }
        let sampleRate = ogg ? 48_000 : 16_000
        var code: Int32 = 0
        guard let codec = op_audio_create(Int32(channels), Int32(sampleRate), &code) else { throw NativeAudioError.codecFailure(code) }
        defer { op_audio_destroy(codec) }
        let output = try PrivateAudioFile(beside: outputURL, suffix: "mp3")
        let capacity = sampleRate * 120 / 1000
        var pcm = [Int16](repeating: 0, count: capacity * channels)
        var encoded = [UInt8](repeating: 0, count: 32_768)
        var total: Int64 = 0, written: Int64 = 0
        var packetCount = 0, concealedPackets = 0, consecutiveConcealed = 0
        var highlights: [Double] = []
        var skip = reader?.skipSamples ?? 0
        while true {
            try Task.checkCancellation()
            let packet: Data?
            if let reader { packet = try reader.next() }
            else {
                let bytes = try input.read(upToCount: 80 * channels) ?? Data()
                if bytes.isEmpty { packet = nil }
                else {
                    guard bytes.count == 80 * channels else { throw NativeAudioError.incompleteAudio }
                    packet = bytes
                }
            }
            guard var packet else { break }
            if highlightFormat, !ogg, RecorderHighlightFrames.normalize(&packet) {
                highlights.append(Double(packetCount) * 0.02)
            }
            packetCount += 1
            var count = packet.withUnsafeBytes { p in
                op_audio_decode(codec, p.bindMemory(to: UInt8.self).baseAddress, Int32(packet.count), &pcm, Int32(capacity))
            }
            // Authenticated recorder files can contain isolated malformed Opus
            // packets. Conceal only INVALID_PACKET (-4), after valid audio, in
            // the fixed 20ms format. Imports/Ogg remain strict. Never shift time
            // by skipping bytes or accept a wrong key/format as recovered audio.
            if count == -4, recoverDamagedRecorderPackets, !ogg, written > 0 {
                guard consecutiveConcealed < 2 else { throw NativeAudioError.malformedOpus }
                count = op_audio_conceal(codec, &pcm, 320)
                concealedPackets += 1; consecutiveConcealed += 1
            } else { consecutiveConcealed = 0 }
            guard count > 0, ogg || count == 320 else { throw NativeAudioError.codecFailure(count) }
            if let reader,reader.outputGain != 1 {
                for index in 0..<(Int(count)*channels) {pcm[index]=Int16(max(-32768,min(32767,Double(pcm[index])*reader.outputGain)))}
            }
            total += Int64(count)
            let dropped = min(skip, Int(count)); skip -= dropped
            if dropped == count { continue }
            if dropped > 0 { pcm.replaceSubrange(0..<(Int(count) - dropped) * channels, with: pcm[(dropped * channels)..<(Int(count) * channels)]) }
            var usable = Int(count) - dropped
            if let reader, let granule = reader.finalGranule {
                guard granule >= UInt64(reader.skipSamples) else { throw NativeAudioError.malformedOgg }
                let target = Int64(granule) - Int64(reader.skipSamples)
                usable = min(usable, max(0, Int(target - written)))
            }
            if usable == 0 { continue }
            let length = op_audio_mp3(codec, pcm, Int32(usable), &encoded, Int32(encoded.count))
            guard length >= 0 else { throw NativeAudioError.codecFailure(length) }
            try output.handle.write(contentsOf: Data(encoded.prefix(Int(length))))
            written += Int64(usable)
        }
        guard written > 0, skip == 0 else { throw NativeAudioError.incompleteAudio }
        // At most 1% damage in a complete file; never publish widespread damage.
        guard concealedPackets * 100 <= packetCount else { throw NativeAudioError.malformedOpus }
        // A final Ogg granule may trim encoder padding. Require consistency;
        // legacy fixed Opus has exactly 20ms per packet and no padding fields.
        if let reader, let granule = reader.finalGranule {
            guard granule <= UInt64(total), granule >= UInt64(reader.skipSamples),
                  UInt64(total) - granule < 5_760 else { throw NativeAudioError.malformedOgg }
        }
        let duration = Double(written) / Double(sampleRate)
        if let expectedDuration, expectedDuration > 0 {
            guard expectedDuration.isFinite, abs(duration - expectedDuration) <= max(0.6, expectedDuration * 0.05) else { throw NativeAudioError.incompleteAudio }
        }
        let last = op_audio_flush(codec, &encoded, Int32(encoded.count))
        guard last >= 0 else { throw NativeAudioError.codecFailure(last) }
        try output.handle.write(contentsOf: Data(encoded.prefix(Int(last))))
        try output.handle.synchronize(); try output.handle.close()
        // link() is atomic create-if-absent. FileManager.moveItem/rename could
        // otherwise replace a destination created concurrently by another task.
        guard link(output.url.path, outputURL.path) == 0 else {
            if errno == EEXIST { throw NativeAudioError.outputExists }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return NativeAudioConversion(outputURL: outputURL, duration: duration,
                                     decodedSamples: written, sampleRate: sampleRate, channels: channels,
                                     concealedPackets: concealedPackets, recorderHighlightSeconds: highlightFormat && !ogg ? highlights : nil)
    }
}

private final class PrivateAudioFile {
    let url: URL
    let handle: FileHandle
    var keep = false
    init(beside target: URL, suffix: String) throws {
        var template = Array(target.deletingLastPathComponent().appendingPathComponent(".vecta-\(suffix)-XXXXXX").path.utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        url = URL(fileURLWithPath: String(cString: template))
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    deinit { try? handle.close(); if !keep { try? FileManager.default.removeItem(at: url) } }
}
