import AppKit
import SwiftUI
import Combine
import CryptoKit
import NotePinTransport

enum VectaAppChecks {
    static func syntheticWiFiSession() throws -> SessionMaterial {
        let key = Data((0..<32).map(UInt8.init)), nonce = Data((32..<44).map(UInt8.init)), aad = Data((44..<56).map(UInt8.init))
        let proof = try ChaChaPoly.seal(Data("PLAUD.AI".utf8), using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        return try SessionMaterial.authenticate(rsaPlaintext: key + nonce + aad + proof.ciphertext + proof.tag)
    }
    @MainActor static func prepareCustomFormatsUI(model: NativeMacModel, root: URL, resources: URL) throws {
        let user = "synthetic-custom-formats"
        let base = root.appendingPathComponent("catalog"), processing = root.appendingPathComponent("processing")
        try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
        let exporter = VectaLocalAudioExporter(userID: user, defaults: VectaRuntimePreferences.synchronization)
        try exporter.configureFolder(processing)
        let layout = NativeStorageLayout(recordingBase: base,
            userDirectory: base.appendingPathComponent("Users/" + VectaRecordingStore.userDirectoryName(for: user)), servicesDirectory: root.appendingPathComponent("services"))
        let library = try NativeLibraryController(userID: user, layout: layout, exporter: exporter)
        let custom = try library.createFormat(title: "Client review", prompt: "Identify customer needs, objections, agreements and next steps. Do not invent owners or deadlines.")
        let host = try LocalAIHost(root: processing, resources: resources)
        var settings = host.automaticSettings; settings.summaryRecipeID = "format:" + custom.id
        host.setAutomaticSettings(settings)
        precondition(host.automaticSettings.summaryRecipeID == settings.summaryRecipeID)
        model.library = library; model.localAI = host; model.processingRoot = processing
        model.loadWorkspace(); model.destination = .formats
        model.status = "Synthetic formats fixture. Recording, inference and devices are disabled."
    }
    static func verifyCustomFormatStorageAndQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-custom-formats-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func catalogURL(for userID: String, in root: URL) -> URL {
            let user = SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined()
            return root.appendingPathComponent("Users/\(user)/SummaryFormats/formats.json")
        }
        let inheritedRoot = root.appendingPathComponent("inherited")
        let inheritedUser = "synthetic-inherited-formats"
        let inheritedStore = try VectaSummaryFormatStore(userID: inheritedUser, directory: inheritedRoot)
        let inheritedCustom = try inheritedStore.create(title: "Исторический формат", prompt: "Сохранённая инструкция")
        let inheritedCatalog = catalogURL(for: inheritedUser, in: inheritedRoot)
        var inheritedDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: inheritedCatalog)) as! [String: Any]
        var inheritedEntries = inheritedDocument["entries"] as! [[String: Any]]
        let inheritedIndex = inheritedEntries.firstIndex { ($0["format"] as? [String: Any])?["id"] as? String == inheritedCustom.id }!
        inheritedEntries[inheritedIndex]["deletedAt"] = "2026-10-01T00:00:00Z"
        inheritedDocument["entries"] = inheritedEntries
        try JSONSerialization.data(withJSONObject: inheritedDocument, options: [.sortedKeys]).write(to: inheritedCatalog)
        let inheritedReopened = try VectaSummaryFormatStore(userID: inheritedUser, directory: inheritedRoot)
        precondition(!inheritedReopened.all.contains(where: { $0.id == inheritedCustom.id }))
        let preservedInheritedDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: inheritedCatalog)) as! [String: Any]
        precondition((preservedInheritedDocument["entries"] as! [[String: Any]]).contains {
            (($0["format"] as? [String: Any])?["id"] as? String) == inheritedCustom.id && $0["deletedAt"] != nil
        })

        let user = "synthetic-formats"
        let store = try VectaSummaryFormatStore(userID: user, directory: root)
        let custom = try store.create(title: "  Клиентский разбор  ", prompt: "  Потребности клиента\r\nВозражения и следующие шаги  ")
        precondition(custom.isValid && !custom.isBuiltin && custom.revision == 1)
        precondition(custom.title == "Клиентский разбор" && custom.prompt == "Потребности клиента\nВозражения и следующие шаги")
        precondition(custom.displayTitle == custom.title && custom.localizedPrompt(in: .english) == custom.prompt)
        let snapshot = NativeAnalysisQueue.RecipeSnapshot(format: custom, summaryTemplate: nil)
        let identity = NativeRecordingIdentity(serialNumber: "local-audio-" + String(repeating: "a", count: 64), sessionID: 1)
        var settings = AIAutomaticSettings()
        settings.summaryRecipeID = "format:" + custom.id
        let url = root.appendingPathComponent("queue.json")
        let queue = try NativeAnalysisQueue(url: url)
        try queue.append([identity], settings: settings, recipeSnapshot: snapshot)
        let requestID = UUID()
        try queue.attach(requestID, to: identity)
        let request = AIProcessingRequest(version: 1, id: requestID, recordingID: "synthetic", audioFilename: "synthetic.wav",
            audioSHA256: String(repeating: "a", count: 64), provider: .local, format: custom, createdAt: Date(), summaryOnly: false, transcriptRequestID: nil)
        try request.validate()
        let completed = AIProcessingResult(version: 1, request: request, stage: .completed, transcript: "Synthetic transcript",
            segments: [], summary: AIStructuredSummary(summary: "Synthetic completed summary", topics: [], decisions: [], tasks: [], uncertainties: []),
            error: nil, updatedAt: Date(), duration: 1, recognitionSeconds: nil, summarySeconds: nil)
        try completed.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let historicalBytes = try encoder.encode(request)
        let completedBytes = try encoder.encode(completed)
        let competingEditor = try VectaSummaryFormatStore(userID: user, directory: root)
        let updated = try competingEditor.update(id: custom.id, title: custom.title, prompt: "Изменённые инструкции", expectedRevision: 1)
        precondition(updated.revision == 2)
        do {
            _ = try store.update(id: custom.id, title: "Устаревший редактор", prompt: "Не сохранять", expectedRevision: 1)
            fatalError("Stale custom-format editor accepted")
        } catch VectaSummaryFormatError.changedElsewhere {}
        let deleted = try store.delete(id: custom.id, expectedRevision: updated.revision)
        precondition(deleted.revision == 3 && !store.all.contains(where: { $0.id == custom.id }))
        do {
            _ = try store.update(id: custom.id, title: "Удалённый формат", prompt: "Не сохранять", expectedRevision: deleted.revision)
            fatalError("Deleted custom format accepted a stale update")
        } catch VectaSummaryFormatError.missing {}
        let restarted = try VectaSummaryFormatStore(userID: user, directory: root)
        precondition(!restarted.all.contains(where: { $0.id == custom.id }))
        let catalog = catalogURL(for: user, in: root)
        let documentAfterDeletion = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as! [String: Any]
        let entriesAfterDeletion = documentAfterDeletion["entries"] as! [[String: Any]]
        precondition(!entriesAfterDeletion.contains { ($0["format"] as? [String: Any])?["id"] as? String == custom.id })
        let reopened = try NativeAnalysisQueue(url: url)
        precondition(reopened.jobs == queue.jobs && reopened.jobs[0].requestID == requestID)
        precondition(reopened.jobs[0].recipeSnapshot == snapshot && reopened.jobs[0].recipeSnapshot?.format.prompt == custom.prompt)
        let resolvedAfterDeletion = try reopened.jobs[0].resolvedRecipeSnapshot(fallbackSettings: AIAutomaticSettings(), formats: [.detailed], templates: [])
        precondition(resolvedAfterDeletion == snapshot, "Queued snapshot must bypass the edited/deleted current catalog")
        let historicalRequest = try JSONDecoder().decode(AIProcessingRequest.self, from: historicalBytes)
        let unchangedBytes = try encoder.encode(historicalRequest)
        precondition(historicalRequest.format == custom && historicalBytes == unchangedBytes)
        let historicalCompleted = try JSONDecoder().decode(AIProcessingResult.self, from: completedBytes)
        try historicalCompleted.validate()
        let unchangedCompletedBytes = try encoder.encode(historicalCompleted)
        precondition(historicalCompleted.request.format == custom && historicalCompleted.summary == completed.summary && unchangedCompletedBytes == completedBytes)
        let entriesBeforeDeleteLoop = entriesAfterDeletion.count
        for index in 0..<8 {
            let transient = try restarted.create(title: "Временный формат \(index)", prompt: "Временная инструкция \(index)")
            _ = try restarted.delete(id: transient.id, expectedRevision: transient.revision)
            precondition(!restarted.all.contains(where: { $0.id == transient.id }))
        }
        let afterDeleteLoop = try VectaSummaryFormatStore(userID: user, directory: root)
        let documentAfterDeleteLoop = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as! [String: Any]
        precondition((documentAfterDeleteLoop["entries"] as! [[String: Any]]).count == entriesBeforeDeleteLoop)
        do {
            _ = try afterDeleteLoop.delete(id: VectaSummaryInterpretation.detailed.id, expectedRevision: VectaSummaryInterpretation.detailed.revision)
            fatalError("Built-in format deletion accepted")
        } catch VectaSummaryFormatError.invalidDefinition {}
        let duplicate = try afterDeleteLoop.create(title: "Копия конспекта", prompt: VectaSummaryInterpretation.detailed.prompt)
        precondition(!duplicate.isBuiltin && duplicate.id != "detailed" && afterDeleteLoop.all.contains(.detailed))
        _ = try afterDeleteLoop.create(title: "Предельный формат", prompt: String(repeating: "я", count: 12_000))
        for prompt in ["", String(repeating: "я", count: 12_001), "Недопустимый\u{0001}символ"] {
            do { _ = try afterDeleteLoop.create(title: "Не сохранять", prompt: prompt); fatalError("Invalid custom prompt accepted") }
            catch VectaSummaryFormatError.invalidDefinition {}
        }
        let template = AISummaryTemplate(id: "synthetic-template", title: "Старый шаблон", prompt: "Сохрани структуру старого шаблона")
        let recipe = NativeSummarySelection.recipes(formats: [], templates: [template]).first!
        let templateSnapshot = NativeAnalysisQueue.RecipeSnapshot(format: recipe.format, summaryTemplate: template)
        let selectedSnapshot = try NativeAnalysisQueue.RecipeSnapshot.selected(recipeID: settings.summaryRecipeID, formats: [custom], templates: [])
        precondition(selectedSnapshot == snapshot)
        let editedDetailed = VectaSummaryInterpretation(id: "detailed", title: "Мой старый конспект", prompt: "Сохранённые изменённые инструкции", revision: 3)
        let editedSnapshot = try NativeAnalysisQueue.RecipeSnapshot.selected(recipeID: "format:detailed", formats: [editedDetailed], templates: [])
        precondition(editedSnapshot.format == editedDetailed && editedSnapshot.summaryTemplate == nil)
        var recordingSettings = NativeMacRecordingSettings()
        recordingSettings.automaticDiarization = false
        recordingSettings.recognizeKnownVoices = false
        recordingSettings.automaticSummary = true
        recordingSettings.automaticVisualSummary = false
        let conferenceSelection = try NativeConferenceAnalysisSelection.make(settings: recordingSettings, automaticSettings: settings, formats: [custom], templates: [])
        precondition(conferenceSelection.recipeSnapshot == snapshot && conferenceSelection.settings.summaryRecipeID == settings.summaryRecipeID)
        precondition(!conferenceSelection.settings.visual && conferenceSelection.settings.conference?.summary == true && conferenceSelection.settings.conference?.diarization == false)
        precondition(settings.visual == AIAutomaticSettings().visual && settings.conference == nil)
        let second = NativeRecordingIdentity(serialNumber: "local-audio-" + String(repeating: "b", count: 64), sessionID: 1)
        var conferenceSettings = settings
        conferenceSettings.summaryRecipeID = recipe.id
        conferenceSettings.conference = AIConferenceProcessingOptions(diarization: false, recognizeKnownVoices: false, summary: true)
        try reopened.append([second], settings: conferenceSettings, conferenceBundleID: "synthetic.conference", recipeSnapshot: templateSnapshot)
        let conferenceQueue = try NativeAnalysisQueue(url: url)
        precondition(conferenceQueue.jobs[1].recipeSnapshot == templateSnapshot && conferenceQueue.jobs[1].settings?.conference?.diarization == false)
        try conferenceQueue.releaseConferenceWait(second)
        let released = try NativeAnalysisQueue(url: url)
        precondition(released.jobs[1].conferenceBundleID == nil && released.jobs[1].recipeSnapshot == templateSnapshot)
        precondition(released.jobs[0].requestID == requestID)
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        for index in legacy.indices { legacy[index].removeValue(forKey: "recipeSnapshot") }
        let legacyURL = root.appendingPathComponent("legacy.json")
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)
        let legacyQueue = try NativeAnalysisQueue(url: legacyURL)
        precondition(legacyQueue.jobs.allSatisfy { $0.recipeSnapshot == nil } && legacyQueue.jobs[0].requestID == requestID)
        let legacyResolved = try legacyQueue.jobs[0].resolvedRecipeSnapshot(fallbackSettings: AIAutomaticSettings(), formats: [.detailed], templates: [])
        precondition(legacyResolved.format == .detailed && legacyResolved.summaryTemplate == nil)
        let invalidFormat = VectaSummaryInterpretation(id: custom.id, title: custom.title, prompt: "", revision: 1)
        let before = try Data(contentsOf: url)
        do {
            try released.append([.init(serialNumber: "local-audio-" + String(repeating: "c", count: 64), sessionID: 1)], settings: settings,
                recipeSnapshot: .init(format: invalidFormat, summaryTemplate: nil))
            fatalError("Invalid queue recipe accepted")
        } catch AIProcessingError.invalidRequest {}
        let after = try Data(contentsOf: url)
        precondition(before == after && released.jobs == conferenceQueue.jobs)
        let longFormat = VectaSummaryInterpretation(id: custom.id, title: custom.title, prompt: String(repeating: "a", count: 12_000), revision: 1)
        let largeBatch = (1...180).map { NativeRecordingIdentity(serialNumber: "local-audio-" + String(format: "%064llx", UInt64($0)), sessionID: 1) }
        do {
            try released.append(largeBatch, settings: settings, recipeSnapshot: .init(format: longFormat, summaryTemplate: nil))
            fatalError("Oversized queue document accepted")
        } catch AIProcessingError.invalidRequest {}
        let afterOversized = try Data(contentsOf: url)
        precondition(before == afterOversized && released.jobs == conferenceQueue.jobs)
        var invalid = try JSONSerialization.jsonObject(with: before) as! [[String: Any]]
        var rawSnapshot = invalid[0]["recipeSnapshot"] as! [String: Any]
        var rawFormat = rawSnapshot["format"] as! [String: Any]
        rawFormat["prompt"] = ""; rawSnapshot["format"] = rawFormat; invalid[0]["recipeSnapshot"] = rawSnapshot
        let invalidURL = root.appendingPathComponent("invalid.json")
        try JSONSerialization.data(withJSONObject: invalid).write(to: invalidURL)
        do { _ = try NativeAnalysisQueue(url: invalidURL); fatalError("Malformed persisted queue snapshot accepted") }
        catch AIProcessingError.invalidRequest {}
    }
    @MainActor static func run() -> Bool {
        if CommandLine.arguments.contains("--verify-application-lifecycle") {
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            Task { @MainActor in
                let delegate = NativeMacDelegate()
                delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
                guard let window = application.windows.first(where: { $0.title == "Vecta" }) else {
                    fatalError("Missing synthetic main window")
                }
                precondition(!window.isReleasedWhenClosed, "Closed main window must remain reusable")
                let settings = delegate.model.applicationSettings
                precondition(settings.backgroundOperationEnabled, "Background operation defaults on in isolated preferences")
                precondition(!delegate.applicationShouldTerminateAfterLastWindowClosed(application))
                for _ in 0..<3 {
                    window.performClose(nil)
                    precondition(!window.isVisible)
                    precondition(delegate.applicationShouldHandleReopen(application, hasVisibleWindows: false))
                    precondition(window.isVisible && application.windows.filter { $0.title == "Vecta" }.count == 1)
                }
                window.performClose(nil)
                delegate.openSettings()
                precondition(window.isVisible && delegate.model.destination == .settings)
                settings.setBackgroundOperationEnabled(false)
                precondition(delegate.applicationShouldTerminateAfterLastWindowClosed(application), "Off routes last-window close through AppKit termination")
                settings.setBackgroundOperationEnabled(true)
                precondition(!delegate.applicationShouldTerminateAfterLastWindowClosed(application))
                await delegate.model.stop()
                window.orderOut(nil)
                print("PASS compiled application lifecycle: default background, repeated close/Dock reopen of same retained window, Settings reopen, background-off termination policy and safe model cleanup. Isolated preferences; no login registration, owner library, models, capture or device actions.")
                exit(0)
            }
            application.run(); return true
        }
        if CommandLine.arguments.contains("--verify-visual-composition") {
            do {
                let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-visual-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
                defer {try? FileManager.default.removeItem(at:root)}
                try NativeVisualCompositionChecks.run(artifacts:root)
                exit(0)
            } catch {print(error);exit(1)}
        }
        if CommandLine.arguments.contains("--verify-highlights") {
            Task { @MainActor in
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-highlight-" + UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: root) }
                    let model = NativeMacModel()
                    try model.prepareHighlightVerification(root: root)
                    model.duration = 60; model.seek(30); model.addHighlight()
                    precondition(model.highlightPoints == [30])
                    precondition(model.highlightRanges == [.init(start: 20, end: 40)])
                    model.seek(3)
                    precondition(model.highlightRanges == [.init(start: 20, end: 40)], "Highlights must not follow playhead")
                    model.addHighlight()
                    precondition(model.highlightRanges == [.init(start: 0, end: 13), .init(start: 20, end: 40)])
                    model.removeHighlight(30)
                    precondition(model.highlightPoints == [3])
                    let reopened = try VectaRecordingStore(userID: "highlight-fixture", directory: root.appendingPathComponent("catalog"))
                    precondition(reopened.all[0].highlightSeconds == [3])
                    await model.stop()
                    print("PASS compiled Highlight add/seek/remove, exact ±10s windows, playhead independence and persisted reopen. Synthetic silent fixture only.")
                    exit(0)
                } catch { print(error); exit(1) }
            }
            NSApplication.shared.run(); return true
        }
        if CommandLine.arguments.contains("--verify-playback-keyboard") {
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            Task { @MainActor in
                do {
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-keyboard-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: root) }
                    let model = NativeMacModel()
                    try model.prepareConversationVerification(root: root)
                    for _ in 0..<200 {
                        if !model.playback.preparing && model.duration >= 11.9 { break }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    precondition(!model.playback.preparing && model.duration >= 11.9)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
                    var hosting: NSView? = NSHostingView(rootView: Color.white.background(NativeRecordingKeyboard(model: model)).frame(width: 300, height: 160))
                    window.contentView = hosting; window.makeKeyAndOrderFront(nil); application.activate(ignoringOtherApps: true)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    @MainActor func send(_ code: UInt16, _ text: String) async throws {
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
                        application.postEvent(event, atStart: false)
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    try await send(49, " "); precondition(model.playing, "Space starts only generated silent fixture audio")
                    try await send(49, " "); precondition(!model.playing, "Space pauses playback")
                    model.seek(0)
                    try await send(124, "\u{F703}"); precondition(model.focusedSegment == 0 && model.progress == 1)
                    try await send(125, "\u{F701}"); precondition(model.focusedSegment == 1 && model.progress == 4.2)
                    try await send(124, "\u{F703}"); precondition(model.focusedSegment == 2 && model.progress == 7.2)
                    try await send(123, "\u{F702}"); precondition(model.focusedSegment == 1 && model.progress == 4.2)
                    try await send(126, "\u{F700}"); precondition(model.focusedSegment == 0 && model.progress == 1)
                    let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
                    window.contentView?.addSubview(field); window.makeFirstResponder(field)
                    try await send(49, " "); precondition(!model.playing && field.stringValue == " ", "Space remains text input in editors")
                    try await send(124, "\u{F703}"); precondition(model.focusedSegment == 0 && model.progress == 1, "Editor arrows do not seek")
                    window.makeFirstResponder(nil); window.contentView = NSView(); hosting = nil
                    try await send(49, " "); precondition(!model.playing, "Unmounted recording does not intercept keys")
                    await model.stop(); window.orderOut(nil)
                    print("PASS actual scoped recording keyboard: space play/pause on generated silence, four arrow keys seek/scroll phrases, text editing and detached views pass through. No owner audio, recording, models or device actions.")
                    exit(0)
                } catch { print(error); exit(1) }
            }
            application.run(); return true
        }
        if CommandLine.arguments.contains("--verify-conference-policy") {
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-conference-policy-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: root) }
                let identity = NativeRecordingIdentity(serialNumber: "local-audio-" + String(repeating: "a", count: 64), sessionID: 1)
                let url = root.appendingPathComponent("queue.json")
                let queue = try NativeAnalysisQueue(url: url)
                var settings = AIAutomaticSettings(); settings.visual = false
                settings.conference = AIConferenceProcessingOptions(diarization: false, recognizeKnownVoices: false, summary: false)
                try queue.append([identity], settings: settings, conferenceBundleID: "synthetic.conference")
                let reopened = try NativeAnalysisQueue(url: url)
                precondition(reopened.jobs == queue.jobs && reopened.jobs[0].settings?.conference?.summary == false)
                precondition(reopened.jobs[0].conferenceBundleID == "synthetic.conference")
                try reopened.releaseConferenceWait(identity)
                let released = try NativeAnalysisQueue(url: url)
                precondition(released.jobs[0].conferenceBundleID == nil)
                do { try reopened.append([.init(serialNumber: "local-audio-invalid", sessionID: 1)]); fatalError("Invalid imported identity accepted") } catch {}
                let model = NativeMacModel()
                precondition(model.macRecordingPreferences.value.automaticStart && model.macRecordingPreferences.value.askBeforeRecording && model.canRestartForLanguage)
                model.purgingRecording = identity; precondition(model.busy && !model.canRestartForLanguage)
                model.startMacRecording(.meeting)
                precondition(!model.macRecorder.busy)
                precondition(!NativeMacRecordingPolicy.canStartAutomatically(mode: .meeting,
                    microphoneStatus: { .authorized }, screenCaptureAllowed: { false }))
                precondition(!NativeMacRecordingPolicy.canStartAutomatically(mode: .microphone,
                    microphoneStatus: { .denied }, screenCaptureAllowed: { fatalError("Microphone-only mode must not query screen access") }))
                precondition(NativeMacRecordingPolicy.canStartAutomatically(mode: .meeting,
                    microphoneStatus: { .authorized }, screenCaptureAllowed: { true }))
                let idle = NativeMacRecordingDisplay(phase: .idle, elapsed: 0)
                let recording = NativeMacRecordingDisplay(phase: .recording, elapsed: 3675)
                precondition(!idle.busy && !idle.recording && idle.clock == "00:00:00")
                precondition(recording.busy && recording.recording && recording.clock == "01:01:15")
                precondition(!NativeMacRecordingDisplay(phase: .saving, elapsed: 75).recording)
                precondition(NativeMacRecordingMode.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil })
                let card = NSHostingView(rootView: NativeMacRecordingCard(model: model, display: recording, open: {}, settings: {}))
                precondition(card.fittingSize.width >= 330 && !model.macRecorder.busy)
                model.purgingRecording = nil; precondition(!model.busy && model.canRestartForLanguage)
                precondition(!NativeConnectionMessage.failure("native-audio-decoding-failed").contains("native-audio-decoding-failed"))
                print("PASS native conference policy: durable imported-audio queue, frozen transcription-only options, deferred release, malformed identity rejection, purge/restart blockers and disabled fixture capture. No capture, permissions, notifications, owner preferences or models accessed.")
            } catch { fatalError("Conference policy: \(error)") }
            return true
        }
        if CommandLine.arguments.contains("--verify-speaker-merge") {
            do {
                let model=NativeMacModel()
                guard let resources=Bundle.main.resourceURL else {throw AIProcessingError.invalidRequest}
                try model.verifySpeakerMerge(resources:resources)
            } catch {fatalError("Synthetic speaker merge failed: \(error)")}
            return true
        }
        if CommandLine.arguments.contains("--verify-language-restart-policy") {
            let blockers:[(NativeMacModel)->Void]=[
                {$0.resettingDevice=true},{$0.transferring=true},{$0.connecting=true},{$0.syncing=true},
                {$0.fastTransferPhase="switching"},{$0.importingAudio=true},{$0.chatBusy=true},
                {$0.libraryQuestionBusy=true},{$0.requestingAnalysis=true},{$0.visualRetryBusy=true},
                {$0.scanning=true},{$0.languageRestarting=true},{$0.batchChecking=true},{$0.batchActiveRequest=UUID()}
            ]
            for block in blockers {
                let model=NativeMacModel()
                precondition(model.canRestartForLanguage)
                block(model)
                precondition(!model.canRestartForLanguage)
                precondition(model.library == nil && model.localAI == nil)
            }
            let model=NativeMacModel()
            let request=AIProcessingRequest(version:1,id:UUID(),recordingID:"synthetic",audioFilename:"synthetic.wav",
                audioSHA256:String(repeating:"a",count:64),provider:.local,format:.detailed,createdAt:Date(),
                summaryOnly:false,transcriptRequestID:nil)
            model.analyses=[AIProcessingResult(version:1,request:request,stage:.queued,transcript:nil,segments:[],summary:nil,error:nil,updatedAt:Date(),duration:nil,recognitionSeconds:nil,summarySeconds:nil)]
            precondition(model.analysisBusy && !model.canRestartForLanguage)
            model.analyses=[]
            precondition(model.canRestartForLanguage)
            let bundle=URL(fileURLWithPath:"/synthetic/Quoted ' $(false) Vecta.app")
            let helper=NativeLanguageRestart.helper(bundle:bundle,pid:123,arguments:["--synthetic"],environment:["VECTA_TEST_LANGUAGE":"ru"])
            precondition(helper.executableURL?.path=="/bin/sh" && helper.arguments?.dropFirst(3).first=="123")
            precondition(helper.arguments?.contains(bundle.path)==true && helper.arguments?.last=="--synthetic")
            precondition(helper.environment?["VECTA_TEST_LANGUAGE"]==nil && !helper.isRunning)
            print("PASS language restart policy: fourteen activity blockers, queued analysis, idle recovery and positional helper arguments. No restart, process launch, production preferences, device or library accessed.")
            return true
        }
        if CommandLine.arguments.contains("--verify-fast-transfer-availability") {
            do {
                let model = NativeMacModel()
                for features in [nil, Data([1, 0x8a, 0, 0]), Data([1, 0x8a, 0, 8]), Data([1, 0x8a, 0, 8, 0, 1])] as [Data?] {
                    try model.prepareFastTransferVerification(features: features)
                    precondition(model.showsFastTransfer && model.canStartFastTransfer)
                }
                try model.prepareFastTransferVerification(supportsWiFi: false)
                precondition(model.showsFastTransfer && !model.canStartFastTransfer)
                try model.prepareFastTransferVerification(queued: true)
                precondition(model.showsFastTransfer && !model.canStartFastTransfer)
                try model.prepareFastTransferVerification()
                model.fastTransferPhase = "switching"
                precondition(!model.showsFastTransfer && !model.canStartFastTransfer)
                model.fastTransferPhase = nil; model.transferID = nil
                precondition(!model.showsFastTransfer && !model.canStartFastTransfer)
                try model.prepareFastTransferVerification()
                model.savedDevice = try SavedPlaudDevice(serialNumber: String(PlaudModel.notePin.projectCode) + "SYNTHETIC", model: .notePin, protocolVersion: 20)
                precondition(!model.showsFastTransfer && !model.canStartFastTransfer)
                try model.prepareFastTransferVerification()
                model.transferring = false
                precondition(!model.showsFastTransfer && !model.canStartFastTransfer)
                print("PASS Fast transfer availability: real model/transport gate accepts absent/ChaCha/AES/extended features; visible-disabled for busy/unsupported capability; hides for switching/no file/unsupported model/idle. Synthetic only; no Bluetooth, network or Keychain.")
            } catch { print(error); exit(1) }
            return true
        }
        if CommandLine.arguments.contains("--verify-library-ownership") {
            let application = NSApplication.shared
            Task { @MainActor in
                do { try await verifyLibraryOwnership(); exit(0) }
                catch { print(error); exit(1) }
            }
            application.run(); return true
        }
        if CommandLine.arguments.contains("--verify-summary-options") {
            let custom = VectaSummaryInterpretation(id: "custom_" + UUID().uuidString.lowercased(), title: "Клиентский разбор", prompt: "Потребности, возражения и следующие шаги", revision: 1)
            let formats: [VectaSummaryInterpretation] = [.detailed, .actionPlan, .analytical, .nlp, custom]
            let template = AISummaryTemplate(id: "synthetic-template", title: "Проверка после перезапуска", prompt: "Test-only hidden template")
            let recipes = NativeSummarySelection.recipes(formats: formats, templates: [template])
            let visible = NativeSummarySelection.creationRecipes(in: recipes)
            precondition(visible.prefix(4).map(\.id) == ["format:detailed", "format:action_plan", "format:analytical", "format:nlp"])
            precondition(visible.prefix(4).allSatisfy { $0.category == .builtIn && $0.template == nil })
            precondition(visible.suffix(2).allSatisfy { $0.category == .custom })
            precondition(visible.first?.displayInstructions == VectaSummaryInterpretation.detailed.localizedPrompt(in: VL.language))
            precondition(visible.first(where: { $0.format == custom })?.displayInstructions == custom.prompt)
            precondition(visible.first(where: { $0.template == template })?.displayInstructions == template.prompt)
            precondition(NativeSummarySelection.selected("format:" + custom.id, legacyFormat: nil, in: visible)?.format == custom)
            precondition(NativeSummarySelection.selected("template:" + template.id, legacyFormat: nil, in: visible)?.template == template)
            precondition(NativeSummarySelection.selected("format:analytical", legacyFormat: nil, in: visible)?.id == "format:analytical")
            precondition(NativeSummarySelection.selected("format:deleted", legacyFormat: nil, in: visible)?.id == NativeSummarySelection.defaultID)
            precondition(NativeSummarySelection.selected(nil, legacyFormat: custom.id, in: visible)?.format == custom)
            precondition(NativeSummarySelection.creationRecipes(in: NativeSummarySelection.recipes(formats: formats, templates: AISummaryTemplate.defaults)).count == formats.count)
            precondition(AIAutomaticSettings().summaryRecipeID == "format:analytical" && NativeSummarySelection.defaultID == "format:detailed")
            precondition(NativeSummaryCatalog.visible(VectaSummaryInterpretation.allCases).map(\.id) == ["detailed", "action_plan", "analytical", "nlp"])
            do { try verifyCustomFormatStorageAndQueue() }
            catch { fatalError("Custom format persistence/queue: \(error)") }
            print("PASS summary options: four primary plus explicit custom/legacy-template choices, stable fallback and distinct defaults; permanent custom-format deletion after reopen, stale editor rejection, immutable completed/request/queue snapshots, inherited tombstone compatibility, bounded catalog slots, malformed snapshot rejection and legacy queue decoding. Synthetic only; no models or owner state.")
            return true
        }
        if CommandLine.arguments.contains("--verify-reset-policy") {
            do {
                let model = NativeMacModel()
                precondition(!model.canFactoryReset)
                model.savedDevice = try SavedPlaudDevice(serialNumber: "882SYNTHETIC", model: .notePinS, protocolVersion: 20)
                precondition(!model.canFactoryReset)
                model.offlineAuthorizationReady = true
                precondition(model.canFactoryReset)
                for blocker in 0..<7 {
                    model.resettingDevice = blocker == 0; model.transferring = blocker == 1
                    model.connecting = blocker == 2; model.syncing = blocker == 3
                    model.scanning = blocker == 4; model.showingDevicePicker = blocker == 5
                    model.showingDeviceSetup = blocker == 6
                    precondition(!model.canFactoryReset)
                }
                model.showingDeviceSetup = false
                precondition(model.canFactoryReset)
                let before = model.savedDevice
                model.factoryReset(confirmedSerial: "882DIFFERENT")
                precondition(model.savedDevice == before && !model.resettingDevice)
                model.savedDevice = try SavedPlaudDevice(serialNumber: "882SYNTHETIC", model: .notePinS, protocolVersion: 21)
                precondition(!model.canFactoryReset)
                for other in PlaudModel.allCases where other != .notePinS {
                    model.savedDevice = try SavedPlaudDevice(serialNumber: String(other.projectCode) + "SYNTHETIC", model: other, protocolVersion: 20)
                    precondition(!model.canFactoryReset)
                }
                precondition(model.library == nil && model.localAI == nil)
                print("PASS reset policy: supported target, cached authorization, seven busy/setup blockers and stale confirmation; no device, Keychain or library accessed")
            } catch { print(error); exit(1) }
            return true
        }
        if CommandLine.arguments.contains("--verify-export-eligibility") {
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-export-check-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let model = NativeMacModel()
                try model.prepareConversationVerification(root: root)
                let completed = model.analyses[0]
                precondition(model.canExportDocument(.summary, result: completed))
                precondition(model.canExportDocument(.transcript, result: completed))
                precondition(model.canExportDocument(.fullReport, result: completed))
                var active = completed
                active.stage = .queued; active.transcript = nil; active.segments = []
                active.summary = nil; active.visualSummary = nil; active.semanticSummary = nil
                precondition(!model.canExportDocument(.summary, result: active))
                precondition(!model.canExportDocument(.transcript, result: active))
                precondition(!model.canExportDocument(.fullReport, result: active))
                active.stage = .summarizing; active.transcript = completed.transcript; active.segments = completed.segments
                precondition(model.canExportDocument(.transcript, result: active))
                precondition(!model.canExportDocument(.summary, result: active))
                precondition(model.canExportDocument(.summary, result: completed))
                print("PASS export eligibility: missing active results are disabled; saved transcript and completed snapshot remain exportable")
            } catch { print(error); exit(1) }
            return true
        }
        if CommandLine.arguments.contains("--verify-performance-refresh") {
            let application=NSApplication.shared
            Task { @MainActor in
                do {
                    let formatter=NativeStreamingFormatter()
                    let text="# Heading\n\n"+String(repeating:"Complete **synthetic** paragraph.\n\n",count:8000)+"- final item\n\n```\nfinal code\n```"
                    var heartbeatCount=0,maximumGap=0.0,lastHeartbeat=ProcessInfo.processInfo.systemUptime
                    let heartbeat=Task { @MainActor in
                        while !Task.isCancelled {
                            let now=ProcessInfo.processInfo.systemUptime
                            maximumGap=max(maximumGap,now-lastHeartbeat);lastHeartbeat=now;heartbeatCount+=1
                            try? await Task.sleep(nanoseconds:1_000_000)
                        }
                    }
                    try await Task.sleep(nanoseconds:2_000_000)
                    let initialHeartbeats=heartbeatCount,formatStart=ProcessInfo.processInfo.systemUptime
                    let prepared=try await formatter.format(text),repeated=try await formatter.format(text)
                    let formatSeconds=ProcessInfo.processInfo.systemUptime-formatStart
                    heartbeat.cancel()
                    precondition(heartbeatCount>initialHeartbeats && maximumGap<0.5,"Main actor must stay runnable during synthetic formatting")
                    print(String(format:"Synthetic formatting seconds=%.3f mainActorMaxGap=%.3f heartbeats=%d",formatSeconds,maximumGap,heartbeatCount-initialHeartbeats))
                    let expected=AITextDocument(text).parts
                    precondition(prepared.map(\.source)==expected.map(\.displayText))
                    precondition(repeated.map(\.text)==prepared.map(\.text))
                    let final=try await formatter.format(text+"\n\nLast complete paragraph.")
                    precondition(final.last?.source=="Last complete paragraph.")
                    let cancelled=Task {try Task.checkCancellation();return try await formatter.format(text+"Cancelled")}
                    cancelled.cancel()
                    do {_ = try await cancelled.value;preconditionFailure("Cancelled formatting must not deliver")} catch is CancellationError {}
                    let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-performance-refresh-"+UUID().uuidString)
                    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                    defer {try? FileManager.default.removeItem(at:root)}
                    guard let resources=Bundle.main.resourceURL else{throw AIProcessingError.invalidRequest}
                    let model=NativeMacModel(),host=try LocalAIHost(root:root,resources:resources)
                    model.localAI=host;try model.prepareConversationVerification(root:root)
                    await model.reloadAnalysis()
                    let revision=model.presentationRevision
                    var publications=0
                    let observer=model.objectWillChange.sink{publications+=1}
                    await model.reloadAnalysis();await model.reloadAnalysis()
                    precondition(model.presentationRevision==revision && publications==0,"Unchanged history/sidecars must not invalidate presentation")
                    guard let result=model.rawAnalysis,let key=model.conversationKey,let speaker=model.conversation.identities.keys.sorted().first else{throw AIProcessingError.invalidRequest}
                    let store=AIConversationStore(root:root)
                    var recording=try store.recording(key,segments:result.segments)
                    try recording.rename(speaker,to:"Changed sidecar");try store.save(recording,key:key)
                    await model.reloadAnalysis()
                    precondition(model.conversation.name(speaker)=="Changed sidecar","Sidecar-only edits must refresh")
                    let alignment=LocalAIFileStore(root:root).resultURL(result.request.id).appendingPathExtension("alignment.json")
                    try JSONSerialization.data(withJSONObject:["complete":true,"words":[["start":0.0,"end":0.2,"text":"synthetic","globalID":NSNull()]],"centroids":[String:[Float]]()]).write(to:alignment,options:.atomic)
                    await model.reloadAnalysis()
                    precondition(model.wordTimings.map(\.text)==["synthetic"],"Alignment revision must refresh without transcript changes")
                    if let parent=result.request.transcriptRequestID {
                        let parentFile=LocalAIFileStore(root:root).resultURL(parent),savedParent=try Data(contentsOf:LocalAIFileStore(root:root).resultURL(parent))
                        let savedAlignment=try Data(contentsOf:alignment)
                        try FileManager.default.removeItem(at:parentFile)
                        let own=try await model.conversationRefresh.snapshot(root:root,key:key,result:result)
                        precondition(own.alignment?.words.map(\.text)==["synthetic"],"Complete own alignment must not require an unused parent")
                        try JSONSerialization.data(withJSONObject:["complete":false,"words":[Any](),"centroids":[String:[Float]]()]).write(to:alignment,options:.atomic)
                        do {_ = try await model.conversationRefresh.snapshot(root:root,key:key,result:result);preconditionFailure("Incomplete alignment must require its parent")} catch is AIProcessingError {}
                        try savedParent.write(to:parentFile,options:.atomic);try savedAlignment.write(to:alignment,options:.atomic)
                        for index in 0..<10 {
                            let invalidRoot=root.appendingPathComponent("failed-scope-\(index)")
                            try FileManager.default.createDirectory(at:invalidRoot,withIntermediateDirectories:true)
                            let invalidStore=LocalAIFileStore(root:invalidRoot);try invalidStore.prepare()
                            try JSONSerialization.data(withJSONObject:["complete":false,"words":[Any](),"centroids":[String:[Float]]()]).write(to:invalidStore.resultURL(result.request.id).appendingPathExtension("alignment.json"),options:.atomic)
                            do {_ = try await model.conversationRefresh.snapshot(root:invalidRoot,key:key,result:result);preconditionFailure("Missing parent must fail")} catch is AIProcessingError {}
                            let retained=await model.conversationRefresh.retainedIncompleteAlignmentCount
                            precondition(retained<=1,"Failed snapshot metadata must remain bounded to its current chain")
                        }
                    }
                    let delayed=Task {await model.refreshConversation(snapshotReader:{_,_,_ in
                        try await Task.sleep(nanoseconds:50_000_000)
                        return NativeConversationRefresh.Snapshot(revision:"stale",alignment:nil)
                    })}
                    try await Task.sleep(nanoseconds:10_000_000)
                    model.renameSpeaker(speaker,name:"Current local edit")
                    await delayed.value
                    precondition(model.conversation.name(speaker)=="Current local edit" && !model.wordTimings.isEmpty,"Delayed snapshot must not overwrite an edit")
                    let switched=Task {await model.refreshConversation(snapshotReader:{_,_,_ in
                        try await Task.sleep(nanoseconds:50_000_000)
                        return NativeConversationRefresh.Snapshot(revision:"old library",alignment:nil)
                    })}
                    try await Task.sleep(nanoseconds:10_000_000);model.libraryGeneration=UUID()
                    await switched.value
                    precondition(model.appliedConversationRevision != "old library","Old library snapshots must be rejected")
                    let cachedRevision=model.appliedConversationRevision,oldMessage=model.analysisMessage
                    let failed=Task {await model.refreshConversation(snapshotReader:{_,_,_ in
                        try await Task.sleep(nanoseconds:50_000_000);throw AIProcessingError.invalidRequest
                    })}
                    try await Task.sleep(nanoseconds:10_000_000)
                    let replacementRoot=root.appendingPathComponent("replacement-scope")
                    model.processingRoot=replacementRoot;model.conversationStateRoot=replacementRoot;model.voiceStateRoot=replacementRoot
                    await failed.value
                    precondition(model.conversationStateRoot==replacementRoot && model.voiceStateRoot==replacementRoot && model.appliedConversationRevision==cachedRevision && model.analysisMessage==oldMessage,"A stale failure must not mutate the replacement scope")
                    model.processingRoot=nil;await model.reloadAnalysis()
                    let originalSelection=model.selected
                    let oldReload=Task {await model.reloadAnalysis(historyReader:{try await Task.sleep(nanoseconds:50_000_000);return []})}
                    try await Task.sleep(nanoseconds:10_000_000)
                    let nextSelection=NativeRecordingIdentity(serialNumber:"SYNTHETIC",sessionID:2)
                    model.selected=nextSelection;model.analyses=[]
                    await model.reloadAnalysis();precondition(model.analysisReloadPending)
                    await oldReload.value
                    for _ in 0..<50 {
                        if !model.loadingHistory && !model.analyses.isEmpty {break}
                        try await Task.sleep(nanoseconds:10_000_000)
                    }
                    precondition(model.selected==nextSelection && !model.analyses.isEmpty,"A blocked selection reload must eventually load without another action")
                    model.selected=originalSelection
                    observer.cancel()
                    print("PASS complete cached streaming formatting/cancellation, unchanged-history publication, sidecar/alignment ancestry, stale success/failure guards and queued selection reload; synthetic only, no inference")
                    exit(0)
                } catch {print(error);exit(1)}
            }
            application.run();return true
        }
        if CommandLine.arguments.contains("--verify-saved-detail-preparation") {
            let application=NSApplication.shared
            Task { @MainActor in
                do {
                    let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-detail-check-"+UUID().uuidString)
                    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                    defer {try? FileManager.default.removeItem(at:root)}
                    let model=NativeMacModel()
                    try model.prepareConversationVerification(root:root)
                    await model.preparePresentation()
                    let expected=model.conversation.rendered(model.rawAnalysis!)
                    precondition(model.analysis==expected,"Off-main saved projection preserves source content")
                    let old=model.presentationRevision
                    let pending=Task {await model.preparePresentation()}
                    model.conversation=AIRecordingSpeakers()
                    await pending.value
                    precondition(model.presentationRevision != old)
                    await model.preparePresentation()
                    precondition(model.analysis==model.conversation.rendered(model.rawAnalysis!),"A superseded projection cannot overwrite speaker edits")
                    let host=try LocalAIHost(root:root,resources:Bundle.main.resourceURL!)
                    model.localAI=host
                    var changes=0
                    let observer=model.objectWillChange.sink {changes+=1}
                    for _ in 0..<100 {host.processingProgress=[:];host.summaryDrafts=[UUID():"Unrelated synthetic draft"]}
                    await Task.yield()
                    precondition(changes==0,"Unrelated host progress/drafts must not invalidate idle detail")
                    host.summaryDrafts=[model.rawAnalysis!.request.id:"Selected synthetic draft"]
                    try await Task.sleep(nanoseconds:20_000_000)
                    precondition(changes==1 && model.analysis?.summaryDraft=="Selected synthetic draft","Selected draft remains visible with coalesced root invalidation")
                    withExtendedLifetime(observer){}
                    let visual=model.rawAnalysis!.visualSummary!
                    let input=NativeVisualPreparationInput(report:visual,semantic:model.rawAnalysis!.semanticSummary,speakers:model.resolvedConversation)
                    let prepared=try await NativeVisualPreparation.shared.prepare(input)
                    precondition(prepared.displayed==AIVisualEditorial.refined(input.speakers.renderedVisual(input.semantic?.visual(style:.editorial) ?? visual)))
                    let again=try await NativeVisualPreparation.shared.prepare(input)
                    precondition(again.displayed==prepared.displayed && again.composition.fingerprint==prepared.composition.fingerprint)
                    print("PASS off-main saved projection, superseded speaker state, 100 unrelated host updates, selected draft forwarding and bounded visual preparation reuse; synthetic only")
                    exit(0)
                } catch {print(error);exit(1)}
            }
            application.run();return true
        }
        if CommandLine.arguments.contains("--verify-performance-state") {
            let model=NativeMacModel();var rootChanges=0,playerChanges=0,questionChanges=0
            let a=model.objectWillChange.sink{rootChanges+=1},b=model.playback.objectWillChange.sink{playerChanges+=1},c=model.libraryQuestionState.objectWillChange.sink{questionChanges+=1}
            for i in 0..<200 {model.progress=Double(i)/20;model.libraryQuestionPhase="Phase \(i)";model.libraryAnswerDraft="Draft \(i)"}
            precondition(rootChanges==0 && playerChanges==199 && questionChanges==400,"Fast state must stay scoped")
            model.progress=9.95;precondition(playerChanges==199,"Equal playback state must not publish")
            model.search="Question";_=model.librarySearchSession.submit(model.search);model.clearLibraryQuestion()
            precondition(model.search.isEmpty && !model.hasLibraryQuestion && model.libraryAnswerDraft.isEmpty && model.libraryQuestionPhase.isEmpty)
            model.wordTimings=(0..<20000).map{AIWordTiming(start:Double($0)*0.2,end:Double($0)*0.2+0.15,text:"word",globalID:nil)}
            let segment=AISpeechSegment(id:1,start:100,end:105,speaker:"Собеседник",text:"test")
            let expected=model.wordTimings.filter{$0.start>=segment.start-0.001 && $0.end<=segment.end+0.001}
            precondition(model.words(for:segment)==expected,"Indexed word slice must retain boundaries")
            model.wordTimings=[];precondition(model.words(for:segment).isEmpty,"Word cache invalidates")
            let navigator=NativeMacDelegate(),identity=NativeRecordingIdentity(serialNumber:"fixture",sessionID:42)
            navigator.model.selected=identity;navigator.model.progress=17;let navigation=navigator.model.searchFocusSignal
            navigator.openLibrary()
            precondition(navigator.model.selected==identity && navigator.model.progress==17 && navigator.model.searchFocusSignal != navigation,"Library command preserves detail selection and explicitly navigates")
            withExtendedLifetime([a,b,c]){}
            print("PASS scoped playback/search notifications, identical state deduplication, X clears question and draft, 20000-word indexed slicing and invalidation; library command preserves selection")
            return true
        }
        if CommandLine.arguments.contains("--verify-model-download-host") {
            let application = NSApplication.shared
            Task { @MainActor in
                do { try await verifyModelDownloadHost(); exit(0) }
                catch { print(error); exit(1) }
            }
            application.run(); return true
        }
        if CommandLine.arguments.contains("--verify-library-search") {
            let application=NSApplication.shared
            Task { @MainActor in
                do {try await verifyLibrarySearch();exit(0)} catch {print(error);exit(1)}
            }
            application.run();return true
        }
        if CommandLine.arguments.contains("--verify-library-engine") {
            let application=NSApplication.shared
            Task { @MainActor in
                do {try await NativeMacModel.verifyLibraryEngine(resources:Bundle.main.resourceURL!);exit(0)} catch {print(error);exit(1)}
            }
            application.run();return true
        }
        if CommandLine.arguments.contains("--verify-ai-result-events") {
            let application=NSApplication.shared
            Task { @MainActor in
                do {
                    let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-result-events-"+UUID().uuidString)
                    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                    defer {try? FileManager.default.removeItem(at:root)}
                    guard let resources=Bundle.main.resourceURL else {throw AIProcessingError.invalidRequest}
                    let host=try LocalAIHost(root:root,resources:resources),model=NativeMacModel()
                    model.localAI=host
                    try model.prepareConversationVerification(root:root)
                    let completed=model.analyses[0],id=completed.request.id
                    var active=completed;active.stage = .visualizing;active.visualSummary=nil
                    model.analyses[0]=active
                    host.activeRequest=id
                    var updates=0
                    let observer=host.resultUpdates.sink { changed in
                        precondition(changed==id)
                        precondition((try? LocalAIFileStore(root:root).result(changed))?.stage == .completed)
                        precondition(host.activeRequest==id)
                        updates += 1
                    }
                    try host.persistResult(active);precondition(updates==0)
                    try host.persistResult(completed);precondition(updates==1)
                    host.activeRequest=nil
                    // Consumer receives completion even after the worker is released,
                    // with no polling timer and no pending manual request.
                    for _ in 0..<20 {
                        if model.rawAnalysis?.stage == .completed {break}
                        try await Task.sleep(nanoseconds:10_000_000)
                    }
                    precondition(model.rawAnalysis?.visualSummary==completed.visualSummary)
                    precondition(model.analysisID==id && model.rawAnalysis?.stage == .completed)
                    observer.cancel()
                    print("PASS: persisted terminal event survives worker release; visual result delivered without polling or changing version")
                    exit(0)
                } catch {print(error);exit(1)}
            }
            application.run();return true
        }
        if CommandLine.arguments.contains("--verify-confirmed-learning") {
            do {
                guard let resources=Bundle.main.resourceURL else {throw AIProcessingError.invalidRequest}
                try NativeMacModel().verifyConfirmedVoiceLearning(resources:resources)
            } catch {print(error);exit(1)}
            return true
        }
        if CommandLine.arguments.contains("--verify-sync-state") { NativeMacModel().verifySyncPreservesDetail(); return true }
        if let index=CommandLine.arguments.firstIndex(of:"--verify-processing-copy"),CommandLine.arguments.indices.contains(index+1) {
            let app=NSApplication.shared
            Task { @MainActor in
                do {
                    let root=URL(fileURLWithPath:CommandLine.arguments[index+1])
                    guard root.lastPathComponent.hasPrefix("Vecta-private-validation-"),let resources=Bundle.main.resourceURL else {throw AIProcessingError.invalidRequest}
                    let host=try LocalAIHost(root:root,resources:resources),store=LocalAIFileStore(root:root)
                    let requests=try store.requests();guard requests.count==1,let request=requests.first else {throw AIProcessingError.invalidRequest}
                    host.start()
                    for _ in 0..<900 {
                        try await Task.sleep(nanoseconds:1_000_000_000)
                        if let result=try store.result(request.id),!result.stage.isActive {
                            let report:[String:Any]=["stage":result.stage.rawValue,"transcriptCharacters":result.transcript?.count ?? 0,"segments":result.segments.count,"summary":result.summary != nil,"visual":result.visualSummary != nil,"error":result.error ?? "","visualError":result.visualError ?? ""]
                            try JSONSerialization.data(withJSONObject:report,options:.sortedKeys).write(to:root.appendingPathComponent("verification.json"))
                            host.stop();exit(result.stage == .completed && result.visualSummary != nil ? 0:1)
                        }
                    }
                    host.stop();exit(2)
                } catch {print("Private verification failed: \(error.localizedDescription)");exit(1)}
            }
            app.run();return true
        }
        return false
    }
}

