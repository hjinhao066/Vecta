import Foundation
import Darwin

/// A framed, network-denied Speech worker. The host serializes exchanges and owns
/// the cross-process heavy-AI lease while `warm` or `process` is in flight.
final class LocalAISpeechWorker {
    private struct Command: Encodable {
        let command: String
        let requestPath: String?
        let audioPath: String?
        let whisperModelPath: String?
        let speakersPath: String?
        let tokenizerPath: String?
        let outputPath: String?
        let remainingWindows: Int?
        var eventPath: String? = nil

        static func warm(whisper: URL, tokenizer: URL, remainingWindows: Int) -> Command {
            Command(command: "warm", requestPath: nil, audioPath: nil,
                    whisperModelPath: whisper.path, speakersPath: nil,
                    tokenizerPath: tokenizer.path, outputPath: nil,
                    remainingWindows: remainingWindows)
        }

        static func process(request: URL, audio: URL, whisper: URL, speaker: URL?, tokenizer: URL, output: URL, eventURL: URL?) -> Command {
            Command(command: "process", requestPath: request.path, audioPath: audio.path,
                    whisperModelPath: whisper.path, speakersPath: speaker?.path ?? "",
                    tokenizerPath: tokenizer.path, outputPath: output.path,
                    remainingWindows: nil, eventPath: eventURL?.path)
        }

        static let unload = Command(command: "unload", requestPath: nil, audioPath: nil,
                                    whisperModelPath: nil, speakersPath: nil, tokenizerPath: nil,
                                    outputPath: nil, remainingWindows: nil)
        static let shutdown = Command(command: "shutdown", requestPath: nil, audioPath: nil,
                                      whisperModelPath: nil, speakersPath: nil, tokenizerPath: nil,
                                      outputPath: nil, remainingWindows: nil)
    }

    private struct Response: Decodable {
        let ok: Bool
        let command: String
        let error: String?
    }

    let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let diagnostic: FileHandle
    private let diagnosticURL: URL

    init(executable: URL, eventsRoot: URL) throws {
        try FileManager.default.createDirectory(at: eventsRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        diagnosticURL = eventsRoot.appendingPathComponent(UUID().uuidString + ".tmp")
        FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        diagnostic = try FileHandle(forWritingTo: diagnosticURL)

        let incoming = Pipe(), outgoing = Pipe()
        input = incoming.fileHandleForWriting
        output = outgoing.fileHandleForReading
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", "(version 1)(allow default)(deny network*)", executable.path, "--serve-speech"]
        process.qualityOfService = .utility
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        process.standardInput = incoming
        process.standardOutput = outgoing
        process.standardError = diagnostic
        try process.run()
    }

    func warm(whisper: URL, tokenizer: URL, remainingWindows: Int = 4) async throws {
        try await exchange(.warm(whisper: whisper, tokenizer: tokenizer, remainingWindows: remainingWindows))
    }

    func recognize(request: URL, audio: URL, whisper: URL, speaker: URL?, tokenizer: URL, output: URL, eventURL: URL? = nil) async throws {
        try await exchange(.process(request: request, audio: audio, whisper: whisper,
                                    speaker: speaker, tokenizer: tokenizer, output: output, eventURL: eventURL))
    }

    func unload() async throws {
        try await exchange(.unload)
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let child = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        }
    }

    func stop() async {
        if process.isRunning {
            _ = try? await exchange(.shutdown)
            terminate()
        }
        let child = process
        await Task.detached(priority: .utility) { child.waitUntilExit() }.value
        try? input.close()
        try? output.close()
        try? diagnostic.close()
        try? FileManager.default.removeItem(at: diagnosticURL)
    }

    private func exchange(_ command: Command) async throws {
        guard process.isRunning else { throw AIProcessingError.interrupted }
        let data = try JSONEncoder().encode(command)
        guard data.count < 256_000 else { throw AIProcessingError.invalidRequest }
        let incoming = input, outgoing = output, child = process
        let seconds: UInt64? = command.command == "shutdown" ? 3 : command.command == "warm" ? 300 : nil
        let watchdog = seconds.map { seconds in Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if !Task.isCancelled { self.terminate() }
        } }
        defer { watchdog?.cancel() }
        try await withTaskCancellationHandler(operation: {
            let reply = try await Task.detached(priority: .utility) {
                try incoming.write(contentsOf: data + Data([10]))
                var frame = Data()
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(outgoing.fileDescriptor, $0.baseAddress, 8192)
                    }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw AIProcessingError.interrupted
                    }
                    if count == 0 { throw AIProcessingError.interrupted }
                    let bytes = Data(buffer.prefix(count))
                    guard let end = bytes.firstIndex(of: 10) else {
                        frame.append(bytes)
                        guard frame.count < 128_000 else { throw AIProcessingError.invalidSummary }
                        continue
                    }
                    guard end == bytes.index(before: bytes.endIndex), frame.count + end < 128_000 else {
                        throw AIProcessingError.invalidSummary
                    }
                    frame.append(bytes.prefix(upTo: end))
                    return frame
                }
            }.value
            let response = try JSONDecoder().decode(Response.self, from: reply)
            guard response.ok, response.command == command.command else { throw AIProcessingError.interrupted }
        }, onCancel: {
            if child.isRunning { self.terminate() }
        })
    }
}
