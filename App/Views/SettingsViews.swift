import AppKit
import SwiftUI

struct NativeGeneralSettings: View {
    @ObservedObject var model: NativeMacModel
    @AppStorage("vecta.appearance") private var appearance="dark"
    @State private var continuousWarning=false
    private var syncSelection:Binding<NativeSyncInterval> {
        Binding<NativeSyncInterval>(get:{model.autoSyncInterval},set:{value in
            if value == .continuous && model.autoSyncInterval != .continuous {continuousWarning=true}
            else {model.setAutoSyncInterval(value)}
        })
    }
    var body: some View {
        ScrollViewReader { proxy in ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenTitle(title: VL.text("Настройки"), subtitle: VL.text("Библиотека, устройство и локальный ИИ."))
                NativeApplicationBehaviorSettings(settings: model.applicationSettings)
                NativeLanguagePicker(model:model).padding(20).background(Ink.surface).cornerRadius(9)
                HStack {Text(VL.text("Оформление"));Spacer();Picker(VL.text("Тема"),selection:$appearance) {ForEach(VectaAppearance.allCases) {Text($0.title).tag($0.rawValue)}}.frame(width:200)}.padding(20).background(Ink.surface).cornerRadius(9)
                NativeColorThemePicker().padding(20).background(Ink.surface).cornerRadius(9).id("colorTheme")
                    .onAppear {
                        #if VECTA_DEVELOPMENT
                        if CommandLine.arguments.contains("--verify-scroll-themes") { DispatchQueue.main.async { proxy.scrollTo("colorTheme", anchor: .top) } }
                        #endif
                    }
                VStack(alignment: .leading, spacing: 16) {
                    Text(VL.text("Библиотека")).font(.system(size: 18, weight: .semibold))
                    HStack { Text(VL.text("Папка обработки")).foregroundColor(Ink.secondary); Spacer(); Text(VectaLegacyPaths.presentationFolder(model.library?.exporter.folderName)) }
                    HStack {
                        if let host = model.localAI { Button(VL.text("Показать в Finder")) { NSWorkspace.shared.open(host.root) }.buttonStyle(QuietButton()) }
                        Button(VL.text("Открыть существующую библиотеку…"), action: model.selectExistingLibrary).buttonStyle(QuietButton()).disabled(model.busy || model.analysisBusy)
                    }
                }.padding(20).background(Ink.surface).cornerRadius(9)
                VStack(alignment: .leading, spacing: 14) {
                    Text(VL.text("Автоматическая синхронизация")).font(.system(size: 18, weight: .semibold))
                    HStack {
                        Text(VL.text("Интервал")).foregroundColor(Ink.secondary)
                        Spacer()
                        Picker(VL.text("Интервал автосинхронизации"), selection: syncSelection) {
                            ForEach(NativeSyncInterval.allCases) { interval in Text(interval.title).tag(interval) }
                        }.labelsHidden().frame(width: 200)
                    }
                    Text(model.autoSyncInterval == .continuous ? VL.text("Пока Vecta открыт и Mac не спит, соединение с Plaud поддерживается. Новые записи проверяются каждые 30 секунд; при потере связи Vecta попробует подключиться снова."):VL.text("Работает, пока Vecta открыт. После синхронизации Bluetooth освобождается."))
                        .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                    if model.autoSyncInterval == .off {
                        Text(VL.text("Автоподключение отключено. Синхронизацию можно запустить вручную.")).font(.system(size: 12)).foregroundColor(Ink.secondary)
                    } else if model.savedDevice == nil {
                        Text(VL.text("Сначала выберите свой Plaud на экране устройства.")).font(.system(size: 12)).foregroundColor(Ink.secondary)
                    } else if model.autoSyncInterval == .continuous {
                        Label(VL.text("Постоянное подключение может быстрее разряжать Plaud."),systemImage:"battery.25").font(.system(size:12)).foregroundColor(Ink.secondary)
                    } else if let next = model.nextAutoSync {
                        Text(VL.text("Следующая попытка: ") + next.vectaFormatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundColor(Ink.secondary)
                    }
                }.padding(20).background(Ink.surface).cornerRadius(9)
                VStack(alignment: .leading, spacing: 14) {
                    Text(VL.text("Обработка записей")).font(.system(size: 18, weight: .semibold))
                    Toggle(VL.text("Автоматическое саммари после синхронизации"), isOn: Binding(get: { model.automaticSummary }, set: model.setAutomaticSummary))
                        .toggleStyle(.checkbox)
                    Toggle(VL.text("Быстрая расшифровка"), isOn: Binding(get: { model.localAI?.fastTranscriptionEnabled ?? true }, set: { value in model.localAI?.setFastTranscriptionEnabled(value) }))
                        .toggleStyle(.checkbox)
                        .disabled(model.localAI == nil)
                    Text(VL.text("Быстрее начинает расшифровку, сохраняя движок в памяти, пока Vecta открыт. Это может занимать около 700 МБ дополнительной оперативной памяти. При выключении используется обычный запуск модели для каждой записи. Первая подготовка всё равно занимает время.")).font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                    Text(VL.text("Расшифровка и саммари создаются на этом Mac. Модели устанавливаются отдельно.")).font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                    Text(VL.text("После синхронизации новые скачанные записи обрабатываются в выбранных ниже форматах. Изменения применяются к новым заданиям; готовые результаты сохраняются."))
                        .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                    NativeAutomaticFormats(model:model)
                    HStack { Button(VL.text("Настроить модели")) { model.destination = .ai }.buttonStyle(QuietButton()); Button(VL.text("Форматы саммари")) { model.destination = .formats }.buttonStyle(QuietButton()) }
                }.padding(20).background(Ink.surface).cornerRadius(9)
                NativeVoiceSettings(model:model)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Vecta").font(.system(size: 18, weight: .semibold))
                    Text(VL.text("Нативное приложение macOS · версия ") + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")).foregroundColor(Ink.secondary)
                    Text(VL.text("Bluetooth подключается только для работы с диктофоном. Записи на устройстве не удаляются автоматически.")).font(.system(size: 12)).foregroundColor(Ink.muted).lineSpacing(4)
                    if let resources = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: resources.appendingPathComponent("LocalAI/Licenses").path) {
                        Button(VL.text("Лицензии компонентов ИИ")) { NSWorkspace.shared.open(resources.appendingPathComponent("LocalAI/Licenses")) }.buttonStyle(QuietButton())
                    }
                }.padding(20).background(Ink.surface).cornerRadius(9)
            }.frame(maxWidth: 760, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .topLeading)
        } }.onAppear { model.loadWorkspace() }
        .onChange(of: model.processingRoot ?? model.localAI?.root) { _ in model.loadWorkspace() }
        .alert(VL.text("Постоянное подключение к Plaud"),isPresented:$continuousWarning) {
            Button(VL.text("Включить постоянно")) {model.setAutoSyncInterval(.continuous)}
            Button(VL.text("Отмена"),role:.cancel) {}
        } message: {Text(VL.text("Vecta будет поддерживать Bluetooth-соединение с Plaud. Это может привести к более быстрому разряду устройства."))}
    }
}

