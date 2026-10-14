import AppKit
import SwiftUI
import Combine
import CryptoKit
import NotePinTransport

enum VectaAppChecks {
    static func syntheticWiFiSession() throws -> SessionMaterial {
        let key = Data((0..<32).map(UInt8.init)), nonce = Data((32..<44).map(UInt8.init)), aad = Data((44..<56).map(UInt8.init))
        let proof = try ChaChaPoly.seal(Data("PLAUD.AI".utf8), using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        return try SessionMaterial.authenticate(rsaPlaintext: key + nonce + aad + proof.ciphertext + proof.tag)
    }
    @MainActor static func run() -> Bool {
        if CommandLine.arguments.contains("--verify-speaker-merge") {
            do {
                let model=NativeMacModel()
                guard let resources=Bundle.main.resourceURL else {throw AIProcessingError.invalidRequest}
                try model.verifySpeakerMerge(resources:resources)
            } catch {fatalError("Synthetic speaker merge failed: \(error)")}
            return true
        }
        if CommandLine.arguments.contains("--verify-language-restart-policy") {
            let blockers:[(NativeMacModel)->Void]=[
                {$0.resettingDevice=true},{$0.transferring=true},{$0.connecting=true},{$0.syncing=true},
                {$0.fastTransferPhase="switching"},{$0.importingAudio=true},{$0.chatBusy=true},
                {$0.libraryQuestionBusy=true},{$0.requestingAnalysis=true},{$0.visualRetryBusy=true},
                {$0.scanning=true},{$0.languageRestarting=true},{$0.batchChecking=true},{$0.batchActiveRequest=UUID()}
            ]
            for block in blockers {
                let model=NativeMacModel()
                precondition(model.canRestartForLanguage)
                block(model)
                precondition(!model.canRestartForLanguage)
                precondition(model.library == nil && model.localAI == nil)
            }
            let model=NativeMacModel()
            let request=AIProcessingRequest(version:1,id:UUID(),recordingID:"synthetic",audioFilename:"synthetic.wav",
                audioSHA256:String(repeating:"a",count:64),provider:.local,format:.detailed,createdAt:Date(),
                summaryOnly:false,transcriptRequestID:nil)
            model.analyses=[AIProcessingResult(version:1,request:request,stage:.queued,transcript:nil,segments:[],summary:nil,error:nil,updatedAt:Date(),duration:nil,recognitionSeconds:nil,summarySeconds:nil)]
            precondition(model.analysisBusy && !model.canRestartForLanguage)
            model.analyses=[]
            precondition(model.canRestartForLanguage)
            let bundle=URL(fileURLWithPath:"/synthetic/Quoted ' $(false) Vecta.app")
            let helper=NativeLanguageRestart.helper(bundle:bundle,pid:123,arguments:["--synthetic"],environment:["VECTA_TEST_LANGUAGE":"ru"])
            precondition(helper.executableURL?.path=="/bin/sh" && helper.arguments?.dropFirst(3).first=="123")
            precondition(helper.arguments?.contains(bundle.path)==true && helper.arguments?.last=="--synthetic")
            precondition(helper.environment?["VECTA_TEST_LANGUAGE"]==nil && !helper.isRunning)
            print("PASS language restart policy: fourteen activity blockers, queued analysis, idle recovery and positional helper arguments. No restart, process launch, production preferences, device or library accessed.")
            return true
        }
        if CommandLine.arguments.contains("--verify-fast-transfer-availability") {
            do {
                let model = NativeMacModel()
                for features in [nil, Data([1, 0x8a, 0, 0]), Data([1, 0x8a, 0, 8]), Data([1, 0x8a, 0, 8, 0, 1])] as [Data?] {
                    try model.prepareFastTransferVerification(features: features)
                    precondition(model.showsFastTransfer && model.canStartFastTransfer)
                }
                try model.prepareFastTransferVerification(supportsWiFi: false)
                precondition(model.showsFastTransfer && !model.canStartFastTransfer)
                try model.prepareFastTransferVerification(queued: true)
                precondition(model.showsFastTransfer && !model.canStartFastTransfer)
                try model.prepareFastTransferVerification()
                model.fastTransferPhase = "switching"
                precondition(!model.showsFastTransfer && !model.canStartFastTransfer)
                model.fastTransferPhase = nil; model.transferID = nil
                precondition(!model.showsFastTransfer && !model.canStartFastTransfer)
                try model.prepareFastTransferVerification()
                model.savedDevice = try SavedPlaudDevice(serialNumber: String(PlaudModel.notePin.projectCode) + "SYNTHETIC", model: .notePin, protocolVersion: 20)
                precondition(!model.showsFastTransfer && !model.canStartFastTransfer)
                try model.prepareFastTransferVerification()
                model.transferring = false
                precondition(!model.showsFastTransfer && !model.canStartFastTransfer)
                print("PASS Fast transfer availability: real model/transport gate accepts absent/ChaCha/AES/extended features; visible-disabled for busy/unsupported capability; hides for switching/no file/unsupported model/idle. Synthetic only; no Bluetooth, network or Keychain.")
            } catch { print(error); exit(1) }
            return true
        }
        if CommandLine.arguments.contains("--verify-library-ownership") {
            let application = NSApplication.shared
            Task { @MainActor in
                do { try await verifyLibraryOwnership(); exit(0) }
                catch { print(error); exit(1) }
            }
            application.run(); return true
        }
        if CommandLine.arguments.contains("--verify-summary-options") {
            let custom = VectaSummaryInterpretation(id: "custom_" + UUID().uuidString, title: "Проверка диктофона — кратко", prompt: "Test-only hidden instruction", revision: 1)
            let formats: [VectaSummaryInterpretation] = [.detailed, .actionPlan, .analytical, .nlp, custom]
            let template = AISummaryTemplate(id: "synthetic-template", title: "Проверка после перезапуска", prompt: "Test-only hidden template")
            let recipes = NativeSummarySelection.recipes(formats: formats, templates: [template])
            let visible = NativeSummarySelection.creationRecipes(in: recipes)
            precondition(visible.map(\.id) == ["format:detailed", "format:action_plan", "format:analytical", "format:nlp"])
            precondition(visible.allSatisfy { $0.group == "Основные" && $0.template == nil })
            precondition(NativeSummarySelection.selected("format:" + custom.id, legacyFormat: nil, in: visible)?.id == NativeSummarySelection.defaultID)
            precondition(NativeSummarySelection.selected("template:" + template.id, legacyFormat: nil, in: visible)?.id == NativeSummarySelection.defaultID)
            precondition(NativeSummarySelection.selected("format:analytical", legacyFormat: nil, in: visible)?.id == "format:analytical")
            precondition(recipes.contains { $0.format == custom } && recipes.contains { $0.template == template })
            print("PASS summary options: only four primary choices; hidden saved selection falls back to detailed; stored format/template and historical recipes preserved")
            return true
        }
        if CommandLine.arguments.contains("--verify-reset-policy") {
            do {
                let model = NativeMacModel()
                precondition(!model.canFactoryReset)
                model.savedDevice = try SavedPlaudDevice(serialNumber: "882SYNTHETIC", model: .notePinS, protocolVersion: 20)
                precondition(!model.canFactoryReset)
                model.offlineAuthorizationReady = true
                precondition(model.canFactoryReset)
                for blocker in 0..<7 {
                    model.resettingDevice = blocker == 0; model.transferring = blocker == 1
                    model.connecting = blocker == 2; model.syncing = blocker == 3
                    model.scanning = blocker == 4; model.showingDevicePicker = blocker == 5
                    model.showingDeviceSetup = blocker == 6
                    precondition(!model.canFactoryReset)
                }
                model.showingDeviceSetup = false
                precondition(model.canFactoryReset)
                let before = model.savedDevice
                model.factoryReset(confirmedSerial: "882DIFFERENT")
                precondition(model.savedDevice == before && !model.resettingDevice)
                model.savedDevice = try SavedPlaudDevice(serialNumber: "882SYNTHETIC", model: .notePinS, protocolVersion: 21)
                precondition(!model.canFactoryReset)
                for other in PlaudModel.allCases where other != .notePinS {
                    model.savedDevice = try SavedPlaudDevice(serialNumber: String(other.projectCode) + "SYNTHETIC", model: other, protocolVersion: 20)
                    precondition(!model.canFactoryReset)
                }
                precondition(model.library == nil && model.localAI == nil)
                print("PASS reset policy: supported target, cached authorization, seven busy/setup blockers and stale confirmation; no device, Keychain or library accessed")
            } catch { print(error); exit(1) }
            return true
        }
        if CommandLine.arguments.contains("--verify-export-eligibility") {
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-export-check-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let model = NativeMacModel()
                try model.prepareConversationVerification(root: root)
                let completed = model.analyses[0]
                precondition(model.canExportDocument(.summary, result: completed))
                precondition(model.canExportDocument(.transcript, result: completed))
                precondition(model.canExportDocument(.fullReport, result: completed))
                var active = completed
                active.stage = .queued; active.transcript = nil; active.segments = []
                active.summary = nil; active.visualSummary = nil; active.semanticSummary = nil
                precondition(!model.canExportDocument(.summary, result: active))
                precondition(!model.canExportDocument(.transcript, result: active))
                precondition(!model.canExportDocument(.fullReport, result: active))
                active.stage = .summarizing; active.transcript = completed.transcript; active.segments = completed.segments
                precondition(model.canExportDocument(.transcript, result: active))
                precondition(!model.canExportDocument(.summary, result: active))
                precondition(model.canExportDocument(.summary, result: completed))
                print("PASS export eligibility: missing active results are disabled; saved transcript and completed snapshot remain exportable")
            } catch { print(error); exit(1) }
            return true
        }
        if CommandLine.arguments.contains("--verify-performance-refresh") {
            let application=NSApplication.shared
            Task { @MainActor in
                do {
                    let formatter=NativeStreamingFormatter()
                    let text="# Heading\n\n"+String(repeating:"Complete **synthetic** paragraph.\n\n",count:8000)+"- final item\n\n```\nfinal code\n```"
                    var heartbeatCount=0,maximumGap=0.0,lastHeartbeat=ProcessInfo.processInfo.systemUptime
                    let heartbeat=Task { @MainActor in
                        while !Task.isCancelled {
                            let now=ProcessInfo.processInfo.systemUptime
                            maximumGap=max(maximumGap,now-lastHeartbeat);lastHeartbeat=now;heartbeatCount+=1
                            try? await Task.sleep(nanoseconds:1_000_000)
                        }
                    }
                    try await Task.sleep(nanoseconds:2_000_000)
                    let initialHeartbeats=heartbeatCount,formatStart=ProcessInfo.processInfo.systemUptime
                    let prepared=try await formatter.format(text),repeated=try await formatter.format(text)
                    let formatSeconds=ProcessInfo.processInfo.systemUptime-formatStart
                    heartbeat.cancel()
                    precondition(heartbeatCount>initialHeartbeats && maximumGap<0.5,"Main actor must stay runnable during synthetic formatting")
                    print(String(format:"Synthetic formatting seconds=%.3f mainActorMaxGap=%.3f heartbeats=%d",formatSeconds,maximumGap,heartbeatCount-initialHeartbeats))
                    let expected=AITextDocument(text).parts
                    precondition(prepared.map(\.source)==expected.map(\.displayText))
                    precondition(repeated.map(\.text)==prepared.map(\.text))
                    let final=try await formatter.format(text+"\n\nLast complete paragraph.")
                    precondition(final.last?.source=="Last complete paragraph.")
                    let cancelled=Task {try Task.checkCancellation();return try await formatter.format(text+"Cancelled")}
                    cancelled.cancel()
                    do {_ = try await cancelled.value;preconditionFailure("Cancelled formatting must not deliver")} catch is CancellationError {}
                    let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-performance-refresh-"+UUID().uuidString)
                    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                    defer {try? FileManager.default.removeItem(at:root)}
                    guard let resources=Bundle.main.resourceURL else{throw AIProcessingError.invalidRequest}
                    let model=NativeMacModel(),host=try LocalAIHost(root:root,resources:resources)
                    model.localAI=host;try model.prepareConversationVerification(root:root)
                    await model.reloadAnalysis()
                    let revision=model.presentationRevision
                    var publications=0
                    let observer=model.objectWillChange.sink{publications+=1}
                    await model.reloadAnalysis();await model.reloadAnalysis()
                    precondition(model.presentationRevision==revision && publications==0,"Unchanged history/sidecars must not invalidate presentation")
                    guard let result=model.rawAnalysis,let key=model.conversationKey,let speaker=model.conversation.identities.keys.sorted().first else{throw AIProcessingError.invalidRequest}
                    let store=AIConversationStore(root:root)
                    var recording=try store.recording(key,segments:result.segments)
                    try recording.rename(speaker,to:"Changed sidecar");try store.save(recording,key:key)
                    await model.reloadAnalysis()
                    precondition(model.conversation.name(speaker)=="Changed sidecar","Sidecar-only edits must refresh")
                    let alignment=LocalAIFileStore(root:root).resultURL(result.request.id).appendingPathExtension("alignment.json")
                    try JSONSerialization.data(withJSONObject:["complete":true,"words":[["start":0.0,"end":0.2,"text":"synthetic","globalID":NSNull()]],"centroids":[String:[Float]]()]).write(to:alignment,options:.atomic)
                    await model.reloadAnalysis()
                    precondition(model.wordTimings.map(\.text)==["synthetic"],"Alignment revision must refresh without transcript changes")
                    if let parent=result.request.transcriptRequestID {
                        let parentFile=LocalAIFileStore(root:root).resultURL(parent),savedParent=try Data(contentsOf:LocalAIFileStore(root:root).resultURL(parent))
                        let savedAlignment=try Data(contentsOf:alignment)
                        try FileManager.default.removeItem(at:parentFile)
                        let own=try await model.conversationRefresh.snapshot(root:root,key:key,result:result)
                        precondition(own.alignment?.words.map(\.text)==["synthetic"],"Complete own alignment must not require an unused parent")
                        try JSONSerialization.data(withJSONObject:["complete":false,"words":[Any](),"centroids":[String:[Float]]()]).write(to:alignment,options:.atomic)
                        do {_ = try await model.conversationRefresh.snapshot(root:root,key:key,result:result);preconditionFailure("Incomplete alignment must require its parent")} catch is AIProcessingError {}
                        try savedParent.write(to:parentFile,options:.atomic);try savedAlignment.write(to:alignment,options:.atomic)
                        for index in 0..<10 {
                            let invalidRoot=root.appendingPathComponent("failed-scope-\(index)")
                            try FileManager.default.createDirectory(at:invalidRoot,withIntermediateDirectories:true)
                            let invalidStore=LocalAIFileStore(root:invalidRoot);try invalidStore.prepare()
                            try JSONSerialization.data(withJSONObject:["complete":false,"words":[Any](),"centroids":[String:[Float]]()]).write(to:invalidStore.resultURL(result.request.id).appendingPathExtension("alignment.json"),options:.atomic)
                            do {_ = try await model.conversationRefresh.snapshot(root:invalidRoot,key:key,result:result);preconditionFailure("Missing parent must fail")} catch is AIProcessingError {}
                            let retained=await model.conversationRefresh.retainedIncompleteAlignmentCount
                            precondition(retained<=1,"Failed snapshot metadata must remain bounded to its current chain")
                        }
                    }
                    let delayed=Task {await model.refreshConversation(snapshotReader:{_,_,_ in
                        try await Task.sleep(nanoseconds:50_000_000)
                        return NativeConversationRefresh.Snapshot(revision:"stale",alignment:nil)
                    })}
                    try await Task.sleep(nanoseconds:10_000_000)
                    model.renameSpeaker(speaker,name:"Current local edit")
                    await delayed.value
                    precondition(model.conversation.name(speaker)=="Current local edit" && !model.wordTimings.isEmpty,"Delayed snapshot must not overwrite an edit")
                    let switched=Task {await model.refreshConversation(snapshotReader:{_,_,_ in
                        try await Task.sleep(nanoseconds:50_000_000)
                        return NativeConversationRefresh.Snapshot(revision:"old library",alignment:nil)
                    })}
                    try await Task.sleep(nanoseconds:10_000_000);model.libraryGeneration=UUID()
                    await switched.value
                    precondition(model.appliedConversationRevision != "old library","Old library snapshots must be rejected")
                    let cachedRevision=model.appliedConversationRevision,oldMessage=model.analysisMessage
                    let failed=Task {await model.refreshConversation(snapshotReader:{_,_,_ in
                        try await Task.sleep(nanoseconds:50_000_000);throw AIProcessingError.invalidRequest
                    })}
                    try await Task.sleep(nanoseconds:10_000_000)
                    let replacementRoot=root.appendingPathComponent("replacement-scope")
                    model.processingRoot=replacementRoot;model.conversationStateRoot=replacementRoot;model.voiceStateRoot=replacementRoot
                    await failed.value
                    precondition(model.conversationStateRoot==replacementRoot && model.voiceStateRoot==replacementRoot && model.appliedConversationRevision==cachedRevision && model.analysisMessage==oldMessage,"A stale failure must not mutate the replacement scope")
                    model.processingRoot=nil;await model.reloadAnalysis()
                    let originalSelection=model.selected
                    let oldReload=Task {await model.reloadAnalysis(historyReader:{try await Task.sleep(nanoseconds:50_000_000);return []})}
                    try await Task.sleep(nanoseconds:10_000_000)
                    let nextSelection=NativeRecordingIdentity(serialNumber:"SYNTHETIC",sessionID:2)
                    model.selected=nextSelection;model.analyses=[]
                    await model.reloadAnalysis();precondition(model.analysisReloadPending)
                    await oldReload.value
                    for _ in 0..<50 {
                        if !model.loadingHistory && !model.analyses.isEmpty {break}
                        try await Task.sleep(nanoseconds:10_000_000)
                    }
                    precondition(model.selected==nextSelection && !model.analyses.isEmpty,"A blocked selection reload must eventually load without another action")
                    model.selected=originalSelection
                    observer.cancel()
                    print("PASS complete cached streaming formatting/cancellation, unchanged-history publication, sidecar/alignment ancestry, stale success/failure guards and queued selection reload; synthetic only, no inference")
                    exit(0)
                } catch {print(error);exit(1)}
            }
            application.run();return true
        }
        if CommandLine.arguments.contains("--verify-saved-detail-preparation") {
            let application=NSApplication.shared
            Task { @MainActor in
                do {
                    let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-detail-check-"+UUID().uuidString)
                    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                    defer {try? FileManager.default.removeItem(at:root)}
                    let model=NativeMacModel()
                    try model.prepareConversationVerification(root:root)
                    await model.preparePresentation()
                    let expected=model.conversation.rendered(model.rawAnalysis!)
                    precondition(model.analysis==expected,"Off-main saved projection preserves source content")
                    let old=model.presentationRevision
                    let pending=Task {await model.preparePresentation()}
                    model.conversation=AIRecordingSpeakers()
                    await pending.value
                    precondition(model.presentationRevision != old)
                    await model.preparePresentation()
                    precondition(model.analysis==model.conversation.rendered(model.rawAnalysis!),"A superseded projection cannot overwrite speaker edits")
                    let host=try LocalAIHost(root:root,resources:Bundle.main.resourceURL!)
                    model.localAI=host
                    var changes=0
                    let observer=model.objectWillChange.sink {changes+=1}
                    for _ in 0..<100 {host.processingProgress=[:];host.summaryDrafts=[UUID():"Unrelated synthetic draft"]}
                    await Task.yield()
                    precondition(changes==0,"Unrelated host progress/drafts must not invalidate idle detail")
                    host.summaryDrafts=[model.rawAnalysis!.request.id:"Selected synthetic draft"]
                    try await Task.sleep(nanoseconds:20_000_000)
                    precondition(changes==1 && model.analysis?.summaryDraft=="Selected synthetic draft","Selected draft remains visible with coalesced root invalidation")
                    withExtendedLifetime(observer){}
                    let visual=model.rawAnalysis!.visualSummary!
                    let input=NativeVisualPreparationInput(report:visual,semantic:model.rawAnalysis!.semanticSummary,speakers:model.resolvedConversation)
                    let prepared=try await NativeVisualPreparation.shared.prepare(input,supportedSymbols:[])
                    precondition(prepared.displayed==AIVisualEditorial.refined(input.speakers.renderedVisual(input.semantic?.visual(style:.editorial) ?? visual)))
                    let again=try await NativeVisualPreparation.shared.prepare(input,supportedSymbols:[])
                    precondition(again.displayed==prepared.displayed && again.markdown==prepared.markdown)
                    print("PASS off-main saved projection, superseded speaker state, 100 unrelated host updates, selected draft forwarding and bounded visual preparation reuse; synthetic only")
                    exit(0)
                } catch {print(error);exit(1)}
            }
            application.run();return true
        }
        if CommandLine.arguments.contains("--verify-performance-state") {
            let model=NativeMacModel();var rootChanges=0,playerChanges=0,questionChanges=0
            let a=model.objectWillChange.sink{rootChanges+=1},b=model.playback.objectWillChange.sink{playerChanges+=1},c=model.libraryQuestionState.objectWillChange.sink{questionChanges+=1}
            for i in 0..<200 {model.progress=Double(i)/20;model.libraryQuestionPhase="Phase \(i)";model.libraryAnswerDraft="Draft \(i)"}
            precondition(rootChanges==0 && playerChanges==199 && questionChanges==400,"Fast state must stay scoped")
            model.progress=9.95;precondition(playerChanges==199,"Equal playback state must not publish")
            model.search="Question";_=model.librarySearchSession.submit(model.search);model.clearLibraryQuestion()
            precondition(model.search.isEmpty && !model.hasLibraryQuestion && model.libraryAnswerDraft.isEmpty && model.libraryQuestionPhase.isEmpty)
            model.wordTimings=(0..<20000).map{AIWordTiming(start:Double($0)*0.2,end:Double($0)*0.2+0.15,text:"word",globalID:nil)}
            let segment=AISpeechSegment(id:1,start:100,end:105,speaker:"Собеседник",text:"test")
            let expected=model.wordTimings.filter{$0.start>=segment.start-0.001 && $0.end<=segment.end+0.001}
            precondition(model.words(for:segment)==expected,"Indexed word slice must retain boundaries")
            model.wordTimings=[];precondition(model.words(for:segment).isEmpty,"Word cache invalidates")
            let navigator=NativeMacDelegate(),identity=NativeRecordingIdentity(serialNumber:"fixture",sessionID:42)
            navigator.model.selected=identity;navigator.model.progress=17;let navigation=navigator.model.searchFocusSignal
            navigator.openLibrary()
            precondition(navigator.model.selected==identity && navigator.model.progress==17 && navigator.model.searchFocusSignal != navigation,"Library command preserves detail selection and explicitly navigates")
            withExtendedLifetime([a,b,c]){}
            print("PASS scoped playback/search notifications, identical state deduplication, X clears question and draft, 20000-word indexed slicing and invalidation; library command preserves selection")
            return true
        }
        if CommandLine.arguments.contains("--verify-library-engine") {
            let application=NSApplication.shared
            Task { @MainActor in
                do {try await NativeMacModel.verifyLibraryEngine(resources:Bundle.main.resourceURL!);exit(0)} catch {print(error);exit(1)}
            }
            application.run();return true
        }
        if CommandLine.arguments.contains("--verify-ai-result-events") {
            let application=NSApplication.shared
            Task { @MainActor in
                do {
                    let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-result-events-"+UUID().uuidString)
                    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                    defer {try? FileManager.default.removeItem(at:root)}
                    guard let resources=Bundle.main.resourceURL else {throw AIProcessingError.invalidRequest}
                    let host=try LocalAIHost(root:root,resources:resources),model=NativeMacModel()
                    model.localAI=host
                    try model.prepareConversationVerification(root:root)
                    let completed=model.analyses[0],id=completed.request.id
                    var active=completed;active.stage = .visualizing;active.visualSummary=nil
                    model.analyses[0]=active
                    host.activeRequest=id
                    var updates=0
                    let observer=host.resultUpdates.sink { changed in
                        precondition(changed==id)
                        precondition((try? LocalAIFileStore(root:root).result(changed))?.stage == .completed)
                        precondition(host.activeRequest==id)
                        updates += 1
                    }
                    try host.persistResult(active);precondition(updates==0)
                    try host.persistResult(completed);precondition(updates==1)
                    host.activeRequest=nil
                    // Consumer receives completion even after the worker is released,
                    // with no polling timer and no pending manual request.
                    for _ in 0..<20 {
                        if model.rawAnalysis?.stage == .completed {break}
                        try await Task.sleep(nanoseconds:10_000_000)
                    }
                    precondition(model.rawAnalysis?.visualSummary==completed.visualSummary)
                    precondition(model.analysisID==id && model.rawAnalysis?.stage == .completed)
                    observer.cancel()
                    print("PASS: persisted terminal event survives worker release; visual result delivered without polling or changing version")
                    exit(0)
                } catch {print(error);exit(1)}
            }
            application.run();return true
        }
        if CommandLine.arguments.contains("--verify-confirmed-learning") {
            do {
                guard let resources=Bundle.main.resourceURL else {throw AIProcessingError.invalidRequest}
                try NativeMacModel().verifyConfirmedVoiceLearning(resources:resources)
            } catch {print(error);exit(1)}
            return true
        }
        if CommandLine.arguments.contains("--verify-sync-state") { NativeMacModel().verifySyncPreservesDetail(); return true }
        if let index=CommandLine.arguments.firstIndex(of:"--verify-processing-copy"),CommandLine.arguments.indices.contains(index+1) {
            let app=NSApplication.shared
            Task { @MainActor in
                do {
                    let root=URL(fileURLWithPath:CommandLine.arguments[index+1])
                    guard root.lastPathComponent.hasPrefix("Vecta-private-validation-"),let resources=Bundle.main.resourceURL else {throw AIProcessingError.invalidRequest}
                    let host=try LocalAIHost(root:root,resources:resources),store=LocalAIFileStore(root:root)
                    let requests=try store.requests();guard requests.count==1,let request=requests.first else {throw AIProcessingError.invalidRequest}
                    host.start()
                    for _ in 0..<900 {
                        try await Task.sleep(nanoseconds:1_000_000_000)
                        if let result=try store.result(request.id),!result.stage.isActive {
                            let report:[String:Any]=["stage":result.stage.rawValue,"transcriptCharacters":result.transcript?.count ?? 0,"segments":result.segments.count,"summary":result.summary != nil,"visual":result.visualSummary != nil,"error":result.error ?? "","visualError":result.visualError ?? ""]
                            try JSONSerialization.data(withJSONObject:report,options:.sortedKeys).write(to:root.appendingPathComponent("verification.json"))
                            host.stop();exit(result.stage == .completed && result.visualSummary != nil ? 0:1)
                        }
                    }
                    host.stop();exit(2)
                } catch {print("Private verification failed: \(error.localizedDescription)");exit(1)}
            }
            app.run();return true
        }
        return false
    }
}

