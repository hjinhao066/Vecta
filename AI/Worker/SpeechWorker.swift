import Foundation
import CryptoKit
import Darwin

/// Production entry point: B only. Host owns the cross-process heavy-AI lease.
@main struct VectaSpeechWorker {
    static func main() async {
        var request: AIProcessingRequest?
        let output = CommandLine.arguments.count == 7 ? URL(fileURLWithPath:CommandLine.arguments[6]) : nil
        do {
            guard CommandLine.arguments.count == 7, let output else { throw AIProcessingError.invalidRequest }
            let audio = URL(fileURLWithPath:CommandLine.arguments[2])
            let decoded = try JSONDecoder().decode(AIProcessingRequest.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
            request = decoded;try decoded.validate()
            guard decoded.provider == .local,!decoded.summaryOnly else { throw AIProcessingError.invalidRequest }
            let duration = try LocalAudioReader.duration(audio)
            try AIAudioPolicy.validate(duration:duration)
            let values = try audio.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isRegularFile == true,values.isSymbolicLink != true else { throw AIProcessingError.invalidRequest }
            let file=try FileHandle(forReadingFrom:audio);defer { try? file.close() }
            var hash=SHA256()
            while let data=try file.read(upToCount:1048576),!data.isEmpty { try Task.checkCancellation();hash.update(data:data) }
            guard hash.finalize().map({String(format:"%02x",$0)}).joined()==decoded.audioSHA256 else { throw AIProcessingError.invalidRequest }
            let tokenizer=CommandLine.arguments[5]
            for name in ["tokenizer.json","tokenizer_config.json","config.json"] {
                guard FileManager.default.fileExists(atPath:URL(fileURLWithPath:tokenizer).appendingPathComponent(name).path) else { throw AIProcessingError.modelsMissing }
            }
            try await VectaSpeechPipeline.runWholeRecording(request:decoded,audio:audio,output:output,duration:duration,speakers:CommandLine.arguments[4],tokenizer:tokenizer,whisperModel:CommandLine.arguments[3])
        } catch {
            if let output,let request {
                var state=(try? JSONDecoder().decode(AIProcessingResult.self,from:Data(contentsOf:output))) ?? AIProcessingResult(version:1,request:request,stage:.failed,transcript:nil,segments:[],summary:nil,error:nil,updatedAt:Date(),duration:nil,recognitionSeconds:nil,summarySeconds:nil)
                state.stage = .failed;state.error=error.localizedDescription;state.updatedAt=Date()
                if let data=try? JSONEncoder().encode(state) { try? data.write(to:output,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path) }
            }
            fputs("Local speech processing failed.\n",stderr);exit(1)
        }
    }
}
