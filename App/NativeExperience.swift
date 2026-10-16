import AppKit
import SwiftUI
import CryptoKit
import AVFoundation
#if VECTA_DEVELOPMENT
import NotePinTransport
#endif

enum NativeDestination: String { case library, device, ai, formats, settings,tasks,conferences }

/// Heavy alignment reads are serialized off-main; journal recovery stays with UI edits.
actor NativeConversationRefresh {
    struct Snapshot {
        let revision:String
        let alignment:AISpeakerAlignment?
    }
    private let results=LocalAIReadCache()
    private var alignments:[String:(stamp:String,value:AISpeakerAlignment,cost:Int)]=[:]
    private var alignmentOrder:[String]=[]
    private var incompleteAlignments:[String:String]=[:]
    #if VECTA_DEVELOPMENT
    var retainedIncompleteAlignmentCount:Int {incompleteAlignments.count}
    #endif
    func result(_ id:UUID,root:URL)throws->AIProcessingResult? {try results.result(id,root:root)}
    func history(root:URL)throws->[AIProcessingResult] {
        let directory=root.appendingPathComponent("LocalAI/Results")
        guard FileManager.default.fileExists(atPath:directory.path) else{return []}
        return try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
            .filter{$0.pathExtension=="json"}.compactMap {file in
                guard let id=UUID(uuidString:file.deletingPathExtension().lastPathComponent) else{return nil}
                return try results.result(id,root:root)
            }.sorted{$0.request.createdAt>$1.request.createdAt}
    }
    func snapshot(root:URL,key:String,result:AIProcessingResult)throws->Snapshot {
        try Task.checkCancellation()
        let store=LocalAIFileStore(root:root)
        var current=result,visited=Set<UUID>(),files=[URL](),stamps=[String](),selectedAlignment:AISpeakerAlignment?
        var complete=false,liveAlignments=Set<String>()
        defer {incompleteAlignments=incompleteAlignments.filter{liveAlignments.contains($0.key)}}
        for _ in 0..<64 {
            try Task.checkCancellation()
            guard visited.insert(current.request.id).inserted else{throw AIProcessingError.invalidRequest}
            let file=store.resultURL(current.request.id).appendingPathExtension("alignment.json"),stamp=AIFileRevision.stamp(file)
            files.append(file);stamps.append(stamp);liveAlignments.insert(file.path)
            if let cached=alignments[file.path],cached.stamp==stamp {
                selectedAlignment=cached.value
                alignmentOrder.removeAll{$0==file.path};alignmentOrder.append(file.path)
            }
            else if stamp != "missing",incompleteAlignments[file.path] != stamp {
                var reader=AIRevisionFileCache<AISpeakerAlignment>()
                if let value=reader.read(file,limit:32_000_000,decode:{try JSONDecoder().decode(AISpeakerAlignment.self,from:$0)}),value.complete {
                    selectedAlignment=value
                    alignments[file.path]=nil;alignmentOrder.removeAll{$0==file.path}
                    let cost=max(16384,((try? file.resourceValues(forKeys:[.fileSizeKey]))?.fileSize ?? 0)*4)
                    if cost<=64*1024*1024 {
                        while !alignmentOrder.isEmpty,(alignmentOrder.count>=2 || alignments.values.reduce(0,{$0+$1.cost})+cost>64*1024*1024) {
                            alignments[alignmentOrder.removeFirst()]=nil
                        }
                        alignments[file.path]=(stamp,value,cost);alignmentOrder.append(file.path)
                    }
                } else {incompleteAlignments[file.path]=stamp}
            }
            // Own complete alignment wins even if an unused historical parent is absent.
            if selectedAlignment != nil {complete=true;break}
            guard let source=current.request.transcriptRequestID else{complete=true;break}
            let parentURL=store.resultURL(source);files.append(parentURL);stamps.append(AIFileRevision.stamp(parentURL))
            guard let parent=try results.result(source,root:root),parent.request.audioSHA256==result.request.audioSHA256,
                  parent.request.audioFilename==result.request.audioFilename else{throw AIProcessingError.invalidRequest}
            current=parent
        }
        guard complete else{throw AIProcessingError.invalidRequest}
        try Task.checkCancellation()
        guard files.map(AIFileRevision.stamp)==stamps else{throw CancellationError()}
        let revision=root.path+"|"+files.enumerated().map{"\($0.element.path)|\(stamps[$0.offset])"}.joined(separator:"|")
        let sidecars=root.appendingPathComponent("ConversationV2")
        let small=[sidecars.appendingPathComponent(key+".json"),sidecars.appendingPathComponent("voices.json"),
                   sidecars.appendingPathComponent("pending-voice-edit.json"),root.appendingPathComponent("LocalAI/AssistantV1/"+key+".json")]
        return Snapshot(revision:revision+"|"+key+"|"+small.map(AIFileRevision.stamp).joined(separator:"|"),alignment:selectedAlignment)
    }
}