/// The gate deliberately ignores cancellation, like a detached filesystem read.
@MainActor private final class VectaOwnershipReadGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in self.continuation = continuation; entered = true }
    }
    func release() { continuation?.resume(); continuation = nil }
    func awaitEntry() async throws {
        for _ in 0..<200 {
            if entered { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw AIProcessingError.invalidRequest
    }
}

extension VectaAppChecks {
    @MainActor static func verifyLibraryOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-library-ownership-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Vecta.OwnershipChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let resources = Bundle.main.resourceURL!
        let identity = NativeRecordingIdentity(serialNumber: "882SYNTHETIC", sessionID: 42)
        func fixture(_ name: String) throws -> (NativeLibraryController, LocalAIHost) {
            let base = root.appendingPathComponent(name), user = "fixture-owner"
            let layout = NativeStorageLayout(recordingBase: base,
                userDirectory: base.appendingPathComponent("Users/" + VectaRecordingStore.userDirectoryName(for: user)),
                servicesDirectory: base.appendingPathComponent("services"))
            try FileManager.default.createDirectory(at: base.appendingPathComponent("Exports"), withIntermediateDirectories: true)
            let exporter = VectaLocalAudioExporter(userID: user, defaults: defaults)
            try exporter.configureFolder(base.appendingPathComponent("Exports"))
            let library = try NativeLibraryController(userID: user, layout: layout, exporter: exporter)
            precondition(library.recordingStore.begin(sessionID: 42, serialNumber: identity.serialNumber, duration: 1))
            let audio = library.recordingStore.audioDirectory(serialNumber: identity.serialNumber).appendingPathComponent("42.mp3")
            try Data("synthetic metadata fixture, never decoded".utf8).write(to: audio)
            precondition(library.recordingStore.markLocal(sessionID: 42, serialNumber: identity.serialNumber, outputPath: audio.path))
            library.reloadLibrary()
            return (library, try LocalAIHost(root: base.appendingPathComponent("Exports"), resources: resources))
        }
        let (libraryA, hostA) = try fixture("A"), (libraryB, hostB) = try fixture("B")
        defer { hostA.stop(); hostB.stop() }
        let model = NativeMacModel()
        func activate(_ library: NativeLibraryController, _ host: LocalAIHost) {
            model.libraryGeneration = UUID(); model.library = library; model.localAI = host
            model.processingRoot = host.root; model.batchChecking = false
            model.analysisMessage = nil; model.searchError = nil
        }
        let request = AIProcessingRequest(version: 1, id: UUID(), recordingID: "42", audioFilename: "42.mp3",
            audioSHA256: String(repeating: "a", count: 64), provider: .local, format: .standard, createdAt: Date(),
            summaryOnly: false, transcriptRequestID: nil, summaryModel: .qwen4b)
        let result = AIProcessingResult(version: 1, request: request, stage: .completed, transcript: "A only",
            segments: [], summary: nil, error: nil, updatedAt: Date(), duration: 1)
        let source = AILibrarySource(id: "S1", recordingKey: NativeMacModel.libraryKey(identity), requestID: request.id,
            transcriptID: nil, revision: "fixture", title: "A", date: Date(), text: "A only", segmentIDs: [], start: nil, end: nil)
        activate(libraryA, hostA)
        let sourceGate = VectaOwnershipReadGate()
        model.openLibrarySource(source, resultReader: { _ in await sourceGate.wait(); return result })
        let sourceTask = model.librarySourceTask!
        try await sourceGate.awaitEntry()
        activate(libraryB, hostB); model.analyses = []; model.selected = nil
        sourceGate.release(); await sourceTask.value
        precondition(model.analyses.isEmpty && model.selected == nil && model.searchError == nil)

        var workspaceA = AIWorkspace()
        workspaceA.tasks = [AILibraryTask(id: "A-only", title: "A-only task", details: "", status: "open", recordingID: "42",
            requestID: request.id, conversationKey: "fixture", sourceSegments: [], createdAt: Date(), manuallyEdited: true)]
        try AIWorkspaceStore(root: hostA.root).save(workspaceA)
        let workspaceBytesA = try Data(contentsOf: AIWorkspaceStore(root: hostA.root).url)
        activate(libraryA, hostA)
        let importGate = VectaOwnershipReadGate()
        let importTask = Task { await model.importLibraryTasks(historyReader: { _ in await importGate.wait(); return [result] }) }
        try await importGate.awaitEntry()
        activate(libraryB, hostB); model.loadWorkspace()
        let tasksB = model.workspace.tasks
        importGate.release(); await importTask.value
        precondition(model.workspace.tasks == tasksB && model.workspaceStateRoot == hostB.root.standardizedFileURL && model.analysisMessage == nil)
        let unchangedWorkspaceA = try Data(contentsOf: AIWorkspaceStore(root: hostA.root).url)
        precondition(unchangedWorkspaceA == workspaceBytesA && model.workspace.tasks?.first?.title != "A-only task")

        let queueA = try NativeAnalysisQueue(url: NativeAnalysisQueue.scopedURL(processingRoot: hostA.root))
        let queueB = try NativeAnalysisQueue(url: NativeAnalysisQueue.scopedURL(processingRoot: hostB.root))
        try queueA.append([identity]); try queueB.append([identity])
        activate(libraryA, hostA); model.analysisQueue = queueA
        let queueGate = VectaOwnershipReadGate()
        let batchTask = Task { await model.pumpAnalysisQueue(historyReader: { _ in await queueGate.wait(); return [] }) }
        try await queueGate.awaitEntry()
        batchTask.cancel(); activate(libraryB, hostB); model.analysisQueue = queueB
        model.batchMessage = "B sentinel"; model.batchCount = 7; model.batchFailures = 3
        queueGate.release(); await batchTask.value
        precondition(model.batchMessage == "B sentinel" && model.batchCount == 7 && model.batchFailures == 3 && !model.batchChecking)
        precondition(queueA.jobs.count == 1 && queueA.jobs[0].requestID == nil && queueB.jobs.count == 1 && queueB.jobs[0].requestID == nil)
        let before = model.libraryGeneration
        await model.stop()
        precondition(model.libraryGeneration != before && model.batchMessage == nil && model.batchCount == 0 && model.batchFailures == 0 && model.batchProgress == nil)
        print("PASS library ownership: gated late source, workspace import, cancelled queue resume and shutdown presentation reset; equal recording IDs, isolated temporary fixtures, no workers/devices/Keychain/models")
    }
    @MainActor static func verifyModelDownloadHost() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "VectaHostDownloadChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        func wait(_ message: String, until condition: () async -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 6
            while !(await condition()) {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw NSError(domain: "VectaHostDownloadChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out: " + message])
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-host-downloads-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources"), exports = root.appendingPathComponent("Exports"), models = root.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("LocalAI"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false)
        let bytes = Data("host synthetic pinned model bytes".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = String(repeating: "b", count: 40)
        let ids = LocalModelManager.speechIDs + ["qwen4b", "qwen9b"]
        let definitions = ids.map { id in
            LocalModelDefinition(id: id, title: id, variant: "synthetic", repository: "fixture/" + id,
                revision: revision, license: "MIT", files: [LocalModelFile(name: "fixture.bin",
                    url: URL(string: "https://huggingface.co/fixture/\(id)/resolve/\(revision)/\(id == "whisper" ? "openai_whisper-large-v3-v20240930_turbo_632MB/" : "")fixture.bin")!,
                    sha256: hash, size: Int64(bytes.count))], backend: id.hasPrefix("qwen") ? "mlx" : nil)
        }
        try JSONEncoder().encode(LocalModelRegistry(version: 1, models: definitions)).write(to: resources.appendingPathComponent("LocalAI/models.json"))
        let gate = VectaHostDownloadGate()
        let host = try LocalAIHost(root: exports, resources: resources, modelsRoot: models,
            makeDownloader: { VectaHostFixtureDownloader(gate: gate, bytes: bytes) })
        // No start(): no mailbox polling, workers, timers, memory leases or owner state.
        await host.refreshModels()
        host.selectSummaryModel(.qwen4b)
        host.installAll()
        try check(ids.allSatisfy(host.isModelBusy), "All five installs must be admitted synchronously")
        try await wait("all five explicit downloads enter concurrently") { await gate.startedCount == 5 }
        try check(host.summaryModel == .qwen4b, "Installation must not change the selected model")
        try check(host.modelsNeeded(reuseTranscript: true) == ["qwen4b"], "Transcript reuse requires only the selected model")
        try check(Set(host.modelsNeeded(reuseTranscript: false)) == Set(["qwen4b"] + LocalModelManager.speechIDs), "Fresh processing requires selected model and speech, not both Qwens")
        try check(host.modelsNeeded(reuseTranscript: true, model: .qwen9b) == ["qwen9b"], "Frozen request selection must override later UI selection")
        await gate.release("qwen4b")
        try await wait("selected model completes independently") { host.statuses["qwen4b"]?.state == .installed && !host.isModelBusy("qwen4b") }
        try check(host.isModelBusy("qwen9b") && !host.modelsNeeded(reuseTranscript: true).contains(where: host.isModelBusy), "Unrelated 9B/speech downloads must not block selected-model reuse")
        host.cancelDownload("qwen9b")
        try await wait("cancelled task releases ownership") { !host.isModelBusy("qwen9b") }
        let qwenPartial = models.appendingPathComponent(".install-qwen9b-" + revision).appendingPathComponent("fixture.bin")
        try check(FileManager.default.fileExists(atPath: qwenPartial.path), "Cancellation preserves private resumable bytes")
        await gate.release("qwen9b")
        host.install("qwen9b")
        try await wait("explicit resume installs") { host.statuses["qwen9b"]?.state == .installed && !host.isModelBusy("qwen9b") }
        let attempts = await gate.attempts(for: "qwen9b")
        try check(attempts == 2, "Explicit resume creates exactly one new download")
        host.remove("whisper")
        try check(host.statuses["whisper"]?.state == .deleting, "Deletion closes admission before awaiting cancellation")
        host.install("whisper")
        try check(host.statuses["whisper"]?.state == .deleting, "Install cannot race a pending deletion")
        try await wait("download cancellation and partial removal") { host.statuses["whisper"]?.state == .notInstalled && !host.isModelBusy("whisper") }
        let whisperDirectory = try await host.manager.directory(for: "whisper")
        let whisperPartial = models.appendingPathComponent(".install-whisper-" + revision)
        try check(!FileManager.default.fileExists(atPath: whisperDirectory.path) && !FileManager.default.fileExists(atPath: whisperPartial.path), "Removal cleans installed and partial model paths")
        host.remove("qwen9b")
        await gate.release("whisper")
        host.install("whisper")
        try await wait("unrelated install during deletion") { host.statuses["whisper"]?.state == .installed && host.statuses["qwen9b"]?.state == .notInstalled && !host.isModelBusy("qwen9b") }
        let qwenDirectory = try await host.manager.directory(for: "qwen9b")
        try check(!FileManager.default.fileExists(atPath: qwenDirectory.path), "Explicit removal deletes an installed model")
        await gate.release("speaker"); await gate.release("tokenizer")
        try await wait("remaining independent speech installs") { LocalModelManager.speechIDs.allSatisfy { host.statuses[$0]?.state == .installed && !host.isModelBusy($0) } }
        // The fake invokes old progress after both success and cancellation. Let all
        // callbacks drain to prove generation guards prevent stale resurrection.
        try await Task.sleep(nanoseconds: 450_000_000)
        try check(host.statuses["qwen9b"]?.state == .notInstalled, "Late progress must not resurrect a deleted model")
        try check((["qwen4b"] + LocalModelManager.speechIDs).allSatisfy { host.statuses[$0]?.state == .installed && !host.isModelBusy($0) }, "Late cancelled/success callbacks must not replace terminal installed statuses")
        for id in ["qwen4b"] + LocalModelManager.speechIDs { _ = try await host.manager.verify(id) }
        try check(host.summaryModel == .qwen4b && !host.installingSpeech && host.activeRequest == nil, "Selection and idle state survive concurrent install/cancel/remove")
        print("PASS \(checks) host model-download checks: all five concurrent admissions, unchanged/frozen selection, required-only busy policy, explicit cancel/resume, delete-await-cancel, unrelated install, pinned integrity and stale-progress rejection. Isolated synthetic files and injected downloader only; no host start/poll, network, weights, workers, inference, devices or owner data.")
    }

    @MainActor static func verifyLibrarySearch() async throws {
        func check(_ condition:Bool,_ message:String = "Library search regression",line:Int = #line) throws {
            guard condition else {throw NSError(domain:"VectaLibrarySearchTest",code:line,userInfo:[NSLocalizedDescriptionKey:message+" (line \(line))"])}
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-library-search-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:root)}
        let index=try AITranscriptIndexStore(root:root,semanticSearch:false)
        func source(_ key:String,_ title:String,_ text:String) -> AILibrarySource {
            AILibrarySource(id:"",recordingKey:key,requestID:nil,transcriptID:nil,revision:"v1",title:title,date:Date(timeIntervalSince1970:0),text:text,segmentIDs:[7],start:12,end:19)
        }
        let target=source("survey","Анна Абрашина · рабочая встреча","Анна Абрашина: По опросу договорились отправить анкету в пятницу. Игорь подготовит вопросы.")
        try await index.replace(AILibraryDocument(key:target.recordingKey,revision:"v1",sources:[target]))
        let other=source("other","Опрос сотрудников","По опросу сотрудников пока ничего не решили.")
        try await index.replace(AILibraryDocument(key:other.recordingKey,revision:"v1",sources:[other]))
        let query="О чем мы договорились по поводу опроса с анной абрашиной?"
        let found=try await index.search(query,visible:["survey","other"])
        try check(found.first?.recordingKey=="survey" && found.first?.segmentIDs==[7] && found.first?.start==12,"Inflected participant and topic must find cited source without embedding assets")
        let base=try await index.search("Анна Абрашина опрос",visible:["survey","other"])
        try check(base.first?.recordingKey=="survey","Base and inflected names retrieve the same recording")
        let absent=try await index.search("космонавтика",visible:["survey","other"])
        try check(absent.isEmpty,"No lexical evidence must not invent a match")
        let quoted=try await index.search("\" OR * NEAR(опроса) --",visible:["survey"])
        try check(quoted.allSatisfy{$0.recordingKey=="survey"},"FTS punctuation stays data")
        let hidden=(0..<90).map {source("hidden-\($0)","Анна Абрашина опрос","Анна Абрашина опрос опрос опрос")}
        for value in hidden {try await index.replace(AILibraryDocument(key:value.recordingKey,revision:"v1",sources:[value]))}
        let scoped=try await index.search(query,visible:["survey"])
        try check(scoped.first?.recordingKey=="survey","Invisible recordings must not exhaust lexical candidate limit")
        let small=try await index.search(query,visible:["survey"],characterBudget:10)
        try check(small.isEmpty,"Character budget remains strict")
        let english=source("english","Survey planning","Anna: We agreed to send the survey on Friday.")
        try await index.replace(AILibraryDocument(key:english.recordingKey,revision:"v1",sources:[english]))
        let englishFound=try await index.search("What did we agree about the survey with Anna?",visible:["english"])
        try check(englishFound.first?.recordingKey=="english")
        let yo=source("yo","Артём","Артём: Отчёт отправим в четверг.")
        try await index.replace(AILibraryDocument(key:yo.recordingKey,revision:"v1",sources:[yo]))
        let yoFound=try await index.search("отчет Артем",visible:["yo"])
        try check(yoFound.first?.text==yo.text,"Search normalization must not rewrite quoted source text")
        let answer=AILibraryAnswer(schemaVersion:1,status:"answered",paragraphs:[AILibraryParagraph(text:"Договорились отправить анкету в пятницу.",sourceIDs:[found[0].id])])
        _=try answer.validated(sources:found)
        try await index.erase("survey")
        let deleted=try await index.search(query,visible:["survey"])
        try check(deleted.isEmpty,"Erased recording is not searchable")

        let resources=root.appendingPathComponent("Resources"),models=root.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at:resources.appendingPathComponent("LocalAI"),withIntermediateDirectories:true)
        let bytes=Data("synthetic model fixture, not weights".utf8),revision=String(repeating:"a",count:40)
        let hash=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        let definitions=["whisper","speaker","tokenizer","qwen4b","qwen9b"].map {id in
            LocalModelDefinition(id:id,title:id,variant:"fixture",repository:"fixture/test",revision:revision,license:"MIT",files:[LocalModelFile(name:"fixture.bin",url:URL(string:"https://huggingface.co/fixture/test/resolve/"+revision+"/"+(id == "whisper" ? "openai_whisper-large-v3-v20240930_turbo_632MB/":"")+"fixture.bin")!,sha256:hash,size:Int64(bytes.count))],backend:id.hasPrefix("qwen") ? "mlx":nil)
        }
        let registry=LocalModelRegistry(version:1,models:definitions)
        try JSONEncoder().encode(registry).write(to:resources.appendingPathComponent("LocalAI/models.json"))
        for id in ["qwen4b","qwen9b"] {
            let directory=models.appendingPathComponent(id+"-"+revision)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try bytes.write(to:directory.appendingPathComponent("fixture.bin"))
        }
        let exports=root.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at:exports,withIntermediateDirectories:false)
        let host=try LocalAIHost(root:exports,resources:resources,modelsRoot:models)
        for model in AISummaryModelID.allCases {
            try check(host.statuses[model.rawValue]?.state == .verifying)
            let directory=try await host.acquireAnswerModel(model)
            try check(directory.lastPathComponent==model.rawValue+"-"+revision && host.statuses[model.rawValue]?.state == .installed)
            await host.manager.release(model.rawValue)
        }
        try check(host.statuses["whisper"]?.state == .verifying,"Answer readiness requires no speech models")
        host.selectSummaryModel(.qwen9b)
        host.statuses["qwen9b"]?.state = .notInstalled
        let chosen=try await host.acquireAnswerModel(.qwen9b)
        try check(chosen.lastPathComponent.hasPrefix("qwen9b-") && host.summaryModel == .qwen9b,"Stale missing snapshot must use selected 9B, not silently switch to 4B")
        await host.manager.release("qwen9b")
        try Data(repeating:0,count:bytes.count).write(to:chosen.appendingPathComponent("fixture.bin"),options:.atomic)
        do {_=try await host.acquireAnswerModel(.qwen9b);preconditionFailure("Corrupt installed model accepted")} catch {
            try check(host.statuses["qwen9b"]?.state == .damaged && host.summaryModel == .qwen9b)
        }
        try FileManager.default.removeItem(at:chosen)
        host.statuses["qwen9b"]?.state = .installed
        do {_=try await host.acquireAnswerModel(.qwen9b);preconditionFailure("Missing model accepted")} catch {
            try check(host.statuses["qwen9b"]?.state == .notInstalled && host.summaryModel == .qwen9b)
        }
        print("PASS global library search: Russian name/topic inflections, English, ё/е, strict visibility/budget, 90 hidden decoys, source IDs/timestamps, deletion and no-evidence; shared selected 4B/9B verified acquire ignores stale UI status, needs no ASR and rejects corrupt/missing files. Synthetic only; no weights, downloads, inference or owner library.")
    }
}

