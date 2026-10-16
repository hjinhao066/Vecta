import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

// Permission preparation is separate from capture; only Start opens audio sources.
enum NativeMacRecordingMode: Int, CaseIterable, Codable {
    case system, microphone, meeting, application
    var title: String {
        switch self {
        case .system: return VL.text("Системный звук")
        case .microphone: return VL.text("Микрофон Mac")
        case .meeting: return VL.text("Системный звук + микрофон")
        case .application: return VL.text("Микрофон + приложение")
        }
    }
    var needsMicrophone: Bool { self != .system }
    var symbol: String {
        switch self {
        case .system: return "speaker.wave.2"
        case .microphone: return "mic"
        case .meeting: return "person.2.wave.2"
        case .application: return "app"
        }
    }
}

struct NativeMacAudioApplication: Identifiable, Equatable {
    let id: String
    let name: String
    static func captureApplications(from applications: [SCRunningApplication], bundleID: String) throws -> [SCRunningApplication] {
        let selected = applications.filter { $0.bundleIdentifier == bundleID && $0.bundleIdentifier != "app.vecta.mac" }
        guard !bundleID.isEmpty, !selected.isEmpty else { throw NativeMacRecordingError.applicationUnavailable }
        return selected
    }
    static func running() -> [Self] {
        var applications: [String: Self] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, id != "app.vecta.mac" else { continue }
            applications[id] = Self(id: id, name: app.localizedName ?? id)
        }
        return applications.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct NativeMacRecordingSettings: Codable, Equatable {
    var mode: NativeMacRecordingMode = .meeting
    var showMenuIcon = true
    var showElapsed = true
    var includeVectaAudio = false
    var openAfterSaving = true
    var bitrate = 128_000
    var maximumMinutes = 180
    var recordingTitle = "Mac"
    var microphoneID = ""
    var conferenceApplicationID = ""
    var automaticStart = true
    var automaticStop = true
    var askBeforeRecording = true
    var onlyWithParticipants = true
    var enabledApplications = NativeConferenceActivity.applications.map(\.id)
    var naming = "application"
    var automaticTranscription = true
    var automaticDiarization = true
    var recognizeKnownVoices = false
    var automaticSummary = true
    var automaticVisualSummary = true
    var processAfterConference = true

    init() {}
    private enum CodingKeys: String, CodingKey { case mode, showMenuIcon, showElapsed, includeVectaAudio, openAfterSaving, bitrate, maximumMinutes, recordingTitle, microphoneID, conferenceApplicationID, automaticStart, automaticStop, askBeforeRecording, onlyWithParticipants, enabledApplications, naming, automaticTranscription, automaticDiarization, recognizeKnownVoices, automaticSummary, automaticVisualSummary, processAfterConference }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var value = Self()
        value.mode = try values.decodeIfPresent(NativeMacRecordingMode.self, forKey: .mode) ?? value.mode
        value.showMenuIcon = try values.decodeIfPresent(Bool.self, forKey: .showMenuIcon) ?? value.showMenuIcon
        value.showElapsed = try values.decodeIfPresent(Bool.self, forKey: .showElapsed) ?? value.showElapsed
        value.includeVectaAudio = try values.decodeIfPresent(Bool.self, forKey: .includeVectaAudio) ?? value.includeVectaAudio
        value.openAfterSaving = try values.decodeIfPresent(Bool.self, forKey: .openAfterSaving) ?? value.openAfterSaving
        value.bitrate = try values.decodeIfPresent(Int.self, forKey: .bitrate) ?? value.bitrate
        value.maximumMinutes = try values.decodeIfPresent(Int.self, forKey: .maximumMinutes) ?? value.maximumMinutes
        value.recordingTitle = try values.decodeIfPresent(String.self, forKey: .recordingTitle) ?? value.recordingTitle
        value.microphoneID = try values.decodeIfPresent(String.self, forKey: .microphoneID) ?? value.microphoneID
        value.conferenceApplicationID = try values.decodeIfPresent(String.self, forKey: .conferenceApplicationID) ?? value.conferenceApplicationID
        value.automaticStart = try values.decodeIfPresent(Bool.self, forKey: .automaticStart) ?? value.automaticStart
        value.automaticStop = try values.decodeIfPresent(Bool.self, forKey: .automaticStop) ?? value.automaticStop
        value.askBeforeRecording = try values.decodeIfPresent(Bool.self, forKey: .askBeforeRecording) ?? value.askBeforeRecording
        value.onlyWithParticipants = try values.decodeIfPresent(Bool.self, forKey: .onlyWithParticipants) ?? value.onlyWithParticipants
        value.enabledApplications = try values.decodeIfPresent([String].self, forKey: .enabledApplications) ?? value.enabledApplications
        value.naming = try values.decodeIfPresent(String.self, forKey: .naming) ?? value.naming
        value.automaticTranscription = try values.decodeIfPresent(Bool.self, forKey: .automaticTranscription) ?? value.automaticTranscription
        value.automaticDiarization = try values.decodeIfPresent(Bool.self, forKey: .automaticDiarization) ?? value.automaticDiarization
        value.recognizeKnownVoices = try values.decodeIfPresent(Bool.self, forKey: .recognizeKnownVoices) ?? value.recognizeKnownVoices
        value.automaticSummary = try values.decodeIfPresent(Bool.self, forKey: .automaticSummary) ?? value.automaticSummary
        value.automaticVisualSummary = try values.decodeIfPresent(Bool.self, forKey: .automaticVisualSummary) ?? value.automaticVisualSummary
        value.processAfterConference = try values.decodeIfPresent(Bool.self, forKey: .processAfterConference) ?? value.processAfterConference
        self = value.validated
    }
    var validated: Self {
        var value = self
        if ![64_000, 128_000, 192_000].contains(value.bitrate) { value.bitrate = 128_000 }
        if ![15, 30, 60, 120, 180, 360].contains(value.maximumMinutes) { value.maximumMinutes = 180 }
        value.recordingTitle = String(value.recordingTitle.prefix(100))
        if value.conferenceApplicationID.count > 255 || value.conferenceApplicationID == "app.vecta.mac" || value.conferenceApplicationID.contains(where: { $0.isWhitespace || $0.isNewline }) { value.conferenceApplicationID = "" }
        if !["custom", "application", "meeting", "date"].contains(value.naming) { value.naming = "application" }
        value.enabledApplications = Array(Set(value.enabledApplications.filter { !$0.isEmpty && $0.count < 256 && $0 != "app.vecta.mac" })).sorted()
        return value
    }
    var safeTitle: String {
        let title = recordingTitle.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\0")).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title.hasPrefix(".") ? "Mac" : String(title.prefix(100))
    }
}