@MainActor extension NativeMacModel {
    var formats: [VectaSummaryInterpretation] { NativeSummaryCatalog.visible(library?.formats ?? []) }
    func automaticRecipeSnapshot(settings: AIAutomaticSettings) throws -> NativeAnalysisQueue.RecipeSnapshot {
        loadWorkspace()
        guard let root = (processingRoot ?? localAI?.root)?.standardizedFileURL, workspaceStateRoot == root else {
            throw AIProcessingError.invalidRequest
        }
        return try .selected(recipeID: settings.summaryRecipeID, formats: formats, templates: workspace.templates)
    }
    var rawAnalysis: AIProcessingResult? { if let analysisID { return analyses.first { $0.request.id == analysisID } }; return analyses.first }
    var resolvedConversation:AIRecordingSpeakers {presentation().0}
    var analysis:AIProcessingResult? {var value=presentation().1;if let id=value?.request.id,let draft=localAI?.summaryDrafts[id] {value?.summaryDraft=draft};return value}
    var conversationKey: String? {
        rawAnalysis.map { SHA256.hash(data:Data(($0.request.audioSHA256 + ($0.request.transcriptRequestID ?? $0.request.id).uuidString).utf8)).map { String(format:"%02x",$0) }.joined() }
    }
    var currentVoiceRoot: URL? {
        guard let root=(processingRoot ?? localAI?.root)?.standardizedFileURL, voiceStateRoot==root else { return nil }
        return root
    }
    var currentConversationRoot: URL? {
        guard let root=(processingRoot ?? localAI?.root)?.standardizedFileURL,
              conversationStateRoot==root, conversationLoadedKey==conversationKey else { return nil }
        return root
    }
    func loadConversation() {
        appliedConversationRevision=nil
        guard let root=(processingRoot ?? localAI?.root)?.standardizedFileURL,let result=rawAnalysis,let key=conversationKey else { return }
        conversationStateRoot=nil;conversationLoadedKey=nil;voiceStateRoot=nil
        wordTimings=[];speakerCentroids=[:]
        do {
            let store=AIConversationStore(root:root)
            conversation=try store.recording(key,segments:result.segments)
            conversationStateRoot=root;conversationLoadedKey=key
            voiceLibrary=try store.voices();voiceStateRoot=root
            if loadedChatKey != key {chat=try AIChatStore(root:root).load(key);loadedChatKey=key}
            if let alignment=try LocalAIFileStore(root:root).speakerAlignment(for:result) {
                wordTimings=alignment.words;speakerCentroids=alignment.centroids
            }
        } catch { analysisMessage=error.localizedDescription }
    }
    func refreshConversation(snapshotReader:((URL,String,AIProcessingResult) async throws -> NativeConversationRefresh.Snapshot)? = nil) async {
        guard let root=(processingRoot ?? localAI?.root)?.standardizedFileURL,let result=rawAnalysis,let key=conversationKey else{return}
        let generation=libraryGeneration,selection=selected,version=analysisID,host=localAI
        let editRevision=presentationRevision,chatVersion=chatRevision
        func ownsSnapshot()->Bool {
            !Task.isCancelled && libraryGeneration==generation && selected==selection && analysisID==version && localAI===host &&
                (processingRoot ?? localAI?.root)?.standardizedFileURL==root && conversationKey==key &&
                rawAnalysis?.request==result.request && rawAnalysis?.segments==result.segments &&
                presentationRevision==editRevision && chatRevision==chatVersion
        }
        do {
            let snapshot:NativeConversationRefresh.Snapshot
            if let snapshotReader {snapshot=try await snapshotReader(root,key,result)}
            else {snapshot=try await conversationRefresh.snapshot(root:root,key:key,result:result)}
            guard ownsSnapshot() else{return}
            guard appliedConversationRevision != snapshot.revision || appliedConversationSegments != result.segments ||
                  conversationStateRoot != root || conversationLoadedKey != key || voiceStateRoot != root else{return}
            let store=AIConversationStore(root:root)
            let recording=try store.recording(key,segments:result.segments),voices=try store.voices()
            let words=snapshot.alignment?.words ?? [],centroids=snapshot.alignment?.centroids ?? [:]
            let history=loadedChatKey != key ? try AIChatStore(root:root).load(key):nil
            if conversation != recording {conversation=recording}
            if voiceLibrary != voices {voiceLibrary=voices}
            if wordTimings != words {wordTimings=words}
            if speakerCentroids != centroids {speakerCentroids=centroids}
            if let history {chat=history;loadedChatKey=key}
            conversationStateRoot=root;conversationLoadedKey=key;voiceStateRoot=root
            appliedConversationRevision=snapshot.revision;appliedConversationSegments=result.segments
        } catch is CancellationError {} catch {
            guard ownsSnapshot() else{return}
            appliedConversationRevision=nil;conversationStateRoot=nil;voiceStateRoot=nil
            if analysisMessage != error.localizedDescription {analysisMessage=error.localizedDescription}
        }
    }
    func editConversation(_ edit:(inout AIRecordingSpeakers)throws->Void) {
        guard let root=currentConversationRoot,let key=conversationKey else { analysisMessage=VL.text("Состояние собеседников ещё не загружено для этой библиотеки.");return }
        do { var value=conversation;try edit(&value);try AIConversationStore(root:root).save(value,key:key);conversation=value;libraryCorpusVersion+=1 }
        catch { analysisMessage=error.localizedDescription }
    }
    func renameSpeaker(_ id:String,name:String) { editConversation { try $0.rename(id,to:name) } }
    func speakerMergeNeedsConfirmation(_ id:String,into target:String) -> Bool {
        let resolved=resolvedConversation
        guard let source=resolved.identities[id],let destination=resolved.identities[target] else {return false}
        return voiceLibrary.mergeNeedsConfirmation(source:source,destination:destination)
    }
    @discardableResult func mergeSpeaker(_ id:String,into target:String,allowProfileChange:Bool=false) -> Bool {
        guard let root=currentVoiceRoot,currentConversationRoot==root,let key=conversationKey,let result=rawAnalysis else {
            analysisMessage=VL.text("Собеседники и голоса ещё не загружены для этой библиотеки.");return false
        }
        do {
            var people=voiceLibrary
            let alignment=AISpeakerAlignment(complete:true,words:wordTimings,centroids:speakerCentroids)
            let recording=try people.mergeSpeakers(id,into:target,recording:conversation,result:result,alignment:alignment,key:key,
                                                   title:selection?.title,allowProfileChange:allowProfileChange)
            try AIConversationStore(root:root).saveTogether(recording,key:key,voices:people)
            conversation=recording;voiceLibrary=people;libraryCorpusVersion+=1;analysisMessage=nil;return true
        } catch {analysisMessage=VL.text("Не удалось объединить собеседников: ")+error.localizedDescription;return false}
    }
    func splitSpeaker(_ ids:Set<Int>,name:String) { guard let segments=rawAnalysis?.segments else{return};editConversation { try $0.split(ids,segments:segments,name:name) } }
    func updateVoices(_ edit:(inout AIVoiceLibrary)throws->Void) {
        guard let root=currentVoiceRoot else {analysisMessage=VL.text("Библиотека голосов не загружена; сохранённые данные не изменены.");return}
        do { var value=voiceLibrary;try edit(&value);try AIConversationStore(root:root).save(value);voiceLibrary=value;libraryCorpusVersion+=1 }
        catch { analysisMessage=error.localizedDescription }
    }
    @discardableResult func forgetVoice(_ profile:UUID) -> Bool {
        guard let root=currentVoiceRoot else {analysisMessage=VL.text("Хранилище голосов недоступно или ещё не загружено.");return false}
        do {
            var value=voiceLibrary;try value.forget(profile)
            try AIConversationStore(root:root).save(value)
            voiceLibrary=value;libraryCorpusVersion+=1;analysisMessage=nil;return true
        } catch {analysisMessage=VL.text("Не удалось удалить голос: ")+error.localizedDescription;return false}
    }
    func separateVoiceSample(_ profile:UUID,index:Int) {
        guard let root=currentVoiceRoot,let person=voiceLibrary.profiles.first(where:{$0.id==profile}),person.samples.indices.contains(index) else{return}
        let sample=person.samples[index]
        do {
            let store=AIConversationStore(root:root)
            var people=voiceLibrary;let newID=try people.separate(profile,sample:index,name:VL.text("Новый собеседник"))
            var recording=try store.recording(sample.recordingKey,segments:[])
            if var identity=recording.identities[sample.speakerID],identity.profileID.map(people.canonical)==people.canonical(profile) {
                identity.profileID=newID;identity.name=VL.text("Новый собеседник");identity.nameOverride=false;identity.origin="profileConfirmed";recording.identities[sample.speakerID]=identity;recording.summaryNeedsReview=true
            }
            try store.saveTogether(recording,key:sample.recordingKey,voices:people);libraryCorpusVersion+=1
            voiceLibrary=people;if conversationKey==sample.recordingKey {conversation=recording};analysisMessage=nil
        } catch {analysisMessage=VL.text("Не удалось отделить образец: ")+error.localizedDescription}
    }
    func voiceSample(_ id:String) -> AIVoiceSample? {
        guard currentConversationRoot != nil,let key=conversationKey,let result=rawAnalysis else {return nil}
        var sample=AISpeakerAlignment(complete:true,words:wordTimings,centroids:speakerCentroids).sample(id,result:result,conversation:conversation,key:key)
        sample?.recordingTitle=selection?.title
        return sample
    }
    func voiceCandidates(_ id:String) -> [AIVoiceProfile] {
        guard conversation.identities[id]?.profileID==nil,conversation.identities[id]?.origin != "userUnknown",let sample=voiceSample(id) else{return []}
        let rejected=Set(conversation.dismissedSuggestions?[id] ?? [])
        return voiceLibrary.ranked(sample).compactMap {candidate in
            rejected.contains(candidate.0.uuidString) ? nil:voiceLibrary.profiles.first {$0.id==candidate.0}
        }
    }
    func dismissVoiceCandidates(_ id:String) {editConversation {value in
        var dismissed=value.dismissedSuggestions ?? [:];dismissed[id]=voiceLibrary.profiles.map{$0.id.uuidString};value.dismissedSuggestions=dismissed
    }}
    @discardableResult func assignSpeaker(_ id:String,name:String,profile:UUID?,remember:Bool) -> Bool {
        guard let root=currentVoiceRoot, currentConversationRoot==root, let key=conversationKey,var identity=conversation.identities[id] else {analysisMessage=VL.text("Собеседники и голоса ещё не загружены для этой библиотеки.");return false}
        do {
            var people=voiceLibrary;var recording=conversation
            identity.referenceNames=Array(Set((identity.referenceNames ?? [])+[resolvedConversation.name(id),identity.name])).sorted()
            let clean=name.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !clean.isEmpty,clean.count<=120,!clean.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {throw AIProcessingError.invalidRequest}
            identity.suggestedProfileID=nil
            if profile==nil {identity.profileID=nil;identity.previousName=nil;identity.nameOverride=nil}
            let sample=voiceSample(id)
            var feedback=VL.text("Имя подтверждено")
            var target=profile.map(people.canonical)
            if let target {
                guard people.activeProfiles.contains(where:{$0.id==target}) else {throw AIProcessingError.invalidRequest}
                // Manual confirmation cannot bind simultaneous distinct voices to one person.
                let others=recording.identities.values.filter {$0.id != id && $0.profileID.map(people.canonical)==target}.map(\.id)
                let segments=rawAnalysis?.segments ?? []
                let mine=segments.filter {recording.speakerID($0)==id}
                let conflicting=segments.filter {others.contains(recording.speakerID($0) ?? "")}
                guard !mine.contains(where:{a in conflicting.contains {b in min(a.end,b.end)>max(a.start,b.start)}}) else {analysisMessage=VL.text("Этот человек уже назначен другому голосу, звучащему одновременно. Сначала исправьте авторство реплик.");return false}
            }
            // Explicit confirmation of an enrolled person also learns this
            // recording. Suggestions alone never add an embedding.
            if remember || (target != nil && sample != nil) {
                guard let sample else {analysisMessage=VL.text("Для этого участника пока нет отдельного образца голоса. Имя можно сохранить без запоминания.");return false}
                let sourceOwners=people.activeProfiles.filter {$0.samples.contains {$0.isSameSource(as:sample)}}
                let sameTarget=target.map {target in sourceOwners.contains {$0.id==target}} ?? false
                target=try people.remember(name:clean,sample:sample,profileID:target,forceNewProfile:profile==nil)
                feedback=sourceOwners.isEmpty ? VL.text("Образец голоса сохранён"):sameTarget ? VL.text("Имя подтверждено"):VL.text("Образец голоса обновлён")
            }
            if let target,let person=people.profiles.first(where:{$0.id==target}) {
                if identity.profileID==nil {identity.previousName=identity.name}
                identity.profileID=target
                let localName=profile==nil && clean != person.name
                identity.name=localName ? clean:person.name;identity.nameOverride=localName;identity.origin=localName ? "manual":"profileConfirmed"
            } else {
                recording.identities[id]=identity
                try recording.rename(id,to:clean);identity=recording.identities[id]!
            }
            recording.identities[id]=identity
            try AIConversationStore(root:root).saveTogether(recording,key:key,voices:people);libraryCorpusVersion+=1
            conversation=recording;voiceLibrary=people;analysisMessage=nil;showVoiceFeedback(feedback);return true
        } catch {analysisMessage=VL.text("Не удалось сохранить собеседника: ")+error.localizedDescription;return false}
    }
    @discardableResult func confirmSuggestedVoice(_ id:String) -> Bool {
        guard let identity=resolvedConversation.identities[id], identity.origin=="voiceSuggestion", voiceSample(id) != nil,
              let suggested=identity.suggestedProfileID,
              let profile=voiceLibrary.activeProfiles.first(where: {$0.id==voiceLibrary.canonical(suggested)}) else {
            analysisMessage=VL.text("Предложение больше недоступно. Выберите собеседника вручную.");return false
        }
        return assignSpeaker(id,name:profile.name,profile:profile.id,remember:false)
    }
    @discardableResult func markSpeakerUnknown(_ id:String) -> Bool {
        analysisMessage=nil
        let suggestion=resolvedConversation.name(id)
        editConversation { value in
            guard var identity=value.identities[id] else {throw AIProcessingError.invalidRequest}
            identity.referenceNames=Array(Set((identity.referenceNames ?? [])+[suggestion])).sorted()
            value.identities[id]=identity
            try value.markSpeakerUnknown(id,rejectedProfiles:voiceLibrary.profiles.map(\.id))
        }
        return analysisMessage==nil && conversation.identities[id]?.origin=="userUnknown"
    }
    func saveVoice(_ id:String) { _=assignSpeaker(id,name:conversation.name(id),profile:conversation.identities[id]?.profileID,remember:true) }
    func confirmVoice(_ profile:UUID,speaker:String) {guard let value=voiceLibrary.profiles.first(where:{$0.id==voiceLibrary.canonical(profile)}) else{return};_ = assignSpeaker(speaker,name:value.name,profile:profile,remember:false)}
    func rejectVoice(_ speaker:String) {
        editConversation { value in
            guard var identity=value.identities[speaker] else{throw AIProcessingError.invalidRequest}
            if let profile=identity.profileID {var map=value.dismissedSuggestions ?? [:];map[speaker,default:[]].append(profile.uuidString);value.dismissedSuggestions=map}
            identity.name=identity.previousName ?? VL.text("Собеседник");identity.previousName=nil;identity.profileID=nil;identity.nameOverride=false;identity.origin="manual";value.identities[speaker]=identity
        }
    }
    func openVoiceRecording(_ recordingID:String,start:Double?=nil,end:Double?=nil) {
        guard let item=library?.items.first(where:{$0.audioURL?.deletingPathExtension().lastPathComponent==recordingID}) ?? (verificationItem?.audioURL?.deletingPathExtension().lastPathComponent==recordingID ? verificationItem:nil) else { analysisMessage=VL.text("Связанная запись недоступна в текущей библиотеке.");return }
        if verificationItem == nil {select(item.identity)}
        destination = .library;openDetailSignal=UUID()
        if let start,let end {playExcerpt(start:start,end:end,segment:nil)}
    }
    var analysisBusy: Bool { requestingAnalysis || (pendingAnalysis.map { id in analyses.contains { $0.request.id == id } } ?? false) || analyses.contains { $0.stage.isActive } }
    var busy: Bool { purgingRecording != nil || resettingDevice || transferring || connecting || syncing || fastTransferPhase != nil }

