import Foundation

/// Model-free IPC checks. Every child is a temporary shell fixture; this never starts
/// the host, touches a user library/defaults suite, opens recordings, or loads a model.
@main struct FastTranscriptionChecks {
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func script(_ root: URL, _ name: String, _ body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(body.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    static func object(_ line: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw AIProcessingError.invalidSummary
        }
        return value
    }

    static func caught(_ work: () async throws -> Void) async -> Error? {
        do {
            try await work()
            return nil
        } catch {
            return error
        }
    }

    @MainActor static func preferenceChecks(root: URL) throws {
        let suite = "Vecta.Verification.FastTranscription." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let resources = root.appendingPathComponent("resources/LocalAI", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: resources.appendingPathComponent("models.json"))
        func host() throws -> LocalAIHost {
            try LocalAIHost(root: root.appendingPathComponent("processing"), resources: resources.deletingLastPathComponent(),
                            modelsRoot: root.appendingPathComponent("models"), defaults: defaults,
                            makeDownloader: { fatalError("A preference change must never create a downloader") })
        }
        let first = try host()
        defer { first.stop() }
        check(first.fastTranscriptionEnabled, "missing preference defaults to enabled")
        check(defaults.object(forKey: "VectaFastTranscriptionEnabled") == nil, "reading the default does not overwrite preferences")
        first.setFastTranscriptionEnabled(false)
        check(!first.fastTranscriptionEnabled && defaults.object(forKey: "VectaFastTranscriptionEnabled") as? Bool == false, "explicit off is persisted")
        let second = try host()
        defer { second.stop() }
        check(!second.fastTranscriptionEnabled, "a new host preserves explicit off")
        second.setFastTranscriptionEnabled(true)
        let third = try host()
        defer { third.stop() }
        check(third.fastTranscriptionEnabled, "re-enabling survives host recreation")
        third.setQueuePaused(true)
        check(defaults.bool(forKey: "VectaLocalAIQueuePaused"), "queue preference also uses the injected suite")
        check(!first.hasActiveWorker && !second.hasActiveWorker && !third.hasActiveWorker, "preferences never launch a worker before host startup")
        check(third.statuses.values.allSatisfy { $0.state == .verifying }, "preference changes neither verify nor download models")
        check(third.speechEngine == .whisper && !third.modelsNeeded(reuseTranscript: false).contains("gigaam"), "a missing engine preference keeps Whisper")
        check(third.registry.models.contains { $0.id == "gigaam" && $0.backend == "mlx" && $0.license == "MIT" }, "the catalog pins GigaAM as an MLX model")
        third.selectSpeechEngine(.gigaam)
        let fourth = try host()
        defer { fourth.stop() }
        check(fourth.speechEngine == .gigaam, "the recognition engine choice survives host recreation")
        check(Set(fourth.modelsNeeded(reuseTranscript: false)) == Set([fourth.summaryModel.rawValue, "gigaam", "speaker"]), "GigaAM jobs need SpeakerKit but no Whisper files")
        check(fourth.statuses.values.allSatisfy { $0.state == .verifying } && !fourth.hasActiveWorker, "choosing an engine neither downloads nor launches a worker")
        fourth.selectSpeechEngine(.whisper)
    }

    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw AIProcessingError.invalidRequest }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vecta-fast-transcription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try preferenceChecks(root: root)

        let recorder = try script(root, "recording-worker", """
        #!/bin/sh
        log="$(dirname "$0")/frames.log"
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$log"
          case "$line" in
            *'"command":"warm"'*) printf '{"ok":true,"command":"warm"}\\n' ;;
            *'"command":"process"'*) printf '{"ok":true,"command":"process"}\\n' ;;
            *'"command":"unload"'*) printf '{"ok":true,"command":"unload"}\\n' ;;
            *'"command":"shutdown"'*) printf '{"ok":true,"command":"shutdown"}\\n'; exit 0 ;;
            *) printf '{"ok":false,"command":"unknown","error":"invalidRequest"}\\n' ;;
          esac
        done
        """)
        let events = root.appendingPathComponent("events", isDirectory: true)
        let worker = try LocalAISpeechWorker(executable: recorder, eventsRoot: events)
        let whisper = URL(fileURLWithPath: "/fixture/whisper"), tokenizer = URL(fileURLWithPath: "/fixture/tokenizer")
        try await worker.warm(whisper: whisper, tokenizer: tokenizer)
        try await worker.recognize(
            request: URL(fileURLWithPath: "/fixture/request.json"),
            audio: URL(fileURLWithPath: "/fixture/audio.wav"),
            whisper: whisper,
            speaker: URL(fileURLWithPath: "/fixture/speaker"),
            tokenizer: tokenizer,
            output: URL(fileURLWithPath: "/fixture/result.json")
        )
        try await worker.unload()
        await worker.stop()