private actor VectaHostDownloadGate {
    private var started = [String: Int]()
    private var released = Set<String>()
    var startedCount: Int { started.count }
    func begin(_ id: String) { started[id, default: 0] += 1 }
    func attempts(for id: String) -> Int { started[id, default: 0] }
    func release(_ id: String) { released.insert(id) }
    func isHeld(_ id: String) -> Bool { !released.contains(id) }
}

// Intentionally invokes callbacks after the downloader has returned, reproducing
// late delegate-to-MainActor publications without a URLSession or network.
private final class VectaHostLateProgress: @unchecked Sendable {
    let callback: (Int64) -> Void
    init(_ callback: @escaping (Int64) -> Void) { self.callback = callback }
    func schedule() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { self.callback(1) }
    }
}

private struct VectaHostFixtureDownloader: LocalModelDownloading {
    let gate: VectaHostDownloadGate
    let bytes: Data
    func download(_ file: LocalModelFile, to destination: URL, progress: @escaping (Int64) -> Void) async throws {
        let id = file.url.pathComponents[2]
        await gate.begin(id)
        let late = VectaHostLateProgress(progress)
        defer { late.schedule() }
        try bytes.prefix(3).write(to: destination, options: .atomic)
        progress(3)
        while await gate.isHeld(id) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Task.checkCancellation()
        try bytes.write(to: destination, options: .atomic)
        progress(file.size)
    }
}