    func updateTransferProgress() { transferProgress = transferMetrics?.snapshot(at: ProcessInfo.processInfo.systemUptime) }
    func clearTransferProgress() { transferTimer?.invalidate(); transferTimer = nil; transferMetrics = nil; transferProgress = nil }

    func reloadAnalysis(historyReader:(() async throws -> [AIProcessingResult])? = nil) async {
        guard !loadingHistory else{analysisReloadPending=true;return}
        let generation=libraryGeneration,selectedAtStart=selected,host=localAI,library=self.library
        loadingHistory=true;analysisReloadPending=false
        defer {
            if libraryGeneration==generation {
                loadingHistory=false
                if analysisReloadPending {analysisReloadPending=false;Task {await reloadAnalysis()}}
            }
        }
        do {
            if let pending=pendingAnalysis,let host {
                let result=try await conversationRefresh.result(pending,root:host.root)
                guard !Task.isCancelled,libraryGeneration==generation,selected==selectedAtStart,localAI===host,self.library===library else{return}
                if pendingAnalysis==pending,let result,!result.stage.isActive {pendingAnalysis=nil}
            }
            let values:[AIProcessingResult]
            if let historyReader {values=try await historyReader()}
            else if verificationItem != nil,let host {values=try await conversationRefresh.history(root:host.root)}
            else {
                guard let id=selectedAtStart,let library,selection?.audioURL != nil else{return}
                values=try await library.localHistory(for:id)
            }
            guard !Task.isCancelled,selected==selectedAtStart,libraryGeneration==generation,self.library===library,localAI===host else{return}
            if let id=selectedAtStart,let library,let result=values.first(where:{$0.stage == .completed}),let title=result.recordingTopicTitle,
               library.items.first(where:{$0.identity==id})?.local?.generatedTitle.flatMap(AIRecordingTitle.validated)==nil {
                if library.recordingStore.saveGeneratedTitle(sessionID:id.sessionID,serialNumber:id.serialNumber,title:title) {library.reloadLibrary()}
            }
            if analyses != values {analyses=values}
            if let pending=pendingAnalysis,let result=values.first(where:{$0.request.id==pending}) {
                if analysisID != pending {analysisID=pending}
                if !result.stage.isActive {pendingAnalysis=nil}
            }
            if analysisID==nil {analysisID=values.first?.request.id}
            await refreshConversation()
        } catch is CancellationError {} catch {
            if libraryGeneration==generation,self.library===library,pendingAnalysis != nil,analysisMessage != error.localizedDescription {analysisMessage=error.localizedDescription}
        }
    }

