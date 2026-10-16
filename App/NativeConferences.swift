import AppKit
import AVFoundation
import SwiftUI

enum NativeConferenceAnalysisSelection {
    /// Conference switches override only their existing processing options; the
    /// model and shared recipe selection remain the same as other new jobs.
    static func make(settings: NativeMacRecordingSettings, automaticSettings: AIAutomaticSettings,
                     formats: [VectaSummaryInterpretation], templates: [AISummaryTemplate]) throws
        -> (settings: AIAutomaticSettings, recipeSnapshot: NativeAnalysisQueue.RecipeSnapshot) {
        var processing = automaticSettings
        processing.visual = settings.automaticSummary && settings.automaticVisualSummary
        processing.conference = AIConferenceProcessingOptions(diarization: settings.automaticDiarization,
            recognizeKnownVoices: settings.automaticDiarization && settings.recognizeKnownVoices, summary: settings.automaticSummary)
        try processing.validate()
        let recipe = try NativeAnalysisQueue.RecipeSnapshot.selected(recipeID: processing.summaryRecipeID,
            formats: formats, templates: templates)
        return (processing, recipe)
    }
}

@MainActor extension NativeMacModel {
    func startMacRecording(_ mode: NativeMacRecordingMode, activity: NativeConferenceActivity? = nil) {
        #if VECTA_DEVELOPMENT
        guard !VectaRuntimePreferences.isVerification else { status = VL.text("Проверка интерфейса: захват звука отключён."); return }
        #endif
        guard let library, !importingAudio, purgingRecording == nil, !macRecorder.busy else { return }
        if playing { togglePlayback() }
        var settings = macRecordingPreferences.value.validated
        let applications = mode == .application ? [settings.conferenceApplicationID] : settings.enabledApplications
        let call = activity.flatMap { applications.contains($0.bundleID) ? $0 : nil }
            ?? NativeConferenceActivity.read(allowed: applications).first { $0.inputActive && $0.outputActive }
        let applicationName = mode == .application ? NativeMacAudioApplication.running().first { $0.id == settings.conferenceApplicationID }?.name : nil
        if mode == .application, applicationName == nil { status = NativeMacRecordingError.applicationUnavailable.localizedDescription; destination = .conferences; return }
        if settings.naming == "application" { settings.recordingTitle = applicationName ?? call?.application ?? "Mac" }
        if settings.naming == "meeting" { settings.recordingTitle = call?.availableMeetingTitle() ?? applicationName ?? call?.application ?? "Mac" }
        if settings.naming == "date" { settings.recordingTitle = "Mac" }
        conferenceMonitor?.recordingStarted(for: call)
        macRecorder.start(mode: mode, root: services.appendingPathComponent("MacRecordings", isDirectory: true), settings: settings) { [weak self] url in
            let identity = try await library.importAudio(url)
            guard let self, self.library === library else { return }
            if settings.openAfterSaving { destination = .library; select(identity) }
            status = VL.text("Аудиозапись сохранена на Mac")
            if settings.automaticTranscription {
                guard let queue = analysisQueue else {
                    status = VL.text("Запись сохранена. Настройте локальный ИИ, чтобы включить автоматическую обработку."); return
                }
                do {
                    loadWorkspace()
                    guard let root = (processingRoot ?? localAI?.root)?.standardizedFileURL, workspaceStateRoot == root else {
                        throw AIProcessingError.invalidRequest
                    }
                    let selection = try NativeConferenceAnalysisSelection.make(settings: settings,
                        automaticSettings: localAI?.automaticSettings ?? AIAutomaticSettings(), formats: formats, templates: workspace.templates)
                    try queue.append([identity], settings: selection.settings,
                        conferenceBundleID: settings.processAfterConference ? call?.bundleID : nil, recipeSnapshot: selection.recipeSnapshot)
                    batchCount = queue.jobs.count
                    batchMessage = VL.text("Конференция сохранена и добавлена в очередь локальной обработки.")
                } catch { status = VL.text("Аудио сохранено, но не удалось добавить обработку в очередь: ") + error.localizedDescription }
            }
        }
    }
}

struct NativeMacRecordingStrip: View {
    @ObservedObject var recorder: NativeMacRecorder
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle.fill").foregroundColor(Ink.error)
            Text(recorder.mode.title).font(.system(size: 12, weight: .medium))
            if recorder.phase == .recording {
                Text(String(format: "%02d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60)).monospacedDigit()
                Spacer()
                Button(VL.text("Остановить и сохранить запись")) { Task { await recorder.stop() } }.buttonStyle(QuietButton())
            } else {
                ProgressView().controlSize(.small)
                Text(recorder.phase == .starting ? VL.text("Ожидание разрешения macOS…") : VL.text("Сохраняем аудиозапись…"))
                Spacer()
            }
        }.font(.system(size: 12)).padding(12).background(Ink.surface).cornerRadius(8)
    }
}

