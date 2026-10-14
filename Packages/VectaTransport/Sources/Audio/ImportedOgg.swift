import CNativeAudio
import Foundation

/// Imported Ogg is validated completely before publishing decoded audio.
/// One mono/stereo Opus or Vorbis stream; damaged/chained containers fail.
struct ImportedOggInfo {
    let opus:Bool
    let channels:Int
    let sampleRate:Int
    let frames:Int64
    var duration:Double {Double(frames)/Double(sampleRate)}
    static func inspect(_ url:URL,maximumDuration:Double)throws->ImportedOggInfo {
        let file=try FileHandle(forReadingFrom:url);defer {try? file.close()}
        var serial:UInt32?,sequence:UInt32=0,pending=Data(),head:Data?,ended=false,granule:UInt64=0
        func exact(_ n:Int)throws->Data {let b=try file.read(upToCount:n) ?? Data();guard b.count==n else {throw NativeAudioError.malformedOgg};return b}
        while !ended {
            try Task.checkCancellation()
            let header=try exact(27),h=Array(header)
            guard header.prefix(4)==Data("OggS".utf8),h[4]==0,h[5] & ~UInt8(7)==0,
                  audioUInt32(h,18)==sequence,(h[5]&1 != 0) == !pending.isEmpty else {throw NativeAudioError.malformedOgg}
            let pageSerial=audioUInt32(h,14)
            if let serial {guard serial==pageSerial,h[5]&2==0 else {throw NativeAudioError.malformedOgg}}
            else {guard h[5]&2 != 0 else {throw NativeAudioError.malformedOgg};serial=pageSerial}
            sequence &+= 1
            let laces=Array(try exact(Int(h[26]))),body=try exact(laces.reduce(0){$0+Int($1)})
            var page=header+Data(laces)+body;page.replaceSubrange(22..<26,with:[0,0,0,0])
            guard OggOpusReader.checksum(page)==audioUInt32(h,22) else {throw NativeAudioError.checksumMismatch}
            var offset=0
            for lace in laces {
                let size=Int(lace)
                guard pending.count+size<=1_048_576 else {throw NativeAudioError.malformedOgg}
                pending.append(body.subdata(in:offset..<(offset+size)));offset+=size
                if lace<255 {if head==nil {head=pending};pending.removeAll(keepingCapacity:true)}
            }
            ended=h[5]&4 != 0
            if ended {guard pending.isEmpty else {throw NativeAudioError.malformedOgg};granule=UInt64(audioUInt32(h,6))|UInt64(audioUInt32(h,10))<<32}
        }
        guard (try file.read(upToCount:1) ?? Data()).isEmpty,let head,granule>0,granule<Int64.max else {throw NativeAudioError.malformedOgg}
        let b=Array(head),opus=head.prefix(8)==Data("OpusHead".utf8)
        let channels:Int,rate:Int,frames:Int64
        if opus {
            guard b.count==19,b[8]==1,b[18]==0 else {throw NativeAudioError.malformedOgg}
            channels=Int(b[9]);rate=48000
            let skip=UInt64(audioUInt16(b,10));guard granule>skip else {throw NativeAudioError.malformedOgg}
            frames=Int64(granule-skip)
        } else {
            guard b.count==30,b[0]==1,Data(b[1..<7])==Data("vorbis".utf8),audioUInt32(b,7)==0 else {throw NativeAudioError.malformedOgg}
            channels=Int(b[11]);rate=Int(audioUInt32(b,12));frames=Int64(granule)
        }
        guard (channels==1 || channels==2),(8000...192000).contains(rate),
              Double(frames)/Double(rate)<=maximumDuration else {throw NativeAudioError.incompleteAudio}
        return .init(opus:opus,channels:channels,sampleRate:rate,frames:frames)
    }
}
