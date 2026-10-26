import AppKit
import SwiftUI

struct NativeMacView: View {
    @ObservedObject var model: NativeMacModel
    @State private var detail = CommandLine.arguments.contains("--verify-conversation") && !CommandLine.arguments.contains("--verify-library-ui")
    @AppStorage("vecta.sidebarCollapsed") private var compactSidebar = false
    @AppStorage("vecta.librarySort") private var oldestFirst = false
    @AppStorage("vecta.appearance") private var appearance="dark"
    @FocusState private var searchFocused:Bool
    @State private var hovered: NativeRecordingIdentity?
    @State private var deletingRecording: NativeLibraryItem?
    @State private var showingRecordingTrash = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: compactSidebar ? 62 : 210)
            Rectangle().fill(Ink.border).frame(width: 1)
            VStack(spacing: 0) {
                switch model.destination {
                case .library:
                    if detail, model.selection != nil { NativeRecordingDetail(model: model, back: { detail = false }) }
                    else { library }
                case .conferences: NativeConferencesScreen(model: model)
                case .device: NativeDeviceScreen(model: model)
                case .ai:
                    if let host = model.localAI { NativeAISettings(host: host) }
                    else { unavailable }
                case .settings: NativeGeneralSettings(model: model)
                case .tasks: NativeTaskScreen(model:model)
                case .formats:
                    if let controller = model.library { NativeFormatsScreen(model:model,library: controller) }
                    else { unavailable }
                }
                if model.macRecorder.busy {
                    NativeMacRecordingStrip(recorder: model.macRecorder).padding(.horizontal, 28).padding(.bottom, 12)
                }
                if model.transferring || model.fastTransferPhase != nil {
                    NativeTransferStrip(model: model).padding(.horizontal, 28).padding(.bottom, 16)
                }
                HStack(spacing: 8) {
                    if model.busy && !model.transferring { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.status).lineLimit(2)
                        if let message = model.batchMessage { Text(message).foregroundColor(Ink.secondary).lineLimit(2) }
                        if let job=model.analysisQueue?.jobs.first {
                            let done=job.completedBefore ?? 0,total=job.batchTotal ?? model.batchCount
                            Text(VL.text("Очередь: обработано \(done) из \(total), ошибок: \(job.failedBefore ?? 0)"))

                        }
                        if !detail, let id=model.batchActiveRequest,let host=model.localAI {NativeProcessingProgress(host:host,id:id)}
                        if let title = model.batchTitle { Text(title).foregroundColor(Ink.text).lineLimit(1) }
                        if model.localAI?.queuePaused == true { Text(VL.text("Очередь приостановлена")).foregroundColor(Ink.secondary) }
                    }
                    Spacer(minLength: 0)
                    if model.batchActiveRequest != nil { Button(VL.text("Отменить"),action:model.cancelAnalysis).buttonStyle(QuietButton()) }
                    if model.batchCount > 0, let host = model.localAI {
                        NativeAIQueueControl(host:host)
                    }
                }.font(.system(size: 11)).foregroundColor(Ink.muted).padding(.horizontal, 28).padding(.vertical, 12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.canvas)
        }.foregroundColor(Ink.text).font(.system(size: 14)).preferredColorScheme((VectaAppearance(rawValue:appearance) ?? .dark).scheme).tint(Ink.text)
            .overlay(alignment: .bottom) {
                if let feedback = model.voiceFeedback {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundColor(Ink.text)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Ink.surface).cornerRadius(10).shadow(radius: 8)
                        .padding(.bottom, 58).allowsHitTesting(false)
                        .accessibilityLabel(feedback)
                }
            }
            .onChange(of:model.selected) { value in if value != nil {detail=true} }
            .onChange(of:model.openDetailSignal) {_ in detail=true}
            .onChange(of:model.searchFocusSignal) {_ in detail=false;searchFocused=true}
            .onChange(of:model.sidebarToggleSignal) {_ in compactSidebar.toggle()}
            .frame(minWidth: 760, minHeight: 560)
            .sheet(isPresented: $model.showingDevicePicker, onDismiss: model.closePicker) {
                DevicePickerView(model: model).frame(minWidth: 520, minHeight: 360).background(Ink.canvas).buttonStyle(QuietButton())
            }
            .sheet(isPresented: $model.showingDeviceSetup) { DeviceSetupView(model: model) }
            .sheet(isPresented: $model.showingFastTransferWarning) {
                NativeFastTransferWarningView(onContinue: model.confirmFastTransfer, onCancel: { model.showingFastTransferWarning = false })
            }
            .onAppear {
                #if VECTA_DEVELOPMENT
                if CommandLine.arguments.contains("--verify-device-setup") { model.showingDeviceSetup = true }
                #endif
            }
            .confirmationDialog(VL.text("Удалить запись?"), isPresented: Binding(get: { deletingRecording != nil }, set: { if !$0 { deletingRecording = nil } })) {
                Button(VL.text("Удалить запись"), role: .destructive) { if let item = deletingRecording { model.deleteRecording(item.identity) }; deletingRecording = nil }
                Button(VL.text("Отмена"), role: .cancel) { deletingRecording = nil }
            } message: {
                Text("«" + (deletingRecording?.title ?? VL.text("Запись")) + VL.text("» будет перемещена в корзину Vecta вместе с расшифровками и саммари. Её можно восстановить. Запись на Plaud сохранится и не вернётся при синхронизации."))
            }
            .sheet(isPresented: $showingRecordingTrash) { NativeRecordingTrash(model: model) }
            .task(id:model.libraryCorpusFingerprint) {model.refreshLibraryIndex()}
            .task { if !VectaRuntimePreferences.isVerification { await model.start() } }
    }
    private var unavailable: some View {
        VStack(spacing: 16) {
            ScreenTitle(title: VL.text("Подготовка библиотеки"))
            Text(VL.text("Локальные настройки появятся после открытия библиотеки.")).foregroundColor(Ink.secondary)
            Button(VL.text("Открыть существующую библиотеку…"), action: model.selectExistingLibrary)
        }.padding(32).frame(maxHeight: .infinity, alignment: .top).buttonStyle(QuietButton())
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 23))
                    if !compactSidebar { Text("Vecta").font(.system(size: 17, weight: .semibold)); Spacer(minLength: 0) }
                    sidebarToggle
                }
                VStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 23))
                    sidebarToggle
                }
            }.padding(.horizontal, 8).padding(.top, 8)
            VStack(spacing: 5) {
                nav(.library, VL.text("Все записи"), "waveform", count: model.library?.items.count)
                nav(.conferences, VL.text("Конференции"), "person.2.wave.2")
                nav(.formats, VL.text("Форматы"), "text.badge.plus")
                nav(.ai, VL.text("Локальный ИИ"), "sparkles")
                nav(.settings, VL.text("Настройки"), "gearshape")
            }
            Spacer()
                Button { model.destination = .device } label: {
                    HStack(spacing: 10) {
                        VStack(spacing: 3) {
                            Image(systemName: "externaldrive.fill").font(.system(size: 23)).foregroundColor(Ink.secondary)
                            if compactSidebar, let battery = sidebarBattery { Text("\(battery)%").font(.system(size: 9, weight: .semibold)).monospacedDigit().foregroundColor(batteryColor(battery)) }
                        }
                        if !compactSidebar { VStack(alignment: .leading, spacing: 5) {
                            Text(model.savedDevice?.model.displayName ?? VL.text("Plaud не выбран")).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            HStack(spacing: 4) {
                                Circle().fill(model.connected ? Ink.success : Ink.muted).frame(width: 5, height: 5)
                                Text(model.connected ? VL.text("Подключён") : (model.savedDevice == nil ? VL.text("Устройство не выбрано") : VL.text("Готов к синхронизации"))).lineLimit(1)
                            }.font(.system(size: 10)).foregroundColor(Ink.secondary)
                            // Own row: the sidebar is too narrow to share one with the status text.
                            if let battery = sidebarBattery {
                                HStack(spacing: 4) {
                                    Image(systemName: batterySymbol(battery)).font(.system(size: 12))
                                    Text("\(battery)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                }.foregroundColor(batteryColor(battery))
                            }
                        } }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(model.destination == .device ? Ink.selection : Ink.surface).cornerRadius(8)
                }.buttonStyle(.plain).help(deviceCardHelp)
                    .accessibilityLabel(model.savedDevice?.model.displayName ?? VL.text("Подключить Plaud"))
                    .accessibilityValue(deviceCardValue)

        }.padding(.horizontal, compactSidebar ? 10 : 14).padding(.vertical, 16).background(Ink.sidebar)
    }
    /// Glanceable battery for the sidebar card; the last reported level stays (dimmed) between syncs.
    private var sidebarBattery: Int? { model.savedDevice == nil ? nil : model.battery }
    private var batteryLabel: String { model.connected ? VL.text("Заряд") : VL.text("Последний известный заряд") }
    private var deviceCardHelp: String {
        guard let battery = sidebarBattery else { return VL.text("Открыть Plaud") }
        return batteryLabel + " \(battery)%"
    }
    private var deviceCardValue: String {
        let state = model.connected ? VL.text("Подключён") : VL.text("Не подключён")
        guard let battery = sidebarBattery else { return state }
        return state + ", " + batteryLabel + " \(battery)%"
    }
    private func batterySymbol(_ level: Int) -> String {
        level >= 88 ? "battery.100percent" : level >= 63 ? "battery.75percent" : level >= 38 ? "battery.50percent" : level >= 13 ? "battery.25percent" : "battery.0percent"
    }
    private func batteryColor(_ level: Int) -> Color { level <= 15 ? Ink.error : model.connected ? Ink.text : Ink.muted }
    private var sidebarToggle: some View {
        Button { compactSidebar.toggle() } label: {
            Label(compactSidebar ? VL.text("Показать боковую панель") : VL.text("Скрыть боковую панель"), systemImage: "sidebar.left").labelStyle(.iconOnly)
        }.buttonStyle(.plain).vectaFocusStyle().foregroundColor(Ink.secondary).padding(4)
            .help(compactSidebar ? VL.text("Показать боковую панель") : VL.text("Скрыть боковую панель"))
    }
    private func nav(_ destination: NativeDestination, _ title: String, _ icon: String, count: Int? = nil) -> some View {
        Button {
            model.destination = destination
            if destination == .library { detail = false }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                if !compactSidebar {
                    Text(title); Spacer(minLength: 0)
                    if let count { Text("\(count)").font(.system(size: 11)).foregroundColor(Ink.muted) }
                }
            }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading).background(model.destination == destination ? Ink.selection : .clear).cornerRadius(7)
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
            .accessibilityValue(model.destination == destination ? VL.text("Выбрано") : VL.text("Не выбрано"))
            .accessibilityAddTraits(model.destination == destination ? [.isSelected] : [])
    }
    private var libraryActions: some View {
        HStack(spacing:8) {
            Button { showingRecordingTrash = true } label: { Label(VL.text("Корзина"), systemImage: "trash") }.buttonStyle(QuietButton()).help(VL.text("Удалённые записи")).accessibilityLabel(VL.text("Удалённые записи"))
            Button(VL.text("Импорт аудио…"),action:model.chooseAudioImport).buttonStyle(QuietButton()).disabled(model.library == nil || model.importingAudio)
            Button(action:model.refresh) {Label(model.savedDevice == nil ? VL.text("Подключить Plaud"):VL.text("Синхронизировать"),systemImage:"arrow.triangle.2.circlepath")}.buttonStyle(QuietButton(primary:true)).disabled(model.busy)
        }.fixedSize(horizontal:true,vertical:false)
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 22) {
            ViewThatFits(in:.horizontal) {
                HStack { ScreenTitle(title:VL.text("Все записи")); libraryActions }.fixedSize(horizontal:true,vertical:false)
                VStack(alignment:.leading,spacing:12) { ScreenTitle(title:VL.text("Все записи")); libraryActions }
            }
            if model.importingAudio { HStack {ProgressView().controlSize(.small);Text(VL.text("Проверяем и сохраняем аудиофайл…"));Button(VL.text("Отменить")) {model.importTask?.cancel()}.buttonStyle(QuietButton())} }
            HStack(spacing:10) {
                Image(systemName:"sparkles").foregroundColor(Ink.muted)
                TextField(VL.text("Спросите Vecta AI по всем вашим записям"),text:$model.search).textFieldStyle(.plain).focused($searchFocused).onSubmit(model.askLibraryQuestion)
                if !model.search.isEmpty || model.hasLibraryQuestion {
                    Button(action:model.clearLibraryQuestion) {Image(systemName:"xmark.circle.fill").foregroundColor(Ink.muted)}.buttonStyle(.plain).help(VL.text("Очистить вопрос и ответ")).accessibilityLabel(VL.text("Очистить вопрос и ответ"))
                }
                Button(action:model.askLibraryQuestion) {Image(systemName:"arrow.up").font(.system(size:12,weight:.semibold)).frame(width:28,height:28).background(Ink.text).foregroundColor(Ink.canvas).cornerRadius(7)}.buttonStyle(.plain).disabled(model.search.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.search.count>2000).help(VL.text("Спросить Vecta AI")).accessibilityLabel(VL.text("Спросить Vecta AI"))
            }.padding(12).background(Ink.surface).cornerRadius(9).frame(maxWidth:760)
            if let validation=VectaUX.questionValidation(model.search) {Text(validation).font(.system(size:11)).foregroundColor(Ink.secondary)}
            if !model.libraryIndexMessage.isEmpty {HStack {Text(model.libraryIndexMessage).font(.system(size:11)).foregroundColor(Ink.muted);if model.libraryAssetsMissing {Button(VL.text("Установить ресурсы поиска"),action:model.installLibrarySearchAssets).buttonStyle(.plain).font(.system(size:11))}}}
            if model.hasLibraryQuestion {
                NativeLibraryAIResults(model:model)
            } else {
                HStack {Text(VectaUX.recordings(model.items.count));Spacer();Menu(oldestFirst ? VL.text("Сначала старые"):VL.text("Сначала новые")) {Button(VL.text("Сначала новые")){oldestFirst=false};Button(VL.text("Сначала старые")){oldestFirst=true}}.menuStyle(.borderlessButton).fixedSize()}.font(.system(size:11)).foregroundColor(Ink.muted)
            }
            if model.hasLibraryQuestion {
                EmptyView()
            } else if model.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 30)).foregroundColor(Ink.muted)
                    Text(VL.text("Записей пока нет")).font(.system(size: 16, weight: .medium))
                    Text(VL.text("Подключите диктофон или импортируйте аудиофайл.")).foregroundColor(Ink.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.orderedItems(oldestFirst:oldestFirst)) { item in
                            Button { model.select(item.identity); detail = true } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "waveform").font(.system(size: 20)).frame(width: 42, height: 42).background(Ink.elevated).cornerRadius(8)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.title).font(.system(size: 16, weight: .medium)).lineLimit(1)
                                        HStack(spacing: 12) {
                                            Text(item.createdAt.vectaFormatted(date: .abbreviated, time: .shortened))
                                            if item.duration > 0 { Text(clock(item.duration)) }
                                            Text(item.audioURL == nil ? VL.text("На диктофоне") : VL.text("На Mac"))
                                        }.font(.system(size: 11)).foregroundColor(Ink.muted)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: item.audioURL == nil ? "arrow.down.circle" : "chevron.right").foregroundColor(Ink.muted)
                                }.padding(.vertical, 13).padding(.horizontal, 12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .contextMenu { Button(VL.text("Удалить запись"), role: .destructive) { deletingRecording = item }.disabled(!model.canDeleteRecording(item.identity)) }
                            .background(hovered == item.identity ? Ink.surface : .clear).cornerRadius(8).onHover { hovered = $0 ? item.identity : nil }
                            Rectangle().fill(Ink.border.opacity(0.7)).frame(height: 1).padding(.leading, 68)
                        }
                    }
                }
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

    }
}

