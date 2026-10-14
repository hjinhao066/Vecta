import SwiftUI
import CryptoKit
struct NativeSearchHit:Identifiable {
    var id=UUID()
    let recording:NativeRecordingIdentity
    let request:UUID?
    let title:String
    let date:Date
    let text:String
    let speaker:String?
    let segment:Int?
    let start:Double?
    let end:Double?
    var kind=VL.text("Расшифровка")
}
@MainActor extension NativeMacModel {
    func searchLibrary() async {
        let query=search.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty,let library,let host=localAI else {globalSearchHits=[];return}
        let scope = NativeLibraryOperationScope(library: library, host: host, generation: libraryGeneration)
        do {try await Task.sleep(nanoseconds:250_000_000)} catch {return}
        guard ownsLibraryOperation(scope),search.trimmingCharacters(in:.whitespacesAndNewlines)==query else{return}
        searchingLibrary=true;searchError=nil
        defer {if ownsLibraryOperation(scope, checkCancellation: false),search.trimmingCharacters(in:.whitespacesAndNewlines)==query {searchingLibrary=false}}
        var hits=[NativeSearchHit]()
        for item in library.items {
            guard ownsLibraryOperation(scope) else{return}
            let values=item.audioURL != nil ? (try? await library.localHistory(for:item.identity)) ?? []:[]
            guard ownsLibraryOperation(scope),search.trimmingCharacters(in:.whitespacesAndNewlines)==query else{return}
            var seen=Set<String>()
            for result in values {
                let key=SHA256.hash(data:Data((result.request.audioSHA256+(result.request.transcriptRequestID ?? result.request.id).uuidString).utf8)).map{String(format:"%02x",$0)}.joined()
                let speakers=(try? AIConversationStore(root:host.root).recording(key,segments:result.segments)) ?? .initial(result.segments)
                for segment in result.segments where AILocalTextSearch.matches(segment.text,query:query) {
                    guard seen.insert("\(segment.start):\(segment.text)").inserted else {continue}
                    hits.append(NativeSearchHit(recording:item.identity,request:result.request.id,title:item.title,date:item.createdAt,text:segment.text,speaker:speakers.name(speakers.speakerID(segment)),segment:segment.id,start:segment.start,end:segment.end))
                }
                if result.summary?.blocks?.isEmpty != false,let summary=result.summary?.summary,AILocalTextSearch.matches(summary,query:query),seen.insert("legacy:"+summary).inserted {
                    hits.append(NativeSearchHit(recording:item.identity,request:result.request.id,title:item.title,date:item.createdAt,text:summary,speaker:nil,segment:nil,start:nil,end:nil,kind:VL.text("Саммари")))
                }
                for block in result.summary?.blocks ?? [] where AILocalTextSearch.matches(speakers.render(block.tokens),query:query) {
                    let text=speakers.render(block.tokens)
                    guard seen.insert("summary:"+text).inserted else {continue}
                    let source=result.segments.first{block.sourceSegments.contains($0.id)}
                    hits.append(NativeSearchHit(recording:item.identity,request:result.request.id,title:item.title,date:item.createdAt,text:text,speaker:nil,segment:source?.id,start:source?.start,end:source?.end,kind:VL.text("Саммари")))
                }
            }
            if AILocalTextSearch.matches(item.title,query:query) {
                hits.append(NativeSearchHit(recording:item.identity,request:nil,title:item.title,date:item.createdAt,text:item.title,speaker:nil,segment:nil,start:nil,end:nil,kind:VL.text("Название")))
            }
            if let text=item.local?.transcript,values.isEmpty,AILocalTextSearch.matches(text,query:query) {
                hits.append(NativeSearchHit(recording:item.identity,request:nil,title:item.title,date:item.createdAt,text:text,speaker:nil,segment:nil,start:nil,end:nil))
            }
            if hits.count>=100 {break}
        }
        if ownsLibraryOperation(scope),search.trimmingCharacters(in:.whitespacesAndNewlines)==query {globalSearchHits=Array(hits.filter { hit in library.items.contains { $0.identity == hit.recording } }.prefix(100))}
    }
    func openSource(_ hit:NativeSearchHit) {
        guard let library, let host = localAI else { return }
        let scope = NativeLibraryOperationScope(library: library, host: host, generation: libraryGeneration)
        destination = .library;select(hit.recording);openDetailSignal=UUID()
        Task {
            // Existing select reloads history asynchronously; await that operation.
            for _ in 0..<80 {
                guard ownsLibraryOperation(scope),selected==hit.recording else{return}
                if !loadingHistory {await reloadAnalysis()}
                guard ownsLibraryOperation(scope),selected==hit.recording else{return}
                if !loadingHistory,!analyses.isEmpty {break}
                try? await Task.sleep(nanoseconds:50_000_000)
            }
            guard ownsLibraryOperation(scope),selected==hit.recording else{return}
            if let id=hit.request,analyses.contains(where:{$0.request.id==id}) {analysisID=id;loadConversation()}
            if let start=hit.start,let end=hit.end {playExcerpt(start:start,end:end,segment:hit.segment)}
        }
    }
    func beginImportLibraryTasks() {
        workspaceImportTask?.cancel()
        workspaceImportTask = Task { await importLibraryTasks() }
    }
    func importLibraryTasks(historyReader: ((NativeRecordingIdentity) async throws -> [AIProcessingResult])? = nil) async {
        loadWorkspace()
        guard !Task.isCancelled,let library,let host=localAI else{return}
        let scope = NativeLibraryOperationScope(library: library, host: host, generation: libraryGeneration)
        let token = UUID(); workspaceImportGeneration = token
        defer { if workspaceImportGeneration == token { workspaceImportTask = nil } }
        var value=workspace
        for item in library.items where item.audioURL != nil {
            do {
                let history: [AIProcessingResult]
                if let historyReader { history = try await historyReader(item.identity) }
                else { history = try await library.localHistory(for:item.identity) }
                guard ownsLibraryOperation(scope), workspaceImportGeneration == token else { return }
                for result in history where result.stage == .completed {
                    guard let summary=result.summary else {continue}
                    let key=SHA256.hash(data:Data((result.request.audioSHA256+(result.request.transcriptRequestID ?? result.request.id).uuidString).utf8)).map{String(format:"%02x",$0)}.joined()
                    let speakers=try AIConversationStore(root:host.root).recording(key,segments:result.segments)
                    value.importTasks(summary,recordingID:result.request.recordingID,requestID:result.request.id,conversationKey:key,speakers:speakers)
                }
            } catch {
                guard ownsLibraryOperation(scope), workspaceImportGeneration == token else { return }
                analysisMessage=VL.text("Не все задачи прочитаны: ")+error.localizedDescription
            }
        }
        guard ownsLibraryOperation(scope), workspaceImportGeneration == token else { return }
        do {try AIWorkspaceStore(root:host.root).save(value);workspace=value} catch {analysisMessage=error.localizedDescription}
    }
    func taskOwner(_ task:AILibraryTask)->String {
        guard let id=task.ownerSpeakerID,let host=localAI else{return task.assignee ?? VL.text("Не указан")}
        let value=try? AIConversationStore(root:host.root).recording(task.conversationKey,segments:[])
        return value?.name(id) ?? task.assignee ?? VL.text("Не указан")
    }
    func taskSourceLabel(_ task:AILibraryTask,id:Int)->String {
        guard let host=localAI,let result=try? LocalAIFileStore(root:host.root).result(task.requestID),let segment=result.segments.first(where:{$0.id==id}) else { return VL.text("Источник · сегмент \(id)") }
        let time=String(format:"[%d:%02d]",Int(segment.start)/60,Int(segment.start)%60)
        let title=library?.items.first(where:{$0.audioURL?.deletingPathExtension().lastPathComponent==task.recordingID})?.title ?? VL.text("Запись")
        return "\(title) · \(time)"
    }
    func playTaskSource(_ task:AILibraryTask,id:Int) {
        guard let item=library?.items.first(where:{$0.audioURL?.deletingPathExtension().lastPathComponent==task.recordingID}),let host=localAI,let result=try? LocalAIFileStore(root:host.root).result(task.requestID),let segment=result.segments.first(where:{$0.id==id}) else {analysisMessage=VL.text("Источник задачи недоступен.");return}
        openSource(NativeSearchHit(recording:item.identity,request:task.requestID,title:item.title,date:item.createdAt,text:segment.text,speaker:nil,segment:id,start:segment.start,end:segment.end))
    }
}
struct NativeLibrarySearchResults:View {
    @ObservedObject var model:NativeMacModel
    @State private var deleting: NativeRecordingIdentity?
    var body:some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:16) {
                if model.searchingLibrary {HStack {ProgressView().controlSize(.small);Text(VL.text("Ищем в сохранённых расшифровках и саммари…"))}}
                if model.globalSearchHits.isEmpty && !model.searchingLibrary {Text(VL.text("Ничего не найдено")).foregroundColor(Ink.secondary)}
                ForEach(model.globalSearchHits.reduce(into:[NativeRecordingIdentity]()) {result,hit in if !result.contains(hit.recording) {result.append(hit.recording)}},id:\.self) {recording in
                VStack(alignment:.leading,spacing:8) {
                ForEach(model.globalSearchHits.filter {$0.recording==recording}) {hit in Button {model.openSource(hit)} label:{
                    VStack(alignment:.leading,spacing:8) {
                        Text(highlight(hit.title)).font(.system(size:16,weight:.medium))
                        Text(hit.kind).font(.system(size:11,weight:.medium)).foregroundColor(Ink.secondary)
                        Text(highlight(hit.text)).font(.system(size:13)).lineLimit(3).foregroundColor(Ink.secondary)
                        HStack {Text(hit.date.vectaFormatted(date:.abbreviated,time:.shortened));if let speaker=hit.speaker {Text(speaker)};if let start=hit.start {Text(String(format:"[%d:%02d]",Int(start)/60,Int(start)%60))} else {Text(VL.text("Без точного таймкода"))}}.font(.system(size:11)).foregroundColor(Ink.muted)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(16).background(Ink.surface).cornerRadius(8)
                }.buttonStyle(.plain)}
                }.padding(8).overlay(RoundedRectangle(cornerRadius:10).stroke(Ink.border))
                .contextMenu { Button(VL.text("Удалить запись"), role: .destructive) { deleting = recording }.disabled(!model.canDeleteRecording(recording)) }
                }
                if model.globalSearchHits.count>=100 {Text(VL.text("Показаны первые 100 совпадений. Уточните запрос.")).font(.system(size:11)).foregroundColor(Ink.secondary)}
            }
        }
        .confirmationDialog(VL.text("Удалить запись?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(VL.text("Удалить запись"), role: .destructive) { if let id = deleting { model.deleteRecording(id) }; deleting = nil }
            Button(VL.text("Отмена"), role: .cancel) { deleting = nil }
        } message: { Text(VL.text("Запись будет перемещена в корзину Vecta вместе с расшифровками и саммари. Её можно восстановить. Запись на Plaud сохранится и не вернётся при синхронизации.")) }
    }
    private func highlight(_ text:String)->AttributedString {
        var value=AttributedString(text)
        for term in model.search.split(whereSeparator:{$0.isWhitespace}).map(String.init) where !term.isEmpty {
            var range=text.startIndex..<text.endIndex
            while let found=text.range(of:term,options:[.caseInsensitive,.diacriticInsensitive],range:range) {
                if let attributed=Range(found,in:value) {value[attributed].backgroundColor=Ink.selection;value[attributed].foregroundColor=Ink.text}
                range=found.upperBound..<text.endIndex
            }
        }
        return value
    }

}
struct NativeTaskScreen:View {
    @ObservedObject var model:NativeMacModel
    @State private var query=""
    @State private var filter="all"
    @State private var editing:AILibraryTask?
    @State private var deleting:AILibraryTask?
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {Text(VL.text("Задачи")).font(.system(size:28,weight:.semibold));Spacer();Button(VL.text("Новая задача")) {editing=AILibraryTask(id:UUID().uuidString,title:"",details:"",status:"open",recordingID:"",requestID:UUID(),conversationKey:"",sourceSegments:[],createdAt:Date(),manuallyEdited:true)}.buttonStyle(QuietButton(primary:true));Menu {Button(VL.text("Обновить из записей")) {model.beginImportLibraryTasks()}} label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).fixedSize().help(VL.text("Импорт задач из саммари"))}
            VStack(alignment:.leading,spacing:8) {TextField(VL.text("Поиск задач"),text:$query).textFieldStyle(.roundedBorder);VectaSegmentedControl(label:VL.text("Статус задач"),choices:[VectaChoice(id:"all",title:VL.text("Все")),VectaChoice(id:"open",title:VL.text("Открытые")),VectaChoice(id:"done",title:VL.text("Выполненные")),VectaChoice(id:"cancelled",title:VL.text("Отменённые"))],selection:$filter)}
            ScrollView {
                LazyVStack(alignment:.leading,spacing:14) {
                    ForEach((model.workspace.tasks ?? []).filter {(filter=="all" || $0.status==filter) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.details.localizedCaseInsensitiveContains(query))}) {task in
                        VStack(alignment:.leading,spacing:10) {
                            HStack {Text(task.title).font(.system(size:15,weight:.medium));Spacer();Button(VL.text("Изменить")) {editing=task}.buttonStyle(QuietButton());Button {deleting=task} label:{Image(systemName:"trash")}.buttonStyle(.plain)}
                            if !task.details.isEmpty {Text(task.details).foregroundColor(Ink.secondary)}
                            HStack {Text(VL.text("Ответственный: ")+model.taskOwner(task));Text(VL.text("Срок: ")+(task.deadline ?? VL.text("Не указан")));Text(task.status=="done" ? VL.text("Выполнена"):task.status=="cancelled" ? VL.text("Отменена"):VL.text("Открыта"))}.font(.system(size:11)).foregroundColor(Ink.secondary)
                            if !task.sourceSegments.isEmpty { ScrollView(.horizontal,showsIndicators:false) { HStack(spacing:6) { ForEach(task.sourceSegments,id:\.self) { id in Button(model.taskSourceLabel(task,id:id)) { model.playTaskSource(task,id:id) }.buttonStyle(.plain).foregroundColor(Ink.secondary).help(VL.text("Открыть источник и воспроизвести")) } } } }
                        }.padding(16).background(Ink.surface).cornerRadius(9)
                    }
                    if (model.workspace.tasks ?? []).isEmpty {Text(VL.text("Задач пока нет. Нажмите «Новая задача» или импортируйте задачи из сохранённых саммари через меню ⋯.")).foregroundColor(Ink.secondary)}
                }
            }
        }.padding(28).onAppear {model.beginImportLibraryTasks()}.sheet(item:$editing) {task in NativeTaskEditor(model:model,task:task)}
            .confirmationDialog(VL.text("Удалить задачу?"),isPresented:Binding(get:{deleting != nil},set:{if !$0 {deleting=nil}})) {Button(VL.text("Удалить"),role:.destructive) {if let id=deleting?.id {model.editWorkspace {$0.deleteTask(id)}};deleting=nil};Button(VL.text("Отмена"),role:.cancel) {}} message:{Text(VL.text("Исходная запись сохранится. Повторный импорт не восстановит удалённую задачу."))}
    }
}
private struct NativeTaskEditor:View {
    @ObservedObject var model:NativeMacModel
    let task:AILibraryTask
    @Environment(\.dismiss) private var dismiss
    @State private var draft:AILibraryTask?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(VL.text("Задача")).font(.system(size:22,weight:.semibold))
            if draft != nil {
                TextField(VL.text("Название"),text:Binding(get:{draft!.title},set:{draft!.title=$0})).textFieldStyle(.roundedBorder)
                TextField(VL.text("Описание"),text:Binding(get:{draft!.details},set:{draft!.details=$0}),axis:.vertical).lineLimit(2...6)
                TextField(VL.text("Ответственный"),text:Binding(get:{draft!.assignee ?? ""},set:{draft!.assignee=$0.isEmpty ? nil:$0;draft!.ownerSpeakerID=nil}))
                TextField(VL.text("Срок (как указан в записи)"),text:Binding(get:{draft!.deadline ?? ""},set:{draft!.deadline=$0.isEmpty ? nil:$0}))
                VectaSegmentedControl(label:VL.text("Статус задачи"),choices:[VectaChoice(id:"open",title:VL.text("Открыта")),VectaChoice(id:"done",title:VL.text("Выполнена")),VectaChoice(id:"cancelled",title:VL.text("Отменена"))],selection:Binding(get:{draft!.status},set:{draft!.status=$0}))
            }
            if let error=VectaUX.taskValidation(draft?.title ?? "") {Text(error).font(.system(size:12)).foregroundColor(Ink.secondary)}
            HStack {Spacer();Button(VL.text("Отмена")) {dismiss()}.keyboardShortcut(.cancelAction);Button(VL.text("Сохранить")) {guard var value=draft,VectaUX.taskValidation(value.title)==nil else{return};value.title=value.title.trimmingCharacters(in:.whitespacesAndNewlines);value.manuallyEdited=true;if model.editWorkspace({workspace in if let index=workspace.tasks?.firstIndex(where:{$0.id==value.id}) {workspace.tasks?[index]=value} else {workspace.tasks=(workspace.tasks ?? [])+[value]}}) {dismiss()}}.disabled(VectaUX.taskValidation(draft?.title ?? "") != nil)}
        }.padding(24).frame(width:520).onAppear {draft=task}
    }
}