struct NativeConferencesScreen: View {
    @ObservedObject var model: NativeMacModel
    @ObservedObject var recorder: NativeMacRecorder
    @ObservedObject var preferences: NativeMacRecordingPreferences
    init(model: NativeMacModel) {
        self.model = model; recorder = model.macRecorder; preferences = model.macRecordingPreferences
    }
    @State private var microphones: [AVCaptureDevice] = []
    @State private var applications: [NativeMacAudioApplication] = []
    private var elapsed: String {
        let seconds = Int(recorder.elapsed)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ScreenTitle(title: VL.text("Конференции"), subtitle: VL.text("Запись встреч и голоса с Mac. Только локально, без облака."))
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label(recorder.busy ? VL.text("Запись с Mac") : VL.text("Новая запись"), systemImage: "waveform.circle")
                            .font(.system(size: 18, weight: .semibold))
                        Spacer()
                        if recorder.phase == .recording { Text(elapsed).monospacedDigit().foregroundColor(Ink.error) }
                    }
                    Picker(VL.text("Источник звука"), selection: $preferences.value.mode) {
                        ForEach(NativeMacRecordingMode.allCases, id: \.rawValue) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.menu).disabled(recorder.busy)
                    if preferences.value.mode == .application {
                        HStack {
                            Picker(VL.text("Приложение конференции"), selection: $preferences.value.conferenceApplicationID) {
                                Text(VL.text("Выберите приложение…")).tag("")
                                ForEach(applications) { app in Text(app.name).tag(app.id) }
                                if !preferences.value.conferenceApplicationID.isEmpty, !applications.contains(where: { $0.id == preferences.value.conferenceApplicationID }) {
                                    Text(VL.text("Выбранное приложение недоступно")).tag(preferences.value.conferenceApplicationID)
                                }
                            }.disabled(recorder.busy)
                            Button { applications = NativeMacAudioApplication.running() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.plain).help(VL.text("Обновить список приложений")).disabled(recorder.busy)
                        }
                        Text(VL.text("Записываются микрофон и звук только выбранного приложения. Если выбрать браузер, будут слышны все его вкладки: изоляция отдельной вкладки пока не поддерживается."))
                            .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                    }
                    if preferences.value.mode.needsMicrophone {
                        HStack {
                            Picker(VL.text("Микрофон"), selection: $preferences.value.microphoneID) {
                                Text(VL.text("Микрофон по умолчанию macOS")).tag("")
                                ForEach(microphones, id: \.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
                                if !preferences.value.microphoneID.isEmpty, !microphones.contains(where: { $0.uniqueID == preferences.value.microphoneID }) {
                                    Text(VL.text("Выбранный микрофон недоступен")).tag(preferences.value.microphoneID)
                                }
                            }.disabled(recorder.busy)
                            Button { microphones = NativeMicrophoneCapture.devices() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.plain).help(VL.text("Обновить список микрофонов")).disabled(recorder.busy)
                        }
                    }
                    if preferences.value.mode != .application {
                        Text(VL.text("Для совещаний выберите системный звук и микрофон: будут слышны собеседники и ваш голос. Системный звук включает другие приложения Mac; звук самой Vecta по умолчанию исключён."))
                            .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                    }
                    HStack(spacing: 12) {
                        if recorder.phase == .recording {
                            Button(VL.text("Остановить и сохранить запись")) { Task { await recorder.stop() } }.buttonStyle(QuietButton(primary: true))
                            Text(recorder.mode.title).font(.system(size: 12)).foregroundColor(Ink.secondary)
                        } else if recorder.phase == .starting {
                            ProgressView().controlSize(.small)
                            Text(VL.text("Ожидание разрешения macOS…")).foregroundColor(Ink.secondary)
                            Button(VL.text("Отмена")) { Task { await recorder.stop() } }.buttonStyle(QuietButton())
                        } else if recorder.phase == .saving {
                            ProgressView().controlSize(.small)
                            Text(VL.text("Сохраняем аудиозапись…")).foregroundColor(Ink.secondary)
                        } else {
                            Button(VL.text("Начать запись")) { model.startMacRecording(preferences.value.mode) }
                                .buttonStyle(QuietButton(primary: true)).disabled(model.library == nil || model.importingAudio || model.purgingRecording != nil || (preferences.value.mode == .application && !applications.contains(where: { $0.id == preferences.value.conferenceApplicationID })))
                        }
                    }
                    if !recorder.message.isEmpty { Text(recorder.message).font(.system(size: 12)).foregroundColor(Ink.secondary).textSelection(.enabled) }
                    if model.library == nil { Text(VL.text("Сначала откройте библиотеку Vecta.")).font(.system(size: 12)).foregroundColor(Ink.secondary) }
                }.padding(20).background(Ink.surface).cornerRadius(9)

