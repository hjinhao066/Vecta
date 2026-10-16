import Foundation
import CryptoKit
import Darwin

private enum SpeechWorkerInput {
    static func process(requestPath: String, audioPath: String, outputPath: String, whisperModelPath: String, tokenizerPath: String, speakersPath: String, modelCache: VectaSpeechModelCache? = nil, eventPath: String? = nil) async throws {
        var request: AIProcessingRequest?
        let output = URL(fileURLWithPath: outputPath)
        do {
            let audio = URL(fileURLWithPath: audioPath)
            let decoded = try JSONDecoder().decode(AIProcessingRequest.self, from: Data(contentsOf: URL(fileURLWithPath: requestPath)))
            request = decoded; try decoded.validate()
            guard decoded.provider == .local, !decoded.summaryOnly else { throw AIProcessingError.invalidRequest }
            let duration = try LocalAudioReader.duration(audio)
            try AIAudioPolicy.validate(duration: duration)
            let values = try audio.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AIProcessingError.invalidRequest }
            let file = try FileHandle(forReadingFrom: audio); defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation(); hash.update(data: data)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == decoded.audioSHA256 else { throw AIProcessingError.invalidRequest }
            try tokenizerExists(at: tokenizerPath)
            try await VectaSpeechPipeline.runWholeRecording(request: decoded, audio: audio, output: output, duration: duration, speakers: speakersPath, tokenizer: tokenizerPath, whisperModel: whisperModelPath, modelCache: modelCache, eventURL: eventPath.map { URL(fileURLWithPath: $0) })
        } catch {
            if let request {
                var state = (try? JSONDecoder().decode(AIProcessingResult.self, from: Data(contentsOf: output))) ?? AIProcessingResult(version: 1, request: request, stage: .failed, transcript: nil, segments: [], summary: nil, error: nil, updatedAt: Date(), duration: nil, recognitionSeconds: nil, summarySeconds: nil)
                state.stage = .failed; state.error = error.localizedDescription; state.updatedAt = Date()
                if let data = try? JSONEncoder().encode(state) {
                    try? data.write(to: output, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                }
            }
            throw error
        }
    }

    static func tokenizerExists(at path: String) throws {
        for name in ["tokenizer.json", "tokenizer_config.json", "config.json"] {
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(name).path) else { throw AIProcessingError.modelsMissing }
        }
    }
}

private struct SpeechServerCommand: Decodable {
    enum Name: String, Decodable { case warm, process, unload, shutdown }
    let command: Name
    let requestPath: String?
    let audioPath: String?
    let outputPath: String?
    let whisperModelPath: String?
    let tokenizerPath: String?
    let speakersPath: String?
    let remainingWindows: Int?
    let eventPath: String?

    func processingPaths() throws -> (request: String, audio: String, output: String, whisper: String, tokenizer: String, speakers: String) {
        guard let requestPath, let audioPath, let outputPath, let whisperModelPath, let tokenizerPath, let speakersPath else { throw AIProcessingError.invalidRequest }
        return (requestPath, audioPath, outputPath, whisperModelPath, tokenizerPath, speakersPath)
    }

    func warmPaths() throws -> (whisper: String, tokenizer: String, remainingWindows: Int) {
        guard let whisperModelPath, let tokenizerPath else { throw AIProcessingError.invalidRequest }
        let remainingWindows = remainingWindows ?? 4
        guard VectaSpeechModelConfiguration.supportsWarm(remainingWindows: remainingWindows) else { throw AIProcessingError.invalidRequest }
        return (whisperModelPath, tokenizerPath, remainingWindows)
    }
}

private struct SpeechServerResponse: Encodable {
    let ok: Bool
    let command: String
    let error: String?
}

/// Persistent, serial worker mode. Its retained object is always unloaded before
/// diarization or idle time, leaving only the process/framework cache available.
private final class SpeechServer {
    private static let maximumFrameBytes = 1_048_576
    private let replies: FileHandle
    private let modelCache = VectaSpeechModelCache()