extension NativeMacModel {
    @MainActor func prepareHighlightVerification(root: URL) throws {
        try prepareConversationVerification(root: root)
        let base = root.appendingPathComponent("catalog")
        let layout = NativeStorageLayout(recordingBase: base,
            userDirectory: base.appendingPathComponent("Users/" + VectaRecordingStore.userDirectoryName(for: "highlight-fixture")), servicesDirectory: root)
        let exporter = VectaLocalAudioExporter(userID: "highlight-fixture", defaults: VL.preferences)
        try exporter.configureFolder(root)
        let library = try NativeLibraryController(userID: "highlight-fixture", layout: layout, exporter: exporter)
        self.library = library
        let serial = "882SYNTHETIC", session = 123
        precondition(library.recordingStore.begin(sessionID: session, serialNumber: serial, duration: 60))
        let audio = library.recordingStore.audioDirectory(serialNumber: serial).appendingPathComponent("123.wav")
        try FileManager.default.copyItem(at: root.appendingPathComponent("synthetic.wav"), to: audio)
        precondition(library.recordingStore.markLocal(sessionID: session, serialNumber: serial, outputPath: audio.path))
        library.reloadLibrary()
        verificationItem = nil
        select(NativeRecordingIdentity(serialNumber: serial, sessionID: session))
        duration = 60
        if CommandLine.arguments.contains("--verify-highlight-ui") {
            precondition(library.recordingStore.saveHighlights(sessionID: session, serialNumber: serial, seconds: [30]))
            library.reloadLibrary()
            let recording = library.recordingStore.all[0]
            let filename = VectaLocalAudioExporter.filenames(for: recording)[0]
            let digest = SHA256.hash(data: try Data(contentsOf: audio)).map { String(format: "%02x", $0) }.joined()
            let request = AIProcessingRequest(version: 1, id: UUID(), recordingID: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
                audioFilename: filename, audioSHA256: digest, provider: .local, format: .standard, createdAt: Date(), summaryOnly: false, transcriptRequestID: nil, summaryModel: .qwen4b)
            try LocalAIFileStore(root: root).submit(request)
            let segments = [AISpeechSegment(id: 0, start: 5, end: 9, speaker: nil, text: "Before the highlight."),
                            AISpeechSegment(id: 1, start: 25, end: 35, speaker: nil, text: "This important part is highlighted."),
                            AISpeechSegment(id: 2, start: 49, end: 53, speaker: nil, text: "After the highlight.")]
            analyses = [AIProcessingResult(version: 1, request: request, stage: .completed,
                transcript: segments.map(\.text).joined(separator: " "), segments: segments, summary: AIStructuredSummary(summary: "Synthetic highlight example", topics: [], decisions: [], tasks: [], uncertainties: []),
                error: nil, updatedAt: Date(), duration: 60)]
            try LocalAIFileStore(root: root).save(analyses[0])
            let words: [[String: Any]] = [
                ["start": 5.0, "end": 9.0, "text": "Before the highlight."],
                ["start": 25.0, "end": 27.0, "text": "This important "],
                ["start": 27.0, "end": 31.0, "text": "part is "],
                ["start": 31.0, "end": 35.0, "text": "highlighted."],
                ["start": 49.0, "end": 53.0, "text": "After the highlight."]
            ]
            try JSONSerialization.data(withJSONObject: ["complete": true, "words": words, "centroids": [String: [Double]]()])
                .write(to: LocalAIFileStore(root: root).resultURL(request.id).appendingPathExtension("alignment.json"))
            analysisID = request.id
            waveform = Array(repeating: [Float(0.2),0.5,0.7,0.4,0.8], count: 30).flatMap { $0 }
            progress = 30
        }
    }
}
