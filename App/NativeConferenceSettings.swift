import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeConferenceAutomationSettings: View {
    @ObservedObject var model: NativeMacModel
    @ObservedObject var preferences: NativeMacRecordingPreferences
    @State private var confirmingAutomaticRecording = false
    @State private var showingApplications = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(VL.text("Автоматизация конференций")).font(.system(size: 18, weight: .semibold))
            Toggle(VL.text("Автоматически начинать запись"), isOn: Binding(get: { preferences.value.automaticStart }, set: { enabled in
                if enabled { confirmingAutomaticRecording = true } else { preferences.value.automaticStart = false }
            })).toggleStyle(.checkbox)
            Toggle(VL.text("Автоматически останавливать запись"), isOn: $preferences.value.automaticStop).toggleStyle(.checkbox)
            Toggle(VL.text("Спрашивать перед записью"), isOn: $preferences.value.askBeforeRecording).toggleStyle(.checkbox)
            Toggle(VL.text("Записывать только при наличии собеседников"), isOn: $preferences.value.onlyWithParticipants).toggleStyle(.checkbox)
            Text(VL.text("Просто открытый Zoom, Телемост или браузер не запускает запись. Vecta ищет одновременную активность микрофона и вывода звука выбранных приложений. Это признак возможного звонка, а не гарантированное обнаружение конференции."))
                .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
            Text(VL.text("macOS не сообщает число участников сторонних звонков. Если оно неизвестно, режим «только при наличии собеседников» всегда требует вашего подтверждения, даже если «Спрашивать перед записью» выключено."))
                .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
            Text(VL.text("Автоостановка срабатывает через 45 секунд после прекращения аудиоактивности приложения. Длительное отключение звука может выглядеть как окончание звонка, а воспроизведение музыки — продлить запись. Кнопка остановки всегда доступна."))
                .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
            DisclosureGroup(VL.text("Приложения для обнаружения звонков"), isExpanded: $showingApplications) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(applicationIDs, id: \.self) { id in
                        Toggle(applicationName(id), isOn: Binding(get: { preferences.value.enabledApplications.contains(id) }, set: { enabled in
                            if enabled { preferences.value.enabledApplications.append(id) }
                            else { preferences.value.enabledApplications.removeAll { $0 == id } }
                        })).toggleStyle(.checkbox)
                    }
                    Button(VL.text("Добавить приложение…"), action: chooseApplication).buttonStyle(QuietButton())
                }.padding(.top, 10)
            }
            if let monitor = model.conferenceMonitor { NativeConferenceSuggestion(monitor: monitor) }
        }.padding(20).background(Ink.surface).cornerRadius(9)
        .alert(VL.text("Разрешить автоматизацию записи?"), isPresented: $confirmingAutomaticRecording) {
            Button(VL.text("Включить автоматизацию")) {
                preferences.value.automaticStart = true
                model.conferenceMonitor?.requestNotifications()
            }
            Button(VL.text("Отмена"), role: .cancel) {}
        } message: {
            Text(VL.text("При включённых подтверждениях Vecta предложит запись уведомлением. Если выключить и подтверждение, и проверку собеседников, запись будет запускаться автоматически по признакам аудиоактивности. Такой режим может ошибаться. Убедитесь, что участники согласны на запись."))
        }
    }
    private var applicationIDs: [String] {
        Array(Set(NativeConferenceActivity.applications.map(\.id) + preferences.value.enabledApplications)).sorted { applicationName($0) < applicationName($1) }
    }
    private func applicationName(_ id: String) -> String {
        NativeConferenceActivity.applications.first(where: { $0.id == id })?.name ??
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id
    }
    private func chooseApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
            if !preferences.value.enabledApplications.contains(id) { preferences.value.enabledApplications.append(id) }
        }
    }
}

