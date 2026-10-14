import Foundation
import SwiftUI

@MainActor extension NativeMacModel {
    static func libraryKey(_ id:NativeRecordingIdentity) -> String {id.serialNumber+"|"+String(id.sessionID)}
    var libraryCorpusFingerprint:String {
        String(libraryCorpusVersion)+"|"+String(library?.revision ?? 0)
    }
    var hasLibraryQuestion:Bool {!librarySearchSession.submittedQuestion.isEmpty}
    func refreshLibraryIndex() {
        guard let host=localAI,let library else {return}
        libraryIndexTask?.cancel();let token=UUID();libraryIndexGeneration=token
        let items=library.items.compactMap {item -> AILibraryCatalogItem? in
            guard let local=item.local else {return nil}
            return AILibraryCatalogItem(key:Self.libraryKey(item.identity),filenames:Set(VectaLocalAudioExporter.filenames(for:local)),title:item.title,date:item.createdAt,legacyText:local.transcript)
        }
        do {if libraryCorpus==nil {libraryCorpus=try AITranscriptCorpus(root:host.root)}} catch {libraryIndexMessage=error.localizedDescription;return}
        guard let corpus=libraryCorpus else {return}
        libraryIndexMessage=VL.text("Подготавливаю поиск…")
        libraryIndexTask=Task { [self] in
            do {
                try await Task.sleep(nanoseconds:150_000_000);try Task.checkCancellation()
                let result=try await corpus.reconcile(items) { [weak self] done,total in
                    if done%10==0 || done==total {Task{@MainActor in if let self,self.libraryIndexGeneration==token {self.libraryIndexMessage=VL.text("Подготавливаю поиск: \(done) из \(total)")}}}
                }
                guard !Task.isCancelled,libraryIndexGeneration==token else {return}
                libraryIndexStatus=result
                libraryAssetsMissing=result.semanticChunks<result.chunks
                libraryIndexMessage=result.semanticChunks==result.chunks ? "":VL.text("Смысловой поиск доступен не для всех расшифровок.")
            } catch is CancellationError {} catch {if libraryIndexGeneration==token {libraryIndexMessage=error.localizedDescription}}
        }
    }
    func installLibrarySearchAssets() {
        guard let corpus=libraryCorpus, let library, let host=localAI else {return}
        let scope = NativeLibraryOperationScope(library: library, host: host, generation: libraryGeneration)
        Task {
            do {
                try await corpus.index.requestAssets()
                guard ownsLibraryOperation(scope) else { return }
                refreshLibraryIndex()
            } catch { if ownsLibraryOperation(scope) { libraryIndexMessage=error.localizedDescription } }
        }
    }
    func clearLibraryQuestion() {
        objectWillChange.send()
        librarySearchSession.clear()
        libraryQuestionScroll=0;search="";libraryAnswer=nil;libraryAnswerSources=[];libraryAnswerDraft="";libraryQuestionPhase="";searchError=nil;libraryQuestionBusy=false;libraryQuestionModel=nil
        libraryQuestionTask?.cancel();libraryQuestionTask=nil;searchFocusSignal=UUID()
    }
    func askLibraryQuestion() {
        objectWillChange.send()
        let question=search.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !question.isEmpty,question.count<=2000,let library,let host=localAI else {return}
        libraryQuestionTask?.cancel()
        libraryQuestionScroll=0
        let token=librarySearchSession.submit(question),model=host.summaryModel
        libraryAnswer=nil;libraryAnswerSources=[];libraryAnswerDraft="";searchError=nil;libraryQuestionBusy=true;libraryQuestionPhase=VL.text("Ищу в расшифровках…");libraryQuestionModel=model
        if libraryCorpus==nil {refreshLibraryIndex()}
        let indexing=libraryIndexTask,version=libraryCorpusVersion
        let scope = NativeLibraryOperationScope(library: library, host: host, generation: libraryGeneration)
        libraryQuestionTask=Task { [self] in
            defer {if ownsLibraryOperation(scope, checkCancellation: false),librarySearchSession.accepts(token) {libraryQuestionBusy=false;libraryQuestionTask=nil}}
            do {
                await indexing?.value;try Task.checkCancellation()
                guard ownsLibraryOperation(scope),librarySearchSession.accepts(token) else {return}
                guard let corpus=libraryCorpus else {throw AITranscriptIndexError.database}
                let visible=Set(library.items.map{Self.libraryKey($0.identity)})
                let sources=try await corpus.index.search(question,visible:visible,characterBudget:ProcessInfo.processInfo.physicalMemory<16*1_073_741_824 ? 4500:9000)
                guard ownsLibraryOperation(scope),librarySearchSession.accepts(token) else {return}
                guard !sources.isEmpty else {libraryAnswer=AILibraryAnswer(schemaVersion:1,status:"insufficient_evidence",paragraphs:[]);return}
                let answer=try await host.answerLibrary(question:question,sources:sources,model:model,onPhase:{[weak self] phase in
                    guard let self,self.ownsLibraryOperation(scope),self.librarySearchSession.accepts(token) else {return};if self.libraryQuestionPhase != phase {self.libraryQuestionPhase=phase}
                },onDraft:{[weak self] text in
                    guard let self,self.ownsLibraryOperation(scope),self.librarySearchSession.accepts(token) else {return};if self.libraryAnswerDraft != text {self.libraryAnswerDraft=text}
                })
                guard ownsLibraryOperation(scope),librarySearchSession.accepts(token) else {return}
                if libraryCorpusVersion != version {await libraryIndexTask?.value}
                guard ownsLibraryOperation(scope),librarySearchSession.accepts(token) else {return}
                let revisions=try await corpus.index.revisions()
                guard ownsLibraryOperation(scope),librarySearchSession.accepts(token) else {return}
                let active=Set(library.items.map{Self.libraryKey($0.identity)})
                let cited=Set(answer.paragraphs.flatMap(\.sourceIDs))
                let selected=sources.filter{cited.contains($0.id)}
                guard selected.allSatisfy({active.contains($0.recordingKey) && revisions[$0.recordingKey]==$0.revision}) else {throw AIProcessingError.invalidRequest}
                libraryAnswer=answer;libraryAnswerSources=selected;libraryAnswerDraft="";libraryQuestionPhase=""
            } catch is CancellationError {} catch {if ownsLibraryOperation(scope),librarySearchSession.accepts(token) {searchError=error.localizedDescription;libraryAnswerDraft="";libraryQuestionPhase=""}}
        }
    }
    func openLibrarySource(_ source:AILibrarySource, resultReader: ((UUID) async throws -> AIProcessingResult?)? = nil) {
        guard let library,let item=items.first(where:{Self.libraryKey($0.identity)==source.recordingKey}),let host=localAI else {searchError=VL.text("Запись-источник недоступна.");return}
        // Read precisely the immutable result named by the answer. No history polling or audio hashing.
        librarySourceTask?.cancel()
        let scope = NativeLibraryOperationScope(library: library, host: host, generation: libraryGeneration)
        let token = UUID(); librarySourceGeneration = token
        librarySourceTask = Task {
            defer { if librarySourceGeneration == token { librarySourceTask = nil } }
            do {
                let result:AIProcessingResult?
                if let id=source.requestID {
                    if let resultReader { result = try await resultReader(id) }
                    else { result=try await Task.detached {try LocalAIFileStore(root:host.root).result(id)}.value }
                    guard ownsLibraryOperation(scope), librarySourceGeneration == token else { return }
                    guard let result,source.segmentIDs.allSatisfy({id in result.segments.contains{$0.id==id}}) else {throw AIProcessingError.invalidTranscript}
                } else {result=nil}
                guard ownsLibraryOperation(scope), librarySourceGeneration == token else { return }
                guard items.contains(where:{$0.identity==item.identity}) else {throw NativeLibraryError.invalidRecording}
                librarySourceNavigation=true
                destination = .library;select(item.identity)
                if let result {analyses=[result];analysisID=result.request.id;loadConversation()}
                openDetailSignal=UUID()
                if let start=source.start {seek(start);focusedSegment=source.segmentIDs.first;playbackNavigationID=UUID()}
            } catch {
                if ownsLibraryOperation(scope), librarySourceGeneration == token { searchError=VL.text("Источник ответа недоступен. Обновите вопрос.") }
            }
        }
    }
}

