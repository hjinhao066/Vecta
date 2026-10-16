import AppKit
import SwiftUI
import CoreText
import UniformTypeIdentifiers

@MainActor extension NativeMacModel {
    func loadWorkspace() {
        guard let root = (processingRoot ?? localAI?.root)?.standardizedFileURL else { workspaceStateRoot=nil;return }
        let revision=AIFileRevision.stamp(AIWorkspaceStore(root:root).url)
        if workspaceStateRoot==root,workspaceFileRevision==revision {return}
        workspaceStateRoot = nil
        do {
            let value = try AIWorkspaceStore(root: root).load()
            workspace = value
            workspaceStateRoot = root
            workspaceFileRevision=revision
        } catch { analysisMessage = error.localizedDescription }
    }
    @discardableResult func editWorkspace(_ edit:(inout AIWorkspace)->Void)->Bool {
        guard let root = (processingRoot ?? localAI?.root)?.standardizedFileURL,
              workspaceStateRoot?.standardizedFileURL == root else { return false }
        do {
            var value = workspace
            edit(&value)
            guard (processingRoot ?? localAI?.root)?.standardizedFileURL == root,
                  workspaceStateRoot?.standardizedFileURL == root else { return false }
            try AIWorkspaceStore(root: root).save(value)
            workspace = value
            workspaceFileRevision=AIFileRevision.stamp(AIWorkspaceStore(root:root).url)
            return true
        } catch { analysisMessage = error.localizedDescription; return false }
    }
    func askAssistant(_ question:String) {
        let question=question.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !chatBusy,let host=localAI,let key=conversationKey,let result=analysis,!result.segments.isEmpty,!question.isEmpty,question.count<=2000 else {return}
        chat.messages.append(AIChatMessage(role:"user",text:question));chatError=nil
        do {try AIChatStore(root:host.root).save(chat,key:key)} catch {chatError=error.localizedDescription;return}
        let preceding=Array(chat.messages.dropLast()),segments=result.segments
        let snapshot=chat
        chatBusy=true;chatDraft="";chatDraftKey=key
        chatTask=Task {
            defer {chatBusy=false;chatTask=nil;if chatDraftKey==key {chatDraft="";chatDraftKey=nil}}
            var saved=snapshot
            do {
                let answer=try await host.answer(question:question,segments:segments,history:preceding) {text in
                    if self.conversationKey==key && self.chatDraftKey==key {self.chatDraft=text}
                }
                saved.messages.append(AIChatMessage(role:"assistant",text:answer.summary,blocks:answer.blocks ?? []))
                try AIChatStore(root:host.root).save(saved,key:key)
                if conversationKey==key {chat=saved}
            } catch {
                let message=Task.isCancelled ? VL.text("Генерация остановлена. История сохранена."):error.localizedDescription
                let partial=chatDraftKey==key ? chatDraft:""
                saved.messages.append(AIChatMessage(role:"assistant",text:AITextDocument(partial).markdown,error:message))
                try? AIChatStore(root:host.root).save(saved,key:key)
                if conversationKey==key {chat=saved;chatError=message}
            }
        }
    }
    func clearChat() {
        guard !chatBusy,let host=localAI,let key=conversationKey else{return}
        do {try AIChatStore(root:host.root).save(AIChatHistory(),key:key);chat=AIChatHistory();chatError=nil}
        catch {chatError=error.localizedDescription}
    }
    func retryVisualReport() {
        guard !visualRetryBusy,let id=analysis?.request.id,let host=localAI else{return}
        visualRetryBusy=true
        visualRetryTask=Task {
            defer {visualRetryBusy=false;visualRetryTask=nil}
            do {try await host.retryVisual(id)} catch {analysisMessage=error.localizedDescription}
            await reloadAnalysis()
        }
    }
    typealias ExportDocument = NativeExportKind