@MainActor final class NativeMacRecordingPreferences: ObservableObject {
    private let defaults: UserDefaults
    private let key = "Vecta.macRecording.settings.v1"
    @Published var value: NativeMacRecordingSettings {
        didSet { if let data = try? JSONEncoder().encode(value.validated) { defaults.set(data, forKey: key) } }
    }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        value = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(NativeMacRecordingSettings.self, from: $0) }?.validated ?? .init()
    }
}

enum NativeMacRecordingError: LocalizedError {
    case microphonePermission, microphoneUnavailable, applicationUnavailable, systemPermission, unavailable, noAudio, storage, encoding
    var errorDescription: String? {
        switch self {
        case .microphonePermission: return VL.text("Разрешите Vecta доступ к микрофону в Системных настройках → Конфиденциальность и безопасность → Микрофон.")
        case .microphoneUnavailable: return VL.text("Выбранный микрофон недоступен. Подключите его или выберите другое устройство.")
        case .applicationUnavailable: return VL.text("Выберите запущенное приложение в разделе «Конференции». Если оно закрылось, запись не переключается на весь системный звук.")
        case .systemPermission: return VL.text("Разрешите Vecta запись системного аудио в Системных настройках → Конфиденциальность и безопасность → Запись экрана и системного аудио. Видео не записывается.")
        case .unavailable: return VL.text("Запись системного звука требует macOS 15 или новее и доступного дисплея.")
        case .noAudio: return VL.text("Аудио не получено. Проверьте источник звука и разрешения macOS.")
        case .storage: return VL.text("Недостаточно места для записи. Освободите место на диске.")
        case .encoding: return VL.text("Не удалось сохранить аудио полностью. Исходные дорожки оставлены в папке несохранённых записей.")
        }
    }
}