                NativeConferenceAutomationSettings(model: model, preferences: preferences)
                NativeConferenceProcessingSettings(model: model, preferences: preferences)
                VStack(alignment: .leading, spacing: 16) {
                    Text(VL.text("Параметры записи")).font(.system(size: 18, weight: .semibold))
                    Picker(VL.text("Название записи"), selection: $preferences.value.naming) {
                        Text(VL.text("Приложение и дата")).tag("application")
                        Text(VL.text("Название встречи, если доступно")).tag("meeting")
                        Text(VL.text("Дата и время")).tag("date")
                        Text(VL.text("Своё название")).tag("custom")
                    }
                    Text(VL.text("Название встречи берётся из заголовка окна только если macOS уже разрешает его прочитать. Иначе используются приложение и дата. Доступ к экрану ради названия отдельно не запрашивается."))
                        .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                    HStack {
                        Text(VL.text("Своё название")); Spacer()
                        TextField("Mac", text: $preferences.value.recordingTitle).textFieldStyle(.roundedBorder).frame(width: 260).disabled(preferences.value.naming != "custom")
                    }
                    HStack {
                        Text(VL.text("Качество аудио")); Spacer()
                        Picker(VL.text("Качество аудио"), selection: $preferences.value.bitrate) {
                            Text("64 kbps").tag(64_000); Text("128 kbps").tag(128_000); Text("192 kbps").tag(192_000)
                        }.labelsHidden().frame(width: 200)
                    }
                    HStack {
                        Text(VL.text("Автоостановка")); Spacer()
                        Picker(VL.text("Автоостановка"), selection: $preferences.value.maximumMinutes) {
                            ForEach([15, 30, 60, 120, 180, 360], id: \.self) { minutes in Text(VL.text("Через \(minutes) мин")).tag(minutes) }
                        }.labelsHidden().frame(width: 200)
                    }
                    Toggle(VL.text("Включать звук воспроизведения Vecta"), isOn: $preferences.value.includeVectaAudio).toggleStyle(.checkbox)
                    Toggle(VL.text("Открывать запись после сохранения"), isOn: $preferences.value.openAfterSaving).toggleStyle(.checkbox)
                    Text(VL.text("Аудио сохраняется в M4A (AAC) в текущую библиотеку Vecta. Видео не записывается. Расшифровку и саммари можно запустить на экране сохранённой записи."))
                        .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                }.disabled(recorder.busy).padding(20).background(Ink.surface).cornerRadius(9)

                VStack(alignment: .leading, spacing: 14) {
                    Text(VL.text("Строка меню")).font(.system(size: 18, weight: .semibold))
                    Toggle(VL.text("Показывать значок Vecta в строке меню"), isOn: $preferences.value.showMenuIcon).toggleStyle(.checkbox)
                    Toggle(VL.text("Показывать время записи рядом со значком"), isOn: $preferences.value.showElapsed).toggleStyle(.checkbox)
                        .disabled(!preferences.value.showMenuIcon)
                    Text(VL.text("Если скрыть значок, записью можно управлять здесь. Закрытие окна следует настройке «Работать в фоновом режиме»: если она выключена, Vecta завершает работу; выход из приложения останавливает и сохраняет запись."))
                        .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                }.padding(20).background(Ink.surface).cornerRadius(9)

                VStack(alignment: .leading, spacing: 14) {
                    Text(VL.text("Доступ и безопасность")).font(.system(size: 18, weight: .semibold))
                    Text(VL.text("Открытие этой страницы не запрашивает доступ и не начинает захват. Доступ к микрофону запрашивается только при явном запуске записи, если он нужен выбранному источнику. ScreenCaptureKit проверяет разрешение на системный звук только при явном «Начать запись» или отдельно включённом автоматическом запуске конференции. Настройка не начинает запись; уведомления запрашиваются только отдельным явным действием. Видео не сохраняется. Убедитесь, что участники согласны на запись."))
                        .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                    HStack {
                        Button(VL.text("Разрешения микрофона")) { openSettings("Privacy_Microphone") }.buttonStyle(QuietButton())
                        Button(VL.text("Разрешения системного аудио")) { openSettings("Privacy_ScreenCapture") }.buttonStyle(QuietButton())
                    }
                    HStack {
                        Button(VL.text("Настройки звука macOS")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
                        }.buttonStyle(QuietButton())
                        Button(VL.text("Несохранённые записи…")) {
                            let root = model.services.appendingPathComponent("MacRecordings", isDirectory: true)
                            if FileManager.default.fileExists(atPath: root.path) { NSWorkspace.shared.open(root) }
                        }.buttonStyle(QuietButton())
                    }
                    Text(VL.text("При нехватке места, переходе Mac в сон или выходе запись останавливается. Если сохранение не удалось, исходные дорожки остаются для восстановления."))
                        .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                }.padding(20).background(Ink.surface).cornerRadius(9)
            }.frame(maxWidth: 800, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .topLeading)
        }.task {
            model.loadWorkspace()
            microphones = NativeMicrophoneCapture.devices()
            applications = NativeMacAudioApplication.running()
        }
    }
    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
}
