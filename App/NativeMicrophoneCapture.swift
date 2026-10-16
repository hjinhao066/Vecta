import AVFoundation
import Foundation

/// Capture-session control is serialized off the UI thread; samples use the
/// same private AAC sink as system audio. Construct/start only after consent.
final class NativeMicrophoneCapture: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.vecta.microphone-control", qos: .userInitiated)
    private let sink: NativeSystemAudioSink
    private var observers: [NSObjectProtocol] = []
    init(sink: NativeSystemAudioSink) {
        self.sink = sink
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.didStopRunningNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak sink] _ in sink?.onFailure?() })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified).devices
    }
    func start(deviceID: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let device = deviceID.isEmpty ? AVCaptureDevice.default(for: .audio) : Self.devices().first { $0.uniqueID == deviceID }
                    guard let device else { throw NativeMacRecordingError.microphoneUnavailable }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self.sink, queue: self.sink.queue)
                    self.session.beginConfiguration()
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                        self.session.commitConfiguration(); throw NativeMacRecordingError.microphoneUnavailable
                    }
                    self.session.addInput(input); self.session.addOutput(output); self.session.commitConfiguration()
                    self.session.startRunning()
                    guard self.session.isRunning else { throw NativeMacRecordingError.microphoneUnavailable }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { self.session.stopRunning(); continuation.resume() }
        }
    }
}
