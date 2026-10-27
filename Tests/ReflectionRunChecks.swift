import Foundation

/// Synthetic checks for Start reflection: request file, launchd kick, pull and pipeline progress lines.
/// Runs in a temporary folder; the kick is a stub, so nothing is started.
@main enum ReflectionRunChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor final class Pull: ReflectionPullSource {
        var device = true
        var state = ReflectionPull.finished
        var starts = 0
        func startReflectionPull() -> Bool { starts += 1; return device }
        var reflectionPull: ReflectionPull { state }
    }

    static func write(_ object: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    @MainActor static func main() throws {
        var assertions = 0
        func check(_ value: Bool, _ message: String) throws {
            assertions += 1
            if !value { throw Failure(description: message) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reflection-run-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ReflectionRunFiles(folder: folder)
        func requestID() -> String? {
            (try? Data(contentsOf: files.request)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["id"] as? String
        }

        // Nothing pressed yet: no line, no request.
        var kicks = 0
        var kickResult = true
        let run = ReflectionRunController(files: files) { done in kicks += 1; done(kickResult) }
        let pull = Pull(); run.source = pull
        try check(run.display == nil, "No status before the first press")

        // Press: the recorder is pulled first; the pipeline is not kicked until the pull ends.
        pull.state = .waitingForRecorder
        run.start()
        try check(pull.starts == 1 && kicks == 0 && requestID() == nil, "The pull comes before the request")
        try check(run.display?.text == "Waiting for the recorder…" && run.display?.busy == true, "Waiting for the recorder")
        run.start()
        try check(pull.starts == 1, "A second press while busy does nothing")
        pull.state = .copying(done: 1, total: 3); run.tick()
        try check(run.display?.text == "Copying from the recorder 2/3", "Pull progress n/m: \(run.display?.text ?? "nil")")
        pull.state = .finished; run.tick()
        try check(kicks == 1 && requestID() != nil, "A finished pull writes the request and kicks the job once")
        let first = requestID()!
        try check(run.display?.text == "Waiting for the current run to finish…", "Kicked, not answered yet")

        // The pipeline's answers, step by step.
        try write(["id": "someone-else", "stage": "done", "written": ["2026-10-26"]], files.status); run.tick()
        try check(run.display?.busy == true, "An answer for another request is not ours")
        try write(["id": first, "stage": "importing"], files.status); run.tick()
        try check(run.display?.text == "Collecting recordings…", "Importing")
        try write(["id": first, "stage": "waiting_audio"], files.status); run.tick()
        try check(run.display?.text == "Waiting for the recording to finish saving…", "Waiting for audio")
        try write(["id": first, "stage": "transcribing", "sources": ["/a/1.mp3", "/a/2.mp3"]], files.status)
        try write(["state": "transcribing", "source": "/a/2.mp3", "completed_seconds": 300, "total_seconds": 1200], files.transcription); run.tick()
        try check(run.display?.text == "Transcribing 2/2 · 25%", "Transcription n/m with percent: \(run.display?.text ?? "nil")")
        try write(["state": "idle"], files.transcription); run.tick()
        try check(run.display?.text == "Transcribing 1/2", "Transcription without a current file")
        try write(["id": first, "stage": "waiting_memory"], files.status); run.tick()
        try check(run.display?.busy == true && run.display?.text.contains("memory") == true, "Memory wait is still working, said plainly")
        try write(["id": first, "stage": "reviewing", "day": "2026-10-26"], files.status); run.tick()
        try check(run.display?.text == "Writing the day’s summary…", "Reviewing")
        try write(["id": first, "stage": "done", "written": ["2026-10-26"], "updated_at": "2026-10-27T05:14:00.123456+00:00"], files.status); run.tick()
        try check(run.display?.tone == .done && run.display?.text.hasPrefix("Done · ") == true, "Done with the time")

        // A restart keeps showing the last result of the day.
        let reopened = ReflectionRunController(files: files) { _ in kicks += 100 }
        try check(reopened.display?.tone == .done && kicks == 1, "Reopened app shows the last result and starts nothing")

        // Unchanged recordings: the pipeline answers done with nothing written.
        pull.state = .finished; run.start(); run.tick()
        let second = requestID()!
        try check(second != first && kicks == 2, "Each press is a new request")
        try write(["id": second, "stage": "done", "written": [String]()], files.status); run.tick()
        try check(run.display?.text == "No new recordings — the summary is up to date", "No new recordings")

        // Pull failed and nothing new: the pull's reason is the result.
        pull.state = .waitingForRecorder; run.start()
        pull.state = .failed("recording"); run.tick()
        let third = requestID()!
        try check(third != second && kicks == 3, "A failed pull still lets the Mac process what it already has")
        try write(["id": third, "stage": "done", "written": [String]()], files.status); run.tick()
        try check(run.display?.tone == .failed && run.display?.text == "The recorder is still recording — stop it and press again", "Recording reason")

        // Pipeline failures, one plain sentence each.
        let reasons: [String?: String] = ["quota": "Model limit reached — the summary will be written after the limit resets",
                                          "signed_out": "The summary account is signed out", "transcribe": "Transcription failed",
                                          "drive": "Summary saved on this Mac, but Google Drive hasn’t taken it yet",
                                          "crash": "Processing stopped unexpectedly", nil: "Couldn’t write the day’s summary"]
        for (reason, text) in reasons {
            let shown = ReflectionRunState.display(pull: .finished, requestID: "x", kickFailed: false,
                                                   answer: .init(id: "x", stage: "failed", reason: reason, sources: [], written: [], updatedAt: nil), transcription: nil)
            try check(shown?.text == text && shown?.tone == .failed, "Reason \(reason ?? "nil"): \(shown?.text ?? "nil")")
        }
        for code in ["timeout-scanning", "bluetooth-powered-off", "timeout-list", "copy"] {
            try check(ReflectionRunState.pullFailure(code).contains(" ") && !ReflectionRunState.pullFailure(code).contains("timeout"), "Pull reason \(code) is plain text")
        }

        // No recorder set up: straight to the pipeline. A missing launchd job is a failure, not a spinner.
        pull.device = false; kickResult = false
        run.start(); RunLoop.main.run(until: Date().addingTimeInterval(0.3)); run.tick()
        try check(run.display?.text == "Background processing isn’t installed on this Mac" && run.display?.tone == .failed, "Kick failure")

        print("PASS: \(assertions) Start reflection checks")
    }
}