struct NativeSpeakerControls:View {
    @ObservedObject var model:NativeMacModel
    @State private var editing:NativeSpeakerSelection?
    @State private var pendingMerge:(source:String,target:String)?
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            ForEach(model.resolvedConversation.identities.values.sorted{$0.id<$1.id}) {identity in
                VStack(alignment:.leading,spacing:8) {
                    HStack {
                        NativeSpeakerIdentityActions(model:model,speakerID:identity.id,allowsConfirmation:true,editingSpeaker:$editing)
                        Spacer()
                        Menu {ForEach(model.resolvedConversation.identities.values.filter{$0.id != identity.id}.sorted{$0.id<$1.id}) {target in Button(VL.text("Объединить с ")+target.displayName) {
                            if model.speakerMergeNeedsConfirmation(identity.id,into:target.id) {pendingMerge=(identity.id,target.id)}
                            else {model.mergeSpeaker(identity.id,into:target.id)}
                        }}} label:{Image(systemName:"ellipsis")}.help(VL.text("Исправить разделение собеседников"))
                    }
                    Text(identity.isVoiceConfirmed ? VL.text("Подтверждено вами"):identity.origin=="voiceSuggestion" ? VL.text("По сходству голоса · подтвердите, кто говорит"):identity.origin=="userUnknown" ? VL.text("Вы указали: неизвестный"):identity.origin=="manual" ? VL.text("Имя в этой записи"):VL.text("Имя не указано")).font(.system(size:11)).foregroundColor(Ink.secondary)
                    HStack {
                        if identity.origin=="voiceSuggestion" {Text(VL.text("«Да» подтверждает голос и сохраняет доступный образец. «Нет» открывает выбор другого или нового человека.")).font(.system(size:11)).foregroundColor(Ink.secondary).fixedSize(horizontal:false,vertical:true)}
                        Spacer()
                        Button(VL.text("Выбрать собеседника")) {editing=NativeSpeakerSelection(id:identity.id)}.buttonStyle(QuietButton())
                    }
                }.padding(.vertical,4)
            }
        }.padding(16).background(Ink.surface).cornerRadius(9)
        .sheet(item:$editing) {person in NativeSpeakerSheet(model:model,speakerID:person.id,rejectedProfileID:person.rejectedProfileID)}
        .alert(VL.text("Объединить разных собеседников?"),isPresented:Binding(get:{pendingMerge != nil},set:{if !$0 {pendingMerge=nil}})) {
            if let merge=pendingMerge {
                Button(VL.text("Объединить с ")+model.resolvedConversation.name(merge.target)) {
                    model.mergeSpeaker(merge.source,into:merge.target,allowProfileChange:true);pendingMerge=nil
                }
            }
            Button(VL.text("Отмена"),role:.cancel) {pendingMerge=nil}
        } message:{
            Text(VL.text("Для этих частей записи выбраны или предложены разные люди. Реплики и образцы объединённых частей будут привязаны к выбранному человеку. Остальные записи и профили не объединяются."))
        }
    }
}