enum NativeMacMicrophoneAuthorization {
    static func requestIfNeeded(status: () -> AVAuthorizationStatus,
                                request: () async -> Bool) async -> Bool {
        switch status() {
        case .authorized:
            return true
        case .notDetermined:
            return await request()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

enum NativeMacRecordingPolicy {
    static func canStartAutomatically(mode: NativeMacRecordingMode,
                                      microphoneStatus: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
                                      screenCaptureAllowed: () -> Bool = { CGPreflightScreenCaptureAccess() }) -> Bool {
        if mode.needsMicrophone, microphoneStatus() != .authorized { return false }
        return mode == .microphone || screenCaptureAllowed()
    }
    static let maximumDuration: TimeInterval = 21_600
    static func hasSpace(_ root: URL, starting: Bool) -> Bool {
        guard let free = try? (FileManager.default.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else { return false }
        return free >= (starting ? 256 : 64) * 1_048_576
    }
}

struct NativeCapturedTrack {
    let url: URL
    let start: CMTime
}

/// Serial sample queue owns the writers. Only audio outputs are registered;
/// ScreenCaptureKit video frames are neither requested as outputs nor saved.
@available(macOS 13.0, *)
final class NativeSystemAudioSink: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.vecta.mac-audio", qos: .userInitiated)
    let directory: URL
    let bitrate: Int
    var onFailure: (() -> Void)?
    private struct Track {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let start: CMTime
        let url: URL
    }
    private var tracks: [Int: Track] = [:]
    private var failure: Error?
    private var ending = false
    init(directory: URL, bitrate: Int = 128_000) { self.directory = directory; self.bitrate = bitrate }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        append(sampleBuffer, source: type.rawValue)
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        append(sampleBuffer, source: 2)
    }
    // Also used by the synthetic executable check; never opens a capture source.
    func append(_ buffer: CMSampleBuffer, source: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !ending, failure == nil, CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer) else { return }
        do {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  (1...2).contains(asbd.mChannelsPerFrame), asbd.mSampleRate > 0 else { throw NativeMacRecordingError.encoding }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard pts.isValid, pts.isNumeric else { throw NativeMacRecordingError.encoding }
            if tracks[source] == nil {
                let url = directory.appendingPathComponent("track-\(source).m4a")
                let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: asbd.mSampleRate,
                    AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame), AVEncoderBitRateKey: bitrate
                ], sourceFormatHint: format)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw NativeMacRecordingError.encoding }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? NativeMacRecordingError.encoding }
                writer.startSession(atSourceTime: pts)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                tracks[source] = Track(writer: writer, input: input, start: pts, url: url)
            }
            guard let track = tracks[source], track.input.isReadyForMoreMediaData,
                  track.input.append(buffer) else { throw NativeMacRecordingError.encoding }
        } catch { failure = error; onFailure?() }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?() }
    func finish() async throws -> [NativeCapturedTrack] {
        let values: [Track] = await withCheckedContinuation { continuation in
            queue.async {
                self.ending = true
                let values = Array(self.tracks.values)
                values.filter { $0.writer.status == .writing }.forEach { $0.input.markAsFinished() }
                continuation.resume(returning: values)
            }
        }
        for track in values {
            if track.writer.status == .writing { await track.writer.finishWriting() }
            guard track.writer.status == .completed else { throw track.writer.error ?? NativeMacRecordingError.encoding }
        }
        if let failure { throw failure }
        guard !values.isEmpty else { throw NativeMacRecordingError.noAudio }
        return values.map { .init(url: $0.url, start: $0.start) }
    }
}

