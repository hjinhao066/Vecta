import Foundation
import Darwin
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Explicit offline research executable. Never packaged or called by the app.
/// Prompts and private recordings are supplied at invocation, not embedded here.
@main struct SummaryBenchmark {
    enum Failure: Error {case input, context, missingCompletion}
    static func main() async {
        do {try await run()}
        catch {FileHandle.standardError.write(Data("summary_benchmark_failed: \(error)\n".utf8));exit(1)}
    }
    static func run() async throws {
        guard CommandLine.arguments.count==4 else {throw Failure.input}
        let modelDirectory=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let inputURL=URL(fileURLWithPath:CommandLine.arguments[2])
        let output=URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
        guard let input=try JSONSerialization.jsonObject(with:Data(contentsOf:inputURL)) as? [String:Any],
              let segments=input["segments"] as? [[String:Any]],!segments.isEmpty,
              let instruction=input["instruction"] as? String,
              let mode=input["mode"] as? String,["direct","facts","chunkFacts"].contains(mode)
        else {throw Failure.input}
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        func save(_ name:String,_ data:Data)throws {
            let path=output.appendingPathComponent(name)
            try data.write(to:path,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        }
        func json(_ name:String,_ value:[String:Any])throws {
            try save(name,JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]))
        }
        func event(_ phase:String,_ completed:Int=0,_ total:Int=0)throws {
            try json("events.json",["pid":getpid(),"phase":phase,"completed":completed,"total":total])
        }
        let began=Date()
        Memory.cacheLimit=64*1024*1024
        Memory.memoryLimit=Int(Double(ProcessInfo.processInfo.physicalMemory)*0.65)
        Memory.peakMemory=0
        try event("loading")
        let loadStart=Date()
        let model=try await LLMModelFactory.shared.loadContainer(from:modelDirectory,using:#huggingFaceTokenizerLoader())
        let loadSeconds=Date().timeIntervalSince(loadStart)
        let tokenizer=await model.tokenizer
        let context=min(262144,max(8192,input["contextTokens"] as? Int ?? 65536))
        let maxOutput=min(65536,max(256,input["maxTokens"] as? Int ?? 4096))
        let temperature=(input["temperature"] as? NSNumber)?.floatValue ?? 0
        let topP=(input["topP"] as? NSNumber)?.floatValue ?? 1
        let topK=input["topK"] as? Int ?? 0
        let repetitionPenalty=(input["repetitionPenalty"] as? NSNumber)?.floatValue
        let repetitionContextSize=input["repetitionContextSize"] as? Int ?? 20
        var calls=[[String:Any]]()
        func count(_ system:String,_ text:String)throws->Int {
            try tokenizer.applyChatTemplate(messages:[["role":"system","content":system],["role":"user","content":text]],tools:nil,additionalContext:["enable_thinking":false]).count
        }
        func generate(_ system:String,_ text:String,_ label:String,_ limit:Int)async throws->String {
            let inputTokens=try count(system,text)
            guard inputTokens+limit<=context else {throw Failure.context}
            try event(label)
            let session=ChatSession(model,instructions:system,
                generateParameters:GenerateParameters(maxTokens:limit,temperature:temperature,topP:topP,topK:topK,repetitionPenalty:repetitionPenalty,repetitionContextSize:repetitionContextSize,seed:42),
                additionalContext:["enable_thinking":false])
            let started=Date()
            var raw="",completion:GenerateCompletionInfo?,toolCalls=0
            var checkpointCharacters=0
            do {
                for try await item in session.streamDetails(to:text) {
                    try Task.checkCancellation()
                    switch item {
                    case .chunk(let text):
                        raw+=text
                        if raw.utf8.count-checkpointCharacters>=16384 {
                            try save(label+".partial.txt",Data(raw.utf8))
                            checkpointCharacters=raw.utf8.count
                        }
                    case .info(let info):completion=info
                    case .toolCall,.rejectedToolCall:toolCalls+=1
                    }
                }
                await session.synchronize()
            } catch {
                try? save(label+".partial.txt",Data(raw.utf8))
                await session.clear();Memory.clearCache();throw error
            }
            let elapsed=Date().timeIntervalSince(started)
            try save(label+".txt",Data(raw.utf8))
            await session.clear();Memory.clearCache()
            guard let info=completion else {throw Failure.missingCompletion}
            let call:[String:Any]=["label":label,"wallSeconds":elapsed,"countedPromptTokens":inputTokens,
                "promptTokens":info.promptTokenCount,"totalPromptTokens":info.totalPromptTokenCount,
                "cachedPromptTokens":info.cachedPromptTokenCount,"generationTokens":info.generationTokenCount,
                "evictedTokens":info.evictedTokenCount,"promptSeconds":info.promptTime,
                "generationSeconds":info.generateTime,"stopReason":String(describing:info.stopReason),
                "toolCalls":toolCalls,"outputLimit":limit]
            calls.append(call);try json("calls.json",["calls":calls])
            return raw
        }
        let lines=segments.map {($0["speakerID"] as? String ?? "unknown")+": "+($0["text"] as? String ?? "")}
        let transcript=lines.joined(separator:"\n")
        let prefix=input["userPrefix"] as? String ?? ""
        let suffix=input["userSuffix"] as? String ?? ""
        var raw:String
        var sourceGroups=[[Int]]()
        if mode=="direct" {
            sourceGroups=[Array(segments.indices)]
            raw=try await generate(instruction,prefix+transcript+suffix,"final",maxOutput)
        } else {
            guard let extraction=input["extractInstruction"] as? String else {throw Failure.input}
            let extractLimit=min(3072,max(512,input["extractMaxTokens"] as? Int ?? 2048))
            let target=input["chunkTokens"] as? Int ?? 4096
            var chunks=[String]()
            if mode=="facts" {chunks=[transcript];sourceGroups=[Array(segments.indices)]}
            else {
                var group=[Int](),used=0
                for index in lines.indices {
                    let size=tokenizer.encode(text:lines[index]).count+1
                    guard size<=target else {throw Failure.context}
                    if !group.isEmpty && used+size>target {
                        chunks.append(group.map {lines[$0]}.joined(separator:"\n"));sourceGroups.append(group);group=[];used=0
                    }
                    group.append(index);used+=size
                }
                if !group.isEmpty {chunks.append(group.map {lines[$0]}.joined(separator:"\n"));sourceGroups.append(group)}
            }
            var facts=[String]()
            for index in chunks.indices {
                let value=try await generate(extraction,"Фрагмент \(index+1) из \(chunks.count).\nТРАНСКРИПТ:\n"+chunks[index],"extract_\(index+1)",extractLimit)
                facts.append(value);try event("extracting",index+1,chunks.count)
            }
            let combined=facts.enumerated().map {"Часть \($0.offset+1):\n"+$0.element}.joined(separator:"\n\n")
            raw=try await generate(instruction,prefix+combined+suffix,"final",maxOutput)
        }
        guard sourceGroups.flatMap({$0})==Array(segments.indices) else {throw Failure.input}
        try json("coverage.json",["segmentCount":segments.count,"sourceGroups":sourceGroups])
        try save("result.txt",Data(raw.utf8))
        var usage=rusage();let status=getrusage(RUSAGE_SELF,&usage)
        let userCPU=Double(usage.ru_utime.tv_sec)+Double(usage.ru_utime.tv_usec)/1_000_000
        let systemCPU=Double(usage.ru_stime.tv_sec)+Double(usage.ru_stime.tv_usec)/1_000_000
        let elapsed=Date().timeIntervalSince(began)
        try json("metrics.json",["loadSeconds":loadSeconds,"pipelineSeconds":elapsed,"calls":calls,
            "peakMLXBytes":Memory.peakMemory,"peakProcessRSSBytes":status==0 ? usage.ru_maxrss:0,
            "cpuSeconds":userCPU+systemCPU,"meanCPUPercent":(userCPU+systemCPU)/max(elapsed,0.001)*100,
            "contextLimit":context,"temperature":temperature,"seed":42,"sourceGroupCount":sourceGroups.count,
            "physicalMemory":ProcessInfo.processInfo.physicalMemory,
            "repetitionPenalty":repetitionPenalty.map { Double($0) } ?? 1.0,
            "repetitionContextSize":repetitionContextSize])
        try event("completed",1,1)
    }
}