struct NativeVoiceSettings:View {
    @ObservedObject var model:NativeMacModel
    @State private var search=""
    @State private var editing:AIVoiceProfile?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(VL.text("Собеседники")).font(.system(size:18,weight:.semibold))
            Toggle(VL.text("Предлагать сохранённых собеседников"),isOn:Binding(get:{model.voiceLibrary.recognitionEnabled},set:{enabled in model.updateVoices{$0.recognitionEnabled=enabled}})).toggleStyle(.checkbox)
            Text(VL.text("Подтверждение сохранённого собеседника добавляет образец записи в его профиль. При сравнении учитываются несколько образцов; имя подтверждаете вы. Всё остаётся на этом Mac.")).font(.system(size:12)).foregroundColor(Ink.secondary)
            if model.voiceLibrary.activeProfiles.isEmpty {
                Text(VL.text("Откройте расшифровку, выберите «Новый человек» и включите «Сохранить голос для будущих записей».")).font(.system(size:12)).foregroundColor(Ink.secondary)
                Button(VL.text("Выбрать запись")) {model.select(nil);model.destination = .library}.buttonStyle(QuietButton())
            } else {
                TextField(VL.text("Найти собеседника"),text:$search).textFieldStyle(.roundedBorder)
                ForEach(model.voiceLibrary.activeProfiles.filter {search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)}.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}) {profile in
                    Button {editing=profile} label: {
                        HStack(spacing:12) {
                            Image(systemName:"person.crop.circle").font(.system(size:22)).foregroundColor(Ink.secondary)
                            VStack(alignment:.leading,spacing:3) {Text(profile.name).foregroundColor(Ink.text);Text(VL.text("Образцов голоса: \(profile.samples.count)")).font(.system(size:11)).foregroundColor(Ink.secondary)}
                            Spacer();Image(systemName:"chevron.right").foregroundColor(Ink.muted)
                        }.padding(.vertical,6).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(VL.text("Открыть собеседника ")+profile.name)
                }
                if model.voiceLibrary.activeProfiles.allSatisfy({!search.isEmpty && !$0.name.localizedCaseInsensitiveContains(search)}) {Text(VL.text("Никого не найдено")).foregroundColor(Ink.secondary)}
            }
        }.padding(20).background(Ink.surface).cornerRadius(9)
        .onAppear {if let host=model.localAI,let voices=try? AIConversationStore(root:host.root).voices(){model.voiceLibrary=voices}}
        .sheet(item:$editing) {profile in NativeVoiceProfileSheet(model:model,profileID:profile.id)}
    }
}