enum NativeMacAudioMix {
    static func export(_ tracks: [NativeCapturedTrack], to output: URL) async throws {
        guard output.isFileURL, !FileManager.default.fileExists(atPath: output.path) else { throw NativeMacRecordingError.encoding }
        guard let origin = tracks.map(\.start).min(by: { CMTimeCompare($0, $1) < 0 }) else { throw NativeMacRecordingError.noAudio }
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        for source in tracks {
            let asset = AVURLAsset(url: source.url)
            guard let audio = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw NativeMacRecordingError.noAudio }
            let range = try await audio.load(.timeRange)
            guard range.duration.seconds > 0, range.duration.seconds.isFinite else { throw NativeMacRecordingError.noAudio }
            let offset = CMTimeSubtract(source.start, origin)
            try target.insertTimeRange(range, of: audio, at: offset)
            let parameter = AVMutableAudioMixInputParameters(track: target)
            parameter.setVolume(tracks.count > 1 ? 0.5 : 1, at: .zero)
            parameters.append(parameter)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw NativeMacRecordingError.encoding }
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters; session.audioMix = mix
        session.outputURL = output; session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else { throw session.error ?? NativeMacRecordingError.encoding }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
}

@MainActor final class NativeMacRecorder: NSObject, ObservableObject {
    enum Phase { case idle, starting, recording, saving }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var mode: NativeMacRecordingMode = .microphone
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var message = ""
    var busy: Bool { phase != .idle }
    private var microphone: NativeMicrophoneCapture?
    private var stream: SCStream?
    private var sink: NativeSystemAudioSink?
    private var directory: URL?
    private var timer: Timer?
    private var started: TimeInterval = 0
    private var startTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var publish: ((URL) async throws -> Void)?
    private var sourceFailed = false
    private var captureID = UUID()
    private var recordingTitle = "Mac"