struct NativeRecordingTrash: View {
    @ObservedObject var model: NativeMacModel
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: NativeDeletedRecording?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(VL.text("Удалённые записи")).font(.system(size: 22, weight: .semibold))
            Text(VL.text("Записи в корзине не появляются при синхронизации. Восстановление возвращает аудио, расшифровки и саммари; место на диске пока сохраняется.")).font(.system(size: 12)).foregroundColor(Ink.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.library?.deletedRecordings.isEmpty != false { Text(VL.text("Корзина пуста")).foregroundColor(Ink.secondary) }
                    ForEach((model.library?.deletedRecordings ?? []).sorted { $0.deletedAt > $1.deletedAt }) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) { Text(item.title).lineLimit(2); Text(item.deletedAt.vectaFormatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundColor(Ink.muted) }
                            Spacer()
                            Button(VL.text("Восстановить")) { model.restoreRecording(item.identity) }.buttonStyle(QuietButton()).disabled(model.busy || model.library?.purgedRecordings.contains(item.identity) == true)
                            Button(VL.text("Удалить навсегда"), role: .destructive) { deleting = item }
                                .buttonStyle(QuietButton()).disabled(!model.canPermanentlyDeleteRecording(item.identity))
                        }.padding(12).background(Ink.surface).cornerRadius(8)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button(VL.text("Готово")) { dismiss() }.buttonStyle(QuietButton(primary: true)).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 620, height: 420).background(Ink.canvas).foregroundColor(Ink.text)
        .alert(VL.text("Удалить запись навсегда?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(VL.text("Удалить навсегда"), role: .destructive) {
                if let item = deleting { model.permanentlyDeleteRecording(item.identity) }; deleting = nil
            }
            Button(VL.text("Отмена"), role: .cancel) { deleting = nil }
        } message: {
            Text((deleting?.title ?? "") + "\n\n" + VL.text("Аудио, расшифровки и саммари этой записи будут удалены из библиотеки Vecta на Mac без возможности восстановления. Оригинал на Plaud, внешние экспорты и резервные копии останутся."))
        }
    }
}