    init() {
        let fd = dup(STDOUT_FILENO)
        precondition(fd >= 0)
        replies = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        _ = dup2(STDERR_FILENO, STDOUT_FILENO)
    }

    func run() async {
        var frame = Data()
        var discardingOversizeFrame = false
        var buffer = [UInt8](repeating: 0, count: 8192)
        while !Task.isCancelled {
            // A persistent pipe must return available bytes, not wait to fill a buffer.
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, 8192) }
            if count < 0 { if errno == EINTR { continue }; break }
            guard count > 0 else { break }
            let bytes = buffer.prefix(count)
            for byte in bytes {
                if discardingOversizeFrame {
                    if byte == 0x0A { discardingOversizeFrame = false }
                    continue
                }
                if byte == 0x0A {
                    let shouldShutdown = await handle(frame)
                    frame.removeAll(keepingCapacity: true)
                    if shouldShutdown {
                        await modelCache.unload()
                        return
                    }
                    continue
                }
                frame.append(byte)
                if frame.count > Self.maximumFrameBytes {
                    frame.removeAll(keepingCapacity: true)
                    discardingOversizeFrame = true
                    reply(ok: false, command: "unknown", error: "invalidRequest")
                }
            }
        }
        await modelCache.unload()
    }

    private func handle(_ frame: Data) async -> Bool {
        guard !frame.isEmpty, let command = try? JSONDecoder().decode(SpeechServerCommand.self, from: frame) else {
            reply(ok: false, command: "unknown", error: "invalidRequest")
            return false
        }
        do {
            switch command.command {
            case .process:
                let paths = try command.processingPaths()
                try await SpeechWorkerInput.process(requestPath: paths.request, audioPath: paths.audio, outputPath: paths.output, whisperModelPath: paths.whisper, tokenizerPath: paths.tokenizer, speakersPath: paths.speakers, modelCache: modelCache, eventPath: command.eventPath)
            case .warm:
                let paths = try command.warmPaths()
                try SpeechWorkerInput.tokenizerExists(at: paths.tokenizer)
                do {
                    let whisper = try await modelCache.model(modelFolder: paths.whisper, tokenizerFolder: URL(fileURLWithPath: paths.tokenizer), remainingWindows: paths.remainingWindows)
                    try await whisper.loadModels()
                    await modelCache.unload()
                } catch {
                    await modelCache.unload()
                    throw error
                }
            case .unload:
                await modelCache.unload()
            case .shutdown:
                await modelCache.unload()
            }
            reply(ok: true, command: command.command.rawValue, error: nil)
            return command.command == .shutdown
        } catch {
            reply(ok: false, command: command.command.rawValue, error: errorCategory(error))
            return false
        }
    }

    private func reply(ok: Bool, command: String, error: String?) {
        guard let json = try? JSONEncoder().encode(SpeechServerResponse(ok: ok, command: command, error: error)) else { return }
        replies.write(json + Data([0x0A]))
    }

    private func errorCategory(_ error: Error) -> String {
        if let error = error as? AIProcessingError {
            switch error {
            case .invalidRequest: return "invalidRequest"
            case .modelsMissing: return "modelsMissing"
            case .interrupted: return "interrupted"
            default: return "processingFailed"
            }
        }
        return error is CancellationError ? "interrupted" : "processingFailed"
    }
}

/// Production entry point: B only. Host owns the cross-process heavy-AI lease.
@main struct VectaSpeechWorker {
    static func main() async {
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--serve-speech" {
            await SpeechServer().run()
            return
        }
        do {
            guard CommandLine.arguments.count == 7 else { throw AIProcessingError.invalidRequest }
            try await SpeechWorkerInput.process(requestPath: CommandLine.arguments[1], audioPath: CommandLine.arguments[2], outputPath: CommandLine.arguments[6], whisperModelPath: CommandLine.arguments[3], tokenizerPath: CommandLine.arguments[5], speakersPath: CommandLine.arguments[4])
        } catch {
            fputs("Local speech processing failed.\n", stderr)
            exit(1)
        }
    }
}
