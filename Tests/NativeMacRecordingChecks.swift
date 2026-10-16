import AVFoundation
import Foundation

private func check(_ value: Bool, _ message: String = "") { precondition(value, message) }

@main struct NativeMacRecordingChecks {
    static func sample(frame: Int, frequency: Double, origin: Int64) throws -> CMSampleBuffer {
        let count = 960
        let pcm = (0..<count).map { Float(0.15 * sin(2 * Double.pi * frequency * Double(frame + $0) / 48_000)) }
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count * 4, flags: 0, blockBufferOut: &block) == noErr)
        pcm.withUnsafeBytes { bytes in check(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) == noErr) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: origin + Int64(frame), timescale: 48_000), decodeTimeStamp: .invalid)
        var size = 4, buffer: CMSampleBuffer?
        check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr)
        return buffer!
    }
    @MainActor static func main() async throws {
        let defaults = NativeMacRecordingSettings()
        check(defaults.automaticStart && defaults.automaticStop && defaults.askBeforeRecording && defaults.onlyWithParticipants)
        check(defaults.automaticTranscription && defaults.automaticSummary && defaults.automaticVisualSummary && defaults.maximumMinutes <= 360)
        let savedOff = try JSONDecoder().decode(NativeMacRecordingSettings.self, from: Data("{\"automaticStart\":false,\"automaticTranscription\":false,\"automaticVisualSummary\":false}".utf8))
        check(!savedOff.automaticStart && !savedOff.automaticTranscription && !savedOff.automaticVisualSummary, "Explicit saved choices must survive new defaults")
        let legacy = try JSONDecoder().decode(NativeMacRecordingSettings.self, from: Data("{\"showMenuIcon\":false,\"bitrate\":64000}".utf8))
        check(!legacy.showMenuIcon && legacy.bitrate == 64_000 && legacy.automaticStart && legacy.askBeforeRecording)
        var settings = defaults; settings.bitrate = 1; settings.maximumMinutes = 999; settings.recordingTitle = "../../outside"
        check(settings.validated.bitrate == 128_000 && settings.validated.maximumMinutes == 180 && settings.safeTitle == "Mac")
        let suite = "Vecta.RecordingChecks." + UUID().uuidString
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let preferences = NativeMacRecordingPreferences(defaults: storage)
        preferences.value.showMenuIcon = false; preferences.value.microphoneID = "synthetic-mic"; preferences.value.automaticSummary = false
        let reopened = NativeMacRecordingPreferences(defaults: storage)
        check(!reopened.value.showMenuIcon && reopened.value.microphoneID == "synthetic-mic" && !reopened.value.automaticSummary && reopened.value.automaticStart)
        var activity = NativeConferenceActivity(bundleID: "synthetic.call", application: "Synthetic Call", pid: 123, inputActive: false, outputActive: false)
        check(activity.decision(automaticStart: true, ask: false, requireParticipants: false) == .ignore)
        activity.inputActive = true
        check(activity.decision(automaticStart: true, ask: false, requireParticipants: false) == .ignore)
        activity.outputActive = true
        check(activity.decision(automaticStart: false, ask: false, requireParticipants: false) == .ignore)
        check(activity.decision(automaticStart: true, ask: false, requireParticipants: true) == .ask)
        check(activity.decision(automaticStart: true, ask: true, requireParticipants: false) == .ask)
        check(activity.decision(automaticStart: true, ask: false, requireParticipants: false) == .start)
        activity.participants = 1
        check(activity.decision(automaticStart: true, ask: false, requireParticipants: true) == .ignore)
        activity.participants = 2
        check(activity.decision(automaticStart: true, ask: false, requireParticipants: true) == .start)
        let recorder = NativeMacRecorder()
        check(!recorder.busy && recorder.phase == .idle && recorder.elapsed == 0)
        await recorder.stop()
        check(!recorder.busy)
        check(NativeMacRecordingMode.allCases.count == 4)
        check(!NativeMacRecordingMode.system.needsMicrophone && NativeMacRecordingMode.meeting.needsMicrophone && NativeMacRecordingMode.application.needsMicrophone)

        for mode in NativeMacRecordingMode.allCases {
            for status: AVAuthorizationStatus in [.authorized, .notDetermined, .denied, .restricted] {
                for screenAllowed in [false, true] {
                    var microphoneQueries = 0, screenQueries = 0
                    let allowed = NativeMacRecordingPolicy.canStartAutomatically(mode: mode,
                        microphoneStatus: { microphoneQueries += 1; return status },
                        screenCaptureAllowed: { screenQueries += 1; return screenAllowed })
                    let expected = (!mode.needsMicrophone || status == .authorized) && (mode == .microphone || screenAllowed)
                    check(allowed == expected, "Automatic capture must have every required current grant before reaching a capture API")
                    check(microphoneQueries == (mode.needsMicrophone ? 1 : 0))
                    check(screenQueries == ((mode == .microphone || (mode.needsMicrophone && status != .authorized)) ? 0 : 1))
                }
            }
        }

        var authorizedQueries = 0
        var authorizedRequests = 0
        let authorized = await NativeMacMicrophoneAuthorization.requestIfNeeded(
            status: { authorizedQueries += 1; return .authorized },
            request: { authorizedRequests += 1; return false })
        check(authorized && authorizedQueries == 1 && authorizedRequests == 0,
              "Authorized microphone access must not request again")

        for expected in [true, false] {
            var requests = 0
            let allowed = await NativeMacMicrophoneAuthorization.requestIfNeeded(
                status: { .notDetermined },
                request: { requests += 1; return expected })
            check(allowed == expected && requests == 1,
                  "Undetermined microphone access must request exactly once and use its result")
        }

        for status: AVAuthorizationStatus in [.denied, .restricted] {
            var requests = 0
            let allowed = await NativeMacMicrophoneAuthorization.requestIfNeeded(
                status: { status },
                request: { requests += 1; return true })
            check(!allowed && requests == 0,
                  "Denied or restricted microphone access must not request again")
        }

        var reentrantStatuses: [AVAuthorizationStatus] = [.notDetermined, .denied]
        var reentrantQueries = 0
        var reentrantRequests = 0
        let initiallyGranted = await NativeMacMicrophoneAuthorization.requestIfNeeded(
            status: { reentrantQueries += 1; return reentrantStatuses.removeFirst() },
            request: { reentrantRequests += 1; return true })
        let subsequentlyDenied = await NativeMacMicrophoneAuthorization.requestIfNeeded(
            status: { reentrantQueries += 1; return reentrantStatuses.removeFirst() },
            request: { reentrantRequests += 1; return true })
        check(initiallyGranted && !subsequentlyDenied && reentrantQueries == 2 && reentrantRequests == 1,
              "Each explicit permission setup must re-check status instead of retaining a granted flag")

        var noMicrophoneStatusQueries = 0
        var noMicrophoneRequests = 0
        for mode in NativeMacRecordingMode.allCases where !mode.needsMicrophone {
            if mode.needsMicrophone {
                _ = await NativeMacMicrophoneAuthorization.requestIfNeeded(
                    status: { noMicrophoneStatusQueries += 1; return .notDetermined },
                    request: { noMicrophoneRequests += 1; return true })
            }
        }
        check(noMicrophoneStatusQueries == 0 && noMicrophoneRequests == 0,
              "Modes that do not need a microphone must not query or request it")

        var appSettings = defaults; appSettings.mode = .application; appSettings.conferenceApplicationID = "synthetic.call"
        let decoded = try JSONDecoder().decode(NativeMacRecordingSettings.self, from: JSONEncoder().encode(appSettings))
        check(decoded.mode == .application && decoded.conferenceApplicationID == "synthetic.call")
        appSettings.conferenceApplicationID = "app.vecta.mac"; check(appSettings.validated.conferenceApplicationID.isEmpty)
        appSettings.conferenceApplicationID = "not an application"; check(appSettings.validated.conferenceApplicationID.isEmpty)
        for id in ["", "synthetic.closed", "app.vecta.mac"] {
            do { _ = try NativeMacAudioApplication.captureApplications(from: [], bundleID: id); preconditionFailure("Missing app must not fall back to system capture") }
            catch NativeMacRecordingError.applicationUnavailable {}
        }
        check(NativeMacRecordingPolicy.maximumDuration == 21_600)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VectaMacAudioTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = NativeSystemAudioSink(directory: root)
        do { _ = try await empty.finish(); preconditionFailure("Empty capture accepted") }
        catch NativeMacRecordingError.noAudio {}
        let sink = NativeSystemAudioSink(directory: root)
        await withCheckedContinuation { continuation in
            sink.queue.async {
                for index in 0..<50 {
                    sink.append(try! sample(frame: index * 960, frequency: 440, origin: 4_800_000), source: 1)
                    sink.append(try! sample(frame: index * 960, frequency: 880, origin: 4_824_000), source: 2)
                    Thread.sleep(forTimeInterval: 0.002)
                }
                continuation.resume()
            }
        }
        let tracks = try await sink.finish()
        check(tracks.count == 2)
        let output = root.appendingPathComponent("meeting.m4a")
        try await NativeMacAudioMix.export(tracks, to: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        check(duration > 1.45 && duration < 1.65, "Clock offset lost: \(duration)")
        check(try await asset.loadTracks(withMediaType: .video).isEmpty)
        check(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let audio = try AVAudioFile(forReading: output)
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
        try audio.read(into: buffer)
        let pcm = buffer.floatChannelData![0]
        let rms = sqrt((0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(pcm[$1] * pcm[$1]) } / Double(buffer.frameLength))
        check(rms > 0.025 && rms < 0.15)
        check(try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int == 0o600)
        let sentinel = root.appendingPathComponent("existing.m4a")
        try Data("preserve".utf8).write(to: sentinel)
        do { try await NativeMacAudioMix.export(tracks, to: sentinel); preconditionFailure("Existing output overwritten") } catch {}
        check(try Data(contentsOf: sentinel) == Data("preserve".utf8))
        print("PASS Mac recording: idle/no permission prompts, stateless injected microphone authorization and non-microphone modes, four source modes and fail-closed application selection, synthetic AAC audio tracks, 500ms clock offset, single-track audio-only mix, nonempty PCM, private permissions, empty-input rejection and no overwrite. No microphone/system capture or playback started.")
    }
}