struct NativeSummaryModelPicker: View {
    @ObservedObject var host: LocalAIHost
    var body: some View {
        Picker(VL.text("Модель ИИ"), selection: Binding(get: { host.summaryModel }, set: host.selectSummaryModel)) {
            ForEach([AISummaryModelID.qwen4b,.qwen9b],id:\.self) { model in Text(model.selectionTitle).tag(model).disabled(!model.compatible()) }
        }.labelsHidden()
    }
}

struct NativeAISettings: View {
    @ObservedObject var host: LocalAIHost
    @State private var removing: String?
    @State private var speechDetailsExpanded=true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ScreenTitle(title: VL.text("Локальный ИИ"), subtitle: VL.text("Записи и результаты остаются на вашем Mac."))
                engineCard
                speechCard
                HStack { Text(VL.text("Модель для всех задач")).foregroundColor(Ink.secondary); Spacer(); NativeSummaryModelPicker(host: host).frame(width: 210) }
                Text(VL.text("Выбранная модель используется для саммари, инфографики и AI-ассистента. Выбор модели не запускает скачивание. Распознавание записей — до 6 часов; требуется Apple Silicon и macOS 15+."))
                    .font(.system(size: 12)).foregroundColor(Ink.muted).lineSpacing(4)
                Text(VL.text("Установленные модели")).font(.system(size: 18, weight: .semibold))
                VStack(spacing: 1) { ForEach(host.registry.models.filter { ["qwen4b", "qwen9b"].contains($0.id) }) { model in modelRow(model) } }
                if !host.supported { Text(VL.text("Локальный ИИ недоступен в этой версии macOS.")).foregroundColor(Color(hex: 0xE9B949)) }
                if let message = host.message { Text(message).font(.system(size: 12)).foregroundColor(Ink.secondary) }
                Button(VL.text("Установить все модели")) { host.installAll() }.buttonStyle(QuietButton(primary:true)).disabled(!host.supported || host.removingSpeech)
                Text(VL.text("Можно скачивать несколько моделей одновременно. Установка не меняет выбранную модель для обработки.")).font(.system(size:12)).foregroundColor(Ink.secondary)
                Button(VL.text("Проверить модели")) { Task { await host.refreshModels() } }.buttonStyle(QuietButton()).disabled(host.activeRequest != nil || host.installingSpeech)
            }.frame(maxWidth: 760, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .topLeading)
        }.confirmationDialog(VL.text("Удалить модель с этого Mac?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(VL.text("Удалить модель"), role: .destructive) { if let removing { if removing == "speech" {host.removeSpeech()} else {host.remove(removing)} }; removing = nil }
            Button(VL.text("Отмена"), role: .cancel) { removing = nil }
        } message: { Text(VL.text("Записи, транскрипты и саммари сохранятся. Для новой обработки модель потребуется установить снова.")) }
    }
    /// Recognition engine choice. Diarization, summaries and exports are shared.
    private var engineCard:some View {
        let missing=host.speechEngine.modelIDs().filter {host.statuses[$0]?.state != .installed}
        let busy=missing.contains(where:host.isModelBusy)
        return VStack(alignment:.leading,spacing:12) {
            HStack(alignment:.center,spacing:12) {
                Image(systemName:"text.bubble").font(.system(size:22)).frame(width:38,height:38).background(Ink.elevated).cornerRadius(8)
                VStack(alignment:.leading,spacing:5) {
                    Text(VL.text("Распознавание речи")).font(.system(size:18,weight:.semibold))
                    Text(VL.text("Выберите модель для новых записей")).font(.system(size:12)).foregroundColor(Ink.secondary)
                }
                Spacer()
                Picker(VL.text("Модель распознавания речи"),selection:Binding(get:{host.speechEngine},set:host.selectSpeechEngine)) {
                    ForEach(AISpeechEngineID.allCases) {engine in Text(engine.title).tag(engine)}
                }.labelsHidden().frame(width:300)
            }
            Text(host.speechEngine.description).font(.system(size:12)).foregroundColor(Ink.secondary).lineSpacing(3)
            Text(VL.text("Разделение реплик по голосам (SpeakerKit), саммари, инфографика, ассистент и экспорт работают одинаково с обеими моделями. Выбор применяется к новым обработкам, уже готовые расшифровки не меняются.")).font(.system(size:12)).foregroundColor(Ink.muted).lineSpacing(3)
            if host.speechEngine == .gigaam {
                if let gigaam=host.registry.models.first(where:{$0.id=="gigaam"}) { modelRow(gigaam) }
                if !missing.isEmpty && !busy {
                    Button(VL.text("Установить GigaAM v3 и SpeakerKit")) {host.installRecognition()}.buttonStyle(QuietButton(primary:true)).disabled(!host.supported || host.removingSpeech)
                    Text(VL.text("SpeakerKit нужен для разделения по голосам. WhisperKit для GigaAM скачивать не нужно.")).font(.system(size:12)).foregroundColor(Ink.secondary)
                }
            }
        }.padding(20).background(Ink.surface).cornerRadius(9)
    }
    private var speechCard:some View {
        let models=host.registry.models.filter{LocalModelManager.speechIDs.contains($0.id)}
        let ready=LocalModelManager.speechIDs.allSatisfy{host.statuses[$0]?.state == .installed}
        let checking=models.contains{host.statuses[$0.id]?.state == .verifying}
        let total=models.reduce(Int64(0)){$0+$1.size}
        let received=models.reduce(Int64(0)) {sum,model in sum+(host.statuses[model.id]?.state == .installed ? model.size:host.statuses[model.id]?.received ?? 0)}
        return VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.top,spacing:12) {
                Image(systemName:"waveform").font(.system(size:22)).frame(width:38,height:38).background(Ink.elevated).cornerRadius(8)
                VStack(alignment:.leading,spacing:5) {
                    Text(VL.text("Голосовая расшифровка")).font(.system(size:18,weight:.semibold))
                    Text(ready ? VL.text("Готово · все 3 компонента установлены"):VL.text("3 компонента · ")+VL.bytes(total)).font(.system(size:12)).foregroundColor(Ink.secondary)
                }
                Spacer()
            }
            Text(VL.text("WhisperKit распознаёт слова, SpeakerKit разделяет реплики по голосам, а токенизатор помогает модели обрабатывать текст. Все три компонента скачиваются параллельно одной кнопкой. Записи обрабатываются на вашем Mac и не отправляются в облако.")).font(.system(size:12)).foregroundColor(Ink.secondary).lineSpacing(3)
            DisclosureGroup(VL.text("Состав загрузки"),isExpanded:$speechDetailsExpanded) {
                ForEach(models) {model in
                    HStack {Text(VL.string(model.title));Spacer();Text(VL.bytes(model.size));if host.statuses[model.id]?.state == .installed {Image(systemName:"checkmark.circle.fill").foregroundColor(Ink.success)}}.font(.system(size:11)).foregroundColor(Ink.secondary).padding(.vertical,4)
                }
            }.font(.system(size:12))
            if host.removingSpeech {HStack {ProgressView().controlSize(.small);Text(VL.text("Удаляем компоненты…")).font(.system(size:12))}}
            else if host.installingSpeech {
                ProgressView(value:Double(received),total:Double(max(1,total)))
                HStack {Text(VL.text("Устанавливаем · \(Int(Double(received)/Double(max(1,total))*100))%")).font(.system(size:11));Spacer();Button(VL.text("Пауза")) {host.cancelSpeechDownload()}.buttonStyle(QuietButton())}
            } else if ready {
                HStack {Label(VL.text("Установлено"),systemImage:"checkmark.circle.fill").font(.system(size:12)).foregroundColor(Ink.success);Spacer();Button {removing="speech"} label:{Image(systemName:"ellipsis")}.buttonStyle(.plain).help(VL.text("Удалить компоненты расшифровки")).disabled(host.activeRequest != nil || host.installingSpeech)}
            } else if checking {HStack {ProgressView().controlSize(.small);Text(VL.text("Проверяем компоненты…")).font(.system(size:12))}}
            else {Button(VL.text("Установить голосовую расшифровку")) {host.installSpeech()}.buttonStyle(QuietButton(primary:true)).disabled(!host.supported || host.activeRequest != nil)}
            if !host.removingSpeech {
                Button(VL.text("Удалить компоненты и незавершённые загрузки…")) { removing="speech" }.buttonStyle(QuietButton()).disabled(host.activeRequest != nil)
                if host.installingSpeech {
                    Text(VL.bytes(Int64(LocalModelManager.speechIDs.reduce(0.0) { $0 + (host.downloadSpeeds[$1] ?? 0) }))+"/s").font(.system(size:11)).foregroundColor(Ink.secondary)
                }
            }
            ForEach(models) {model in if let error=host.statuses[model.id]?.error {Text(VL.string(model.title)+": "+error).font(.system(size:12)).foregroundColor(Ink.secondary)}}
        }.padding(20).background(Ink.surface).cornerRadius(9)
    }
    private func modelRow(_ model: LocalModelDefinition) -> some View {
        let status = host.statuses[model.id]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: ["whisper", "speaker", "tokenizer", "gigaam"].contains(model.id) ? "waveform" : "sparkles").font(.system(size: 19)).frame(width: 38, height: 38).background(Ink.elevated).cornerRadius(8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(AISummaryModelID(rawValue:model.id)?.title ?? VL.string(model.title)).font(.system(size: 15, weight: .medium))
                    if let llm=AISummaryModelID(rawValue:model.id) {
                        Text(llm == .qwen9b ? VL.text("От 16 ГБ памяти"):VL.text("От 8 ГБ памяти")).font(.system(size:12)).foregroundColor(Ink.secondary)
                        Text(llm.description).font(.system(size:12)).foregroundColor(Ink.secondary)
                        Label(VL.text("Саммари · Инфографика · Ассистент"),systemImage:llm == .qwen9b ? "rectangle.3.group":"bubble.left.and.text.bubble.right").font(.system(size:11,weight:.medium))
                        DisclosureGroup(VL.text("Технические сведения")) {Text(VL.string(model.title)+" · "+llm.memoryRequirement).font(.system(size:11)).foregroundColor(Ink.secondary)}.font(.system(size:11))
                    }
                    Text(VL.string(model.variant) + " · " + VL.bytes(model.size)).font(.system(size: 11)).foregroundColor(Ink.muted)
                }
                Spacer()
                if status?.state == .installed {
                    Label(VL.text("Установлена"), systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(Ink.success)
                    Button(VL.text("Удалить…")) { removing = model.id }.buttonStyle(QuietButton()).disabled(host.activeRequest != nil)
                } else if [.preparing, .downloading].contains(status?.state) {
                    Button(VL.text("Пауза")) { host.cancelDownload(model.id) }.buttonStyle(QuietButton())
                } else if [.verifying, .deleting].contains(status?.state) {
                    ProgressView().controlSize(.small); Text(status?.state == .deleting ? VL.text("Удаляем…") : VL.text("Проверяем…")).font(.system(size: 11)).foregroundColor(Ink.secondary)
                } else {
                    Button(status?.state == .damaged ? VL.text("Восстановить") : VL.text("Установить / продолжить")) { host.install(model.id) }.buttonStyle(QuietButton(primary: true)).disabled(!host.supported)
                }
            }
            if status?.state == .downloading {
                ProgressView(value: status?.fraction ?? 0)
                Text("\(Int((status?.fraction ?? 0) * 100))% · " + VL.bytes(status?.received ?? 0) + " · " + VL.bytes(Int64(host.downloadSpeeds[model.id] ?? 0)) + "/s").font(.system(size: 11)).foregroundColor(Ink.secondary)
            }
            if status?.state != .installed && status?.state != .deleting {
                Button(VL.text("Удалить незавершённую загрузку…")) { removing = model.id }.buttonStyle(QuietButton()).disabled(host.activeRequest != nil)
            }
            if let error = status?.error { Text(error).font(.system(size: 12)).foregroundColor(Ink.error) }
        }.padding(18).background(Ink.surface).cornerRadius(9)
    }
}


