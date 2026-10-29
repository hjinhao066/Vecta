import AppKit
import SwiftUI

struct NativeRecordingDetail: View {
    @ObservedObject var model: NativeMacModel
    let back: () -> Void
    @State private var tab = 0
    @State private var preparedRevision:Int?
    @AppStorage("vecta.summaryFormat") private var formatID = "standard"
    @AppStorage("vecta.summaryRecipe") private var recipeID = ""
    @State private var showingGeneration = false
    @State private var confirmingRetranscription = false
    @State private var selectingUtterances=false
    @State private var selectedUtterances=Set<Int>()
    @State private var utteranceScope:NativeTranscriptSelectionScope<NativeRecordingIdentity>?
    @State private var showingInformation=false
    @State private var speakersExpanded=true
    @State private var editingSpeaker:NativeSpeakerSelection?
    @State private var showingExport=false
    @State private var wordSegment:AISpeechSegment?
    private struct PendingModelInstallation {
        let recording: NativeRecordingIdentity
        let recipe: NativeSummaryRecipe
        let reuseTranscript: Bool
        let model: AISummaryModelID
        let models: [LocalModelDefinition]
        var confirmationMessage: String {
            let titles = models.map { VL.string($0.title) }.joined(separator:", ")
            let totalBytes = models.reduce(Int64(0)) { $0 + $1.size }
            let downloads = VL.text("Будут скачаны: ") + titles + " · " + VL.bytes(totalBytes)
            return downloads + ". " + VL.text("После установки начнётся локальная обработка. Исходная запись и предыдущие результаты сохранятся.")
        }
    }
    @State private var pendingModelInstallation: PendingModelInstallation?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: back) { Label(VL.text("Все записи"), systemImage: "chevron.left") }.buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Ink.secondary)
            if let item = model.selection {
                HStack(alignment: .top) {
                    VStack(alignment:.leading,spacing:4) { Text(item.title).font(.system(size:20,weight:.semibold)).lineLimit(2); Text(timeRange(from:item.createdAt,duration:max(item.duration,model.duration))+" · "+clock(max(item.duration,model.duration))).font(.system(size:11)).foregroundColor(Ink.secondary) }.frame(maxWidth:.infinity,alignment:.leading)
                    Button { showingInformation=true } label: { Image(systemName:"info.circle") }.buttonStyle(QuietButton()).help(VL.text("Информация о записи")).accessibilityLabel(VL.text("Информация о записи"))
                    Button {showingExport=true} label:{Image(systemName:"square.and.arrow.up")}.buttonStyle(QuietButton()).help(VL.text("Экспорт…")).accessibilityLabel(VL.text("Экспорт записи"))
                }
                if item.audioURL != nil {
                    NativePlaybackControls(model:model,playback:model.playback)
                } else {
                    Button(VL.text("Скачать запись на Mac"), action: model.download).buttonStyle(QuietButton(primary: true)).disabled(model.busy)
                }
                HStack(spacing: 24) {
                    ForEach(Array([VL.text("Саммари"), VL.text("Расшифровка"), VL.text("Ассистент AI")].enumerated()), id: \.offset) { index, name in
                        Button { tab = index } label: {
                            VStack(spacing: 6) { Text(name).font(.system(size: 13, weight: .medium)).foregroundColor(tab == index ? Ink.text : Ink.muted)
                                Rectangle().fill(tab == index ? Ink.accent : Color.clear).frame(height: 2) }
                        }.buttonStyle(.plain).frame(width: index == 2 ? 102 : 92)
                    }
                    Spacer()
                }.overlay(alignment: .bottom) { Rectangle().fill(Ink.border).frame(height: 1) }
                if preparedRevision==model.presentationRevision,item.audioURL != nil && tab == 1 && model.analysisBusy { actions }
                ScrollViewReader { proxy in
                Group {
                if preparedRevision != model.presentationRevision {
                    HStack(spacing:10) {ProgressView().controlSize(.small);Text(VL.text("Открываем сохранённый результат…")).font(.system(size:12)).foregroundColor(Ink.secondary)}.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).padding(.top,12)
                } else if tab == 2 { NativeAssistantView(model:model) }
                else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if tab == 1 { transcript }
                        else { if item.audioURL != nil { actions }; summary }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 16)
                }
                }
                }
                .onChange(of:model.playbackNavigationID) { _ in if let value=model.focusedSegment { tab=1;DispatchQueue.main.async { withAnimation { proxy.scrollTo(value,anchor:.center) } } } }
                .onAppear {if model.librarySourceNavigation,let value=model.focusedSegment {tab=1;DispatchQueue.main.async {proxy.scrollTo(value,anchor:.center)}}}
                }
            }
        }.padding(16).frame(maxWidth:1120,maxHeight:.infinity,alignment:.topLeading).frame(maxWidth:.infinity)
            .background(NativeRecordingKeyboard(model: model).frame(width: 0, height: 0))
            .sheet(item:$editingSpeaker) {person in NativeSpeakerSheet(model:model,speakerID:person.id,rejectedProfileID:person.rejectedProfileID)}
            .sheet(isPresented:$showingExport) {NativeExportSheet(model:model)}
            .sheet(isPresented:$showingGeneration) {
                NativeSummaryCreationSheet(model:model,recipes:recipes,initialID:selectedRecipe?.id ?? NativeSummarySelection.defaultID) {recipe,selectedModel in
                    recipeID=recipe.id
                    if recipe.template == nil {formatID=recipe.format.id}
                    model.localAI?.selectSummaryModel(selectedModel)
                    requestAnalysis(recipe:recipe,reuseTranscript:true)
                }
            }
            .confirmationDialog(VL.text("Скачать модели и обработать запись?"), isPresented: Binding(get: { pendingModelInstallation != nil }, set: { if !$0 { pendingModelInstallation = nil } })) {
                Button(VL.text("Скачать и обработать")) {
                    guard let pending = pendingModelInstallation, model.selected == pending.recording else { pendingModelInstallation = nil; return }
                    pendingModelInstallation = nil
                    model.localAI?.selectSummaryModel(pending.model)
                    model.analyze(format:pending.recipe.format,reuseTranscript:pending.reuseTranscript,template:pending.recipe.template,installMissingModels:true)
                }
                Button(VL.text("Отмена"),role:.cancel) { pendingModelInstallation = nil }
            } message: {
                if let pending = pendingModelInstallation {
                    Text(pending.confirmationMessage)
                }
            }
            .confirmationDialog(VL.text("Перерасшифровать запись?"),isPresented:$confirmingRetranscription) {
                Button(VL.text("Перерасшифровать")) {startSummary(reuseTranscript:false)}
                Button(VL.text("Отмена"),role:.cancel) {}
            } message: {
                Text(VL.text("WhisperKit и SpeakerKit заново обработают аудио, затем будет создано новое саммари. Это займёт время. Предыдущие версии и исходная запись сохранятся."))
            }
            .onChange(of:model.exportRequested) { _ in consumeExportRequest() }
            .onChange(of:transcriptScope) { _ in resetUtteranceSelection() }
            .sheet(item:$wordSegment) {segment in
                VStack(alignment:.leading,spacing:16) {Text(VL.text("Слова · ")+clock(segment.start)).font(.headline);ScrollView {LazyVStack(alignment:.leading,spacing:8) {ForEach(model.words(for:segment)) {word in Button(clock(word.start)+" · "+word.text) {model.playExcerpt(start:word.start,end:word.end,segment:segment.id)}.buttonStyle(QuietButton()).accessibilityLabel(VL.text("Воспроизвести слово ")+word.text+VL.text(" в ")+clock(word.start))}}};Button(VL.text("Закрыть")) {wordSegment=nil}.keyboardShortcut(.cancelAction)}.padding(24).frame(width:420,height:400)
            }
            .task(id: model.selected) { await model.reloadAnalysis() }
            .task(id:model.presentationRevision) {
                let revision=model.presentationRevision
                await model.preparePresentation()
                guard !Task.isCancelled,model.presentationRevision==revision else{return}
                preparedRevision=revision
            }
            .onAppear {
                #if VECTA_DEVELOPMENT
                if CommandLine.arguments.contains("--verify-highlight-ui") { tab = 1 }
                #endif
                consumeExportRequest();model.loadWorkspace();if model.librarySourceNavigation {tab=1;model.librarySourceNavigation=false}}
            .sheet(isPresented:$showingInformation) {
                VStack(alignment:.leading,spacing:16) {
                    if let item=model.selection { ScrollView { information(item) } }
                    HStack { Spacer();Button(VL.text("Закрыть")) { showingInformation=false }.keyboardShortcut(.cancelAction).buttonStyle(QuietButton()) }
                }.padding(24).frame(minWidth:480,minHeight:320)
            }
    }
    private var transcriptScope:NativeTranscriptSelectionScope<NativeRecordingIdentity>? {
        guard let recordingID=model.selected,let key=model.conversationKey else {return nil}
        return NativeTranscriptSelectionScope(recordingID:recordingID,conversationKey:key)
    }
    private func resetUtteranceSelection() {
        selectedUtterances=[];selectingUtterances=false;utteranceScope=nil
    }
    private func submitUtteranceSelection() {
        // Validate synchronously as well as onChange: a queued click may precede
        // SwiftUI's invalidation callback after a version/recording switch.
        guard NativeUIStatePolicy.canSubmit(captured:utteranceScope,current:transcriptScope,selected:selectedUtterances,available:Set(model.rawAnalysis?.segments.map(\.id) ?? [])) else {
            resetUtteranceSelection();return
        }
        model.splitSpeaker(selectedUtterances,name:VL.text("Новый собеседник"))
        resetUtteranceSelection()
    }
    private func consumeExportRequest() {
        var requested=model.exportRequested
        guard NativeUIStatePolicy.consumeExportRequest(&requested) else {return}
        model.exportRequested=requested
        showingExport=true
    }
    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result=model.analysis, result.summary == nil || model.analysisBusy {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:3) {
                        Text(result.summary == nil ? VL.text("История обработки"):VL.text("Сохранённая версия · ")+result.request.format.displayTitle+" · "+result.request.selectedSummaryModel.title).font(.system(size:12,weight:.medium))
                        Text(result.request.createdAt.vectaFormatted(date:.abbreviated,time:.shortened)+" · "+result.stage.title).font(.system(size:11)).foregroundColor(Ink.secondary)
                    }
                    Spacer(minLength:4)
                    VectaHistoryMenu(results:model.analyses,selection:$model.analysisID) {_ in model.loadConversation()}
                }
            }
            if model.analysisBusy {
                Button(VL.text("Отменить"),action:model.cancelAnalysis).buttonStyle(QuietButton())
            } else if model.analysis?.summary == nil {
                Text(VL.text("Главные темы, решения и договорённости из этой записи.")).font(.system(size:13)).foregroundColor(Ink.secondary)
                HStack(spacing:12) {
                    Button(VL.text("Создать саммари")) {startSummary()}.buttonStyle(QuietButton(primary:true)).disabled(!canStartSummary)
                    Button(VL.text("Настроить…")) {showingGeneration=true}.buttonStyle(QuietButton()).disabled(model.visualRetryBusy)
                }
                Text((selectedRecipe?.title ?? VL.text("Стандартное"))+" · "+(model.localAI?.summaryModel.title ?? VL.text("Быстрая"))).font(.system(size:11)).foregroundColor(Ink.muted)
                if NativeSummarySelection.transcriptSource(model.analyses) != nil {
                    Text(VL.text("На основе сохранённой расшифровки")).font(.system(size:11)).foregroundColor(Ink.muted)
                } else {Text(VL.text("Сначала распознаем речь и собеседников.")).font(.system(size:11)).foregroundColor(Ink.muted)}
            } else {
                HStack(spacing:12) {
                    if let result=model.analysis {
                        Text(result.request.format.displayTitle+" · "+result.request.selectedSummaryModel.title)
                            .font(.system(size:11)).foregroundColor(Ink.secondary)
                            .help(result.request.createdAt.vectaFormatted(date:.abbreviated,time:.shortened)+" · "+result.stage.title)
                    }
                    Spacer(minLength:4)
                    VectaHistoryMenu(results:model.analyses,selection:$model.analysisID) {_ in model.loadConversation()}
                    Button {showingGeneration=true} label: {Image(systemName:"plus")}
                        .buttonStyle(QuietButton()).help(VL.text("Новая версия саммари"))
                        .accessibilityLabel(VL.text("Новая версия саммари")).disabled(model.visualRetryBusy)
                    Menu {
                        Button(VL.text("Перерасшифровать запись…")) {confirmingRetranscription=true}
                    } label: {Image(systemName:"ellipsis").padding(6)}
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel(VL.text("Действия обработки записи")).disabled(model.visualRetryBusy)
                }
            }
            if model.analysis?.summary == nil, !model.analysisBusy, let reason=summaryUnavailable {Text(reason).font(.system(size:12)).foregroundColor(Ink.secondary)}
            if let host=model.localAI,let id=model.analysisID,model.analysisBusy || model.visualRetryBusy {NativeProcessingProgress(host:host,id:id)}
            if !model.analysisBusy, let message = model.analysisMessage { Text(message).font(.system(size:12)).foregroundColor(Ink.secondary) }
            if model.analysis?.stage.isActive == false, let progress = model.analysis?.recognitionProgress,
               progress.completedChunks > 0, progress.completedChunks < progress.totalChunks {
                Text(VL.text("Сохранено фрагментов: \(progress.completedChunks) из \(progress.totalChunks). Завершённые фрагменты и исходная запись сохранены."))
                    .font(.system(size:12)).foregroundColor(Ink.secondary)
            }
            if let error = model.analysis?.error { Text(error).font(.system(size: 12)).foregroundColor(Ink.error) }

        }
    }
    private var recipes:[NativeSummaryRecipe] {NativeSummarySelection.creationRecipes(in:NativeSummarySelection.recipes(formats:model.formats,templates:model.currentSummaryTemplates))}
    private var selectedRecipe:NativeSummaryRecipe? {NativeSummarySelection.selected(recipeID.isEmpty ? nil:recipeID,legacyFormat:formatID,in:recipes)}
    private var summaryUnavailable:String? {
        guard let host=model.localAI else {return VL.text("Локальный ИИ ещё не готов.")}
        if !host.supported {return VL.text("Локальная обработка доступна с macOS 15.")}
        if host.statuses[host.summaryModel.rawValue]?.state != .installed {return VL.text("Для создания саммари установите модель «")+host.summaryModel.title+VL.text("» в разделе «Локальный ИИ».")}
        if NativeSummarySelection.transcriptSource(model.analyses)==nil && !host.speechEngine.modelIDs().allSatisfy({host.statuses[$0]?.state == .installed}) {return VL.text("Для первой обработки установите модели распознавания в разделе «Локальный ИИ».")}
        return nil
    }
    private var canStartSummary:Bool {selectedRecipe != nil && model.localAI?.supported == true && (model.localAI?.summaryModel.compatible() ?? false) && !model.analysisBusy && !model.visualRetryBusy}
    private func startSummary(reuseTranscript:Bool=true) {
        guard let recipe=selectedRecipe else{return}
        requestAnalysis(recipe:recipe,reuseTranscript:reuseTranscript)
    }
    private func requestAnalysis(recipe:NativeSummaryRecipe,reuseTranscript:Bool) {
        guard let host=model.localAI,let recording=model.selected else {return}
        let source=reuseTranscript && NativeSummarySelection.transcriptSource(model.analyses) != nil
        let ids=host.modelsNeeded(reuseTranscript:source).filter {host.statuses[$0]?.state != .installed && !host.isModelBusy($0)}
        if !ids.isEmpty {
            pendingModelInstallation=PendingModelInstallation(recording:recording,recipe:recipe,reuseTranscript:reuseTranscript,model:host.summaryModel,models:host.registry.models.filter {ids.contains($0.id)})
        } else {model.analyze(format:recipe.format,reuseTranscript:reuseTranscript,template:recipe.template)}
    }
    private var summary: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if let draft=model.analysis?.summaryDraft,!draft.isEmpty {
                VStack(alignment:.leading,spacing:12) {
                    HStack(spacing:8) {
                        if model.analysisBusy {ProgressView().controlSize(.small)}
                        Text(model.analysisBusy ? VL.text("Саммари создаётся"):VL.text("Незавершённое саммари")).font(.system(size:13,weight:.semibold))
                        Spacer()
                        Text(model.analysisBusy ? VL.text("Текст дополняется"):VL.text("Генерация остановлена")).font(.system(size:11)).foregroundColor(Ink.secondary)
                    }
                    NativeStreamingText(text:draft)
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Ink.surface).cornerRadius(9)
            }
            if let id=model.analysisID,let draft=model.localAI?.visualDrafts[id] {
                NativeVisualSummaryView(report:draft.visual(style:.editorial),semantic:draft,formatTitle:model.analysis?.request.format.displayTitle,speakers:model.resolvedConversation,segments:model.analysis?.segments ?? []) {segment in model.playExcerpt(start:segment.start,end:segment.end,segment:segment.id)}
            } else if let visual=model.analysis?.visualSummary {
                NativeVisualSummaryView(report:visual,semantic:model.analysis?.semanticSummary,formatTitle:model.analysis?.request.format.displayTitle,speakers:model.resolvedConversation,segments:model.analysis?.segments ?? []) {segment in model.playExcerpt(start:segment.start,end:segment.end,segment:segment.id)}
            }
            if let error=model.analysis?.visualError {
                Text(error+VL.text(" Текстовое саммари сохранено.")).font(.system(size:12)).foregroundColor(Ink.secondary)
            }
            if model.analysis?.summary != nil, model.analysis?.visualSummary == nil {
                Button(model.analysis?.visualError == nil ? VL.text("Создать визуальное саммари") : VL.text("Повторить создание визуального саммари")) { model.retryVisualReport() }
                    .buttonStyle(QuietButton()).disabled(model.analysisBusy || model.visualRetryBusy)
            }
            if model.analysis?.summary != nil {
                if model.conversation.summaryNeedsReview { Text(VL.text("Авторство реплик изменено. Проверьте готовые выводы; содержание саммари автоматически не переписывалось.")).font(.system(size:12)).foregroundColor(Ink.secondary) }
                if let document=model.analysis?.completeTextSummary {
                    NativeStreamingText(text:document.rendered(speakers:model.resolvedConversation,markdownHeadings:true))
                }
                Button(VL.text("Скопировать саммари")) { model.copyAnalysis(transcript: false) }.buttonStyle(QuietButton())
            } else if !model.history.isEmpty { resultSection(VL.text("Сохранённое ранее саммари")) { Text(model.history).textSelection(.enabled).lineSpacing(5) } }
        }
    }
    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if let result = model.analysis, let text = result.transcript {
                DisclosureGroup(VL.text("Собеседники"),isExpanded:$speakersExpanded) {NativeSpeakerControls(model:model)}.font(.system(size:12))
                HStack {
                    Button(selectingUtterances ? VL.text("Завершить выбор") : VL.text("Исправить авторство реплик")) { let selecting = !selectingUtterances;resetUtteranceSelection();selectingUtterances=selecting;utteranceScope=selecting ? transcriptScope:nil }.buttonStyle(QuietButton())
                    if !selectedUtterances.isEmpty { Button(VL.text("Новый собеседник · \(selectedUtterances.count) реплик")) { submitUtteranceSelection() }.buttonStyle(QuietButton()) }
                }
                if result.segments.isEmpty { Text(text).textSelection(.enabled).lineSpacing(5) }
                else { ForEach(result.segments, id: \.id) { segment in
                    NativeTranscriptRow(model:model,playback:model.playback,segment:segment,selectingUtterances:selectingUtterances,selectedUtterances:$selectedUtterances,editingSpeaker:$editingSpeaker,wordSegment:$wordSegment).id(segment.id)
                } }
                if let unmatched = result.unmatchedText,!unmatched.isEmpty {
                    VStack(alignment:.leading,spacing:6) {
                        Text(VL.text("Без надёжных таймкодов")).font(.system(size:11,weight:.medium)).foregroundColor(Ink.secondary)
                        Text(unmatched).textSelection(.enabled).lineSpacing(4)
                    }
                }
                Button(VL.text("Скопировать расшифровку")) { model.copyAnalysis(transcript: true) }.buttonStyle(QuietButton())
            } else if let text=model.selection?.local?.transcript,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                Text(VL.text("Без надёжных таймкодов")).font(.system(size:11,weight:.medium)).foregroundColor(Ink.secondary)
                Text(text).textSelection(.enabled).lineSpacing(5)
            } else { emptyResult(VL.text("Транскрипта пока нет"), VL.text("WhisperKit распознает речь локально, SpeakerKit определит собеседников; результат сохранится на Mac.")) }
        }
    }

    private func information(_ item: NativeLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(VL.text("Об аудиозаписи")).font(.system(size: 20, weight: .semibold))
            info(VL.text("Дата"), timeRange(from: item.createdAt, duration: max(item.duration, model.duration), date: .long))
            info(VL.text("Длительность"), clock(max(item.duration, model.duration)))
            info(VL.text("Хранение"), item.audioURL == nil ? VL.text("На диктофоне") : VL.text("На этом Mac"))
            if let result = model.analysis {
                info(VL.text("Модель саммари"), result.request.selectedSummaryModel.title)
                info(VL.text("Формат"), result.request.format.displayTitle + VL.text(" · версия \(result.request.format.revision)"))
                info(VL.text("Состояние"), result.stage.title)
                if let time = result.recognitionSeconds { info(VL.text("Распознавание"), String(format: VL.text("%.1f с"), time)) }
                if let time = result.summarySeconds { info(VL.text("Создание саммари"), String(format: VL.text("%.1f с"), time)) }
            }
        }.padding(20).background(Ink.surface).cornerRadius(9)
    }
    private func info(_ label: String, _ value: String) -> some View { HStack { Text(label).foregroundColor(Ink.secondary); Spacer(); Text(value) }.font(.system(size: 13)) }
    private func emptyResult(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.system(size: 18, weight: .semibold)); Text(detail).foregroundColor(Ink.secondary).lineSpacing(4) }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Ink.surface).cornerRadius(9)
    }
    private func resultSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { Text(title).font(.system(size: 18, weight: .semibold)); content() }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Ink.surface).cornerRadius(9)
    }
}

struct NativeWaveformView: View {
    let values: [Float]; let fraction: Double
    var highlights: [VectaHighlightRange] = []
    var duration: Double = 0
    let seek: (Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let step = size.width / CGFloat(max(1, values.count))
                for (index, value) in values.enumerated() {
                    let height = max(2, CGFloat(value) * (size.height - 4))
                    let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: max(1, step * 0.48), height: height)
                    let highlighted = highlights.contains { $0.overlaps(start: Double(index) / Double(values.count) * duration,
                                                                 end: Double(index + 1) / Double(values.count) * duration) }
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(highlighted ? Ink.error : (Double(index) / Double(values.count) <= fraction ? Ink.text : Ink.muted.opacity(0.55))))
                }
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in seek(min(1, max(0, value.location.x / max(1, geometry.size.width)))) })
        }.frame(height: 34).accessibilityElement().accessibilityLabel(VL.text("Позиция воспроизведения"))
            .accessibilityValue(VL.text("\(Int(fraction * 100)) процентов"))
            .accessibilityAdjustableAction { direction in
                switch direction { case .increment: seek(min(1, fraction + 0.05)); case .decrement: seek(max(0, fraction - 0.05)); @unknown default: break }
            }
    }
}