    /// An explicit saved result remains eligible even when live analysis changes.
    func canExportDocument(_ kind: ExportDocument, result: AIProcessingResult? = nil) -> Bool {
        captureExportContext(result: result)?.projection(kind) != nil
    }
    func canExportDocument(_ kind: ExportDocument, context: NativeExportContext) -> Bool {
        context.projection(kind) != nil
    }
    func captureExportContext(result savedResult: AIProcessingResult? = nil) -> NativeExportContext? {
        guard let result = savedResult ?? analysis else { return nil }
        func matches(_ item: NativeLibraryItem) -> Bool {
            if item.audioURL?.deletingPathExtension().lastPathComponent == result.request.recordingID { return true }
            // Missing audio does not revoke access to an already saved transcript.
            return item.local.map { VectaLocalAudioExporter.filenames(for: $0).contains(result.request.audioFilename) } ?? false
        }
        // Do not borrow the newly selected recording's title/date/duration for a
        // saved result, or export stale analysis while a new selection loads.
        if savedResult == nil, let selection, !matches(selection) { return nil }
        let item = selection.flatMap { matches($0) ? $0 : nil }
            ?? library?.items.first(where: matches)
        let current = rawAnalysis?.request
        let sameConversation = current?.recordingID == result.request.recordingID
            && current?.audioSHA256 == result.request.audioSHA256
            && current.map { $0.transcriptRequestID ?? $0.id } == (result.request.transcriptRequestID ?? result.request.id)
            && (selection.map(matches) ?? true)
        let speakers = sameConversation ? resolvedConversation : AIRecordingSpeakers.initial(result.segments)
        return NativeExportContext(result: result, speakers: speakers,
            title: item?.title ?? result.recordingTopicTitle ?? VL.text("Запись"), date: item?.createdAt,
            duration: item?.duration ?? result.duration, selectionSerialNumber: item?.identity.serialNumber,
            selectionSessionID: item?.identity.sessionID)
    }
    func exportDocument(kind: ExportDocument, pdf: Bool, result savedResult: AIProcessingResult? = nil) {
        guard let context = captureExportContext(result: savedResult) else {
            analysisMessage = VL.text("Для экспорта сначала откройте сохранённую расшифровку или саммари."); return
        }
        exportDocument(kind: kind, pdf: pdf, context: context)
    }
    func exportDocument(kind: ExportDocument, pdf: Bool, context: NativeExportContext) {
        guard let projection = context.projection(kind) else {
            analysisMessage = VL.text("Нет сохранённого результата для выбранного экспорта."); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [pdf ? .pdf : .plainText]
        panel.nameFieldStringValue = AIExportText.filename(title: context.title, pdf: pdf)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Only captured values may be read after the modal panel's nested run loop.
        do {
            if pdf, let report = projection.visual {
                try NativeVisualPDF.write(report: report, title: context.title, date: context.date,
                    duration: context.duration, speakers: context.speakers, segments: projection.segments,
                    textSummary: projection.textSummary, fullTextDocument: projection.fullText,
                    transcript: projection.transcript, formatTitle: context.result.request.format.displayTitle, semantic: context.result.semanticSummary, to: url)
            } else if pdf {
                let body=projection.fullText.map {"# "+context.title+"\n\n"+$0.rendered(speakers:context.speakers,markdownHeadings:true)} ?? projection.titledBody
                try NativeTextPDF.write(body, to: url)
            }
            else { try AIExportText.plain(projection.titledBody).write(to: url, atomically: true, encoding: .utf8) }
        } catch { analysisMessage = error.localizedDescription }
    }
}

enum NativeTextPDF {
    /// CoreText pagination retains Cyrillic fonts and wraps arbitrarily long exports.
    static func write(_ text:String,to url:URL)throws {
        let attributed=NSMutableAttributedString(string:"")
        for part in AITextDocument(text).parts {
            let paragraph=NSMutableParagraphStyle()
            paragraph.lineSpacing=3;paragraph.paragraphSpacing=part.kind == .heading ? 8:10
            paragraph.paragraphSpacingBefore=part.kind == .heading ? 10:0
            if part.kind == .list || part.kind == .quote {paragraph.headIndent=14}
            attributed.append(NSAttributedString(string:AIExportText.plain(part.text)+"\n",attributes:[.font:part.kind == .code || part.kind == .table ? (NSFont(name:"Menlo-Regular",size:10) ?? NSFont.monospacedSystemFont(ofSize:10,weight:.regular)):(NSFont(name:part.kind == .heading ? "Arial-BoldMT":"ArialMT",size:part.kind == .heading ? 15:11.5) ?? NSFont.systemFont(ofSize:part.kind == .heading ? 15:11.5,weight:part.kind == .heading ? .bold:.regular)),.foregroundColor:NSColor.black,.paragraphStyle:paragraph]))
        }
        let setter=CTFramesetterCreateWithAttributedString(attributed)
        var box=CGRect(x:0,y:0,width:595,height:842)
        let data=NSMutableData()
        guard let consumer=CGDataConsumer(data:data as CFMutableData),let context=CGContext(consumer:consumer,mediaBox:&box,nil) else {throw AIProcessingError.invalidSummary}
        let path=CGPath(rect:CGRect(x:48,y:48,width:499,height:746),transform:nil)
        var offset=0
        while offset<attributed.length {
            let frame=CTFramesetterCreateFrame(setter,CFRange(location:offset,length:0),path,nil)
            let visible=CTFrameGetVisibleStringRange(frame)
            guard visible.length>0 else {throw AIProcessingError.invalidSummary}
            context.beginPDFPage(nil);context.textMatrix = .identity;CTFrameDraw(frame,context);context.endPDFPage()
            offset+=visible.length
        }
        context.closePDF();try (data as Data).write(to:url,options:.atomic)
    }
}

struct NativeAssistantView:View {
    @ObservedObject var model:NativeMacModel
    @State private var question=""
    @State private var clearing=false
    @State private var followAnswer=true
    @FocusState private var inputFocused:Bool
    private let examples=[VL.text("О чём говорили?"),VL.text("Какие решения приняли?"),VL.text("Кто за что отвечает?")]
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {Label(VL.text("Локальный ассистент · ")+(model.localAI?.summaryModel.selectionTitle ?? VL.text("Быстрая · 4B")),systemImage:"sparkles").font(.system(size:12)).foregroundColor(Ink.secondary);Spacer();Menu {Text(VL.text("Ответы строятся по сохранённой расшифровке. Это автоматическое изложение, а не обещания Vecta. Проверяйте источники: поиск может пропустить информацию."))} label:{Image(systemName:"info.circle")}.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(VL.text("Об ассистенте"));if !model.chat.messages.isEmpty {Button(VL.text("Очистить переписку")) {clearing=true}.buttonStyle(QuietButton()).disabled(model.chatBusy)} }
            if model.analysis?.segments.isEmpty != false {
                Text(VL.text("Сначала распознайте запись. Ассистент отвечает по сохранённой расшифровке.")).foregroundColor(Ink.secondary)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                LazyVStack(alignment:.leading,spacing:14) {
                if model.chat.messages.isEmpty {
                    Text(VL.text("Спросите Vecta о записи")).font(.system(size:18,weight:.semibold))
                    Text(VL.text("Ответы строятся по сохранённой расшифровке этой записи. Всё выполняется на Mac.")).foregroundColor(Ink.secondary).lineSpacing(4)
                    VStack(alignment:.leading,spacing:10) {ForEach(examples,id:\.self) {example in Button(example) {question=example;inputFocused=true}.buttonStyle(QuietButton())} }
                } else {
                    ForEach(model.chat.messages) {message in
                        VStack(alignment:.leading,spacing:10) {
                            Text(message.role=="user" ? VL.text("Вы"):VL.text("Пересказ AI · не прямая цитата")).font(.system(size:11,weight:.semibold)).foregroundColor(Ink.secondary)
                            if message.blocks.isEmpty || message.blocks.allSatisfy({$0.sourceSegments.isEmpty}) {NativeStreamingText(text:message.role == "user" ? message.text:model.resolvedConversation.resolveText(message.text))}
                            else {ForEach(message.blocks,id:\.id) {block in
                                Text(model.resolvedConversation.render(block.tokens)).textSelection(.enabled).lineSpacing(4)
                                HStack {ForEach(block.sourceSegments,id:\.self) {id in if let segment=model.analysis?.segments.first(where:{$0.id==id}) {
                                    Button((segment.speaker ?? VL.text("Источник"))+" · "+String(format:"[%d:%02d]",Int(segment.start)/60,Int(segment.start)%60)) {model.playExcerpt(start:segment.start,end:segment.end,segment:id)}.buttonStyle(.plain).foregroundColor(Ink.secondary).help((segment.speaker ?? VL.text("Неизвестный собеседник"))+": "+segment.text)
                                } } }
                                if !block.sourceSegments.isEmpty {
                                    VStack(alignment:.leading,spacing:6) {
                                        Text(VL.text("Слова участников · исходные реплики")).font(.system(size:11,weight:.semibold))
                                        ForEach(block.sourceSegments,id:\.self) {id in if let segment=model.analysis?.segments.first(where:{$0.id==id}) {
                                            VStack(alignment:.leading,spacing:4) {
                                                Text(segment.speaker ?? VL.text("Неизвестный собеседник")).font(.system(size:12,weight:.semibold))
                                                Text("«"+segment.text+"»").textSelection(.enabled)
                                            }.padding(.vertical,4)
                                        } }
                                    }.font(.system(size:12)).foregroundColor(Ink.secondary)
                                }
                            } }
                            if let error=message.error {Text(error).foregroundColor(Ink.error).font(.system(size:12))}
                        }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(message.role=="user" ? Ink.elevated:Ink.surface).cornerRadius(9)
                    }
                }
                if model.chatBusy {
                    VStack(alignment:.leading,spacing:10) {
                        HStack {ProgressView().controlSize(.small);Text(model.chatDraft.isEmpty ? VL.text("Ищем ответ в записи…"):VL.text("Vecta отвечает…"));Spacer();Button(VL.text("Остановить")) {model.chatTask?.cancel()}.buttonStyle(QuietButton())}
                        if model.chatDraftKey==model.conversationKey && !model.chatDraft.isEmpty {NativeStreamingText(text:model.resolvedConversation.resolveText(model.chatDraft))}
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Ink.surface).cornerRadius(9)
                }
                Color.clear.frame(height:1).id("chat-bottom")
                }.frame(maxWidth:.infinity,alignment:.leading)
                }
                .onChange(of:model.chatDraft) {_ in if followAnswer {DispatchQueue.main.async {proxy.scrollTo("chat-bottom",anchor:.bottom)}}}
                .onChange(of:model.chat.messages.count) {_ in DispatchQueue.main.async {proxy.scrollTo("chat-bottom",anchor:.bottom)}}
                .onAppear {proxy.scrollTo("chat-bottom",anchor:.bottom)}
                }
                if model.chatBusy {Toggle(VL.text("Следить за ответом"),isOn:$followAnswer).toggleStyle(.checkbox).font(.system(size:11)).foregroundColor(Ink.secondary)}
                HStack(alignment:.bottom) {
                    TextField(VL.text("Вопрос по записи"),text:$question,axis:.vertical).lineLimit(1...3).textFieldStyle(.plain).focused($inputFocused).onSubmit(send).padding(12).background(Ink.elevated).cornerRadius(8)
                    Button(VL.text("Отправить"),action:send).buttonStyle(QuietButton(primary:true)).disabled(model.chatBusy || question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || question.count>2000)
                }
                if let error=model.chatError {Text(error).font(.system(size:12)).foregroundColor(Ink.error)}
                if let validation=VectaUX.questionValidation(question) {Text(validation).font(.system(size:12)).foregroundColor(Ink.secondary)} else if question.count>1800 {Text(VL.text("\(question.count) / 2000 символов")).font(.system(size:11)).foregroundColor(Ink.secondary)}
            }
        }.confirmationDialog(VL.text("Очистить переписку этой записи?"),isPresented:$clearing) {Button(VL.text("Очистить"),role:.destructive) {model.clearChat()};Button(VL.text("Отмена"),role:.cancel) {} } message: {Text(VL.text("Аудио, расшифровка и саммари сохранятся."))}
    }
    private func send() {model.askAssistant(question);if model.chatBusy {question=""}}
}