struct NativeApplicationBehaviorSettings: View {
    @ObservedObject var settings: NativeApplicationSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(VL.text("Запуск и фоновая работа")).font(.system(size: 18, weight: .semibold))
            Toggle(VL.text("Запускать при входе в macOS"), isOn: Binding(get: { settings.launchAtLoginEnabled }, set: settings.setLaunchAtLoginEnabled))
                .toggleStyle(.checkbox)
            Text(VL.text("Vecta будет запускаться автоматически после входа в вашу учётную запись на Mac.")).font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
            if let message = settings.loginStatusMessage {
                Text(message).font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                Button(VL.text("Открыть объекты входа macOS"), action: settings.openLoginSettings).buttonStyle(QuietButton())
            }
            Toggle(VL.text("Работать в фоновом режиме"), isOn: Binding(get: { settings.backgroundOperationEnabled }, set: settings.setBackgroundOperationEnabled))
                .toggleStyle(.checkbox)
            Text(VL.text("При закрытии окна Vecta продолжает синхронизацию и обработку записей. Открыть окно снова можно из Dock или строки меню. Чтобы завершить работу, выберите «Завершить Vecta» или нажмите ⌘Q. Если выключить эту настройку, закрытие окна завершит приложение.")).font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
        }.padding(20).background(Ink.surface).cornerRadius(9)
    }
}

