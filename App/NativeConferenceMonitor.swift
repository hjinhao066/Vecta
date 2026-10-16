import AppKit
import Combine
import UserNotifications

/// Observes CoreAudio IO flags, not microphone samples or screen content.
/// Participant count is unknown for generic third-party clients; the strict
/// participant gate therefore always asks instead of guessing.
@MainActor final class NativeConferenceMonitor: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var suggestion: NativeConferenceActivity?
    @Published private(set) var message = ""
    private let preferences: NativeMacRecordingPreferences
    private let recorder: NativeMacRecorder
    private let startRecording: (NativeConferenceActivity) -> Void
    private let showConferences: () -> Void
    private let automaticRecordingAllowed: (NativeMacRecordingMode) -> Bool
    private var timer: Timer?
    private var changes: AnyCancellable?
    private var candidateSince: [String: Date] = [:]
    private var lastActive: [String: Date] = [:]
    private var offered = Set<String>()
    private var notificationID: String?
    private(set) var recordingActivity: NativeConferenceActivity?
    private var stopRequested = false
    private var suspended = false

    init(preferences: NativeMacRecordingPreferences, recorder: NativeMacRecorder,
         start: @escaping (NativeConferenceActivity) -> Void, show: @escaping () -> Void,
         automaticRecordingAllowed: @escaping (NativeMacRecordingMode) -> Bool = { NativeMacRecordingPolicy.canStartAutomatically(mode: $0) }) {
        self.preferences = preferences; self.recorder = recorder; startRecording = start; showConferences = show
        self.automaticRecordingAllowed = automaticRecordingAllowed
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(identifier: "VECTA_RECORD", title: VL.text("Начать запись"), options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "VECTA_CONFERENCE", actions: [action], intentIdentifiers: [], options: [])])
        changes = preferences.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func requestNotifications() {
        // Called only by the user's Enable-automation action.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] allowed, _ in
            Task { @MainActor in
                if !allowed { self?.message = VL.text("Уведомления выключены в macOS. Предложение записать встречу появится в разделе «Конференции».") }
            }
        }
    }
    func recordingStarted(for activity: NativeConferenceActivity?) {
        recordingActivity = activity; stopRequested = false
        if let activity { lastActive[activity.bundleID] = Date(); offered.insert(activity.bundleID) }
        dismissSuggestion()
    }
    func dismissSuggestion() {
        if let suggestion { offered.insert(suggestion.bundleID) }
        suggestion = nil
        if let notificationID { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID]) }
        notificationID = nil
    }
    func acceptSuggestion() {
        guard !recorder.busy, let suggestion else { return }
        let current = NativeConferenceActivity.read(allowed: [suggestion.bundleID]).first
        guard current?.audioActive == true else { dismissSuggestion(); return }
        // Clicking Start explicitly confirms this is a call with participants.
        startRecording(suggestion)
        dismissSuggestion()
    }
    func suspend() { suspended = true; dismissSuggestion() }
    func resume() { suspended = false; candidateSince.removeAll() }
    func shutdown() { suspended = true; timer?.invalidate(); timer = nil; dismissSuggestion() }
    private func refresh() {
        if !preferences.value.automaticStart { dismissSuggestion() }
    }
    private func tick() {
        guard !suspended else { return }
        let settings = preferences.value.validated
        guard settings.automaticStart || recordingActivity != nil else { return }
        var allowed = settings.mode == .application ? [settings.conferenceApplicationID].filter { !$0.isEmpty } : settings.enabledApplications
        if let recordingActivity, !allowed.contains(recordingActivity.bundleID) { allowed.append(recordingActivity.bundleID) }
        guard let activities = NativeConferenceActivity.snapshot(allowed: allowed) else {
            message = VL.text("Сведения об аудиоактивности недоступны. Автоматическая запись и автоостановка приостановлены; используйте ручное управление.")
            return
        }
        let now = Date()
        for activity in activities where activity.audioActive { lastActive[activity.bundleID] = now }
        if let recordingActivity {
            if recorder.phase == .idle { self.recordingActivity = nil; stopRequested = false }
            else if settings.automaticStop, !stopRequested,
                    now.timeIntervalSince(lastActive[recordingActivity.bundleID] ?? now) >= 45 {
                stopRequested = true
                Task { await recorder.stop() }
            }
        }
        for id in offered where now.timeIntervalSince(lastActive[id] ?? now) >= 60 {
            offered.remove(id); candidateSince[id] = nil
        }
        if let suggestion, now.timeIntervalSince(lastActive[suggestion.bundleID] ?? now) >= 45 { dismissSuggestion() }
        guard settings.automaticStart, !recorder.busy, suggestion == nil else { return }
        for activity in activities {
            guard activity.inputActive, activity.outputActive else { candidateSince[activity.bundleID] = nil; continue }
            if candidateSince[activity.bundleID] == nil { candidateSince[activity.bundleID] = now }
            guard !offered.contains(activity.bundleID), now.timeIntervalSince(candidateSince[activity.bundleID]!) >= 6 else { continue }
            offered.insert(activity.bundleID)
            switch activity.decision(automaticStart: settings.automaticStart, ask: settings.askBeforeRecording, requireParticipants: settings.onlyWithParticipants) {
            case .ignore: continue
            case .start:
                guard automaticRecordingAllowed(settings.mode) else {
                    suggestion = activity
                    message = VL.text("Автоматическая запись ожидает разрешений macOS. Нажмите «Начать запись», чтобы настроить доступ, или откройте системные настройки.")
                    return
                }
                startRecording(activity)
            case .ask:
                suggestion = activity
                let content = UNMutableNotificationContent()
                content.title = VL.text("Записать конференцию?")
                content.body = VL.text("В \(activity.application) активны микрофон и звук. Если собеседники присоединились, нажмите «Начать запись».")
                content.categoryIdentifier = "VECTA_CONFERENCE"
                let id = UUID().uuidString; notificationID = id
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
            }
            return
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            guard let self, response.notification.request.identifier == notificationID else { completionHandler(); return }
            showConferences()
            if response.actionIdentifier == "VECTA_RECORD" { acceptSuggestion() }
            completionHandler()
        }
    }
}