    func analyze(format: VectaSummaryInterpretation, reuseTranscript: Bool = true,template:AISummaryTemplate? = nil, installMissingModels: Bool = false) {
        guard purgingRecording == nil, let id = selected, let library, let host = localAI, !analysisBusy else { return }
        guard host.supported, host.summaryModel.compatible() else {
            analysisMessage = host.supported ? host.summaryModel.memoryRequirement : VL.text("Локальная обработка доступна с macOS 15."); return
        }
        let source = reuseTranscript ? NativeSummarySelection.transcriptSource(analyses) : nil
        let needed = host.modelsNeeded(reuseTranscript: source != nil)
        let missing = needed.filter { host.statuses[$0]?.state != .installed && !host.isModelBusy($0) }
        guard missing.isEmpty || installMissingModels else {
            analysisMessage = VL.text("Установите необходимые модели в настройках локального ИИ."); destination = .ai; return
        }
        // Only the explicit download-and-process confirmation authorizes new
        // downloads. Existing downloads do not discard this processing request.
        if installMissingModels { for id in missing { host.install(id) } }
        // One preference controls both new manual and automatic jobs. Freeze it
        // together with the shared model before submitting this request.
        let settings = AIAutomaticSettings(model: host.summaryModel, visual: host.automaticSettings.visual)
        let scope = NativeLibraryOperationScope(library: library, host: host, generation: libraryGeneration)
        requestingAnalysis = true
        analysisMessage = needed.contains(where: host.isModelBusy) ? VL.text("Запрос сохранён. Обработка начнётся после установки необходимых моделей.") : nil
        Task {
            defer { if ownsLibraryOperation(scope, checkCancellation: false) { requestingAnalysis = false } }
            do {
                let request = try await library.requestLocalAI(for: id, format: format, transcriptRequestID: source,summaryTemplate:template,automaticSettings:settings)
                guard ownsLibraryOperation(scope) else { library.cancelLocalAI(request); return }
                pendingAnalysis = request
                if selected == id { analysisID = request; await reloadAnalysis() }
            } catch { if ownsLibraryOperation(scope) { analysisMessage = error.localizedDescription } }
        }
    }
    func cancelAnalysis() {
        guard let id = batchActiveRequest ?? pendingAnalysis ?? analysis?.request.id else { return }
        library?.cancelLocalAI(id)
        analysisMessage = VL.text("Отменяем обработку…")
    }
    func exportAudio() {
        guard let source = selection?.audioURL else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = source.lastPathComponent
        panel.title = VL.text("Экспорт аудиозаписи"); panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url, target != source else { return }
        do { _ = try NativeAudioPublication.copyExclusively(source, to: target) }
        catch { analysisMessage = error.localizedDescription }
    }
    func copyAnalysis(transcript: Bool) {
        let value = transcript ? analysis?.readableTranscript : analysis?.completeTextSummary?.rendered(speakers:resolvedConversation)
        guard let value, !value.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
    func verifyConfirmedVoiceLearning(resources:URL) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-confirmed-learning-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        localAI=try LocalAIHost(root:root,resources:resources)
        try prepareConversationVerification(root:root)
        loadConversation()
        precondition(currentConversationRoot == root.standardizedFileURL && currentVoiceRoot == root.standardizedFileURL,
                     "Learning fixture must load its library-scoped conversation and voices")
        speakerCentroids=["0":[1,0],"1":[0,1]]
        voiceLibrary=AIVoiceLibrary();voiceLibrary.recognitionEnabled=true
        let profile=try voiceLibrary.remember(name:"Confirmed person",sample:AIVoiceSample(recordingKey:"previous-recording",speakerID:"speaker_001",embedding:[0.8,0.6],confirmedAt:Date(),recordingID:"previous"))
        precondition(voiceLibrary.profiles[0].samples.count==1)
        precondition(assignSpeaker("speaker_001",name:"Confirmed person",profile:profile,remember:false))
        precondition(voiceLibrary.profiles[0].samples.count==2)
        precondition(assignSpeaker("speaker_001",name:"Confirmed person",profile:profile,remember:false))
        precondition(voiceLibrary.profiles[0].samples.count==2)
        let saved=try AIConversationStore(root:root).voices()
        precondition(saved==voiceLibrary)
        let query=voiceSample("speaker_001")!
        precondition(abs(saved.ranked(query).first!.1-0.1)<0.00001)
        precondition(markSpeakerUnknown("speaker_002"))
        precondition(voiceLibrary==saved)
        print("PASS: native confirmation enrolls without checkbox; independent samples affect score, duplicates and rejection do not learn; restart retains profile")
    }

