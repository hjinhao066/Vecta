import Foundation

/// Bounded, sequential Ogg reader. Rejects CRC damage, gaps, truncation,
/// unsupported channel maps, chained streams and incomplete final packets.
final class OggOpusReader {
    private let input: FileHandle
    private var serial: UInt32?
    private var nextSequence: UInt32 = 0
    private var packet = Data()
    private var ready: [Data] = []
    private var reachedEOS = false
    private var seenTags = false
    private(set) var finalGranule: UInt64?

    init(input: FileHandle) throws {
        self.input = input
        try page()
        guard !ready.isEmpty else { throw NativeAudioError.malformedOgg }
        let head = Array(ready.removeFirst())
        guard head.count == 19, Data(head[0..<8]) == Data("OpusHead".utf8), head[8] == 1,
              (head[9] == 1 || head[9] == 2), head[18] == 0 else {
            throw NativeAudioError.malformedOgg
        }
        // Stored separately to keep header metadata immutable to callers.
        parsedChannels = Int(head[9]); parsedPreSkip = Int(audioUInt16(head, 10));outputGain=pow(10,Double(Int16(bitPattern:audioUInt16(head,16)))/256/20)
    }
    private(set) var outputGain:Double=1
    private var parsedChannels = 0
    private var parsedPreSkip = 0
    var channelCount: Int { parsedChannels }
    var skipSamples: Int { parsedPreSkip }

    func next() throws -> Data? {
        while ready.isEmpty {
            if reachedEOS {
                guard packet.isEmpty, (try input.read(upToCount: 1) ?? Data()).isEmpty else {
                    throw NativeAudioError.malformedOgg
                }
                return nil
            }
            try page()
        }
        let item = ready.removeFirst()
        if !seenTags {
            guard item.count >= 16, item.prefix(8) == Data("OpusTags".utf8) else { throw NativeAudioError.malformedOgg }
            // Parse lengths to avoid treating an arbitrary/truncated packet as tags.
            let b = Array(item), vendorSize = Int(audioUInt32(b, 8))
            guard vendorSize <= b.count - 16 else { throw NativeAudioError.malformedOgg }
            var position = 12 + vendorSize
            let commentCount = audioUInt32(b, position); position += 4
            guard commentCount <= 65_536 else { throw NativeAudioError.malformedOgg }
            for _ in 0..<commentCount {
                guard position + 4 <= b.count else { throw NativeAudioError.malformedOgg }
                let size = Int(audioUInt32(b, position)); position += 4
                guard size <= b.count - position else { throw NativeAudioError.malformedOgg }
                position += size
            }
            seenTags = true
            return try next()
        }
        guard !item.isEmpty, item.count <= 65_536 else { throw NativeAudioError.malformedOgg }
        return item
    }

    private func page() throws {
        let header = try readExactly(27), h = Array(header)
        guard header.prefix(4) == Data("OggS".utf8), h[4] == 0, h[5] & ~UInt8(7) == 0 else {
            throw NativeAudioError.malformedOgg
        }
        let pageSerial = audioUInt32(h, 14), sequence = audioUInt32(h, 18)
        if let serial { guard pageSerial == serial else { throw NativeAudioError.malformedOgg } }
        else {
            guard sequence == 0, h[5] & 2 != 0 else { throw NativeAudioError.malformedOgg }
            serial = pageSerial
        }
        guard sequence == nextSequence, (h[5] & 1 != 0) == !packet.isEmpty,
              sequence == 0 || h[5] & 2 == 0 else { throw NativeAudioError.malformedOgg }
        nextSequence &+= 1
        let laces = Array(try readExactly(Int(h[26])))
        let body = try readExactly(laces.reduce(0) { $0 + Int($1) })
        var entire = header + Data(laces) + body
        entire.replaceSubrange(22..<26, with: [0, 0, 0, 0])
        guard Self.checksum(entire) == audioUInt32(h, 22) else { throw NativeAudioError.checksumMismatch }
        var offset = 0
        for length in laces {
            let count = Int(length)
            guard packet.count + count <= 1_048_576 else { throw NativeAudioError.malformedOgg }
            packet.append(body.subdata(in: offset..<(offset + count))); offset += count
            if length < 255 { ready.append(packet); packet.removeAll(keepingCapacity: true) }
        }
        if h[5] & 4 != 0 {
            guard packet.isEmpty else { throw NativeAudioError.malformedOgg }
            reachedEOS = true
            finalGranule = UInt64(audioUInt32(h, 6)) | UInt64(audioUInt32(h, 10)) << 32
            guard finalGranule != UInt64.max else { throw NativeAudioError.malformedOgg }
        }
    }
    private func readExactly(_ count: Int) throws -> Data {
        let bytes = try input.read(upToCount: count) ?? Data()
        guard bytes.count == count else { throw NativeAudioError.malformedOgg }
        return bytes
    }
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = (crc << 1) ^ (crc & 0x80000000 == 0 ? 0 : 0x04c11db7) }
        }
        return crc
    }
}