    func start(mode: NativeMacRecordingMode, root: URL, settings: NativeMacRecordingSettings = .init(), publish: @escaping (URL) async throws -> Void) {
        guard !busy else { return }
        phase = .starting; self.mode = mode; message = ""; elapsed = 0; sourceFailed = false
        let settings = settings.validated
        recordingTitle = settings.safeTitle
        self.publish = publish; captureID = UUID()
        let attempt = captureID
        startTask = Task { [self] in
            do {
                if mode.needsMicrophone {
                    let allowed = await NativeMacMicrophoneAuthorization.requestIfNeeded(
                        status: { AVCaptureDevice.authorizationStatus(for: .audio) },
                        request: { await AVCaptureDevice.requestAccess(for: .audio) })
                    try Task.checkCancellation()
                    guard allowed else { throw NativeMacRecordingError.microphonePermission }
                }
                var content: SCShareableContent?
                if mode != .microphone {
                    guard #available(macOS 15.0, *) else { throw NativeMacRecordingError.unavailable }
                    do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
                    catch { throw NativeMacRecordingError.systemPermission }
                    try Task.checkCancellation()
                }
                guard NativeMacRecordingPolicy.hasSpace(root, starting: true) else { throw NativeMacRecordingError.storage }
                let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                self.directory = directory
                if mode == .microphone {
                    let sink = NativeSystemAudioSink(directory: directory, bitrate: settings.bitrate)
                    sink.onFailure = { [weak self] in Task { @MainActor in
                        guard let self, self.captureID == attempt else { return }; self.captureFailed()
                    } }
                    let microphone = NativeMicrophoneCapture(sink: sink)
                    self.sink = sink; self.microphone = microphone
                    try await microphone.start(deviceID: settings.microphoneID)
                    try Task.checkCancellation()
                } else if #available(macOS 15.0, *), let display = content?.displays.first {
                    let config = SCStreamConfiguration()
                    config.capturesAudio = true; config.sampleRate = 48_000; config.channelCount = 2
                    config.excludesCurrentProcessAudio = !settings.includeVectaAudio; config.captureMicrophone = mode.needsMicrophone
                    if mode.needsMicrophone, !settings.microphoneID.isEmpty {
                        guard NativeMicrophoneCapture.devices().contains(where: { $0.uniqueID == settings.microphoneID }) else { throw NativeMacRecordingError.microphoneUnavailable }
                        config.microphoneCaptureDeviceID = settings.microphoneID
                    }
                    config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                    let sink = NativeSystemAudioSink(directory: directory, bitrate: settings.bitrate)
                    sink.onFailure = { [weak self] in Task { @MainActor in
                        guard let self, self.captureID == attempt else { return }; self.captureFailed()
                    } }
                    let filter: SCContentFilter
                    if mode == .application {
                        let applications = try NativeMacAudioApplication.captureApplications(from: content?.applications ?? [], bundleID: settings.conferenceApplicationID)
                        filter = SCContentFilter(display: display, including: applications, exceptingWindows: [])
                    } else {
                        filter = SCContentFilter(display: display, excludingWindows: [])
                    }
                    let stream = SCStream(filter: filter, configuration: config, delegate: sink)
                    self.sink = sink; self.stream = stream
                    try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
                    if mode.needsMicrophone { try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue) }
                    try await stream.startCapture()
                    try Task.checkCancellation()
                    guard !sourceFailed else { throw NativeMacRecordingError.encoding }
                } else { throw NativeMacRecordingError.unavailable }
                guard !sourceFailed else { throw NativeMacRecordingError.encoding }
                started = ProcessInfo.processInfo.systemUptime; phase = .recording
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in
                    guard let self, self.phase == .recording else { return }
                    self.elapsed = ProcessInfo.processInfo.systemUptime - self.started
                    if self.elapsed >= min(NativeMacRecordingPolicy.maximumDuration, Double(settings.maximumMinutes * 60)) - 2 || !NativeMacRecordingPolicy.hasSpace(root, starting: false) { await self.stop() }
                } }
                self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            } catch {
                await microphone?.stop(); microphone = nil
                try? await stream?.stopCapture(); stream = nil
                if let sink { _ = try? await sink.finish() }; sink = nil
                message = error is CancellationError ? VL.text("Запись отменена") : error.localizedDescription
                phase = .idle; self.publish = nil
            }
            startTask = nil
        }
    }
    func stop() async {
        if let finishTask { await finishTask.value; return }
        if phase == .starting { startTask?.cancel(); await startTask?.value }
        guard phase == .recording else { return }
        phase = .saving; timer?.invalidate(); timer = nil
        let task = Task { @MainActor in
            do {
                await microphone?.stop()
                try? await stream?.stopCapture(); stream = nil
                guard let directory else { throw NativeMacRecordingError.noAudio }
                let tracks: [NativeCapturedTrack]
                if let sink { tracks = try await sink.finish() }
                else { throw NativeMacRecordingError.noAudio }
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                let output = directory.appendingPathComponent("\(recordingTitle) \(formatter.string(from: Date())).m4a")
                try await NativeMacAudioMix.export(tracks, to: output)
                guard let publish else { throw NativeMacRecordingError.encoding }
                try await publish(output)
                // Delete only this operation's staging after library publication.
                try? FileManager.default.removeItem(at: directory)
                message = sourceFailed ? VL.text("Запись прервалась. Полученное аудио сохранено на Mac.") : VL.text("Аудиозапись сохранена на Mac")
            } catch {
                message = error.localizedDescription + " " + VL.text("Исходные дорожки сохранены в папке несохранённых записей.")
            }
            microphone = nil; sink = nil; stream = nil; directory = nil; publish = nil
            phase = .idle; finishTask = nil
        }
        finishTask = task; await task.value
    }
    private func captureFailed() {
        guard phase == .starting || phase == .recording else { return }
        sourceFailed = true
        guard phase == .recording else { return }
        Task { await stop() }
    }
}