/// The gate deliberately ignores cancellation, like a detached filesystem read.
@MainActor private final class VectaOwnershipReadGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in self.continuation = continuation; entered = true }
    }
    func release() { continuation?.resume(); continuation = nil }
    func awaitEntry() async throws {
        for _ in 0..<200 {
            if entered { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw AIProcessingError.invalidRequest
    }
}

extension VectaAppChecks {
    @MainActor static func verifyLibraryOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-library-ownership-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Vecta.OwnershipChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let resources = Bundle.main.resourceURL!
        let identity = NativeRecordingIdentity(serialNumber: "882SYNTHETIC", sessionID: 42)
        func fixture(_ name: String) throws -> (NativeLibraryController, LocalAIHost) {
            let base = root.appendingPathComponent(name), user = "fixture-owner"
            let layout = NativeStorageLayout(recordingBase: base,
                userDirectory: base.appendingPathComponent("Users/" + VectaRecordingStore.userDirectoryName(for: user)),
                servicesDirectory: base.appendingPathComponent("services"))
            try FileManager.default.createDirectory(at: base.appendingPathComponent("Exports"), withIntermediateDirectories: true)
            let exporter = VectaLocalAudioExporter(userID: user, defaults: defaults)
            try exporter.configureFolder(base.appendingPathComponent("Exports"))
            let library = try NativeLibraryController(userID: user, layout: layout, exporter: exporter)
            precondition(library.recordingStore.begin(sessionID: 42, serialNumber: identity.serialNumber, duration: 1))
            let audio = library.recordingStore.audioDirectory(serialNumber: identity.serialNumber).appendingPathComponent("42.mp3")
            try Data("synthetic metadata fixture, never decoded".utf8).write(to: audio)
            precondition(library.recordingStore.markLocal(sessionID: 42, serialNumber: identity.serialNumber, outputPath: audio.path))
            library.reloadLibrary()
            return (library, try LocalAIHost(root: base.appendingPathComponent("Exports"), resources: resources))
        }
        let (libraryA, hostA) = try fixture("A"), (libraryB, hostB) = try fixture("B")
        defer { hostA.stop(); hostB.stop() }
        let model = NativeMacModel()
        func activate(_ library: NativeLibraryController, _ host: LocalAIHost) {
            model.libraryGeneration = UUID(); model.library = library; model.localAI = host
            model.processingRoot = host.root; model.batchChecking = false
            model.analysisMessage = nil; model.searchError = nil
        }
        let request = AIProcessingRequest(version: 1, id: UUID(), recordingID: "42", audioFilename: "42.mp3",
            audioSHA256: String(repeating: "a", count: 64), provider: .local, format: .standard, createdAt: Date(),
            summaryOnly: false, transcriptRequestID: nil, summaryModel: .qwen4b)
        let result = AIProcessingResult(version: 1, request: request, stage: .completed, transcript: "A only",
            segments: [], summary: nil, error: nil, updatedAt: Date(), duration: 1)
        let source = AILibrarySource(id: "S1", recordingKey: NativeMacModel.libraryKey(identity), requestID: request.id,
            transcriptID: nil, revision: "fixture", title: "A", date: Date(), text: "A only", segmentIDs: [], start: nil, end: nil)
        activate(libraryA, hostA)
        let sourceGate = VectaOwnershipReadGate()
        model.openLibrarySource(source, resultReader: { _ in await sourceGate.wait(); return result })
        let sourceTask = model.librarySourceTask!
        try await sourceGate.awaitEntry()
        activate(libraryB, hostB); model.analyses = []; model.selected = nil
        sourceGate.release(); await sourceTask.value
        precondition(model.analyses.isEmpty && model.selected == nil && model.searchError == nil)

        var workspaceA = AIWorkspace()
        workspaceA.tasks = [AILibraryTask(id: "A-only", title: "A-only task", details: "", status: "open", recordingID: "42",
            requestID: request.id, conversationKey: "fixture", sourceSegments: [], createdAt: Date(), manuallyEdited: true)]
        try AIWorkspaceStore(root: hostA.root).save(workspaceA)
        let workspaceBytesA = try Data(contentsOf: AIWorkspaceStore(root: hostA.root).url)
        activate(libraryA, hostA)
        let importGate = VectaOwnershipReadGate()
        let importTask = Task { await model.importLibraryTasks(historyReader: { _ in await importGate.wait(); return [result] }) }
        try await importGate.awaitEntry()
        activate(libraryB, hostB); model.loadWorkspace()
        let tasksB = model.workspace.tasks
        importGate.release(); await importTask.value
        precondition(model.workspace.tasks == tasksB && model.workspaceStateRoot == hostB.root.standardizedFileURL && model.analysisMessage == nil)
        let unchangedWorkspaceA = try Data(contentsOf: AIWorkspaceStore(root: hostA.root).url)
        precondition(unchangedWorkspaceA == workspaceBytesA && model.workspace.tasks?.first?.title != "A-only task")

        let queueA = try NativeAnalysisQueue(url: NativeAnalysisQueue.scopedURL(processingRoot: hostA.root))
        let queueB = try NativeAnalysisQueue(url: NativeAnalysisQueue.scopedURL(processingRoot: hostB.root))
        try queueA.append([identity]); try queueB.append([identity])
        activate(libraryA, hostA); model.analysisQueue = queueA
        let queueGate = VectaOwnershipReadGate()
        let batchTask = Task { await model.pumpAnalysisQueue(historyReader: { _ in await queueGate.wait(); return [] }) }
        try await queueGate.awaitEntry()
        batchTask.cancel(); activate(libraryB, hostB); model.analysisQueue = queueB
        model.batchMessage = "B sentinel"; model.batchCount = 7; model.batchFailures = 3
        queueGate.release(); await batchTask.value
        precondition(model.batchMessage == "B sentinel" && model.batchCount == 7 && model.batchFailures == 3 && !model.batchChecking)
        precondition(queueA.jobs.count == 1 && queueA.jobs[0].requestID == nil && queueB.jobs.count == 1 && queueB.jobs[0].requestID == nil)
        let before = model.libraryGeneration
        await model.stop()
        precondition(model.libraryGeneration != before && model.batchMessage == nil && model.batchCount == 0 && model.batchFailures == 0 && model.batchProgress == nil)
        print("PASS library ownership: gated late source, workspace import, cancelled queue resume and shutdown presentation reset; equal recording IDs, isolated temporary fixtures, no workers/devices/Keychain/models")
    }
}