/// Colour theme cards: each shows its own canvas, sidebar, accent and text in the current light or dark mode.
struct NativeColorThemePicker: View {
    @AppStorage(VectaColorTheme.preferenceKey) private var selection = "classic"
    @State private var hovered: VectaColorTheme?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(VL.text("Цветовая тема"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(VectaColorTheme.allCases) { theme in card(theme) }
            }
        }
    }
    private func card(_ theme: VectaColorTheme) -> some View {
        let chosen = (VectaColorTheme(rawValue: selection) ?? .classic) == theme
        return Button { selection = theme.rawValue } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(Ink.tone(.accent, in: theme)).frame(width: 22, height: 5)
                        RoundedRectangle(cornerRadius: 2).fill(Ink.tone(.muted, in: theme)).frame(width: 18, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(Ink.tone(.muted, in: theme)).frame(width: 14, height: 4)
                    }.padding(8).frame(width: 40, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top).background(Ink.tone(.sidebar, in: theme))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Aa").font(.system(size: 15, weight: .semibold)).foregroundColor(Ink.tone(.heading, in: theme))
                        RoundedRectangle(cornerRadius: 2).fill(Ink.tone(.text, in: theme)).frame(width: 54, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(Ink.tone(.secondary, in: theme)).frame(width: 40, height: 4)
                    }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Ink.tone(.canvas, in: theme))
                }.frame(height: 62).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.border))
                HStack(spacing: 6) {
                    Text(theme.title).font(.system(size: 12, weight: chosen ? .semibold : .regular)).foregroundColor(Ink.text).lineLimit(1)
                    Spacer(minLength: 0)
                    if chosen { Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundColor(Ink.accent) }
                }
            }.padding(8).background(hovered == theme ? Ink.hover : Ink.elevated).cornerRadius(9)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(chosen ? Ink.accent : Color.clear, lineWidth: 2))
        }.buttonStyle(.plain).onHover { inside in hovered = inside ? theme : (hovered == theme ? nil : hovered) }
            .help(theme.title).accessibilityLabel(theme.title)
            .accessibilityValue(chosen ? VL.text("Выбрано") : VL.text("Не выбрано"))
            .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}