        let frames = try String(contentsOf: root.appendingPathComponent("frames.log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        check(frames.count == 4, "each exchange, including graceful shutdown, writes exactly one frame")
        let warm = try object(frames[0]), process = try object(frames[1]), unload = try object(frames[2]), shutdown = try object(frames[3])
        check(warm["command"] as? String == "warm", "warm command is framed as JSON")
        let warmKeys = Set(warm.keys)
        check(warmKeys.isSubset(of: Set(["command", "whisperModelPath", "tokenizerPath", "remainingWindows"])), "warm is models-only and never exposes request/audio/output paths")
        check(warm["whisperModelPath"] as? String == whisper.path && warm["tokenizerPath"] as? String == tokenizer.path, "warm carries both model paths")
        if let windows = warm["remainingWindows"] as? NSNumber {
            check(windows.intValue == 4, "the optional warm window count retains the protocol default")
        }
        let processKeys: Set<String> = ["command", "requestPath", "audioPath", "outputPath", "whisperModelPath", "tokenizerPath", "speakersPath"]
        check(Set(process.keys) == processKeys, "process sends the complete current framed protocol without null legacy fields")
        check(process["command"] as? String == "process" && process["audioPath"] as? String == "/fixture/audio.wav", "process framing preserves path values")
        check(unload["command"] as? String == "unload" && Set(unload.keys) == Set(["command"]), "unload is content-free")
        check(shutdown["command"] as? String == "shutdown" && Set(shutdown.keys) == Set(["command"]), "shutdown is content-free")

        let rejecter = try script(root, "rejecting-worker", """
        #!/bin/sh
        while IFS= read -r line; do printf '{"ok":false,"command":"warm","error":"invalidRequest"}\\n'; done
        """)
        let rejected = try LocalAISpeechWorker(executable: rejecter, eventsRoot: root.appendingPathComponent("reject-events", isDirectory: true))
        let rejection = await caught { try await rejected.warm(whisper: whisper, tokenizer: tokenizer) }
        check(rejection != nil, "a protocol failure response reaches the caller as an error")
        await rejected.stop()

        let malformed = try script(root, "malformed-worker", """
        #!/bin/sh
        while IFS= read -r line; do printf 'not-json\\n'; done
        """)
        let malformedWorker = try LocalAISpeechWorker(executable: malformed, eventsRoot: root.appendingPathComponent("malformed-events", isDirectory: true))
        let malformedReply = await caught { try await malformedWorker.warm(whisper: whisper, tokenizer: tokenizer) }
        check(malformedReply != nil, "malformed response frames are rejected")
        await malformedWorker.stop()

        let bounded = try LocalAISpeechWorker(executable: recorder, eventsRoot: root.appendingPathComponent("bounded-events", isDirectory: true))
        let oversized = URL(fileURLWithPath: "/" + String(repeating: "x", count: 260_000))
        let oversizedReply = await caught {
            try await bounded.recognize(request: oversized, audio: oversized, whisper: whisper, speaker: nil, tokenizer: tokenizer, output: oversized)
        }
        check(oversizedReply != nil, "oversized outbound commands are rejected before being written to the worker")
        await bounded.stop()

        let blocker = try script(root, "blocking-worker", """
        #!/bin/sh
        while IFS= read -r line; do
          IFS= read -r ignored
        done
        """)
        let cancellable = try LocalAISpeechWorker(executable: blocker, eventsRoot: root.appendingPathComponent("cancel-events", isDirectory: true))
        let pending = Task { await caught { try await cancellable.warm(whisper: whisper, tokenizer: tokenizer) } }
        try await Task.sleep(nanoseconds: 100_000_000)
        pending.cancel()
        let cancellation = await pending.value
        check(cancellation != nil, "cancelling a blocked exchange completes with an error")
        for _ in 0..<40 where cancellable.process.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(!cancellable.process.isRunning, "cancelling an exchange terminates the persistent worker process")
        await cancellable.stop()

        print("PASS: default-on/persisted isolated preferences, framed speech-worker protocol, models-only warmup, response failures, bounds, cancellation, and process cleanup")
    }
}
