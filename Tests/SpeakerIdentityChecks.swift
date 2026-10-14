import Foundation

/// Source-only fixtures. No app, device, model, Keychain or real library access.
@main struct SpeakerIdentityChecks {
    static var count=0
    static func check(_ condition:@autoclosure () throws->Bool,_ message:String)throws {
        guard try condition() else {throw NSError(domain:"SpeakerIdentityChecks",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
        count+=1
    }
    static func rejects(_ operation:()throws->Void)throws {
        do {try operation()} catch {count+=1;return}
        throw NSError(domain:"SpeakerIdentityChecks",code:2)
    }
    static func snapshot<T:Encodable>(_ value:T)throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys;return try encoder.encode(value)
    }
    static func main()throws {
        let key=String(repeating:"a",count:64)
        let segments=[
            AISpeechSegment(id:1,start:0,end:5,speaker:"Собеседник 1",text:"Анна — имя другого человека; literal speaker_001",speakerID:"speaker_001"),
            AISpeechSegment(id:2,start:6,end:9,speaker:"Собеседник 2",text:"Отдельный голос",speakerID:"speaker_002")
        ]
        let request=AIProcessingRequest(version:1,id:UUID(),recordingID:"synthetic-recording",audioFilename:"synthetic.wav",audioSHA256:key,provider:.local,format:.standard,createdAt:Date(),summaryOnly:false,transcriptRequestID:nil)
        let oldName="Анна"
        let attributed=[AISummaryToken(text:"Возможно, Анна предложила план.",speakerID:nil)]
        let explicit=[AISummaryToken(text:nil,speakerID:"speaker_001"),AISummaryToken(text:"предложила план.",speakerID:nil)]
        let quote="Анна literal speaker_001 цитата"
        let full=AIFullTextSummary(schemaVersion:1,paragraphs:[
            .init(id:"p1",heading:"Участник: speaker_001",tokens:attributed,sourceSegments:[1]),
            .init(id:"p2",heading:nil,tokens:explicit,sourceSegments:[1]),
            .init(id:"p3",heading:nil,tokens:[.init(text:"Обсудили документ Анна. «Возможно, Анна сказала speaker_001». Другой speaker_002.",speakerID:nil)],sourceSegments:[1])
        ])
        let semantic=AISemanticSummary(schemaVersion:1,title:"План работы",entries:[
            .init(id:"participant",kind:.participant,title:oldName,tokens:[.init(text:"Анна — участница обсуждения.",speakerID:nil)],sourceSegments:[1],speakerID:"speaker_001"),
            .init(id:"decision",kind:.decision,title:"План",tokens:explicit,sourceSegments:[1],speakerID:"speaker_001"),
            .init(id:"quote",kind:.quote,title:oldName,tokens:[.init(text:quote,speakerID:nil)],sourceSegments:[1],speakerID:"speaker_001")
        ])
        let visual=AIVisualSummary(schemaVersion:1,title:"План работы",theme:"editorial",blocks:[
            .init(id:"persons",type:.keyPoints,title:"Участники",items:[.init(title:oldName,tokens:attributed,sourceSegments:[1],speakerID:"speaker_001")]),
            .init(id:"quotes",type:.quotes,title:"Цитаты",items:[.init(title:oldName,tokens:[.init(text:quote,speakerID:nil)],sourceSegments:[1],speakerID:"speaker_001")])
        ])
        var raw=AIProcessingResult(version:1,request:request,stage:.completed,transcript:segments.map(\.text).joined(separator:"\n"),segments:segments,summary:AIStructuredSummary(summary:"Возможно, Анна предложила план. speaker_002 согласен.",topics:[],decisions:[],tasks:[.init(description:"Подготовить план",assignee:oldName,deadline:"завтра",sourceSegments:[1])],uncertainties:[]),error:nil,updatedAt:Date(),duration:9,recognitionSeconds:nil,summarySeconds:nil)
        raw.fullTextSummary=full;raw.semanticSummary=semantic;raw.visualSummary=visual
        let original=try snapshot(raw)
        let alignment=AISpeakerAlignment(complete:true,words:[],centroids:["0":[1,0]])
        var speakers=AIRecordingSpeakers.initial(segments)
        let query=alignment.sample("speaker_001",result:raw,conversation:speakers,key:key)!
        var voices=AIVoiceLibrary();voices.recognitionEnabled=true
        let person=try voices.remember(name:oldName,sample:.init(recordingKey:"previous",speakerID:"speaker_001",embedding:[0.8,0.6],confirmedAt:Date(),recordingID:"previous"))
        let untouchedVoices=voices
        let proposed=voices.resolving(speakers,result:raw,alignment:alignment,key:key)
        try check(proposed.name("speaker_001")==oldName,"Suggested name is not affirmative")
        try check(proposed.identities["speaker_001"]?.origin=="voiceSuggestion","Internal provisional origin lost")
        try check(proposed.identities["speaker_001"]?.profileID==nil,"Suggestion auto-confirmed identity")
        try check(proposed.identities["speaker_001"]?.suggestedProfileID==person,"Display match key missing")
        try check(proposed.identities["speaker_001"]?.isVoiceConfirmed==false,"Provisional match reported confirmed")
        try check(voices==untouchedVoices,"Display projection trained voice")
        try check(proposed.rendered(raw).summary!.summary.contains("Анна предложила") && !proposed.rendered(raw).summary!.summary.contains("Возможно"),"Old qualifier remains visible")
        var historical=proposed;historical.identities["speaker_001"]?.name="Возможно, Анна"
        try check(historical.name("speaker_001")==oldName,"Historical provisional label not normalized")

        // Correct the stable identity, not words in source speech or a visual-only card.
        speakers=proposed
        try speakers.rename("speaker_001",to:"Мария")
        speakers.identities["speaker_001"]?.profileID=nil
        speakers.identities["speaker_001"]?.suggestedProfileID=nil
        let corrected=speakers.rendered(raw)
        try check(corrected.segments[0].speaker=="Мария","Transcript attribution stale")
        try check(corrected.segments[0].text==segments[0].text && corrected.transcript==raw.transcript,"Original speech mutated")
        try check(corrected.summary!.summary.contains("Мария предложила"),"Legacy summary attribution stale")
        try check(corrected.summary!.tasks[0].assignee=="Мария","Task assignee stale")
        try check(corrected.fullTextSummary!.rendered(speakers:speakers).contains("Мария предложила"),"Full text summary stale")
        try check(corrected.fullTextSummary!.paragraphs[0].tokens.contains {$0.speakerID=="speaker_001"},"Legacy reference not converted to identity key")
        try check(corrected.semanticSummary!.entries[0].title=="Мария","Semantic participant stale")
        try check(speakers.render(corrected.semanticSummary!.entries[0].tokens).contains("Мария —"),"Semantic participant description stale")
        try check(corrected.visualSummary!.blocks[0].items[0].title=="Мария","Legacy visual participant stale")
        try check(speakers.render(corrected.visualSummary!.blocks[0].items[0].tokens).contains("Мария предложила"),"Legacy visual summary stale")
        let derived=corrected.semanticSummary!.visual(style:.editorial)
        try check(derived.blocks.flatMap(\.items).contains {$0.title=="Мария" && $0.speakerID=="speaker_001"},"Semantic engine visual projection stale")
        try check(speakers.render(corrected.semanticSummary!.entries[2].tokens)==quote,"Semantic direct speech changed")
        try check(speakers.render(corrected.visualSummary!.blocks[1].items[0].tokens)==quote,"Legacy visual direct speech changed")
        let prose=corrected.fullTextSummary!.rendered(speakers:speakers)
        try check(prose.contains("документ Анна"),"Unrelated proper-name mention replaced")
        try check(prose.contains("«Возможно, Анна сказала speaker_001»"),"Inline quote changed")
        try check(prose.contains("Собеседник 2"),"Different identity collapsed")
        try check(speakers.rendered(corrected)==corrected,"Summary projection is not idempotent")
        try check(try snapshot(raw)==original,"Inference envelope was rewritten")
        try check(corrected.semanticSummary!.entries.map(\.sourceSegments)==semantic.entries.map(\.sourceSegments),"Evidence keys changed")
        try check(speakers.resolveText("Обсудили документ Анна.")=="Обсудили документ Анна.","Global proper-name replacement remains")
        try check(speakers.resolveText("> speaker_001 говорит Анна")=="> speaker_001 говорит Анна","Markdown direct speech changed")
        let legacyQuote=AIFullTextSummary.preserving(.init(summary:"> speaker_001 говорит Анна",topics:[],decisions:[],tasks:[],uncertainties:[]))
        try check(speakers.renderedFullText(legacyQuote).rendered(speakers:speakers).contains("speaker_001 говорит Анна"),"Legacy quote formatter lost literal guard")
        var renamedAgain=speakers;try renamedAgain.rename("speaker_001",to:"Ольга")
        try check(corrected.fullTextSummary!.rendered(speakers:renamedAgain).contains("Ольга предложила"),"Already projected reference lost dynamic identity")
        try check(renamedAgain.render(corrected.semanticSummary!.entries[1].tokens).contains("Ольга"),"Existing semantic tokens need regeneration")
        try check(renamedAgain.render(corrected.visualSummary!.blocks[0].items[0].tokens).contains("Ольга"),"Existing visual tokens need regeneration")

        // Explicit positive learning adds independent eligible sources; repeat
        // confirmation and source reassignment never multiply the same source.
        try check(alignment.sample("speaker_001",result:raw,conversation:AIRecordingSpeakers.initial(segments),key:key) != nil,"Eligible sample lost")
        try check(AISpeakerAlignment(complete:false,words:[],centroids:alignment.centroids).sample("speaker_001",result:raw,conversation:speakers,key:key)==nil,"Incomplete alignment enrolled")
        _ = try voices.remember(name:oldName,sample:query,profileID:person)
        try check(voices.profiles[0].samples.count==2,"Confirmation did not learn an independent source")
        try check(abs(voices.ranked(query).first!.1-0.1)<0.00001,"Multiple confirmed sources not used in recognition")
        _ = try voices.remember(name:oldName,sample:query,profileID:person)
        try check(voices.profiles[0].samples.count==2,"Duplicate confirmation multiplied sample")
        let learned=voices
        try rejects {_ = try voices.remember(name:"Bad",sample:.init(recordingKey:key,speakerID:"speaker_001",embedding:[0,0],confirmedAt:Date()),profileID:person)}
        try check(voices==learned,"Ineligible sample changed library")
        let newPerson=try voices.remember(name:"Мария",sample:query,forceNewProfile:true)
        try check(newPerson != person,"New-person route reused rejected profile")
        try check(voices.profiles.first {$0.id==person}!.samples.count==1,"Reassignment damaged independent old sample")
        try check(voices.profiles.flatMap(\.samples).filter {$0.isSameSource(as:query)}.count==1,"Reassigned source belongs to two profiles")
        try check(voices.profiles.first {$0.id==person}!.name==oldName,"Old person history deleted")
        let afterReassignment=voices
        var rejected=speakers;try rejected.rejectMatch("speaker_001",profile:newPerson)
        try check(rejected.dismissedSuggestions?["speaker_001"]?.contains(newPerson.uuidString)==true,"Recording-local rejection lost")
        try check(voices==afterReassignment,"Rejection trained a sample")
        try check(voices.probable(query,rejected:[person.uuidString,newPerson.uuidString])==nil,"Rejected match proposed again")
        let alias=UUID();voices.aliases=[alias.uuidString:newPerson.uuidString]
        try check(voices.probable(query,rejected:[person.uuidString,alias.uuidString])==nil,"Rejected alias trains/proposes canonical person")
        var partial=AIRecordingSpeakers.initial(segments)
        partial.identities["split"] = .init(id:"split",name:"Другой",origin:"manual",profileID:nil)
        partial.assignments["1"]="split"
        try check(alignment.sample("speaker_001",result:raw,conversation:partial,key:key)==nil,"Partial reassignment relabelled whole centroid")
        var ambiguous=speakers;ambiguous.identities["speaker_002"]?.referenceNames=["Анна"]
        try check(ambiguous.resolveText("Возможно, Анна предложила план.")=="Возможно, Анна предложила план.","Ambiguous proper name assigned by guess")
        try check(ambiguous.render(explicit).contains("Мария"),"Ambiguous name damaged explicit key")

        // Chooser state is side-effect-free until explicit final confirmation.
        var chooser=AISpeakerChooserState();chooser.rejectedProfileIDs=[person]
        chooser.select(person,in:voices)
        try check(chooser.selectedProfileID==nil,"Chooser selected rejected identity")
        chooser.search="  Мария  "
        try check(chooser.people(in:voices).map(\.id)==[newPerson],"Existing-person search unclear/wrong")
        chooser.select(newPerson,in:voices)
        try check(chooser.choice(in:voices,sampleAvailable:true)?.profileID==newPerson,"Existing selection lost")
        chooser.registerNewPerson();chooser.name="  Новый человек  "
        try check(chooser.selectedProfileID==nil && chooser.choice(in:voices,sampleAvailable:true)?.profileID==nil,"New-person route retained prior binding")
        chooser.remember=true
        try check(chooser.choice(in:voices,sampleAvailable:false)==nil,"Unavailable sample can be enrolled by chooser")
        chooser.remember=false
        try check(chooser.choice(in:voices,sampleAvailable:false)?.name=="Новый человек","Name-only correction unavailable")
        chooser.name="\n";try check(chooser.choice(in:voices,sampleAvailable:true)==nil,"Blank registration enabled")
        chooser.name="Bad\u{0001}";try check(chooser.choice(in:voices,sampleAvailable:true)==nil,"Control characters accepted")
        let beforeDeletion=voices
        chooser.requestVoiceDeletion(newPerson,in:voices)
        try check(voices==beforeDeletion && chooser.pendingVoiceDeletion==newPerson,"Opening deletion mutated profile")
        chooser.cancelVoiceDeletion()
        try check(chooser.confirmedVoiceDeletion(in:voices)==nil && voices==beforeDeletion,"Cancelled deletion authorized")
        chooser.requestVoiceDeletion(newPerson,in:voices)
        let confirmedDeletion=chooser.confirmedVoiceDeletion(in:voices)!
        try voices.forget(confirmedDeletion)
        try check(voices.profiles.first {$0.id==newPerson}!.samples.isEmpty,"Confirmed voice deletion retained embeddings")
        try check(voices.profiles.first {$0.id==newPerson}!.name=="Мария","Voice deletion removed historical person tombstone")
        try check(voices.profiles.first {$0.id==person}!.samples.count==1,"Voice deletion affected different person")
        try check(try snapshot(raw)==original && speakers.name("speaker_001")=="Мария","Voice deletion damaged recordings/results/identity")
        try check(chooser.choice(in:voices,sampleAvailable:true)==nil,"Deleted/stale selection can be confirmed")

        // A recording merge learns both complete acoustic groups, not just the
        // destination centroid. Other recordings and people remain independent.
        let complete=AISpeakerAlignment(complete:true,words:[],centroids:["0":[1,0],"1":[0,1]])
        let cleanRecording=AIRecordingSpeakers.initial(segments)
        var mergeVoices=AIVoiceLibrary();mergeVoices.recognitionEnabled=true
        let mergePerson=try mergeVoices.remember(name:"Merge person",sample:.init(recordingKey:"elsewhere",speakerID:"speaker_001",embedding:[1,0],confirmedAt:Date(),recordingID:"elsewhere"))
        let suggestion=mergeVoices.resolving(cleanRecording,result:raw,alignment:complete,key:key)
        try check(suggestion.identities["speaker_002"]!.needsVoiceConfirmation,"Suggestion confirmation missing")
        try check(suggestion.name("speaker_002")=="Merge person","Merge menu cannot resolve suggested person")
        let merged=try mergeVoices.mergeSpeakers("speaker_001",into:"speaker_002",recording:cleanRecording,result:raw,alignment:complete,key:key,title:"Synthetic title")
        try check(merged.identities.count==1 && merged.identities["speaker_001"]==nil,"Source identity remains after merge")
        try check(merged.canonicalSpeakerID("speaker_001")=="speaker_002" && merged.speakerID(segments[0])=="speaker_002","Merge lost stable assignments/aliases")
        try check(merged.identities["speaker_002"]?.profileID==mergePerson && merged.identities["speaker_002"]?.isVoiceConfirmed==true,"Merge did not bind destination person")
        try check(merged.identities["speaker_002"]?.needsVoiceConfirmation==false,"Merge keeps confirmation controls")
        let joined=mergeVoices.profiles[0].samples.first {$0.recordingKey==key}!
        try check(joined.segmentIDs==[1,2] && joined.speechSeconds==8,"Joined sample omits source turns")
        try check(joined.embedding[0]>0 && joined.embedding[1]>0,"Joined sample omits a voice centroid")
        try check(joined.recordingTitle=="Synthetic title" && mergeVoices.profiles[0].samples.count==2,"Voice source metadata/other recording lost")
        _=try mergeVoices.remember(name:"Merge person",sample:joined,profileID:mergePerson)
        try check(mergeVoices.profiles[0].samples.count==2,"Repeat merged confirmation duplicates evidence")
        try check(try snapshot(raw)==original,"Merge rewrites original inference result")
        var silentVoices=AIVoiceLibrary()
        let unbound=try silentVoices.mergeSpeakers("speaker_001",into:"speaker_002",recording:cleanRecording,result:raw,alignment:complete,key:key)
        try check(unbound.identities["speaker_002"]?.profileID==nil && silentVoices.profiles.isEmpty,"Anonymous merge invents a person")
        var inherited=cleanRecording;inherited.identities["speaker_001"]?.profileID=mergePerson;inherited.identities["speaker_001"]?.origin="profileConfirmed"
        var inheritVoices=mergeVoices;inheritVoices.recognitionEnabled=false
        let inheritedMerge=try inheritVoices.mergeSpeakers("speaker_001",into:"speaker_002",recording:inherited,result:raw,alignment:complete,key:key)
        try check(inheritedMerge.identities["speaker_002"]?.profileID==mergePerson,"Merge discards source confirmed person when target anonymous")
        var conflicts=mergeVoices
        let different=try conflicts.remember(name:"Different person",sample:.init(recordingKey:"another",speakerID:"speaker_001",embedding:[0,1],confirmedAt:Date(),recordingID:"another"))
        let otherHistory=conflicts.profiles.first {$0.id==different}!.samples
        var bound=cleanRecording
        bound.identities["speaker_001"]?.profileID=different;bound.identities["speaker_001"]?.origin="profileConfirmed"
        bound.identities["speaker_002"]?.profileID=mergePerson;bound.identities["speaker_002"]?.origin="profileConfirmed"
        let sourceSample=complete.sample("speaker_001",result:raw,conversation:bound,key:key)!
        _=try conflicts.remember(name:"Different person",sample:sourceSample,profileID:different)
        let beforeConflict=conflicts
        try rejects {_=try conflicts.mergeSpeakers("speaker_001",into:"speaker_002",recording:bound,result:raw,alignment:complete,key:key)}
        try check(conflicts==beforeConflict,"Unconfirmed conflict mutates voice data")
        let confirmedMerge=try conflicts.mergeSpeakers("speaker_001",into:"speaker_002",recording:bound,result:raw,alignment:complete,key:key,allowProfileChange:true)
        try check(confirmedMerge.identities["speaker_002"]?.profileID==mergePerson,"Explicit conflict did not choose destination")
        try check(conflicts.profiles.first {$0.id==different}!.samples==otherHistory,"Recording merge changes other recordings/profile history")
        try check(conflicts.profiles.first {$0.id==mergePerson}!.samples.filter {$0.recordingID==raw.request.recordingID}.count==1,"Merge retains duplicate original-group evidence")
        var mixed=cleanRecording
        mixed.identities["speaker_001"]?.profileID=different;mixed.identities["speaker_001"]?.origin="profileConfirmed"
        let mixedAlignment=AISpeakerAlignment(complete:true,words:[],centroids:["0":[0,1],"1":[1,0]])
        let mixedResolved=beforeConflict.resolving(mixed,result:raw,alignment:mixedAlignment,key:key)
        try check(mixedResolved.identities["speaker_002"]?.suggestedProfileID==mergePerson,"Mixed fixture lacks different suggested destination")
        try check(beforeConflict.mergeNeedsConfirmation(source:mixedResolved.identities["speaker_001"]!,destination:mixedResolved.identities["speaker_002"]!),"Suggested destination bypasses conflict policy")
        var mixedVoices=beforeConflict
        try rejects {_=try mixedVoices.mergeSpeakers("speaker_001",into:"speaker_002",recording:mixed,result:raw,alignment:mixedAlignment,key:key)}
        try check(mixedVoices==beforeConflict,"Suggested-person conflict mutates before confirmation")
        var noAlignment=beforeConflict
        let recoveredMerge=try noAlignment.mergeSpeakers("speaker_001",into:"speaker_002",recording:bound,result:raw,alignment:.init(complete:false,words:[],centroids:[:]),key:key,allowProfileChange:true)
        try check(recoveredMerge.identities["speaker_002"]?.profileID==mergePerson,"Missing alignment loses person")
        try check(noAlignment.profiles.first {$0.id==mergePerson}!.samples.contains(sourceSample),"Missing alignment loses enrolled source voice")
        try check(noAlignment.profiles.first {$0.id==different}!.samples==otherHistory,"Source evidence not moved exclusively")
        let resumedSample=complete.sample("speaker_002",result:raw,conversation:recoveredMerge,key:key)!
        _=try noAlignment.remember(name:"Merge person",sample:resumedSample,profileID:mergePerson)
        try check(noAlignment.profiles.first {$0.id==mergePerson}!.samples.filter {$0.recordingID==raw.request.recordingID}.count==1,"Later alignment confirmation duplicates retained original-group samples")
        try check(noAlignment.profiles.first {$0.id==different}!.samples==otherHistory,"Later alignment confirmation damages other history")
        try check(!joined.isCovered(by:sourceSample),"Partial sample removes broader joined evidence")
        var overlapping=raw
        overlapping.segments[1]=AISpeechSegment(id:2,start:2,end:8,speaker:"Собеседник 2",text:"Overlap",speakerID:"speaker_002")
        var overlapVoices=beforeConflict
        try rejects {_=try overlapVoices.mergeSpeakers("speaker_001",into:"speaker_002",recording:bound,result:overlapping,alignment:complete,key:key,allowProfileChange:true)}
        try check(overlapVoices==beforeConflict,"Overlapping voices were learned as one person")
        var aliasVoices=beforeConflict
        let oldProfile=UUID();aliasVoices.aliases=[oldProfile.uuidString:mergePerson.uuidString]
        var aliased=bound;aliased.identities["speaker_001"]?.profileID=oldProfile
        let samePersonMerge=try aliasVoices.mergeSpeakers("speaker_001",into:"speaker_002",recording:aliased,result:raw,alignment:complete,key:key)
        try check(samePersonMerge.identities["speaker_002"]?.profileID==mergePerson,"Canonical same-person merge treated as conflict")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-speaker-checks-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=AIConversationStore(root:root)
        try store.saveTogether(speakers,key:key,voices:voices)
        try check(try store.voices()==voices,"Restart lost preserved voice history")
        try check(try store.recording(key,segments:segments)==speakers,"Restart lost identity overlay")
        try check(try snapshot(raw)==original,"Synthetic persistence mutated source result")
        print("PASS: \(count) speaker identity, summary projections, learning, chooser and preservation checks. Synthetic source-only fixtures.")
    }
}
