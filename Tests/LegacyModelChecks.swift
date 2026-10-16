import Foundation

@main struct LegacyModelChecks {
    static var checks=0
    static func check(_ value:@autoclosure () throws -> Bool,_ message:String)throws {
        guard try value() else {throw NSError(domain:"LegacyChecks",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
        checks+=1
    }
    static func main()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("vecta-legacy-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=LocalAIFileStore(root:root);try store.prepare()
        try check(store.summaryModel() == .qwen4b,"new profiles default to MLX")
        try store.setSummaryModel(.qwen)
        let preference=root.appendingPathComponent("LocalAI/summary-model.json")
        let preferenceBytes=try Data(contentsOf:preference)
        try check(store.summaryModel() == .qwen,"old explicit selection is not silently changed")
        try JSONEncoder().encode(AIAutomaticSettings(model:.qwen06b)).write(to:root.appendingPathComponent("LocalAI/automatic-processing.json"))
        try check(store.automaticAISettings().model == .qwen06b,"old automatic preference remains readable")
        var requests=[AIProcessingRequest](),originals=[UUID:Data](),completed=[UUID:Data]()
        for model:AISummaryModelID? in [nil,.qwen,.qwen06b] {
            for stage:AIProcessingStage? in [nil,.queued,.recognizing,.summarizing,.failed,.summaryFailed,.completed,.cancelled] {
                let request=AIProcessingRequest(version:1,id:UUID(),recordingID:"synthetic",audioFilename:"synthetic.wav",audioSHA256:String(repeating:"a",count:64),provider:.local,format:.standard,createdAt:Date(),summaryOnly:false,transcriptRequestID:nil,summaryModel:model)
                try request.validate()
                let bytes=try JSONEncoder().encode(request)
                try bytes.write(to:store.requestURL(request.id));requests.append(request);originals[request.id]=bytes
                if let stage {
                    let result=AIProcessingResult(version:1,request:request,stage:stage,transcript:stage == .queued ? nil:"Saved synthetic transcript",segments:[],summary:stage == .completed ? AIStructuredSummary(summary:"Saved synthetic summary",topics:[],decisions:[],tasks:[],uncertainties:[]):nil,error:stage == .failed ? "Original error":nil,updatedAt:Date(),duration:nil,recognitionSeconds:nil,summarySeconds:nil)
                    try store.save(result)
                    if stage == .completed || stage == .cancelled {completed[request.id]=try Data(contentsOf:store.resultURL(request.id))}
                }
            }
        }
        let checkpoint=root.appendingPathComponent("LocalAI/Results/speech-v1-preserved.json")
        try Data("preserved checkpoint".utf8).write(to:checkpoint)
        let changed=try store.recoverLegacyRequests()
        try check(changed.count == 18,"queued, interrupted, failed and absent results are retired")
        for request in requests {
            try check(Data(contentsOf:store.requestURL(request.id)) == originals[request.id],"original request bytes preserved")
            try check(store.result(request.id)?.request == request,"historical request model and identity preserved")
            if let bytes=completed[request.id] {
                try check(Data(contentsOf:store.resultURL(request.id)) == bytes,"completed/cancelled historical result bytes preserved")
            } else {
                let result=try store.result(request.id)!
                try check(!result.stage.isActive,"legacy request cannot stay executable")
                try check(result.error?.contains("MLX") == true,"explicit selection and reprocessing explanation")
                if result.transcript != nil {try check(result.transcript == "Saved synthetic transcript","intermediate transcript preserved")}
            }
        }
        try check(store.recoverLegacyRequests().isEmpty,"idempotent retirement")
        try check(Data(contentsOf:preference) == preferenceBytes,"recovery never changes selected model")
        try check(String(contentsOf:checkpoint,encoding:.utf8) == "preserved checkpoint","checkpoint never removed")
        let cache=LocalAIReadCache()
        try check(cache.nextRequest(root:root) == nil,"no retired queue work can execute")
        let old=requests[0]
        do {try store.submit(old);throw NSError(domain:"LegacyChecks",code:2)}
        catch AIProcessingError.retiredModel {checks+=1}
        let retry=AIProcessingRequest(version:1,id:UUID(),recordingID:old.recordingID,audioFilename:old.audioFilename,audioSHA256:old.audioSHA256,provider:.local,format:old.format,createdAt:Date(),summaryOnly:false,transcriptRequestID:nil,summaryModel:.qwen4b)
        try store.submit(retry)
        try check(cache.nextRequest(root:root)?.id == retry.id,"explicit MLX retry creates distinct work")
        try check(Data(contentsOf:store.requestURL(old.id)) == originals[old.id],"retry never overwrites original")
        for id in [AISummaryModelID.qwen,.qwen06b,.qwen4b,.qwen9b] {
            try check(JSONDecoder().decode(AISummaryModelID.self,from:JSONEncoder().encode(id)) == id,"Codable model identifier preserved")
        }
        try check(retry.wantsDiarization && retry.wantsSummary, "historical jobs retain diarization and summary defaults")
        var conference = retry
        conference.conference = AIConferenceProcessingOptions(diarization: false, recognizeKnownVoices: false, summary: false)
        conference.visualEnabled = true
        try conference.validate()
        try check(!conference.wantsDiarization && !conference.wantsSummary && !conference.wantsVisual, "transcription-only conference does not require speaker/summary stages")
        let decodedConference = try JSONDecoder().decode(AIProcessingRequest.self, from: JSONEncoder().encode(conference))
        try check(decodedConference == conference && decodedConference.conference?.recognizeKnownVoices == false, "conference settings survive request persistence")
        let result = AIProcessingResult(version: 1, request: conference, stage: .completed, transcript: "Synthetic transcript only", segments: [], summary: nil, error: nil, updatedAt: Date(), duration: 1, recognitionSeconds: 1, summarySeconds: nil)
        try result.validate()
        let plan = AIProgressPlan(result: result)
        try check(!plan.stages.contains(.diarizing) && !plan.stages.contains(.summarizing) && !plan.stages.contains(.visualizing), "disabled conference stages remain absent from progress")
        var automation = AIAutomaticSettings()
        automation.conference = conference.conference; automation.visual = false
        let decodedAutomation = try JSONDecoder().decode(AIAutomaticSettings.self, from: JSONEncoder().encode(automation))
        try check(decodedAutomation == automation, "automatic conference options survive durable queue settings")
        try check(JSONDecoder().decode(AIAutomaticSettings.self, from: Data("{}".utf8)).conference == nil, "old automatic settings keep their legacy scope")
        print("PASS \(checks) legacy model compatibility/recovery/retry and conference-processing checks; synthetic data only")
    }
}