@MainActor extension NativeMacModel {
    static func verifyLibraryEngine(resources:URL) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-library-engine-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:root)}
        let host=try LocalAIHost(root:root,resources:resources)
        await host.refreshModels()
        let source=AILibrarySource(id:"S1",recordingKey:"synthetic",requestID:nil,transcriptID:nil,revision:"test",title:VL.text("Оплата поставки"),date:Date(),text:VL.text("Договорились отправить восемьдесят тысяч рублей на расчётный счёт в пятницу."),segmentIDs:[1],start:3,end:9)
        for model in [AISummaryModelID.qwen4b,.qwen9b] {
            host.selectSummaryModel(model)
            for i in 0..<2 {
                let start=Date()
                let answer=try await host.answerLibrary(question:VL.text("Когда и сколько денег решили перевести?"),sources:[source],model:model,onPhase:{_ in},onDraft:{_ in})
                precondition(answer.status=="answered" && answer.paragraphs.allSatisfy{$0.sourceIDs==["S1"]})
                let text=answer.paragraphs.map(\.text).joined(separator:" ")
                precondition(text.contains("пятниц") && !text.contains("октября"),text)
                print("PASS host",model.rawValue,i,Date().timeIntervalSince(start),text);fflush(stdout)
            }
        }
        let cancelled=Task {try await host.answerLibrary(question:VL.text("Объясни подробно решение"),sources:[source],model:.qwen9b,onPhase:{_ in},onDraft:{_ in})}
        try await Task.sleep(nanoseconds:100_000_000);cancelled.cancel()
        do {_=try await cancelled.value;throw AIProcessingError.invalidRequest} catch is CancellationError {} catch AIProcessingError.interrupted {}
        precondition(host.activeRequest==nil && host.libraryWaitingCount==0)
        let lease=LocalAIResourceManager();let acquired=try lease.acquire();precondition(acquired);lease.release()
        host.stop();print("PASS cancellation releases worker and cross-process lease; no ASR request")
        let requests=try LocalAIFileStore(root:root).requests();precondition(requests.isEmpty)
    }
}
