import Foundation

/// Synthetic/private IPC only. No host start, model lookup, worker or user library.
@main struct LocalAIEventCacheChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vecta-event-cache-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("event.json"),other=root.appendingPathComponent("other.json")
        var cache=AIRevisionFileCache<String>(),decodes=0
        func read(_ url:URL?,limit:Int=64)->String? {
            cache.read(url,limit:limit) {bytes in decodes+=1;return String(decoding:bytes,as:UTF8.self)}
        }
        check(read(file)==nil,"missing file must not return a stale snapshot")
        try Data("first".utf8).write(to:file,options:.atomic)
        check(read(file)=="first","initial read")
        for _ in 0..<20 {check(read(file)=="first","unchanged reuse")}
        check(decodes==1,"an unchanged revision decodes exactly once")
        // Atomic same-size replacement with preserved mtime still changes inode.
        let mtime=try file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate!
        try Data("other".utf8).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.modificationDate:mtime],ofItemAtPath:file.path)
        check(read(file)=="other" && decodes==2,"replacement identity must invalidate even with same size/date")
        try Data("second".utf8).write(to:other,options:.atomic)
        check(read(other)=="second" && decodes==3,"changing file ownership invalidates")
        check(read(nil)==nil,"explicit channel invalidation")
        check(read(other)=="second" && decodes==4,"invalidated channel must decode anew")
        try FileManager.default.removeItem(at:other)
        check(read(other)==nil,"deletion must clear a previously decoded value")
        try Data(repeating:65,count:65).write(to:other,options:.atomic)
        check(read(other)==nil && decodes==4,"oversize files are rejected before decode")
        try Data(repeating:65,count:64).write(to:other,options:.atomic)
        check(read(other)?.utf8.count==64 && decodes==5,"exact size limit remains valid")
        let link=root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:other)
        check(read(link)==nil && decodes==5,"symlinks are not IPC files")
        check(read(root)==nil,"directories are not IPC files")
        var failed=AIRevisionFileCache<String>(),failures=0
        for _ in 0..<3 {
            let value=failed.read(file,limit:64) {_ in failures+=1;throw AIProcessingError.invalidSummary}
            check(value==nil,"failed JSON does not expose old state")
        }
        check(failures==1,"invalid revision is not repeatedly decoded")
        var racing=AIRevisionFileCache<String>()
        let raced=racing.read(file,limit:64) {_ in
            try Data("newer".utf8).write(to:file,options:.atomic)
            return "superseded"
        }
        check(raced==nil,"replacement during decode cannot be cached under prior revision")
        check(racing.read(file,limit:64) {String(decoding:$0,as:UTF8.self)}=="newer","replacement recovers on next read")

        let mailbox=LocalAIMailbox(),id=UUID(),checkpoint=root.appendingPathComponent("checkpoint.json")
        let draft=String(repeating:"Полный черновик. ",count:2000)
        func writeEvent(_ text:String) throws {
            try JSONEncoder().encode(AIWorkerEvent(phase:"generating",completed:2,total:4,generatedTokens:17,modelLoadSeconds:nil,draftText:text)).write(to:file,options:.atomic)
        }
        try writeEvent(draft)
        try JSONEncoder().encode(AISummaryProgress(phase:"facts",completed:2,total:4)).write(to:checkpoint,options:.atomic)
        let first=try await mailbox.progressFiles(id,root:root,eventURL:file,checkpointURL:checkpoint)
        let reused=try await mailbox.progressFiles(id,root:root,eventURL:file,checkpointURL:checkpoint)
        check(first.result==nil,"missing result is normal for standalone drafts")
        check(first.worker?.event.draftText==draft,"full draft must not be truncated")
        check(reused.worker?.revision==first.worker?.revision && reused.checkpoint==first.checkpoint,"both pollers reuse the same worker and checkpoint")
        check(first.checkpoint?.completed==2,"checkpoint progress decodes independently")
        try JSONSerialization.data(withJSONObject:["phase":"generating","completed":2,"total":4,"generatedTokens":17,"draftText":"valid text","semanticDraft":NSNull()]).write(to:file,options:.atomic)
        let nullSemantic=try await mailbox.progressFiles(id,root:root,eventURL:file,checkpointURL:nil)
        check(nullSemantic.worker?.event.draftText=="valid text" && nullSemantic.worker?.semanticData==nil,"invalid optional semantic payload must preserve valid progress/text")
        try writeEvent("replacement draft")
        let current=await mailbox.workerRevisionMatches(file,revision:first.worker!.revision)
        check(!current,"semantic await must reject a superseded event revision")
        try Data(repeating:32,count:2_000_001).write(to:file,options:.atomic)
        try Data(repeating:32,count:2_000_001).write(to:checkpoint,options:.atomic)
        let oversized=try await mailbox.progressFiles(id,root:root,eventURL:file,checkpointURL:checkpoint)
        check(oversized.worker==nil && oversized.checkpoint==nil,"both IPC channels enforce byte limits")
        try writeEvent(String(repeating:"x",count:1_000_001))
        let largeDraft=try await mailbox.progressFiles(id,root:root,eventURL:file,checkpointURL:nil)
        check(largeDraft.worker==nil,"draft size limit is enforced independently")
        try FileManager.default.removeItem(at:file)
        let missing=try await mailbox.progressFiles(id,root:root,eventURL:file,checkpointURL:nil)
        check(missing.worker==nil && missing.checkpoint==nil,"missing events do not retain old drafts/checkpoints")

        let library=root.appendingPathComponent("library.json"),newID=UUID()
        let raw="{\"paragraphs\":[{\"text\":\"Первая строка\\nи \\\"цитата\\\"\"},{\"text\":\"Вторая\"},{\"text\":\"unfinished"
        try JSONSerialization.data(withJSONObject:["requestID":id.uuidString,"phase":"reviewing","draftText":raw]).write(to:library,options:.atomic)
        let answer=await mailbox.libraryEvent(library)
        check(answer?.requestID==id.uuidString && answer?.phase=="reviewing","library event preserves ownership and phase")
        check(answer?.draft=="Первая строка\nи \"цитата\"\n\nВторая","only complete JSON strings render, preserving escapes and Unicode")
        let answerReused=await mailbox.libraryEvent(library)
        check(answerReused?.draft==answer?.draft,"unchanged library event reuse")
        try JSONSerialization.data(withJSONObject:["requestID":newID.uuidString,"phase":"generating","draftText":"{\"text\":\"новый\"}"]).write(to:library,options:.atomic)
        let newAnswer=await mailbox.libraryEvent(library)
        check(newAnswer?.requestID != answer?.requestID && newAnswer?.draft=="новый","a reused library worker keeps per-answer identity")
        try Data(repeating:32,count:2_000_001).write(to:library,options:.atomic)
        let largeAnswer=await mailbox.libraryEvent(library)
        check(largeAnswer==nil,"library event size bound")

        let owner=AIWorkerPollIdentity(requestID:id,visualOnlyID:nil,eventURL:file,checkpointURL:checkpoint)
        check(owner.permitsPublication(current:owner,cancelled:false,stopped:false),"current owner publishes")
        check(!owner.permitsPublication(current:owner,cancelled:true,stopped:false),"cancelled await cannot publish")
        check(!owner.permitsPublication(current:owner,cancelled:false,stopped:true),"stopped host cannot publish")
        for stale in [
            AIWorkerPollIdentity(requestID:newID,visualOnlyID:nil,eventURL:file,checkpointURL:checkpoint),
            AIWorkerPollIdentity(requestID:id,visualOnlyID:nil,eventURL:other,checkpointURL:checkpoint),
            AIWorkerPollIdentity(requestID:id,visualOnlyID:id,eventURL:file,checkpointURL:checkpoint),
            AIWorkerPollIdentity(requestID:id,visualOnlyID:nil,eventURL:file,checkpointURL:other)
        ] {check(!owner.permitsPublication(current:stale,cancelled:false,stopped:false),"stale request/file/retry/checkpoint ownership cannot publish")}

        let baseline=AIWorkProgress(stage:.summarizing,fraction:0.5,stageFraction:nil,generatedTokens:3,remainingSeconds:8,weightedEstimate:true,updatedAt:Date(timeIntervalSince1970:1),workerPhase:"generating",workerCompleted:1,workerTotal:2)
        func progress(_ stage:AIProcessingStage = .summarizing,_ fraction:Double = 0.5,_ units:Double? = nil,_ tokens:Int? = 3,_ eta:Double? = 8,_ weighted:Bool = true,_ phase:String? = "generating",_ completed:Int? = 1,_ total:Int? = 2)->AIWorkProgress {
            AIWorkProgress(stage:stage,fraction:fraction,stageFraction:units,generatedTokens:tokens,remainingSeconds:eta,weightedEstimate:weighted,updatedAt:Date(timeIntervalSince1970:2),workerPhase:phase,workerCompleted:completed,workerTotal:total)
        }
        check(!AIProgressPublication.changed(baseline,progress()),"timestamp-only changes must not publish")
        for next in [progress(.visualizing),progress(.summarizing,0.6),progress(.summarizing,0.5,0.1),progress(.summarizing,0.5,nil,4),progress(.summarizing,0.5,nil,3,7),progress(.summarizing,0.5,nil,3,8,false),progress(.summarizing,0.5,nil,3,8,true,"reviewing"),progress(.summarizing,0.5,nil,3,8,true,"generating",2),progress(.summarizing,0.5,nil,3,8,true,"generating",1,3)] {
            check(AIProgressPublication.changed(baseline,next),"stage/units/tokens/ETA/calibration/phase changes must publish")
        }
        check(AIProgressPublication.changed(nil,baseline),"initial progress publishes")
        let measurementURL=root.appendingPathComponent("measurements.json")
        let measurement=AIStageMeasurement(stage:"summarizing",model:"synthetic",inputBucket:0,deviceMemoryGB:8,seconds:2,recordedAt:Date())
        await mailbox.saveMeasurements([measurement],to:measurementURL,revision:2)
        await mailbox.saveMeasurements([],to:measurementURL,revision:1)
        let saved=try JSONDecoder().decode([AIStageMeasurement].self,from:Data(contentsOf:measurementURL))
        check(saved==[measurement],"late measurement writes cannot overwrite newer history")
        print("PASS: local AI revision cache, bounded IPC, complete drafts, ownership, progress publication, serialized measurements")
    }
}
