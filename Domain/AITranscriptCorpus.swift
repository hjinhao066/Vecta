import Foundation
import CryptoKit

struct AILibraryCatalogItem {
    var key:String
    var filenames:Set<String>
    var title:String
    var date:Date
    var legacyText:String?
}

/// Bulk manifest reconciliation happens on library/result events, never inside index search.
actor AITranscriptCorpus {
    let index:AITranscriptIndexStore
    private let root:URL
    private let mailbox=LocalAIMailbox()
    init(root:URL) throws {self.root=root;index=try AITranscriptIndexStore(root:root)}
    static func digest(_ data:Data) -> String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func speechReady(_ result:AIProcessingResult) -> Bool {
        guard !result.stage.isActive,let text=result.transcript,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return false}
        if let p=result.recognitionProgress {return p.completedChunks==p.totalChunks && p.processedSeconds==p.totalSeconds}
        return true
    }
    static func lineage(_ result:AIProcessingResult,results:[UUID:AIProcessingResult]) -> UUID? {
        var current=result,seen=Set<UUID>()
        for _ in 0..<64 {
            guard seen.insert(current.request.id).inserted else {return nil}
            guard let parent=current.request.transcriptRequestID else {return current.request.id}
            guard let next=results[parent],next.request.audioSHA256==result.request.audioSHA256 else {return nil};current=next
        }
        return nil
    }
    static func document(_ item:AILibraryCatalogItem,results:[UUID:AIProcessingResult],speakers:AIConversationStore) throws -> AILibraryDocument? {
        let candidates=results.values.filter {item.filenames.contains($0.request.audioFilename) && speechReady($0)}
        let branches=candidates.compactMap {r -> (AIProcessingResult,UUID,Date)? in
            guard let id=lineage(r,results:results),let original=results[id],speechReady(original) else {return nil}
            return (r,id,original.request.createdAt)
        }.sorted {a,b in a.2==b.2 ? a.0.request.createdAt>b.0.request.createdAt:a.2>b.2}
        guard let (carrier,original,_) = branches.first else {
            guard let body=item.legacyText?.trimmingCharacters(in:.whitespacesAndNewlines),!body.isEmpty else {return nil}
            let revision=digest(Data(("legacy-v2"+item.title+body).utf8))
            return AILibraryDocument(key:item.key,revision:revision,sources:untimed(body,item:item,request:nil,transcript:nil,revision:revision))
        }
        let key=digest(Data((carrier.request.audioSHA256+(carrier.request.transcriptRequestID ?? carrier.request.id).uuidString).utf8))
        let saved=try speakers.recording(key,segments:carrier.segments)
        // Only explicit identity/name corrections are authoritative. Suggestions stay tentative.
        var corrected=saved
        let voices=try speakers.voices()
        for (id,identity) in corrected.identities {
            if let profile=identity.profileID,identity.origin=="profileConfirmed",identity.nameOverride != true,
               let person=voices.profiles.first(where:{$0.id==voices.canonical(profile) && $0.retiredAt==nil}) {corrected.identities[id]?.name=person.name}
        }
        let projected=corrected.rendered(carrier)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let revision=digest(try encoder.encode(projected.segments)+Data(("chunks-v4|"+original.uuidString+item.title+String(item.date.timeIntervalSince1970)+(projected.unmatchedText ?? "")).utf8))
        var sources=[AILibrarySource](),group=[AISpeechSegment](),chars=0
        func flush() {
            guard !group.isEmpty else {return}
            sources.append(AILibrarySource(id:"",recordingKey:item.key,requestID:carrier.request.id,transcriptID:original,revision:revision,title:item.title,date:item.date,
                text:group.map{($0.speaker.map{$0+": "} ?? "")+$0.text}.joined(separator:"\n"),segmentIDs:Array(Set(group.map(\.id))).sorted(),start:group.map(\.start).min(),end:group.map(\.end).max()))
        }
        // Overlap one utterance. Every timed source keeps original, recording-local IDs.
        let bounded=projected.segments.sorted(by:{$0.start<$1.start}).flatMap {segment -> [AISpeechSegment] in
            var pieces=[AISpeechSegment](),position=segment.text.startIndex
            while position<segment.text.endIndex {
                let end=segment.text.index(position,offsetBy:1200,limitedBy:segment.text.endIndex) ?? segment.text.endIndex
                let piece=AISpeechSegment(id:segment.id,start:segment.start,end:segment.end,speaker:segment.speaker,text:String(segment.text[position..<end]),speakerID:segment.speakerID);pieces.append(piece);position=end
            }
            return pieces
        }
        for segment in bounded {
            if chars+segment.text.count>1400 || group.count>=8 {flush();group=Array(group.suffix(1));chars=group.reduce(0){$0+$1.text.count};if chars+segment.text.count>1400 {group=[];chars=0}}
            group.append(segment);chars+=segment.text.count
        }
        flush()
        if let text=projected.unmatchedText,!text.isEmpty {sources+=untimed(text,item:item,request:carrier.request.id,transcript:original,revision:revision)}
        if sources.isEmpty,let text=projected.transcript {sources=untimed(text,item:item,request:carrier.request.id,transcript:original,revision:revision)}
        return AILibraryDocument(key:item.key,revision:revision,sources:sources)
    }
    private static func untimed(_ text:String,item:AILibraryCatalogItem,request:UUID?,transcript:UUID?,revision:String) -> [AILibrarySource] {
        var values=[AILibrarySource](),position=text.startIndex
        while position<text.endIndex {
            let end=text.index(position,offsetBy:1400,limitedBy:text.endIndex) ?? text.endIndex
            values.append(AILibrarySource(id:"",recordingKey:item.key,requestID:request,transcriptID:transcript,revision:revision,title:item.title,date:item.date,text:String(text[position..<end]),segmentIDs:[],start:nil,end:nil));position=end
        }
        return values
    }
    func reconcile(_ items:[AILibraryCatalogItem],onProgress:@escaping @Sendable (Int,Int)->Void) async throws -> AILibraryIndexStatus {
        let store=LocalAIFileStore(root:root),conversation=AIConversationStore(root:root)
        let requests=try await mailbox.requests(root:root)
        let grouped=Dictionary(grouping:requests,by:{$0.audioFilename})
        let voiceStamp=AIFileRevision.stamp(conversation.root.appendingPathComponent("voices.json"))
            + AIFileRevision.stamp(conversation.root.appendingPathComponent("pending-voice-edit.json"))
        let existingInputs=try await index.inputs()
        var indexed=Set<String>()
        try await index.retain(Set(items.map(\.key)))
        for (offset,item) in items.enumerated() {
            try Task.checkCancellation()
            let relevant=Dictionary(uniqueKeysWithValues:item.filenames.flatMap{grouped[$0] ?? []}.map{($0.id,$0)})
            let signatures=relevant.values.map {request -> String in
                let key=Self.digest(Data((request.audioSHA256+(request.transcriptRequestID ?? request.id).uuidString).utf8))
                return request.id.uuidString+AIFileRevision.stamp(store.resultURL(request.id))
                    + AIFileRevision.stamp(conversation.root.appendingPathComponent(key+".json"))
            }.sorted()
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let input=Self.digest(try encoder.encode(["inputs-v4",item.title,String(item.date.timeIntervalSince1970),item.legacyText ?? "",voiceStamp]+signatures))
            if existingInputs[item.key]==input {
                indexed.insert(item.key)
            } else {
                var results=[UUID:AIProcessingResult]()
                for request in relevant.values {
                    if var value=try await mailbox.result(request.id,root:root),value.request==request {
                        value.summary=nil;value.summaryDraft=nil;value.visualSummary=nil;value.semanticSummary=nil;value.fullTextSummary=nil
                        results[request.id]=value
                    }
                }
                if let document=try Self.document(item,results:results,speakers:conversation) {
                    try await index.replace(document)
                    try await index.setInput(item.key,stamp:input)
                    indexed.insert(item.key)
                }
            }
            onProgress(offset+1,items.count)
        }
        try await index.retain(indexed)
        return try await index.status()
    }
}