struct NativeTransferStrip: View {
    @ObservedObject var model: NativeMacModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.fastTransferPhase ?? model.transferProgress?.statusText ?? VL.text("Готовим копирование…")).font(.system(size: 12, weight: .medium))
                Spacer()
                if model.showsFastTransfer {
                    Button(action: model.requestFastTransfer) { Label("Fast transfer", systemImage: "wifi") }
                        .buttonStyle(QuietButton()).font(.system(size: 11))
                        .disabled(!model.canStartFastTransfer)
                        .help(model.canStartFastTransfer
                              ? VL.text("Передать записи через точку доступа PLAUD. Mac временно сменит Wi‑Fi-сеть.")
                              : VL.text("Fast transfer сейчас недоступен. Bluetooth-копирование продолжается."))
                }
                Button(VL.text("Отменить"), action: model.disconnect).buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Ink.secondary)
            }
            if let fraction = model.transferProgress?.fraction { ProgressView(value: fraction).tint(Ink.text) }
            else { ProgressView().controlSize(.small) }
            HStack {
                Text(model.transferProgress?.speedText ?? VL.text("Скорость: —")); Spacer()
                Text(model.transferProgress?.remainingText ?? VL.text("Осталось: —"))
            }.font(.system(size: 11)).foregroundColor(Ink.secondary)
        }.padding(14).background(Ink.surface).cornerRadius(8)
    }
}