    #if VECTA_DEVELOPMENT
    func preparePublicDemo(root:URL) throws {
        let date=ISO8601DateFormatter().date(from:"2026-10-14T10:30:00Z")!
        let audio=root.appendingPathComponent("synthetic.wav")
        let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:768000)!
        buffer.frameLength=768000
        for frame in 0..<Int(buffer.frameLength) {
            let time=Double(frame)/16000
            buffer.floatChannelData![0][frame]=Float(sin(time*2*Double.pi*180)*(0.06+0.25*abs(sin(time*2.3))))
        }
        do {let file=try AVAudioFile(forWriting:audio,settings:format.settings);try file.write(from:buffer)}
        let identity=NativeRecordingIdentity(serialNumber:"SYNTHETIC",sessionID:Int(date.timeIntervalSince1970))
        let recording=VectaRecording(sessionID:identity.sessionID,deviceSerialNumber:"SYNTHETIC",createdAt:date,duration:48,localFileName:"synthetic.wav",status:.ready,statusDetail:nil,transcript:nil,transcriptionID:nil,cloudCheckpoint:nil,updatedAt:date,generatedTitle:"Product planning")
        verificationItem=NativeLibraryItem(identity:identity,local:recording,remote:nil,audioURL:audio)
        select(identity)
        let digest=SHA256.hash(data:try Data(contentsOf:audio)).map {String(format:"%02x",$0)}.joined()
        let request=AIProcessingRequest(version:1,id:UUID(),recordingID:"synthetic",audioFilename:"synthetic.wav",audioSHA256:digest,provider:.local,format:.detailed,createdAt:date,summaryOnly:false,transcriptRequestID:nil,summaryModel:.qwen4b)
        let segments=[
            AISpeechSegment(id:0,start:1,end:16,speaker:"Speaker 1",text:"Let's keep the first release focused on recording imports, saved speakers and PDF reports.",speakerID:"speaker_001"),
            AISpeechSegment(id:1,start:17,end:30,speaker:"Speaker 2",text:"I'll send the test report by Friday. We should review the results before we set a launch date.",speakerID:"speaker_002"),
            AISpeechSegment(id:2,start:31,end:46,speaker:"Speaker 1",text:"Agreed. Test the import flow first, then review the report and decide when to launch.",speakerID:"speaker_001")]
        func item(_ title:String,_ body:String,_ ids:[Int])->AIVisualItem {AIVisualItem(title:title,tokens:[.init(text:body,speakerID:nil)],sourceSegments:ids)}
        let report=AIVisualSummary(schemaVersion:2,title:"Product planning",theme:"editorial",blocks:[
            .init(id:"overview",type:.hero,title:"A focused first release",items:[item("","Recording imports, saved speakers and PDF reports.",[0])],layout:.wide,role:.fact),
            .init(id:"scope",type:.decisions,title:"Agreed scope",items:[item("Keep the first release focused","Prioritize recording imports, saved speakers and PDF reports for the first release.",[0,2])],layout:.half,role:.fact),
            .init(id:"report",type:.tasks,title:"Next action",items:[AIVisualItem(title:"Send the test report",tokens:[.init(text:nil,speakerID:"speaker_002"),.init(text:" will send the test report by Friday.",speakerID:nil)],sourceSegments:[1],deadline:"Friday")],layout:.half,role:.fact),
            .init(id:"next",type:.processFlow,title:"Before launch",items:[item("Test imports","Test the import flow.",[2]),item("Review the report","Review the results together.",[1,2]),item("Choose a launch date","Make the decision after the review.",[1,2])],layout:.wide,role:.fact,edges:[.init(from:0,to:1,label:"Then",sourceSegments:[2]),.init(from:1,to:2,label:"After review",sourceSegments:[1,2])])
        ],subtitle:"Scope, responsibilities and next steps",category:"Fictional meeting",layout:.editorial)
        try report.validate(segments:segments)
        let summary=AIStructuredSummary(summary:"The team agreed to focus the first release on recording imports, saved speakers and PDF reports. The test report is due Friday; a launch date will be chosen after review.",topics:["First-release scope","Testing and launch planning"],decisions:["Keep the first release focused."],tasks:[],uncertainties:["The launch date has not been set."],recordingTitle:"Product planning")
        analyses=[AIProcessingResult(version:1,request:request,stage:.completed,transcript:segments.map(\.text).joined(separator:" "),segments:segments,summary:summary,error:nil,updatedAt:date,duration:48,visualSummary:report)]
        analysisID=request.id;conversation = .initial(segments)
        try LocalAIFileStore(root:root).save(analyses[0])
        var voices=AIVoiceLibrary();voices.recognitionEnabled=true
        _=try voices.remember(name:"Maya Chen",sample:.init(recordingKey:"previous-demo-meeting",speakerID:"speaker_001",embedding:[1,0],confirmedAt:date,recordingID:"previous-demo-meeting"))
        _=try voices.remember(name:"Alex Morgan",sample:.init(recordingKey:"previous-demo-meeting",speakerID:"speaker_002",embedding:[0,1],confirmedAt:date,recordingID:"previous-demo-meeting"))
        guard let key=conversationKey else {throw AIProcessingError.invalidRequest}
        try AIConversationStore(root:root).saveTogether(conversation,key:key,voices:voices)
        loadConversation();speakerCentroids=["0":[1,0],"1":[0,1]]
        precondition(assignSpeaker("speaker_001",name:"Maya Chen",profile:voices.profiles[0].id,remember:false))
        precondition(assignSpeaker("speaker_002",name:"Alex Morgan",profile:voices.profiles[1].id,remember:false))
        chat=AIChatHistory(messages:[.init(role:"user",text:"What needs to happen before launch?"),.init(role:"assistant",text:"Test recording imports, review the test report, then choose a launch date. Alex will send the report by Friday.")])
        try AIChatStore(root:root).save(chat,key:key)
        savedDevice=try SavedPlaudDevice(serialNumber:"882SYNTHETIC",model:.notePinS,protocolVersion:20)
        offlineAuthorizationReady=true
        status="Demo library · fictional meeting data"
        if let index=CommandLine.arguments.firstIndex(of:"--verify-pdf"),CommandLine.arguments.indices.contains(index+1) {
            let target=URL(fileURLWithPath:CommandLine.arguments[index+1])
            guard !FileManager.default.fileExists(atPath:target.path) else {throw AIProcessingError.invalidRequest}
            try NativeVisualPDF.write(report:report,title:report.title,date:date,duration:48,speakers:resolvedConversation,segments:segments,textSummary:summary.summary,transcript:analysis?.readableTranscript ?? "",to:target)
        }
    }
    func prepareSpeakerMergeVerification(root:URL) throws {
        try prepareConversationVerification(root:root)
        loadConversation()
        speakerCentroids=["0":[1,0],"1":[0,1]]
        voiceLibrary=AIVoiceLibrary();voiceLibrary.recognitionEnabled=true
        _=try voiceLibrary.remember(name:"Ada Example",sample:.init(recordingKey:"earlier-ada",speakerID:"speaker_001",embedding:[1,0],confirmedAt:Date(),recordingID:"earlier-ada"))
        _=try voiceLibrary.remember(name:"Boris Example",sample:.init(recordingKey:"earlier-boris",speakerID:"speaker_001",embedding:[0,1],confirmedAt:Date(),recordingID:"earlier-boris"))
        guard let key=conversationKey else {throw AIProcessingError.invalidRequest}
        try AIConversationStore(root:root).saveTogether(conversation,key:key,voices:voiceLibrary)
    }
    func verifySpeakerMerge(resources:URL) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-speaker-merge-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        localAI=try LocalAIHost(root:root,resources:resources)
        try prepareSpeakerMergeVerification(root:root)
        let key=conversationKey!,result=rawAnalysis!
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        let original=try encoder.encode(result)
        precondition(resolvedConversation.name("speaker_001")=="Ada Example" && resolvedConversation.name("speaker_002")=="Boris Example")
        precondition(resolvedConversation.identities["speaker_001"]!.needsVoiceConfirmation)
        precondition(confirmSuggestedVoice("speaker_001"))
        precondition(!resolvedConversation.identities["speaker_001"]!.needsVoiceConfirmation)
        precondition(speakerMergeNeedsConfirmation("speaker_001",into:"speaker_002"))
        let beforeMixed=voiceLibrary,mixedConversation=conversation
        precondition(!mergeSpeaker("speaker_001",into:"speaker_002"))
        precondition(voiceLibrary==beforeMixed && conversation==mixedConversation)
        precondition(confirmSuggestedVoice("speaker_002"))
        precondition(speakerMergeNeedsConfirmation("speaker_002",into:"speaker_001"))
        let unchanged=voiceLibrary,oldConversation=conversation
        precondition(!mergeSpeaker("speaker_002",into:"speaker_001"))
        precondition(voiceLibrary==unchanged && conversation==oldConversation)
        precondition(mergeSpeaker("speaker_002",into:"speaker_001",allowProfileChange:true))
        precondition(conversation.identities.count==1 && resolvedConversation.name("speaker_001")=="Ada Example")
        let person=voiceLibrary.activeProfiles.first {$0.name=="Ada Example"}!
        let sample=person.samples.first {$0.recordingKey==key}!
        precondition(sample.segmentIDs==[0,1,2] && sample.embedding.allSatisfy {$0>0})
        precondition(voiceLibrary.activeProfiles.first {$0.name=="Boris Example"}!.samples.count==1)
        let store=AIConversationStore(root:root)
        let persistedVoices=try store.voices(),persistedRecording=try store.recording(key,segments:result.segments)
        let after=try encoder.encode(rawAnalysis!)
        precondition(persistedVoices==voiceLibrary && persistedRecording==conversation && after==original)
        precondition(assignSpeaker("speaker_001",name:person.name,profile:person.id,remember:false))
        precondition(voiceLibrary.activeProfiles.first {$0.id==person.id}!.samples.count==2)
        print("PASS native speaker confirmation/merge: resolved names, controls policy, explicit conflict, joined centroids/all turns, source reassignment, journaled restart, repeat deduplication, immutable result; isolated synthetic only")
    }
    #endif

    /// Explicit developer mode: isolated synthetic data, no runtime/network or
    /// real library. Exercises the same views, resolver and AVAudioPlayer.
    func prepareConversationVerification(root:URL) throws {
        #if VECTA_DEVELOPMENT
        if CommandLine.arguments.contains("--verify-public-demo") {try preparePublicDemo(root:root);return}
        #endif
        let audio=root.appendingPathComponent("synthetic.wav")
        let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        let frames: AVAudioFrameCount = CommandLine.arguments.contains("--verify-highlight-ui") || CommandLine.arguments.contains("--verify-highlights") ? 960000 : 192000
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames)!
        buffer.frameLength=frames
        buffer.floatChannelData![0].initialize(repeating:0,count:Int(frames))
        if CommandLine.arguments.contains("--verify-highlight-ui") {
            for index in 0..<Int(frames) {
                let time = Double(index) / 16000
                buffer.floatChannelData![0][index] = Float(sin(time * 2 * .pi * 220) * (0.15 + 0.65 * abs(sin(time * 2))))
            }
        }
        do { let file=try AVAudioFile(forWriting:audio,settings:format.settings);try file.write(from:buffer) }
        let identity=NativeRecordingIdentity(serialNumber:"SYNTHETIC",sessionID:1)
        verificationItem=NativeLibraryItem(identity:identity,local:nil,remote:NativeRemoteRecording(identity:identity,duration:12,byteSize:0),audioURL:audio)
        select(identity)
        let request=AIProcessingRequest(version:1,id:UUID(),recordingID:"synthetic",audioFilename:"synthetic.mp3",audioSHA256:String(repeating:"a",count:64),provider:.local,format:.standard,createdAt:Date(),summaryOnly:false,transcriptRequestID:nil,summaryModel:.qwen4b)
        let segments=[AISpeechSegment(id:0,start:1,end:4,speaker:VL.text("Собеседник 1"),text:VL.text("Проверим передачу файлов."),speakerID:"speaker_001"),AISpeechSegment(id:1,start:4.2,end:7,speaker:VL.text("Собеседник 2"),text:VL.text("Я подготовлю отчёт."),speakerID:"speaker_002"),AISpeechSegment(id:2,start:7.2,end:10,speaker:VL.text("Собеседник 1"),text:VL.text("Публикацию пока отложим."),speakerID:"speaker_001")]
        let block=AISummaryBlock(id:"fact_1",kind:"fact",title:VL.text("Проверка перед публикацией"),tokens:[AISummaryToken(text:nil,speakerID:"speaker_002"),AISummaryToken(text:VL.text(" подготовит отчёт о проверке передачи файлов."),speakerID:nil)],sourceSegments:[0,1])
        analyses=[AIProcessingResult(version:1,request:request,stage:.completed,transcript:segments.map(\.text).joined(separator:" "),segments:segments,summary:AIStructuredSummary(summary:VL.text("Проверка перед публикацией"),topics:[],decisions:[],tasks:[],uncertainties:[],recordingTitle:VL.text("Проверка передачи файлов"),blocks:[block]),error:nil,updatedAt:Date(),duration:12)]
        let report=AIVisualSummary(schemaVersion:1,title:VL.text("Проверка перед публикацией — синтетический пример"),theme:"editorial",blocks:Array(AIVisualBlockType.allCases.prefix(10)).enumerated().map {index,type in
            AIVisualBlock(id:"visual_\(index)",type:type,title:type == .hero ? VL.text("Перед публикацией проверим каждую функцию"):type == .quotes ? VL.text("Слова участников"):VL.text("Раздел \(index+1) · Подтверждённые сведения"),items:[AIVisualItem(title:type == .quotes ? VL.text("Точная цитата"):VL.text("Передача файлов и подготовка отчёта"),tokens:[AISummaryToken(text:type == .quotes ? segments[0].text:VL.text("Проверим передачу файлов. Публикацию пока отложим."),speakerID:nil)],sourceSegments:[0,2],value:nil)])
        })
        var newest=analyses[0]
        let newRequest=AIProcessingRequest(version:1,id:UUID(),recordingID:request.recordingID,audioFilename:request.audioFilename,audioSHA256:request.audioSHA256,provider:.local,format:.detailed,createdAt:Date(),summaryOnly:true,transcriptRequestID:request.id,summaryModel:.qwen9b)
        newest=AIProcessingResult(version:1,request:newRequest,stage:.completed,transcript:newest.transcript,segments:segments,summary:newest.summary,error:nil,updatedAt:Date(),duration:12,visualSummary:report)
        analyses.insert(newest,at:0)
        for value in analyses {try LocalAIFileStore(root:root).save(value)}
        analysisID=newRequest.id;conversation = .initial(segments)
        if CommandLine.arguments.contains("--verify-library-ui") {
            search=VL.text("Кто подготовит отчёт и что решили о публикации?")
            _=librarySearchSession.submit(search);libraryQuestionModel = .qwen4b
            libraryAnswer=AILibraryAnswer(schemaVersion:1,status:"answered",paragraphs:[AILibraryParagraph(text:VL.text("Собеседник 2 подготовит отчёт. Публикацию пока решили отложить."),sourceIDs:["S1"])])
            libraryAnswerSources=[AILibrarySource(id:"S1",recordingKey:Self.libraryKey(identity),requestID:newRequest.id,transcriptID:request.id,revision:"fixture",title:VL.text("Проверка передачи файлов"),date:Date(),text:segments.map{($0.speaker ?? "")+": "+$0.text}.joined(separator:"\n"),segmentIDs:segments.map(\.id),start:4.2,end:10)]
            if CommandLine.arguments.contains("--verify-library-loading") {libraryAnswer=nil;libraryAnswerSources=[];libraryQuestionBusy=true;libraryQuestionPhase=VL.text("Ищу в расшифровках…")}
            if CommandLine.arguments.contains("--verify-library-error") {libraryAnswer=nil;libraryAnswerSources=[];searchError=VL.text("Не удалось сформировать ответ. Повторите вопрос.")}
        }

        if CommandLine.arguments.contains("--verify-processing") {
            // Explicit synthetic visual fixture. No inference, library or transport.
            analyses[0].stage = .summarizing;analyses[0].summary=nil;analyses[0].visualSummary=nil
            analyses[0].summaryProgress = .init(phase:"facts",completed:5,total:11)
            try LocalAIFileStore(root:root).save(analyses[0])
            localAI?.processingProgress[newRequest.id]=AIProgressPlan(result:analyses[0]).snapshot(analyses[0])
        }
        if CommandLine.arguments.contains("--verify-streaming") {
            // Synthetic static screenshot fixture, explicitly not inference evidence.
            analyses[0].stage = .summarizing;analyses[0].summary=nil;analyses[0].visualSummary=nil
            analyses[0].summaryDraft=VL.text("## Проверка перед публикацией\n\nУчастники обсуждают проверку передачи файлов. Публикацию отложили до завершения проверки.\n\n### Отчёт и открытые вопросы\n\nУчастник предложил подготовить **тестовый отчёт**. Срок запуска пока не согласован. Текст появляется по мере генерации; это синтетический пример для проверки интерфейса.")
            try LocalAIFileStore(root:root).save(analyses[0])
            if CommandLine.arguments.contains("--verify-assistant-streaming") {
                chat=AIChatHistory(messages:[AIChatMessage(role:"user",text:VL.text("Почему отложили публикацию?"))])
                chatBusy=true;chatDraftKey=conversationKey;chatDraft=analyses[0].summaryDraft ?? ""
                if let key=conversationKey {try AIChatStore(root:root).save(chat,key:key)}
            }
        }
        wordTimings=[AIWordTiming(start:1,end:2,text:VL.text("Проверим "),globalID:0),AIWordTiming(start:2,end:3,text:VL.text("передачу "),globalID:0),AIWordTiming(start:3,end:4,text:VL.text("файлов."),globalID:0),AIWordTiming(start:4.2,end:5,text:VL.text("Я "),globalID:1),AIWordTiming(start:5,end:6,text:VL.text("подготовлю "),globalID:1),AIWordTiming(start:6,end:7,text:VL.text("отчёт."),globalID:1)]
        if CommandLine.arguments.contains("--verify-infographic") {
            let evidence=[AISpeechSegment(id:0,start:1,end:4,speaker:VL.text("Собеседник 1"),text:VL.text("Проверка стоит 30 000 ₽, полный запуск 90 000 ₽."),speakerID:"speaker_001"),AISpeechSegment(id:1,start:4.2,end:7,speaker:VL.text("Собеседник 2"),text:VL.text("Я подготовлю отчёт к пятнице."),speakerID:"speaker_002"),AISpeechSegment(id:2,start:7.2,end:10,speaker:VL.text("Собеседник 1"),text:VL.text("Проверяем передачу файлов, потом решаем вопрос публикации."),speakerID:"speaker_001")]
            func item(_ title:String,_ body:String,_ ids:[Int],_ value:String?=nil,_ number:Double?=nil)->AIVisualItem {AIVisualItem(title:title,tokens:[AISummaryToken(text:body,speakerID:nil)],sourceSegments:ids,value:value,number:number,unit:number==nil ? nil:"RUB")}
            let blocks=[
                AIVisualBlock(id:"hero",type:.hero,title:VL.text("Проверка перед публикацией"),items:[item("",VL.text("Сначала подтвердить надёжность. Решение о публикации пока не принято."),[2])],layout:.wide,role:.fact),
                AIVisualBlock(id:"compare",type:.comparison,title:VL.text("Бюджет работ"),items:[item(VL.text("Проверка"),VL.text("Ограниченный этап проверки."),[0],"30 000 ₽",30000),item(VL.text("Полный запуск"),VL.text("Бюджет полного запуска."),[0],"90 000 ₽",90000)],layout:.half,role:.fact),
                AIVisualBlock(id:"task",type:.tasks,title:VL.text("Отчёт к пятнице"),items:[AIVisualItem(title:VL.text("Подготовить отчёт"),tokens:[AISummaryToken(text:nil,speakerID:"speaker_002"),AISummaryToken(text:VL.text(" обязался подготовить отчёт к пятнице."),speakerID:nil)],sourceSegments:[1],deadline:VL.text("к пятнице"))],layout:.compact,role:.fact),
                AIVisualBlock(id:"flow",type:.processFlow,title:VL.text("Условие публикации"),items:[item(VL.text("Проверить передачу файлов"),VL.text("Проверить передачу файлов."),[2]),item(VL.text("Решить о публикации"),VL.text("Решить о публикации."),[2])],layout:.wide,role:.fact,edges:[AIVisualEdge(from:0,to:1,label:VL.text("После проверки"),sourceSegments:[2])])
            ]
            let infographic=AIVisualSummary(schemaVersion:2,title:VL.text("Проверка перед публикацией"),theme:"editorial",blocks:blocks,subtitle:VL.text("Бюджет, обязательство и следующий шаг"),category:VL.text("Синтетическое обсуждение · проверка интерфейса"),layout:.editorial)
            try infographic.validate(segments:evidence)
            analyses[0].segments=evidence;analyses[0].transcript=evidence.map(\.text).joined(separator:" ");analyses[0].visualSummary=infographic
            if CommandLine.arguments.contains("--verify-visual4") {
                analyses[0].semanticSummary=AISemanticSummary(schemaVersion:1,title:infographic.title,entries:[
                    .init(id:"budget-check",kind:.metric,title:VL.text("Проверка"),tokens:[.init(text:VL.text("Ограниченный этап проверки."),speakerID:nil)],sourceSegments:[0],value:"30 000 ₽",number:30000,unit:"RUB"),
                    .init(id:"budget-launch",kind:.metric,title:VL.text("Полный запуск"),tokens:[.init(text:VL.text("Бюджет запуска."),speakerID:nil)],sourceSegments:[0],value:"90 000 ₽",number:90000,unit:"RUB"),
                    .init(id:"report",kind:.task,title:VL.text("Отчёт"),tokens:[.init(text:VL.text("Подготовить отчёт к пятнице."),speakerID:nil)],sourceSegments:[1],speakerID:"speaker_002",deadline:VL.text("к пятнице")),
                    .init(id:"condition",kind:.decision,title:VL.text("Сначала проверка"),tokens:[.init(text:VL.text("Проверить передачу файлов до решения о публикации."),speakerID:nil)],sourceSegments:[2])])
                analyses[0].visualSummary=analyses[0].semanticSummary?.visual(style:.editorial)
            }
            try LocalAIFileStore(root:root).save(analyses[0]);conversation = .initial(evidence)
            if let index=CommandLine.arguments.firstIndex(of:"--verify-pdf"),CommandLine.arguments.indices.contains(index+1) {
                try NativeVisualPDF.write(report:infographic,title:infographic.title,date:nil,duration:12,speakers:conversation,segments:evidence,textSummary:VL.text("Синтетическое обсуждение: до публикации необходимо проверить передачу файлов. Участник подготовит отчёт к пятнице."),transcript:analyses[0].readableTranscript,to:URL(fileURLWithPath:CommandLine.arguments[index+1]))
            }
        }
        if CommandLine.arguments.contains("--verify-summary-empty") {
            // Only the disposable verification root is written. Preserve a valid
            // transcript to exercise the summary-only first-creation flow.
            for index in analyses.indices {
                analyses[index].summary=nil;analyses[index].visualSummary=nil
                analyses[index].stage = .summaryFailed
                try LocalAIFileStore(root:root).save(analyses[index])
            }
        }
        if let index=CommandLine.arguments.firstIndex(of:"--verify-result-copy"),CommandLine.arguments.indices.contains(index+1) {
            let file=URL(fileURLWithPath:CommandLine.arguments[index+1]).standardizedFileURL
            guard file.pathComponents.contains(where:{$0.hasPrefix("Vecta-private-validation-")}) else {throw AIProcessingError.invalidRequest}
            let copied=try JSONDecoder().decode(AIProcessingResult.self,from:Data(contentsOf:file));try copied.validate()
            let directory=file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let metadataURL=directory.appendingPathComponent("recording-metadata.json")
            if let bytes=try? Data(contentsOf:metadataURL),let metadata=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],let session=metadata["sessionID"] as? Int {
                let realIdentity=NativeRecordingIdentity(serialNumber:"SYNTHETIC",sessionID:session)
                let copiedAudio=directory.appendingPathComponent("recording.mp3")
                verificationItem=NativeLibraryItem(identity:realIdentity,local:nil,remote:NativeRemoteRecording(identity:realIdentity,duration:copied.duration ?? 0,byteSize:0),audioURL:FileManager.default.fileExists(atPath:copiedAudio.path) ? copiedAudio:nil)
                select(realIdentity)
            }
            analyses=[copied];analysisID=copied.request.id;conversation = .initial(copied.segments)
            try LocalAIFileStore(root:root).save(copied)
            let sourceStore=LocalAIFileStore(root:directory),targetStore=LocalAIFileStore(root:root)
            var ancestor=copied,visited=Set<UUID>()
            for _ in 0..<64 {
                guard visited.insert(ancestor.request.id).inserted else {throw AIProcessingError.invalidRequest}
                let sidecar=sourceStore.resultURL(ancestor.request.id).appendingPathExtension("alignment.json")
                if FileManager.default.fileExists(atPath:sidecar.path) {try Data(contentsOf:sidecar).write(to:targetStore.resultURL(ancestor.request.id).appendingPathExtension("alignment.json"),options:.atomic)}
                guard let parent=ancestor.request.transcriptRequestID,let next=try sourceStore.result(parent) else {break}
                guard next.request.audioSHA256==copied.request.audioSHA256 else {throw AIProcessingError.invalidRequest}
                try targetStore.save(next);ancestor=next
            }
            let sourceVoices=try AIConversationStore(root:directory).voices()
            try AIConversationStore(root:root).save(sourceVoices)
            loadConversation()
            if let index=CommandLine.arguments.firstIndex(of:"--verify-real-voices"),CommandLine.arguments.indices.contains(index+1) {
                if let flag=CommandLine.arguments.firstIndex(of:"--verify-forget-voices"),CommandLine.arguments.indices.contains(flag+1) {
                    let original=try Data(contentsOf:targetStore.resultURL(copied.request.id))
                    let others=voiceLibrary.activeProfiles.filter{$0.name != VL.text("Даниил Горелов")}
                    let profile=voiceLibrary.activeProfiles.first{$0.name==VL.text("Даниил Горелов")}!
                    let sample=voiceSample("speaker_001")!
                    var checks=0
                    func check(_ condition:Bool) throws {guard condition else{throw AIProcessingError.invalidRequest};checks+=1}
                    try check(!profile.samples.isEmpty)
                    try check(assignSpeaker("speaker_001",name:profile.name,profile:profile.id,remember:false))
                    try check(forgetVoice(profile.id));loadConversation()
                    try check(voiceLibrary.activeProfiles.first{$0.id==profile.id}==nil && voiceLibrary.profiles.first{$0.id==profile.id}?.samples.isEmpty==true)
                    try check(resolvedConversation.name("speaker_001")==profile.name)
                    try check(conversation.identities["speaker_001"]?.profileID==profile.id)
                    try check(voiceLibrary.probable(sample)?.id != profile.id)
                    try check(voiceLibrary.activeProfiles.filter{$0.id != profile.id}==others)
                    let saved=voiceLibrary
                    try check(!forgetVoice(UUID()));loadConversation()
                    try check(voiceLibrary==saved)
                    try check(try AIConversationStore(root:root).voices()==saved)
                    try check(try Data(contentsOf:targetStore.resultURL(copied.request.id))==original)
                    try JSONSerialization.data(withJSONObject:["passed":checks,"failed":0,"originalResultUnchanged":true,"profileAndConfirmedNamePreserved":true,"otherVoicesUnchanged":true],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[flag+1]),options:.atomic)
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {NSApplication.shared.terminate(nil)}
                    return
                }
                if let quick=CommandLine.arguments.firstIndex(of:"--verify-quick-voices"),CommandLine.arguments.indices.contains(quick+1) {
                    let originals=try Data(contentsOf:targetStore.resultURL(copied.request.id))
                    let originalVoices=voiceLibrary
                    var checks=0
                    func check(_ condition:Bool) throws {guard condition else{throw AIProcessingError.invalidRequest};checks+=1}
                    try check(resolvedConversation.name("speaker_001")==VL.text("Возможно, Даниил Горелов"))
                    try check(resolvedConversation.name("speaker_002")==VL.text("Возможно, Анна Абрашина"))
                    try check(confirmSuggestedVoice("speaker_001"));loadConversation()
                    try check(resolvedConversation.name("speaker_001")==VL.text("Даниил Горелов"))
                    try check(conversation.identities["speaker_001"]?.origin=="profileConfirmed")
                    try check(markSpeakerUnknown("speaker_002"));loadConversation()
                    try check(resolvedConversation.name("speaker_002")==VL.text("Неизвестный собеседник"))
                    try check(conversation.identities["speaker_002"]?.profileID==nil)
                    try check(voiceCandidates("speaker_002").isEmpty)
                    try check(!confirmSuggestedVoice("speaker_002"))
                    let rendered=analysis!.segments
                    try check(rendered.contains{$0.speaker==VL.text("Даниил Горелов")} && rendered.contains{$0.speaker==VL.text("Неизвестный собеседник")})
                    let anna=voiceLibrary.activeProfiles.first{$0.name==VL.text("Анна Абрашина")}!
                    try check(assignSpeaker("speaker_002",name:anna.name,profile:anna.id,remember:false));loadConversation()
                    try check(resolvedConversation.name("speaker_002")==anna.name)
                    try check(markSpeakerUnknown("speaker_002"));loadConversation()
                    try check(resolvedConversation.name("speaker_002")==VL.text("Неизвестный собеседник"))
                    try check(voiceLibrary==originalVoices)
                    try check(try Data(contentsOf:targetStore.resultURL(copied.request.id))==originals)
                    try JSONSerialization.data(withJSONObject:["passed":checks,"failed":0,"fixture":"private real 201.24s recording","originalResultUnchanged":true,"voiceLibraryUnchanged":true],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[quick+1]),options:.atomic)
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {NSApplication.shared.terminate(nil)}
                    return
                }
                let originals=try Data(contentsOf:targetStore.resultURL(copied.request.id))
                var checks=0
                func check(_ value:Bool) throws {guard value else{throw AIProcessingError.invalidRequest};checks+=1}
                for (id,name) in [("speaker_001",VL.text("Даниил Горелов")),("speaker_002",VL.text("Анна Абрашина"))] {
                    try check(voiceSample(id) != nil)
                    try check(resolvedConversation.name(id)==VL.text("Возможно, ")+name)
                    let sample=voiceSample(id)!,profile=voiceLibrary.probable(sample)!.id
                    try check(assignSpeaker(id,name:name,profile:profile,remember:true))
                    loadConversation();try check(resolvedConversation.name(id)==name)
                    try check(assignSpeaker(id,name:name,profile:profile,remember:true))
                    try check(voiceLibrary.profiles.first{$0.id==profile}!.samples.filter{$0.recordingKey==conversationKey && $0.speakerID==id}.count==1)
                    updateVoices {try $0.forget(profile)};loadConversation()
                    try check(voiceLibrary.probable(sample)?.id != profile)
                    try check(resolvedConversation.name(id)==name)
                }
                try check(try Data(contentsOf:targetStore.resultURL(copied.request.id))==originals)
                let report:[String:Any]=["passed":checks,"failed":0,"fixture":"real saved 201.24s recording copied privately","originalResultUnchanged":true,"newInference":false]
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]),options:.atomic)
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {NSApplication.shared.terminate(nil)}
            }
            return
        }
        speakerCentroids=["0":[1,0],"1":[0,1]]
        // Persist the disposable fixture exactly like production sidecars so reopening does not lose embeddings.
        let alignment:[String:Any] = ["complete":true,"words":try JSONSerialization.jsonObject(with:JSONEncoder().encode(wordTimings)),"centroids":speakerCentroids]
        try JSONSerialization.data(withJSONObject:alignment).write(to:LocalAIFileStore(root:root).resultURL(request.id).appendingPathExtension("alignment.json"),options:.atomic)
        if let index=CommandLine.arguments.firstIndex(of:"--verify-speaker-flow"),CommandLine.arguments.indices.contains(index+1) {
            let started=Date(),store=AIConversationStore(root:root)
            let originals=try analyses.map {try Data(contentsOf:LocalAIFileStore(root:root).resultURL($0.request.id))}
            var checks=0
            func check(_ condition:Bool) throws {guard condition else{throw AIProcessingError.invalidRequest};checks+=1}
            loadConversation();try check(voiceSample("speaker_002") != nil)
            try check(assignSpeaker("speaker_002",name:VL.text("Мария"),profile:nil,remember:true))
            let profile=conversation.identities["speaker_002"]!.profileID!
            try check(assignSpeaker("speaker_002",name:VL.text("Мария"),profile:profile,remember:true))
            try check(voiceLibrary.activeProfiles.count==1 && voiceLibrary.activeProfiles[0].samples.count==1)
            try check(voiceCandidates("speaker_001").isEmpty)
            updateVoices {$0.recognitionEnabled=true}
            try check(voiceCandidates("speaker_001").count==1)
            dismissVoiceCandidates("speaker_001");loadConversation();try check(voiceCandidates("speaker_001").isEmpty)
            updateVoices {$0.profiles[0].name=VL.text("Мария Иванова")};loadConversation()
            try check(analysis!.summary!.blocks![0].tokens.contains {$0.speakerID=="speaker_002"} && resolvedConversation.render(analysis!.summary!.blocks![0].tokens).contains(VL.text("Мария Иванова")))
            try check(assignSpeaker("speaker_002",name:VL.text("Маша"),profile:nil,remember:false));loadConversation()
            try check(resolvedConversation.name("speaker_002")==VL.text("Маша") && conversation.identities["speaker_002"]!.profileID==profile)
            try check(assignSpeaker("speaker_002",name:VL.text("Маша"),profile:nil,remember:true));loadConversation();try check(resolvedConversation.name("speaker_002")==VL.text("Маша") && voiceLibrary.activeProfiles[0].samples.count==1)
            // Restore the confirmed link, then separate its saved source, using the same atomic journal as UI.
            try check(assignSpeaker("speaker_002",name:VL.text("Мария Иванова"),profile:profile,remember:false))
            separateVoiceSample(profile,index:0);loadConversation()
            let separated=conversation.identities["speaker_002"]!.profileID!
            try check(separated != profile && resolvedConversation.name("speaker_002")==VL.text("Новый собеседник") && conversation.summaryNeedsReview)
            updateVoices {try $0.retire(separated)};loadConversation()
            try check(resolvedConversation.name("speaker_002")==VL.text("Новый собеседник") && voiceLibrary.profiles.first{$0.id==separated}!.samples.isEmpty)
            rejectVoice("speaker_002");loadConversation();try check(conversation.identities["speaker_002"]!.profileID==nil)
            for (i,result) in analyses.enumerated() {try check(try Data(contentsOf:LocalAIFileStore(root:root).resultURL(result.request.id))==originals[i])}
            try check(try store.voices()==voiceLibrary)
            let result:[String:Any] = ["passed":checks,"failed":0,"durationSeconds":Date().timeIntervalSince(started),"fixture":"synthetic","originalResultsUnchanged":true,"modelInferenceLaunched":false]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]),options:.atomic)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {NSApplication.shared.terminate(nil)}
        }
        status=VL.text("Проверка UI · синтетические данные · библиотека пользователя не открыта")
        if let index=CommandLine.arguments.firstIndex(of:"--verify-playback"),CommandLine.arguments.indices.contains(index+1) {
            let report=URL(fileURLWithPath:CommandLine.arguments[index+1])
            Task {
                playExcerpt(start:1,end:1.1,segment:0)
                try? await Task.sleep(nanoseconds:1_700_000_000)
                let stopped = !playing && progress>=1.89 && progress<=1.91
                togglePlayback()
                try? await Task.sleep(nanoseconds:300_000_000)
                let resumed=playing && progress>2.1
                playExcerpt(start:4.2,end:4.3,segment:1)
                let switched=progress>=3.8 && progress<4.3 && focusedSegment==1
                seek(8);try? await Task.sleep(nanoseconds:300_000_000)
                let manual=playing && progress>=8.1
                togglePlayback()
                let bytes=try? JSONSerialization.data(withJSONObject:["excerptAutoplayAndStop":stopped,"manualPlayClearsExcerpt":resumed,"switchExcerpt":switched,"manualSeekClearsExcerpt":manual],options:[.prettyPrinted,.sortedKeys])
                try? bytes?.write(to:report,options:.atomic)
                NSApp.terminate(nil)
            }
        }
    }
}
