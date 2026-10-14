import Foundation

@MainActor extension NativeMacModel {
    var batchCompletionMessage: String {
        batchFailures == 0 ? VL.text("Расшифровки и саммари готовы. Ранее созданные результаты сохранены.")
            : VL.text("Обработка завершена. Не удалось обработать записей: \(batchFailures). Повторите обработку нужной записи на её экране.")
    }
    func pumpAnalysisQueue(historyReader: ((NativeRecordingIdentity) async throws -> [AIProcessingResult])? = nil) async {
        guard !Task.isCancelled, localAI?.queuePaused != true, !batchChecking, let queue = analysisQueue, let job = queue.jobs.first,
              let library, let host = localAI else { return }
        let scope = NativeLibraryOperationScope(library: library, host: host, generation: libraryGeneration)
        func ownsQueue(checkCancellation: Bool = true) -> Bool {
            ownsLibraryOperation(scope, checkCancellation: checkCancellation) && analysisQueue === queue
        }
        batchChecking = true
        defer { if ownsQueue(checkCancellation: false) { batchChecking = false; batchCount = queue.jobs.count } }
        do {
            if let requestID = job.requestID {
                guard let result = try LocalAIFileStore(root: host.root).result(requestID) else {
                    batchFailures += 1
                    batchMessage = VL.text("Не найден сохранённый запрос обработки. Повторите синхронизацию.")
                    try queue.remove(job.identity,failed:true); return
                }
                if result.stage.isActive {
                    batchActiveRequest = requestID
                    batchProgress = result.recognitionProgress
                    batchTitle = library.items.first(where: { $0.identity == job.identity })?.title
                    batchMessage = result.stage.title + VL.text(" · осталось записей: \(queue.jobs.count)")
                    return
                }
                batchActiveRequest = nil; batchProgress = nil; batchTitle = nil
                if result.stage == .completed, let title = result.recordingTopicTitle {
                    _ = library.recordingStore.saveGeneratedTitle(sessionID: job.identity.sessionID, serialNumber: job.identity.serialNumber, title: title)
                    library.reloadLibrary()
                }
                try queue.remove(job.identity,failed:result.stage != .completed || result.visualError != nil)
                if result.stage != .completed || result.visualError != nil { batchFailures += 1 }
                batchMessage = result.stage == .completed ? (queue.jobs.isEmpty ? batchCompletionMessage : VL.text("В очереди обработки: \(queue.jobs.count)"))
                    : VL.text("Обработка записи остановлена: ") + (result.error ?? result.stage.title)
                if selected == job.identity { await reloadAnalysis() }
                return
            }
            guard !Task.isCancelled, !requestingAnalysis, pendingAnalysis == nil, host.activeRequest == nil,host.libraryWaitingCount==0 else { return }
            guard let item = library.items.first(where: { $0.identity == job.identity }), item.audioURL != nil else {
                try queue.remove(job.identity); return
            }
            let history: [AIProcessingResult]
            if let historyReader { history = try await historyReader(job.identity) }
            else { history = try await library.localHistory(for: job.identity) }
            guard ownsQueue() else { return }
            let legacy = try await library.legacyHistory(for: job.identity)
            guard ownsQueue() else { return }
            let decision = NativeAnalysisPolicy.decision(history: history, legacyTranscript: item.local?.transcript,
                legacySummary: legacy.results.contains { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            let source: UUID?
            switch decision {
            case .complete:
                try queue.remove(job.identity)
                if queue.jobs.isEmpty { batchMessage = batchCompletionMessage }
                return
            case .waiting:
                if let active = history.first(where: { $0.stage.isActive }) { try queue.attach(active.request.id, to: job.identity) }
                return
            case .summaryOnly(let id): source = id
            case .full: source = nil
            }
            let settings=job.settings ?? host.automaticSettings
            guard settings.model.isProductionModel else {
                batchMessage=AIProcessingError.retiredModel.localizedDescription
                return // Preserve queued settings until an explicit new MLX request.
            }
            let needed = [settings.model.rawValue] + (source == nil ? ["whisper", "speaker", "tokenizer"] : [])
            guard host.supported, needed.allSatisfy({ host.statuses[$0]?.state == .installed }) else {
                batchMessage = VL.text("Очередь сохранена. Для обработки установите WhisperKit и SpeakerKit и выбранную модель Qwen в разделе «Локальный ИИ».")
                return
            }
            guard ownsQueue() else { return }
            let recipes=NativeSummarySelection.recipes(formats:formats,templates:workspace.templates)
            guard let recipe=NativeSummarySelection.selected(settings.summaryRecipeID,legacyFormat:nil,in:recipes) else {throw AIProcessingError.invalidRequest}
            let format=recipe.format
            let requestID = try await library.requestLocalAI(for: job.identity, format: format, transcriptRequestID: source,summaryTemplate:recipe.template,automaticSettings:settings)
            guard ownsQueue() else { library.cancelLocalAI(requestID); return }
            try queue.attach(requestID, to: job.identity)
            batchActiveRequest = requestID
            batchMessage = VL.text("Локальная обработка · осталось записей: \(queue.jobs.count)")
            if selected == job.identity { if analysisID == nil { analysisID = requestID }; await reloadAnalysis() }
        } catch AIProcessingError.busy {
            // Another user request owns the bounded mailbox. Keep this job.
        } catch {
            guard ownsQueue() else { return }
            batchFailures += 1
            batchActiveRequest = nil; batchProgress = nil; batchTitle = nil
            batchMessage = VL.text("Не удалось обработать запись: ") + error.localizedDescription
            try? queue.remove(job.identity,failed:true) // no automatic failure/retry loop
        }
    }
}