/// A task-specific sheet. Choosing a recipe or model never starts inference.
struct NativeSummaryCreationSheet:View {
    @ObservedObject var model:NativeMacModel
    let recipes:[NativeSummaryRecipe]
    let initialID:String
    let create:(NativeSummaryRecipe,AISummaryModelID)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var choice=""
    @State private var selectedModel:AISummaryModelID = .qwen4b
    private var creationRecipes:[NativeSummaryRecipe] {NativeSummarySelection.creationRecipes(in: recipes)}
    private var selected:NativeSummaryRecipe? {creationRecipes.first {$0.id==choice}}
    private var readiness:String? {
        guard let host=model.localAI,host.supported else{return VL.text("Локальная обработка доступна с macOS 15.")}
        if !selectedModel.compatible() {return selectedModel.memoryRequirement}
        if host.statuses[selectedModel.rawValue]?.state != .installed {return VL.text("Модель «")+selectedModel.title+VL.text("» не установлена. Скачайте её в разделе «Локальный ИИ».")}
        if NativeSummarySelection.transcriptSource(model.analyses)==nil && !host.speechEngine.modelIDs().allSatisfy({host.statuses[$0]?.state == .installed}) {return VL.text("Для первой обработки установите модели распознавания.")}
        return nil
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(model.analysis?.summary == nil ? VL.text("Создать саммари"):VL.text("Новая версия саммари")).font(.system(size:22,weight:.semibold)).accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    ForEach(NativeSummaryPresentationCategory.allCases) { category in
                        let choices = creationRecipes.filter { $0.category == category }
                        if !choices.isEmpty {
                            Text(category.title).font(.system(size:12,weight:.semibold)).foregroundColor(Ink.secondary)
                            ForEach(choices) { recipe in recipeRow(recipe) }
                        }
                    }
                    Button(VL.text("Управлять форматами")) { dismiss(); model.destination = .formats }.buttonStyle(QuietButton())
                    Divider()
                    Text(VL.text("Модель ИИ · ")+selectedModel.selectionTitle+VL.text(". Общая для саммари, инфографики и ассистента.")).font(.system(size:12)).foregroundColor(Ink.secondary)
                    Text(model.localAI?.automaticSettings.visual == true ? VL.text("Визуальное саммари включено и будет создано автоматически."):VL.text("Визуальное саммари выключено в настройках.")).font(.system(size:11)).foregroundColor(Ink.muted)
                    Text(NativeSummarySelection.transcriptSource(model.analyses) != nil ? VL.text("На основе сохранённой расшифровки. Предыдущие версии сохранятся."):VL.text("Сначала распознаем речь и собеседников, затем создадим саммари.")).font(.system(size:11)).foregroundColor(Ink.muted)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            if let reason=readiness {
                Text(reason).font(.system(size:11)).foregroundColor(Ink.secondary).fixedSize(horizontal:false,vertical:true)
                Button(VL.text("Настройки моделей")) {dismiss();model.destination = .ai}.buttonStyle(QuietButton())
            }
            HStack {
                Spacer()
                Button(VL.text("Отмена")) {dismiss()}.keyboardShortcut(.cancelAction).buttonStyle(QuietButton())
                Button(VL.text("Создать саммари")) {if let selected {create(selected,selectedModel);dismiss()}}.keyboardShortcut(.defaultAction).buttonStyle(QuietButton(primary:true))
                    .disabled(selected==nil || readiness != nil || model.analysisBusy || model.visualRetryBusy)
            }
        }.padding(24).frame(width:480,height:500).background(Ink.canvas).foregroundColor(Ink.text)
        .onAppear {choice=NativeSummarySelection.selected(initialID,legacyFormat:nil,in:creationRecipes)?.id ?? "";selectedModel=model.localAI?.summaryModel ?? .qwen4b}
    }
    private func recipeRow(_ recipe:NativeSummaryRecipe)->some View {
        Button {choice=recipe.id} label: {
            HStack(alignment:.top,spacing:10) {
                Image(systemName:choice==recipe.id ? "largecircle.fill.circle":"circle").padding(.top,1)
                VStack(alignment:.leading,spacing:4) {
                    Text(recipe.title).font(.system(size:13,weight:.medium)).fixedSize(horizontal:false,vertical:true)
                    Text(recipe.detail).font(.system(size:11)).foregroundColor(Ink.secondary).lineLimit(2)
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.padding(10).background(choice==recipe.id ? Ink.elevated:Ink.surface).cornerRadius(7)
        }.buttonStyle(.plain).help(recipe.detail).accessibilityLabel(recipe.title).accessibilityValue(choice==recipe.id ? VL.text("Выбрано"):VL.text("Не выбрано")).accessibilityAddTraits(choice==recipe.id ? [.isSelected]:[])
    }
}