private struct NativeConferenceSuggestion: View {
    @ObservedObject var monitor: NativeConferenceMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let activity = monitor.suggestion {
                Text(VL.text("Возможная конференция: \(activity.application)")).font(.system(size: 14, weight: .medium))
                Text(VL.text("Собеседники уже присоединились? Нажмите «Начать запись», чтобы подтвердить и записывать звук."))
                    .font(.system(size: 12)).foregroundColor(Ink.secondary)
                HStack {
                    Button(VL.text("Начать запись")) { monitor.acceptSuggestion() }.buttonStyle(QuietButton(primary: true))
                    Button(VL.text("Не сейчас")) { monitor.dismissSuggestion() }.buttonStyle(QuietButton())
                }
            }
            if !monitor.message.isEmpty { Text(monitor.message).font(.system(size: 12)).foregroundColor(Ink.secondary) }
        }
    }
}

struct NativeConferenceProcessingSettings: View {
    @ObservedObject var model: NativeMacModel
    @ObservedObject var preferences: NativeMacRecordingPreferences
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(VL.text("Обработка после конференции")).font(.system(size: 18, weight: .semibold))
            Toggle(VL.text("Автоматическая транскрипция"), isOn: $preferences.value.automaticTranscription).toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 14) {
                Toggle(VL.text("Автоматическая диаризация"), isOn: $preferences.value.automaticDiarization).toggleStyle(.checkbox)
                Toggle(VL.text("Распознавание знакомых голосов"), isOn: $preferences.value.recognizeKnownVoices).toggleStyle(.checkbox)
                    .disabled(!preferences.value.automaticDiarization)
                Text(VL.text("Диаризация разделяет речь по голосам. Знакомые голоса сравниваются с вашей библиотекой собеседников; найденные имена остаются предположениями до вашего подтверждения."))
                    .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                Toggle(VL.text("Автоматическое саммари"), isOn: $preferences.value.automaticSummary).toggleStyle(.checkbox)
                NativeAutomaticRecipePicker(model: model)
                    .disabled(!preferences.value.automaticSummary)
                Text(VL.text("Общий формат с автоматической обработкой в Настройках. Изменение здесь меняет тот же формат после синхронизации; ручной выбор хранится отдельно.")).font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
                Toggle(VL.text("Автоматическое визуальное саммари"), isOn: $preferences.value.automaticVisualSummary).toggleStyle(.checkbox)
                    .disabled(!preferences.value.automaticSummary)
                Toggle(VL.text("Отложенная обработка — только после завершения конференции"), isOn: $preferences.value.processAfterConference).toggleStyle(.checkbox)
                Text(VL.text("Если остановить запись раньше окончания звонка, отложенное задание дождётся прекращения аудиоактивности приложения. Если выключить этот режим, обработка начнётся после сохранения записи, даже когда звонок продолжается. Незавершённое аудио не обрабатывается."))
                    .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
            }.disabled(!preferences.value.automaticTranscription)
            Text(VL.text("Настройки записи применяются к новым записям. Формат саммари фиксируется при добавлении задания в очередь. Готовые результаты не перезаписываются. Всё выполняется на Mac; отсутствующие модели нужно установить вручную."))
                .font(.system(size: 12)).foregroundColor(Ink.secondary).lineSpacing(4)
            if let job = model.analysisQueue?.jobs.first, job.conferenceBundleID != nil, job.requestID == nil {
                Button(VL.text("Обработать сохранённую конференцию сейчас")) {
                    do { try model.analysisQueue?.releaseConferenceWait(job.identity); model.conferenceQuietSince[job.identity] = nil; model.batchMessage = VL.text("Конференция готова к локальной обработке.") }
                    catch { model.batchMessage = error.localizedDescription }
                }.buttonStyle(QuietButton()).disabled(model.purgingRecording != nil)
            }
            Button(VL.text("Настроить модели")) { model.destination = .ai }.buttonStyle(QuietButton())
        }.padding(20).background(Ink.surface).cornerRadius(9)
        .onAppear { model.loadWorkspace() }
        .onChange(of: model.processingRoot ?? model.localAI?.root) { _ in model.loadWorkspace() }
    }
}
