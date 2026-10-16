import CryptoKit
import Combine
import AppKit
import Darwin
import SwiftUI
import AVFoundation

@MainActor final class LocalAIHost: ObservableObject {
    @Published var provider: AIProviderID = .local
    @Published var summaryModel: AISummaryModelID = .qwen4b
    var visualModel:AISummaryModelID {summaryModel}
    @Published var automaticSettings = AIAutomaticSettings()
    @Published var statuses: [String: LocalModelStatus] = [:]
    @Published var message: String?
    /// Sent only after a terminal result is committed, before releasing the worker.
    let resultUpdates = PassthroughSubject<UUID, Never>()
    @Published var activeRequest: UUID?
    @Published var processingProgress:[UUID:AIWorkProgress]=[:]
    @Published var summaryDrafts:[UUID:String]=[:]
    @Published var visualDrafts:[UUID:AISemanticSummary]=[:]
    private var progressPlans:[UUID:AIProgressPlan]=[:]
    private var stageObservations:[UUID:(AIProcessingStage,Date)]=[:]
    private var measurements:[AIStageMeasurement]=[]
    private var resumedTimingStages:[UUID:Set<AIProcessingStage>]=[:]
    private var workerEventURL:URL?
    private var draftHandler:((String)->Void)?
    private var lastSemanticRevision:String?
    private var lastWorkerDraft:String?
    private var receivingWorkerState=false
    private var measurementRevision=0
    private var workerPollIdentity:AIWorkerPollIdentity {
        AIWorkerPollIdentity(requestID:visualOnlyID ?? activeRequest,visualOnlyID:visualOnlyID,eventURL:workerEventURL,checkpointURL:summaryCheckpoint)
    }
    /// Both polling cadences share one serialized decode/cache and one publication
    /// path. Capture all ownership before suspension; a new worker must never get
    /// a previous stage's progress or draft (including a retry with the same ID).
    private func receiveWorkerState() async {
        guard !receivingWorkerState,!Task.isCancelled,operation?.isCancelled != true,!stopped,let id=visualOnlyID ?? activeRequest else{return}
        receivingWorkerState=true;defer {receivingWorkerState=false}
        let identity=workerPollIdentity,file=identity.eventURL,checkpoint=identity.checkpointURL,visual=identity.visualOnlyID
        func ownsState()->Bool {
            identity.permitsPublication(current:workerPollIdentity,cancelled:Task.isCancelled || operation?.isCancelled==true,stopped:stopped)
        }
        guard let files=try? await mailbox.progressFiles(id,root:root,eventURL:file,checkpointURL:checkpoint),ownsState() else{return}
        if var result=files.result {
            if checkpoint != nil {result.summaryProgress=files.checkpoint}
            if visual==id {result.stage = .visualizing}
            observeProgress(result,event:files.worker?.event)
        }
        guard let worker=files.worker,let file,ownsState() else{return}
        if let data=worker.semanticData,worker.revision != lastSemanticRevision,let result=files.result,
           visual==id || result.stage == .visualizing {
            lastSemanticRevision=worker.revision
            let segments=result.segments
            let draft=try? await Task.detached(priority:.utility,operation:{try AISemanticSummary.decodeModelResponse(data,segments:segments)}).value
            guard ownsState(),await mailbox.workerRevisionMatches(file,revision:worker.revision),ownsState() else{return}
            if let draft,visualDrafts[id] != draft {visualDrafts[id]=draft}
        }
        guard ownsState(),let text=worker.event.draftText,text != lastWorkerDraft else{return}
        lastWorkerDraft=text
        if let draftHandler {draftHandler(text);return}
        summaryDrafts[id]=text
    }
    func persistResult(_ result: AIProcessingResult) throws {
        try store.save(result)
        if !result.stage.isActive {summaryDrafts[result.request.id]=nil;resultUpdates.send(result.request.id)}
    }
    private var visualOnlyID:UUID?
    private var measurementsURL:URL {root.appendingPathComponent("LocalAI/stage-measurements.json")}
    private func observeProgress(_ result:AIProcessingResult,event:AIWorkerEvent?=nil) {
        let id=result.request.id,now=Date()
        if let old=stageObservations[id],old.0 != result.stage {
            let seconds=now.timeIntervalSince(old.1)
            if !((resumedTimingStages[id] ?? []).contains(old.0)) && old.0.isActive && old.0 != .queued && ![AIProcessingStage.failed,.summaryFailed,.cancelled].contains(result.stage) && !(old.0 == .visualizing && result.visualError != nil) && seconds>0 {
                measurements.append(AIStageMeasurement(stage:old.0.rawValue,model:AIProgressPlan.model(old.0,result:result),inputBucket:AIProgressPlan.bucket(old.0,result:result),deviceMemoryGB:Int(ProcessInfo.processInfo.physicalMemory/1_073_741_824),seconds:seconds,recordedAt:now))
                measurements=Array(measurements.suffix(200))
                measurementRevision+=1
                let values=measurements,url=measurementsURL,revision=measurementRevision
                Task(priority:.utility) {await mailbox.saveMeasurements(values,to:url,revision:revision)}
            }
        }
        if stageObservations[id]?.0 != result.stage {stageObservations[id]=(result.stage,now)}
        // Freeze weights once duration is known. Loading the transcript must not
        // move an almost-finished bar backwards or pin it at 96% during summaries.
        if progressPlans[id]==nil || (visualOnlyID==id && progressPlans[id]?.stages != [.visualizing,.saving]), result.duration != nil || result.request.summaryOnly || visualOnlyID==id {
            progressPlans[id]=AIProgressPlan(result:result,visualOnly:visualOnlyID==id,history:measurements)
        }
        let plan=progressPlans[id] ?? AIProgressPlan(result:result,visualOnly:visualOnlyID==id,history:measurements)
        let next=plan.snapshot(result,event:event,previous:processingProgress[id],now:now,stageStartedAt:stageObservations[id]?.1)
        if AIProgressPublication.changed(processingProgress[id],next) {processingProgress[id]=next}
    }
    let root: URL
    let resources: URL
    let registry: LocalModelRegistry
    let manager: LocalModelManager
    @Published private(set) var installingSpeech=false
    @Published private(set) var removingSpeech=false
    private var downloads: [String: Task<Void, Never>] = [:]
    private var downloadGenerations: [String: UUID] = [:]
    @Published private(set) var downloadSpeeds: [String: Double] = [:]
    private var downloadSamples: [String: (TimeInterval, Int64)] = [:]
    private var timer: Timer?
    private let mailbox=LocalAIMailbox()
    private var polling=false
    private var startupComplete=false
    private var queueDirty=true
    private var lastQueueScan:TimeInterval=0
    private var queueWatcher:DispatchSourceFileSystemObject?
    private func watchQueue() {
        try? store.prepare()
        let fd=open(root.appendingPathComponent("LocalAI/Requests").path,O_EVTONLY)
        guard fd>=0 else{return}
        let source=DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete],queue:DispatchQueue.global(qos:.utility))
        source.setEventHandler { [weak self] in Task{@MainActor in self?.queueDirty=true} }
        source.setCancelHandler{Darwin.close(fd)};queueWatcher=source;source.resume()
    }
    private var lastSettingsSnapshot:LocalAISettingsSnapshot?
    private(set) var libraryAnswerActive=false
    var recordingOperationActive:Bool {activeRequest != nil && !libraryAnswerActive}
    private var operation: Task<Void, Never>?
    private var process: Process?
    private var speechRuntime: LocalAISpeechWorker?
    private var speechRuntimeClosing: Task<Void, Never>?
    private var speechWarmup: Task<Void, Never>?
    private var speechWarmupID: UUID?
    private var speechWarmupFailures = 0
    private var speechRequestActive = false
    private var closeSpeechAfterActive = false
    private var libraryRuntime:LocalAIWarmWorker?
    private var libraryRuntimeClosing:Task<Void,Never>?
    private var libraryIdleTask:Task<Void,Never>?
    private(set) var libraryWaitingCount=0
    private var summaryCheckpoint: URL?
    private var stopped = false
    private let resourceManager = LocalAIResourceManager()
    private var resourceInterrupted = false
    private let preferences: UserDefaults
    @Published var queuePaused: Bool
    @Published private(set) var fastTranscriptionEnabled: Bool
    func setQueuePaused(_ value: Bool) {
        queuePaused = value; preferences.set(value, forKey: "VectaLocalAIQueuePaused")
    }
    func setFastTranscriptionEnabled(_ value: Bool) {
        guard fastTranscriptionEnabled != value else { return }
        fastTranscriptionEnabled = value
        preferences.set(value, forKey: "VectaFastTranscriptionEnabled")
        if value {
            speechWarmupFailures = 0
            closeSpeechAfterActive = false
            Task { [weak self] in
                guard let self else { return }
                await self.cancelSpeechWarmup()
                if let closing = self.speechRuntimeClosing { await closing.value }
                await self.prewarmSpeechIfEligible()
            }
        } else {
            Task { [weak self] in
                guard let self, !self.fastTranscriptionEnabled else { return }
                await self.cancelSpeechWarmup()
                guard !self.fastTranscriptionEnabled else { await self.prewarmSpeechIfEligible(); return }
                if self.speechRequestActive { self.closeSpeechAfterActive = true }
                else { await self.closeSpeechRuntime() }
            }
        }
    }
    var onOpenSettings: (() -> Void)?
    private var refreshingModels = false
    private var store: LocalAIFileStore { LocalAIFileStore(root: root) }
    var supported: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 }

    init(root: URL, resources: URL, modelsRoot: URL? = nil, defaults: UserDefaults = VL.preferences,
         makeDownloader: @escaping @Sendable () -> any LocalModelDownloading = { LocalModelDownloader() }) throws {
        self.root = root; self.resources = resources; preferences = defaults
        queuePaused = defaults.bool(forKey: "VectaLocalAIQueuePaused")
        fastTranscriptionEnabled = (defaults.object(forKey: "VectaFastTranscriptionEnabled") as? Bool) ?? true
        registry = try LocalModelRegistry.load(from: resources.appendingPathComponent("LocalAI/models.json"))
        manager = try LocalModelManager(registry: registry, root: modelsRoot, makeDownloader: makeDownloader)
        if let data=try? Data(contentsOf:measurementsURL),data.count<1000000 {measurements=(try? JSONDecoder().decode([AIStageMeasurement].self,from:data)) ?? []}
        provider = .local; summaryModel = try store.summaryModel(); automaticSettings = try store.automaticAISettings()
        if !summaryModel.isProductionModel { message=AIProcessingError.retiredModel.localizedDescription }
        automaticSettings.model=summaryModel
        for model in registry.models { statuses[model.id] = LocalModelStatus(modelID: model.id, state: .verifying, received: 0, total: model.size, error: nil) }
    }
    func start() {
        watchQueue()
        resourceManager.onCritical = { [weak self] in
            guard let self else {return}
            self.libraryRuntime?.terminate()
            self.speechRuntime?.terminate()
            if self.activeRequest==nil {
                Task {
                    await self.cancelSpeechWarmup()
                    await self.closeSpeechRuntime()
                    await self.closeLibraryRuntime()
                }
                return
            }
            self.resourceInterrupted = true
            self.process?.terminate(); self.operation?.cancel()
        }
        Task {
            await refreshModels()
            await prewarmSpeechIfEligible()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        // Recovery may decode large histories, so it runs off the UI actor.
        let root=self.root
        Task { [weak self] in
            do {
                let recovered=try await Task.detached(priority:.utility) { () -> [UUID] in
                    let store=LocalAIFileStore(root:root);var ids=try store.recoverLegacyRequests()
                    for request in try store.requests() {
                        if var value=try store.result(request.id),value.stage.isActive && value.stage != .queued {
                            value.stage=value.transcript==nil ? .failed:.summaryFailed
                            value.error=AIProcessingError.interrupted.localizedDescription;value.updatedAt=Date();value.processingProgress=nil
                            try store.save(value);ids.append(request.id)
                        }
                    };return ids
                }.value
                guard let self,!self.stopped else{return};self.startupComplete=true
                for id in recovered {self.resultUpdates.send(id)}
                await self.poll()
                await self.prewarmSpeechIfEligible()
            } catch {self?.message=error.localizedDescription;self?.startupComplete=true}
        }
    }
    func selectSummaryModel(_ value: AISummaryModelID) {
        guard AISummaryModelID.allCases.contains(value), value.compatible() else { message = VL.text("Модель не подходит для объёма памяти этого Mac."); return }
        do { try store.setSummaryModel(value); summaryModel = value; automaticSettings.model=value;try store.setAutomaticAISettings(automaticSettings); message = nil }
        catch { message = VL.text("Не удалось сохранить выбранную модель.") }
        if activeRequest==nil {Task{await closeLibraryRuntime()}}
    }
    func selectVisualModel(_ value:AISummaryModelID) {
        selectSummaryModel(value)
    }
    func setAutomaticSettings(_ value:AIAutomaticSettings) {
        do {var unified=value;unified.model=summaryModel;try store.setAutomaticAISettings(unified);automaticSettings=unified;message=nil}
        catch {message=error.localizedDescription}
    }
    func refreshModels() async {
        guard !refreshingModels else { return }
        refreshingModels = true
        defer { refreshingModels = false }
        for model in registry.models where downloads[model.id] == nil && statuses[model.id]?.state != .deleting && !(installingSpeech && LocalModelManager.speechIDs.contains(model.id)) {
            do {
                _ = try await manager.verify(model.id)
                guard downloads[model.id] == nil, statuses[model.id]?.state != .deleting else { continue }
                statuses[model.id] = LocalModelStatus(modelID: model.id, state: .installed, received: model.size, total: model.size, error: nil)
            } catch is CancellationError {
                // Cancelled optional downloads must not mark unrelated installed
                // models damaged merely because hashing inherits cancellation.
                return
            } catch {
                let directory = try? await manager.directory(for: model.id)
                let exists = directory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                guard downloads[model.id] == nil, statuses[model.id]?.state != .deleting else { continue }
                if statuses[model.id]?.state != .failed {
                    statuses[model.id] = LocalModelStatus(modelID: model.id, state: exists ? .damaged : .notInstalled, received: 0, total: model.size, error: nil)
                }
            }
        }
    }
    /// Published status is a UI snapshot, not proof that a selected model is absent.
    /// Acquire through the same pinned manager used by processing; no installation,
    /// alternate model selection or speech-model requirement is involved.
    func acquireAnswerModel(_ model: AISummaryModelID) async throws -> URL {
        guard model.isProductionModel else { throw AIProcessingError.retiredModel }
        guard model.compatible() else { throw AIProcessingError.invalidRequest }
        do {
            let directory = try await manager.acquire(model.rawValue)
            guard !Task.isCancelled, !stopped else {
                await manager.release(model.rawValue)
                throw CancellationError()
            }
            let size = registry.models.first(where: { $0.id == model.rawValue })?.size ?? 0
            statuses[model.rawValue] = LocalModelStatus(modelID: model.rawValue, state: .installed, received: size, total: size, error: nil)
            return directory
        } catch is CancellationError { throw CancellationError() }
        catch LocalModelError.inUse { throw LocalModelError.inUse }
        catch {
            let directory = try? await manager.directory(for: model.rawValue)
            let exists = directory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let size = registry.models.first(where: { $0.id == model.rawValue })?.size ?? 0
            let message = VL.text("Не удалось открыть выбранную модель «") + model.selectionTitle + VL.text("». Проверьте её состояние в разделе «Локальный ИИ».")
            statuses[model.rawValue] = LocalModelStatus(modelID: model.rawValue, state: exists ? .damaged : .notInstalled, received: 0, total: size, error: message)
            throw NSError(domain: "VectaLocalAI", code: 1, userInfo: [NSLocalizedDescriptionKey: message, NSUnderlyingErrorKey: error])
        }
    }
    func modelsNeeded(reuseTranscript: Bool, model: AISummaryModelID? = nil) -> [String] {
        [(model ?? summaryModel).rawValue] + (reuseTranscript ? [] : LocalModelManager.speechIDs)
    }
    func isModelBusy(_ id: String) -> Bool {
        downloads[id] != nil || [.preparing, .downloading, .verifying, .deleting].contains(statuses[id]?.state)
    }
    private func modelsNeeded(for request: AIProcessingRequest) -> [String] {
        (request.wantsSummary ? [request.selectedSummaryModel.rawValue] : []) +
            (request.summaryOnly ? [] : ["whisper", "tokenizer"] + (request.wantsDiarization ? ["speaker"] : []))
    }
    func install(_ id: String) {
        guard supported, registry.models.contains(where: { $0.id == id }), downloads[id] == nil,
              statuses[id]?.state != .deleting, !(removingSpeech && LocalModelManager.speechIDs.contains(id)) else { return }
        let total = registry.models.first(where: { $0.id == id })?.size ?? 0
        statuses[id] = LocalModelStatus(modelID: id, state: .preparing, received: 0, total: total, error: nil)
        message = nil
        if LocalModelManager.speechIDs.contains(id) { installingSpeech = true }
        let generation = UUID()
        downloadGenerations[id] = generation
        downloadSamples[id] = nil; downloadSpeeds[id] = nil
        downloads[id] = Task { [weak self] in
            guard let self else { return }
            if libraryRuntime?.modelID == id, !libraryAnswerActive { await closeLibraryRuntime() }
            do {
                try await manager.install(id) { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.downloadGenerations[id] == generation, self.statuses[id]?.state != .deleting else { return }
                        if status.state == .downloading {
                            let now = ProcessInfo.processInfo.systemUptime
                            if let sample = self.downloadSamples[id] {
                                if now - sample.0 >= 1 {
                                    self.downloadSpeeds[id] = Double(max(0, status.received - sample.1)) / (now - sample.0)
                                    self.downloadSamples[id] = (now, status.received)
                                }
                            } else { self.downloadSamples[id] = (now, status.received) }
                        }
                        self.statuses[id] = status
                    }
                }
                if statuses[id]?.state != .deleting {
                    statuses[id] = LocalModelStatus(modelID: id, state: .installed, received: total, total: total, error: nil)
                    if LocalModelManager.speechIDs.contains(id) { speechWarmupFailures = 0 }
                }
            } catch {
                if statuses[id]?.state != .deleting {
                    statuses[id] = LocalModelStatus(modelID: id, state: error is CancellationError ? .notInstalled : .failed,
                        received: 0, total: total, error: error is CancellationError ? nil : error.localizedDescription)
                }
            }
            downloadGenerations[id] = nil; downloadSamples[id] = nil; downloadSpeeds[id] = nil
            downloads[id] = nil
            installingSpeech = removingSpeech || LocalModelManager.speechIDs.contains { self.downloads[$0] != nil }
            queueDirty = true
            await refreshModels()
            await prewarmSpeechIfEligible()
        }
    }
    func installSpeech() {
        guard supported, !removingSpeech else { return }
        for id in LocalModelManager.speechIDs where statuses[id]?.state != .installed { install(id) }
    }
    func installAll() {
        for model in registry.models where statuses[model.id]?.state != .installed { install(model.id) }
    }
    func cancelSpeechDownload() { for id in LocalModelManager.speechIDs { cancelDownload(id) } }
    func removeSpeech() {
        guard !removingSpeech, activeRequest == nil else { message = LocalModelError.inUse.localizedDescription; return }
        removingSpeech = true; installingSpeech = true
        let tasks = LocalModelManager.speechIDs.compactMap { downloads[$0] }
        for task in tasks { task.cancel() }
        for id in LocalModelManager.speechIDs { statuses[id]?.state = .deleting }
        Task {
            for task in tasks { await task.value }
            await cancelSpeechWarmup()
            await closeSpeechRuntime()
            for id in LocalModelManager.speechIDs {
                do {
                    try await manager.remove(id)
                    statuses[id] = LocalModelStatus(modelID: id, state: .notInstalled, received: 0,
                        total: registry.models.first(where: { $0.id == id })?.size ?? 0, error: nil)
                } catch { statuses[id]?.state = .failed; statuses[id]?.error = error.localizedDescription; message = error.localizedDescription }
            }
            installingSpeech = false; removingSpeech = false; queueDirty = true
            await refreshModels()
        }
    }
    func cancelDownload(_ id: String) { downloads[id]?.cancel() }
    func remove(_ id: String) {
        guard registry.models.contains(where: { $0.id == id }), statuses[id]?.state != .deleting,
              activeRequest == nil, !(removingSpeech && LocalModelManager.speechIDs.contains(id)) else {
            message = LocalModelError.inUse.localizedDescription; return
        }
        let download = downloads[id]
        download?.cancel()
        statuses[id]?.state = .deleting
        Task {
            await download?.value
            if LocalModelManager.speechIDs.contains(id) {
                await cancelSpeechWarmup()
                await closeSpeechRuntime()
            }
            if libraryRuntime?.modelID == id { await closeLibraryRuntime() }
            do {
                try await manager.remove(id)
                statuses[id] = LocalModelStatus(modelID: id, state: .notInstalled, received: 0,
                    total: registry.models.first(where: { $0.id == id })?.size ?? 0, error: nil)
            } catch { statuses[id]?.state = .failed; statuses[id]?.error = error.localizedDescription; message = error.localizedDescription }
            queueDirty = true
            await refreshModels()
        }
    }
    func showSettings() {
        onOpenSettings?()
    }
    private func poll() async {
        guard !stopped,startupComplete,!polling else{return};polling=true;defer{polling=false}
        do {
            if recordingOperationActive {await receiveWorkerState()}
            guard !stopped,!Task.isCancelled else{return}
            let models=registry.models.map {model in LocalAIModelSettings(id:model.id,title:model.title,variant:model.variant,size:model.size,license:model.license,state:LocalAIModelState(rawValue:statuses[model.id]?.state.rawValue ?? "verifying") ?? .verifying,received:statuses[model.id]?.received ?? 0,error:statuses[model.id]?.error)}
            let snapshot=LocalAISettingsSnapshot(models:models,summaryModel:summaryModel,supported:supported,isProcessing:activeRequest != nil,message:message,updatedAt:Date(timeIntervalSince1970:0))
            let changed=lastSettingsSnapshot != snapshot,store=self.store,active=activeRequest
            let events=try await Task.detached(priority:.utility) { () -> (Bool,[LocalAISettingsCommand],Bool) in
                let settings=try store.consumeSettingsRequest(),commands=try store.consumeSettingsCommands()
                if changed {try store.saveSettingsSnapshot(LocalAISettingsSnapshot(models:snapshot.models,summaryModel:snapshot.summaryModel,supported:snapshot.supported,isProcessing:snapshot.isProcessing,message:snapshot.message,updatedAt:Date()))}
                return (settings,commands,active.map{FileManager.default.fileExists(atPath:store.cancelURL($0).path)} ?? false)
            }.value
            guard !stopped else{return};lastSettingsSnapshot=snapshot
            if events.0 {showSettings()}
            for command in events.1 {
                switch command.action {
                case .refresh:Task{await refreshModels()}
                case .selectSummaryModel:if let id=command.modelID,let model=AISummaryModelID(rawValue:id){selectSummaryModel(model)}
                case .install:if let id=command.modelID{install(id)}
                case .cancelDownload:if let id=command.modelID{cancelDownload(id)}
                case .remove:if let id=command.modelID{remove(id)}
                }
            }
            if events.2,activeRequest==active {process?.terminate();operation?.cancel();return}
            guard operation==nil,activeRequest==nil,libraryWaitingCount==0,libraryRuntimeClosing==nil,!queuePaused else{return}
            if let reason=resourceManager.waitingReason {if message != reason{message=reason};return}
            let now=ProcessInfo.processInfo.systemUptime
            guard queueDirty || now-lastQueueScan>=30 else{return}
            queueDirty=false;lastQueueScan=now
            if let request=try await mailbox.nextRequest(root:root) {
                guard !stopped,operation==nil,activeRequest==nil,libraryWaitingCount==0,!queuePaused else{return}
                if modelsNeeded(for: request).contains(where: isModelBusy) {
                    queueDirty = true
                    message = VL.text("Запрос сохранён. Обработка начнётся после установки необходимых моделей.")
                    return
                }
                if libraryRuntime != nil {queueDirty=true;Task{await closeLibraryRuntime()};return}
                if speechWarmup != nil {
                    await cancelSpeechWarmup()
                    queueDirty = true
                    return
                }
                guard try resourceManager.acquire() else{queueDirty=true;message=VL.text("Очередь ожидает освобождения локальной модели другим экземпляром Vecta.");return}
                resourceInterrupted=false;message=nil;activeRequest=request.id
                operation=Task{await run(request);resourceManager.release();activeRequest=nil;operation=nil;queueDirty=true}
            } else {
                Task { [weak self] in await self?.prewarmSpeechIfEligible() }
            }
        } catch {if message != error.localizedDescription{message=error.localizedDescription}}
    }
    private func run(_ request: AIProcessingRequest) async {
        summaryCheckpoint=nil;processingProgress[request.id]=nil;stageObservations[request.id]=nil
        resumedTimingStages[request.id]=[]
        defer {resumedTimingStages[request.id]=nil}
        var result = (try? store.result(request.id)) ?? AIProcessingResult(version: 1, request: request, stage: .queued,
            transcript: nil, segments: [], summary: nil, error: nil, updatedAt: Date(), duration: nil, recognitionSeconds: nil, summarySeconds: nil)
        do {
            guard supported else { throw NSError(domain: "LocalAI", code: 15, userInfo: [NSLocalizedDescriptionKey: VL.text("Локальный AI требует macOS 15 или новее.")]) }
            try request.validate()
            guard request.selectedSummaryModel.isProductionModel else {throw AIProcessingError.retiredModel}
            // A checkpoint recovery must not teach fresh-job ETA that a full
            // recording takes only the remaining fraction of inference time.
            let speechCache=request.speechCheckpointURL(for:store.resultURL(request.id))
            try store.registerArtifact(speechCache, for: request.id)
            if FileManager.default.fileExists(atPath:speechCache.path) {
                resumedTimingStages[request.id]=[.loadingRecognition,.recognizing]
            }
            guard !request.wantsSummary || request.selectedSummaryModel.compatible() else { throw NSError(domain:"Vecta",code:16,userInfo:[NSLocalizedDescriptionKey:request.selectedSummaryModel.memoryRequirement]) }
            if !request.summaryOnly && request.wantsSummary { _ = try await manager.verify(request.selectedSummaryModel.rawValue) }
            if FileManager.default.fileExists(atPath: store.cancelURL(request.id).path) { throw CancellationError() }
            if request.summaryOnly {
                guard let sourceID = request.transcriptRequestID, let source = try store.result(sourceID),
                      source.request.audioSHA256 == request.audioSHA256, source.request.audioFilename == request.audioFilename,
                      let transcript = source.transcript, !transcript.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw AIProcessingError.invalidTranscript }
                result.transcript = transcript; result.segments = source.segments; result.duration = source.duration
                result.recognitionSeconds = source.recognitionSeconds; result.unmatchedText = source.unmatchedText
            } else {
                var speechModels: [String:URL] = [:]
                let speechIDs = ["whisper", "tokenizer"] + (request.wantsDiarization ? ["speaker"] : [])
                do {
                    for id in speechIDs { speechModels[id] = try await manager.acquire(id) }
                    let audio = root.appendingPathComponent("Inbox").appendingPathComponent(request.audioFilename)
                    let audioDuration = try await AVURLAsset(url:audio).load(.duration).seconds
                    try AIAudioPolicy.validate(duration:audioDuration)
                    let attributes = try audio.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw AIProcessingError.invalidRequest }
                    let file = LocalModelFile(name: request.audioFilename, url: audio, sha256: request.audioSHA256, size: Int64(attributes.fileSize ?? 0))
                    try await Task.detached { try LocalModelIntegrity.verify(file, at: audio) }.value
                    if fastTranscriptionEnabled {
                        try await recognizeWithPersistentSpeech(request: request, audio: audio,
                            whisper: speechModels["whisper"]!, speaker: speechModels["speaker"],
                            tokenizer: speechModels["tokenizer"]!, output: store.resultURL(request.id))
                    } else {
                        _ = try await execute(resources.appendingPathComponent("LocalAI/VectaSpeech"),
                            arguments: [store.requestURL(request.id).path, audio.path, speechModels["whisper"]!.path, speechModels["speaker"]?.path ?? "", speechModels["tokenizer"]!.path, store.resultURL(request.id).path])
                    }
                    let decoded=try JSONDecoder().decode(AIProcessingResult.self,from:Data(contentsOf:store.resultURL(request.id)))
                    result=try AISpeechResultAcceptance.accept(decoded,request:request,duration:audioDuration)
                    for id in speechModels.keys { await manager.release(id) }
                } catch { for id in speechModels.keys { await manager.release(id) }; throw error }
            }
            try Task.checkCancellation()
            if !request.wantsSummary {
                result.stage = .completed; result.error = nil; result.updatedAt = Date()
                observeProgress(result); result.processingProgress = processingProgress[request.id]
                try persistResult(result); return
            }
            result.stage = .loadingSummary; result.updatedAt = Date(); observeProgress(result); try persistResult(result)
            let summaryID = request.selectedSummaryModel.rawValue
            let qwen = try await manager.acquire(summaryID)
            do {
                guard let definition = registry.models.first(where: { $0.id == summaryID }), definition.backend == "mlx" else { throw AIProcessingError.modelsMissing }
                let conversationKey=SHA256.hash(data:Data((request.audioSHA256+(request.transcriptRequestID ?? request.id).uuidString).utf8)).map {String(format:"%02x",$0)}.joined()
                let conversationStore=AIConversationStore(root:root)
                let recording=try conversationStore.recording(conversationKey,segments:result.segments)
                let speakers=try conversationStore.voices().resolving(recording,result:result,alignment:store.speakerAlignment(for:result),key:conversationKey)
                let corrected=speakers.rendered(result).segments
                let language=request.resultLanguage
                let style=request.format.localizedPrompt(in:language)+(request.summaryTemplate.map {(language == .english ? "\nTemplate structure: ":"\nСтруктура шаблона «")+$0.title+(language == .english ? "\n":"»: ")+$0.localizedPrompt(in:language)} ?? "")
                var summaryInput: [String: Any] = ["format_prompt": style,
                    "segments": try JSONSerialization.jsonObject(with: JSONEncoder().encode(corrected)),
                    "unmatched_text": result.unmatchedText ?? "", "context_tokens": ProcessInfo.processInfo.physicalMemory < 16 * 1_073_741_824 ? 4096 : 8192]
                if let language=request.outputLanguage {summaryInput["output_language"]=language}
                summaryInput["context_tokens"] = 262144;summaryInput["use_evaluated_detailed_prompt"] = request.format == .detailed && request.summaryTemplate == nil
                let data = try JSONSerialization.data(withJSONObject: summaryInput, options: .sortedKeys)
                result.stage = .summarizing; result.updatedAt = Date(); observeProgress(result); try persistResult(result)
                let checkpoints=root.appendingPathComponent("LocalAI/SummaryCheckpoints",isDirectory:true)
                try FileManager.default.createDirectory(at:checkpoints,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let key=SHA256.hash(data:data+Data(definition.revision.utf8)).map { String(format:"%02x",$0) }.joined()
                let checkpoint=checkpoints.appendingPathComponent(key+".json")
                summaryCheckpoint=checkpoint
                try store.registerArtifact(checkpoint, for: request.id)
                if FileManager.default.fileExists(atPath:checkpoint.path) {resumedTimingStages[request.id,default:[]].insert(.summarizing)}
                let response = try await execute(resources.appendingPathComponent("LocalAI/VectaMLX"), arguments: [qwen.path,checkpoint.path], input: data)
                let decoded = try AITextSummaryRecovery.decode(response,speakerIDs:Set(corrected.compactMap(\.resolvedSpeakerID)))
                try decoded.summary.validate(segmentIDs: Set(result.segments.map(\.id)))
                for block in decoded.summary.blocks ?? [] { try block.validate(segments:corrected,allowUnsourced:decoded.summary.sourcePolicy == "none") }
                result.summarySpeakerIDs=Array(Set(corrected.compactMap(\.speakerID))).sorted()
                // Explicit assignment/deadline must literally occur in cited data.
                let tasks = decoded.summary.tasks.map { task -> AIActionItem in
                    let evidence = result.segments.filter { decoded.summary.sourcePolicy == "none" || task.sourceSegments.contains($0.id) }.map(\.text).joined(separator: " ")
                    return AIActionItem(description: task.description,
                        assignee: task.assignee.flatMap { !$0.isEmpty && evidence.localizedCaseInsensitiveContains($0) ? $0 : nil },
                        deadline: task.deadline.flatMap { !$0.isEmpty && evidence.localizedCaseInsensitiveContains($0) ? $0 : nil }, sourceSegments: task.sourceSegments)
                }
                result.summary = AIStructuredSummary(summary: decoded.summary.summary, topics: decoded.summary.topics,
                    decisions: decoded.summary.decisions, tasks: tasks, uncertainties: decoded.summary.uncertainties, recordingTitle: decoded.summary.recordingTitle, blocks: try decoded.summary.blocks?.map { try $0.resolvingEvidence(result.segments) },sourcePolicy:decoded.summary.sourcePolicy,textRepresentation:decoded.summary.textRepresentation).withoutSourceLinks
                result.fullTextSummary=result.summary.map(AIFullTextSummary.preserving)
                result.summaryDraft=nil
                result.summarySeconds = decoded.seconds
                // Commit successful text before the optional 9B visual stage.
                // A rejected visual JSON cannot destroy ASR or text summary.
                result.updatedAt=Date();observeProgress(result);try persistResult(result)
                await manager.release(summaryID)
                if request.wantsVisual {
                    result.stage = .visualizing;result.updatedAt=Date();observeProgress(result);try persistResult(result)
                    do {
                        let generated=try await generateSemantic(model:request.selectedVisualModel,summary:result.summary,segments:corrected,format:request.format,template:request.summaryTemplate,language:request.resultLanguage)
                        result.semanticSummary=generated.0;result.visualSummary=generated.0.visual(style:.editorial)
                        result.visualError=nil;result.visualSeconds=generated.1;result.visualModel=request.selectedVisualModel.rawValue
                    } catch {
                        result.visualError=VL.text("Инфографика не создана: ")+error.localizedDescription
                        result.updatedAt=Date();observeProgress(result);try persistResult(result);try Task.checkCancellation()
                    }
                }
                await manager.release(summaryID)
            } catch { await manager.release(summaryID); throw error }
            try Task.checkCancellation()
            result.stage = .completed; result.error = nil; result.updatedAt = Date(); observeProgress(result);result.processingProgress=processingProgress[request.id];try persistResult(result)
        } catch {
            if let existing = try? store.result(request.id), existing.request == request { result = existing }
            result.stage = resourceInterrupted ? (result.transcript == nil ? .failed : .summaryFailed) : error is CancellationError || Task.isCancelled ? .cancelled : result.transcript != nil ? .summaryFailed : .failed
            result.error = resourceInterrupted ? VL.text("Обработка остановлена из-за давления памяти. Исходная запись сохранена; обработку можно запустить повторно.") : result.stage == .cancelled ? VL.text("Обработка отменена.") : result.error ?? error.localizedDescription
            result.updatedAt = Date();observeProgress(result);result.processingProgress=processingProgress[request.id];try? persistResult(result)
        }
    }
    /// Uses the same worker, manager, pressure gate and cross-process lease as summaries.
    /// Freeze the shared model before awaiting; settings cannot reroute a running answer.
    func answer(question:String,segments:[AISpeechSegment],history:[AIChatMessage],onDraft:((String)->Void)? = nil) async throws -> AIStructuredSummary {
        guard supported,activeRequest==nil,operation==nil,!isModelBusy(summaryModel.rawValue) else {throw AIProcessingError.busy}
        await cancelSpeechWarmup()
        await closeLibraryRuntime()
        guard activeRequest==nil,operation==nil else {throw AIProcessingError.busy}
        guard !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,question.count<=2000,!segments.isEmpty else {throw AIProcessingError.invalidRequest}
        let model=summaryModel,modelID=model.rawValue
        guard try resourceManager.acquire() else {throw AIProcessingError.busy}
        activeRequest=UUID();resourceInterrupted=false;draftHandler=onDraft
        defer {activeRequest=nil;draftHandler=nil;resourceManager.release()}
        do {
            let directory=try await acquireAnswerModel(model)
            guard let definition=registry.models.first(where:{$0.id==modelID}),definition.backend == "mlx" else {throw AIProcessingError.modelsMissing}
            let conservative=ProcessInfo.processInfo.physicalMemory < 16*1_073_741_824
            let selected=AITranscriptRetrieval.select(segments,question:question,characterBudget:conservative ? 3500:9000)
            guard !selected.isEmpty else {throw AIProcessingError.invalidRequest}
            let data=try JSONSerialization.data(withJSONObject:["mode":"assistant","output_language":VL.language.rawValue,"question":question,"history":history.suffix(4).map { ["role":$0.role,"text":String($0.text.prefix(600))] },"segments":try JSONSerialization.jsonObject(with:JSONEncoder().encode(selected)),"context_tokens":262144])
            let bytes=try await execute(resources.appendingPathComponent("LocalAI/VectaMLX"),arguments:[directory.path],input:data)
            var value=try AITextSummaryRecovery.decode(bytes,speakerIDs:Set(selected.compactMap(\.resolvedSpeakerID))).summary
            try value.validate(segmentIDs:Set(selected.map(\.id)))
            for block in value.blocks ?? [] {try block.validate(segments:selected,allowUnsourced:value.sourcePolicy == "none")}
            value.blocks=try value.blocks?.map {try $0.resolvingEvidence(segments)}
            try Task.checkCancellation();await manager.release(modelID);return value
        } catch {await manager.release(modelID);throw error}
    }
    /// Retries only the optional renderer input stage; saved speech and text stay intact.
    var hasActiveWorker:Bool {process?.isRunning == true}
    func retryVisual(_ id:UUID) async throws {
        guard supported,activeRequest==nil,operation==nil,!isModelBusy(summaryModel.rawValue) else {throw AIProcessingError.busy}
        await cancelSpeechWarmup()
        await closeLibraryRuntime()
        guard activeRequest==nil,operation==nil else {throw AIProcessingError.busy}
        guard var result=try store.result(id),result.summary != nil else {throw AIProcessingError.invalidSummary}
        guard try resourceManager.acquire() else {throw AIProcessingError.busy}
        activeRequest=id;visualOnlyID=id;processingProgress[id]=nil;stageObservations[id]=nil;resourceInterrupted=false
        defer {activeRequest=nil;visualOnlyID=nil;resourceManager.release()}
        do {
            let selected=visualModel // snapshot before the first await
            let request=result.request
            let key=SHA256.hash(data:Data((request.audioSHA256+(request.transcriptRequestID ?? request.id).uuidString).utf8)).map {String(format:"%02x",$0)}.joined()
            let conversationStore=AIConversationStore(root:root)
            let recording=try conversationStore.recording(key,segments:result.segments)
            let speakers=try conversationStore.voices().resolving(recording,result:result,alignment:store.speakerAlignment(for:result),key:key)
            let corrected=speakers.rendered(result).segments
            let generated=try await generateSemantic(model:selected,summary:result.summary,segments:corrected,format:result.request.format,template:result.request.summaryTemplate,language:result.request.resultLanguage)
            try Task.checkCancellation()
            result.semanticSummary=generated.0;result.visualSummary=generated.0.visual(style:.editorial)
            result.visualError=nil;result.visualSeconds=generated.1;result.visualModel=selected.rawValue
            result.updatedAt=Date();observeProgress(result);result.processingProgress=processingProgress[id];try persistResult(result)
        } catch {
            result.visualError=Task.isCancelled ? VL.text("Создание визуального отчёта отменено."):VL.text("Визуальное саммари не создано: ")+error.localizedDescription
            result.updatedAt=Date();var state=result;state.stage=Task.isCancelled ? .cancelled:.failed;observeProgress(state);result.processingProgress=processingProgress[id];try? persistResult(result)
            throw error
        }
    }
    private func generateSemantic(model:AISummaryModelID,summary:AIStructuredSummary?,segments:[AISpeechSegment],format:VectaSummaryInterpretation,template:AISummaryTemplate?,language:VectaLanguage)async throws->(AISemanticSummary,Double) {
        let requestID=visualOnlyID ?? activeRequest
        if let requestID {visualDrafts.removeValue(forKey:requestID)}
        defer {if let requestID {visualDrafts.removeValue(forKey:requestID)}}
        guard model.compatible(),statuses[model.rawValue]?.state == .installed else {throw AIProcessingError.modelsMissing}
        let id=model.rawValue
        do {
            let directory=try await manager.acquire(id)
            guard let definition=registry.models.first(where:{$0.id==id}),definition.backend == "mlx" else {throw AIProcessingError.modelsMissing}
            let context=262144
            let evidence=segments
            let input=try JSONSerialization.data(withJSONObject:["mode":"semantic","output_language":language.rawValue,"model":id,"context_tokens":context,"format_prompt":format.localizedPrompt(in:language)+(template.map {"\n"+$0.localizedPrompt(in:language)} ?? ""),"format_id":format.id,"facts":try JSONSerialization.jsonObject(with:JSONEncoder().encode(summary)),"segments":try JSONSerialization.jsonObject(with:JSONEncoder().encode(evidence))])
            let bytes=try await execute(resources.appendingPathComponent("LocalAI/VectaMLX"),arguments:[directory.path],input:input)
            guard let envelope=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],let raw=envelope["semantic"] else {throw AIProcessingError.invalidSummary}
            let semantic=try AISemanticSummary.decodeModelResponse(JSONSerialization.data(withJSONObject:raw),segments:segments,fallbackText:summary?.summary)
            try Task.checkCancellation();await manager.release(id)
            return (semantic.withoutSourceLinks,envelope["seconds"] as? Double ?? 0)
        } catch {await manager.release(id);throw error}
    }
    private func execute(_ executable: URL, arguments: [String], input: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        var workerArguments=arguments
        if ["VectaSpeech","VectaMLX"].contains(executable.lastPathComponent) {
            let directory=root.appendingPathComponent("LocalAI/WorkerEvents",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let file=directory.appendingPathComponent(UUID().uuidString+".json");workerEventURL=file
            if let id = visualOnlyID ?? activeRequest { try store.registerArtifact(file, for: id) }
            if executable.lastPathComponent == "VectaMLX" {
                if workerArguments.count==1 {workerArguments.append("")};workerArguments.append(file.path)
            }
        }
        let eventFile=workerEventURL,eventOwner=activeRequest;lastWorkerDraft=nil;lastSemanticRevision=nil
        defer {
            if let eventOwner {summaryDrafts[eventOwner]=nil}
            if let eventFile {try? FileManager.default.removeItem(at:eventFile)}
            if workerEventURL==eventFile {workerEventURL=nil;lastWorkerDraft=nil;lastSemanticRevision=nil}
        }
        let worker = Process(); worker.qualityOfService = .utility
        worker.executableURL = URL(fileURLWithPath:"/usr/bin/sandbox-exec"); worker.arguments = ["-p", "(version 1)(allow default)(deny network*)", executable.path] + workerArguments
        worker.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        if executable.lastPathComponent=="VectaSpeech",let eventFile { worker.environment?["VECTA_SPEECH_EVENT_PATH"]=eventFile.path }
        let output = Pipe(), incoming = Pipe()
        let diagnosticURL=root.appendingPathComponent("LocalAI/worker-diagnostic-"+UUID().uuidString+".tmp")
        FileManager.default.createFile(atPath:diagnosticURL.path,contents:nil,attributes:[.posixPermissions:0o600])
        let diagnostic=try FileHandle(forWritingTo:diagnosticURL)
        defer {try? diagnostic.close();try? FileManager.default.removeItem(at:diagnosticURL)}
        worker.standardOutput = output; worker.standardError = diagnostic
        worker.standardInput = incoming
        try worker.run(); process = worker
        let progressPoll=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,!self.stopped,self.workerEventURL==eventFile,self.activeRequest==eventOwner else {break}
                await self.receiveWorkerState()
                guard !Task.isCancelled,!self.stopped,self.workerEventURL==eventFile,self.activeRequest==eventOwner else {break}
                try? await Task.sleep(nanoseconds:500_000_000)
            }
        }
        defer {progressPoll.cancel();process = nil}
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority:.utility) {
                if let input { try incoming.fileHandleForWriting.write(contentsOf: input) }
                try incoming.fileHandleForWriting.close()
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                worker.waitUntilExit()
                guard worker.terminationStatus == 0 else {
                    // Only a content-free machine code enters UI/results, never stderr text/paths.
                    var code=""
                    if let handle=try? FileHandle(forReadingFrom:diagnosticURL) {
                        defer {try? handle.close()}
                        let end=(try? handle.seekToEnd()) ?? 0
                        try? handle.seek(toOffset:end>65536 ? end-65536:0)
                        if let data=try? handle.read(upToCount:65536),let text=String(data:data,encoding:.utf8),
                           let range=text.range(of:"local_summary_failed: [a-z_0-9]{1,64}",options:.regularExpression) {
                            code=" ("+text[range].replacingOccurrences(of:"local_summary_failed: ",with:"")+")"
                        }
                    }
                    throw NSError(domain:"LocalAI",code:1,userInfo:[NSLocalizedDescriptionKey:VL.text("Локальная модель не завершила обработку. Проверьте память, файлы модели и формат аудио.")+code])
                }
                return bytes
            }.value
        }, onCancel: {
            if worker.isRunning {
                worker.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if worker.isRunning { Darwin.kill(worker.processIdentifier, SIGKILL) }
                }
            }
        })
    }
    func stop() {
        stopped = true; timer?.invalidate();queueWatcher?.cancel();queueWatcher=nil
        for download in downloads.values { download.cancel() }
        operation?.cancel(); if process?.isRunning == true { process?.terminate() }
        speechWarmup?.cancel(); speechRuntime?.terminate()
        libraryIdleTask?.cancel(); libraryRuntime?.terminate()
        Task {
            await cancelSpeechWarmup()
            await closeSpeechRuntime()
            await closeLibraryRuntime()
        }
    }
}

@MainActor extension LocalAIHost {
    private func prewarmSpeechIfEligible() async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["VECTA_VERIFICATION_PREFERENCES"] == nil,
              !CommandLine.arguments.contains(where: { $0.hasPrefix("--verify-") }),
              startupComplete, speechWarmupFailures < 2, fastTranscriptionEnabled, !stopped, activeRequest == nil, operation == nil,
              libraryWaitingCount == 0, speechRuntime == nil, speechRuntimeClosing == nil,
              speechWarmup == nil,
              statuses["whisper"]?.state == .installed,
              statuses["tokenizer"]?.state == .installed else { return }
        let identity = UUID()
        let warmup = Task { [weak self] in
            guard let self else { return }
            await self.warmSpeechRuntime()
        }
        speechWarmupID = identity; speechWarmup = warmup
        await warmup.value
        if speechWarmupID == identity { speechWarmup = nil; speechWarmupID = nil }
    }

    private func warmSpeechRuntime() async {
        guard fastTranscriptionEnabled, !stopped, activeRequest == nil, operation == nil,
              libraryWaitingCount == 0, speechRuntime == nil,
              statuses["whisper"]?.state == .installed,
              statuses["tokenizer"]?.state == .installed else { return }
        guard (try? resourceManager.acquire()) == true else { return }
        var modelIDs: [String] = []
        var worker: LocalAISpeechWorker?
        do {
            let whisper = try await manager.acquire("whisper")
            modelIDs.append("whisper")
            let tokenizer = try await manager.acquire("tokenizer")
            modelIDs.append("tokenizer")
            try Task.checkCancellation()
            guard fastTranscriptionEnabled, !stopped, activeRequest == nil, operation == nil,
                  libraryWaitingCount == 0 else { throw CancellationError() }
            let runtime = try LocalAISpeechWorker(
                executable: resources.appendingPathComponent("LocalAI/VectaSpeech"),
                eventsRoot: root.appendingPathComponent("LocalAI/WorkerEvents", isDirectory: true))
            worker = runtime
            speechRuntime = runtime
            process = runtime.process
            try await runtime.warm(whisper: whisper, tokenizer: tokenizer, remainingWindows: 4)
            try Task.checkCancellation()
            try await runtime.warm(whisper: whisper, tokenizer: tokenizer, remainingWindows: 1)
            try Task.checkCancellation()
            speechWarmupFailures = 0
            if process === runtime.process { process = nil }
            for id in modelIDs { await manager.release(id) }
            resourceManager.release()
        } catch {
            if !(error is CancellationError), !Task.isCancelled { speechWarmupFailures += 1 }
            worker?.terminate()
            if let worker {
                if speechRuntime === worker { speechRuntime = nil }
                if process === worker.process { process = nil }
                await worker.stop()
            }
            for id in modelIDs { await manager.release(id) }
            resourceManager.release()
        }
    }

    private func cancelSpeechWarmup() async {
        guard let warmup = speechWarmup else { return }
        let identity = speechWarmupID
        warmup.cancel()
        speechRuntime?.terminate()
        await warmup.value
        if speechWarmupID == identity { speechWarmup = nil; speechWarmupID = nil }
    }

    private func closeSpeechRuntime() async {
        if speechRequestActive {
            closeSpeechAfterActive = true
            return
        }
        if let closing = speechRuntimeClosing {
            await closing.value
            return
        }
        guard let worker = speechRuntime else { return }
        speechRuntime = nil
        worker.terminate()
        let closing = Task {
            await worker.stop()
        }
        speechRuntimeClosing = closing
        await closing.value
        if process === worker.process { process = nil }
        speechRuntimeClosing = nil
        closeSpeechAfterActive = false
    }

    private func recognizeWithPersistentSpeech(request: AIProcessingRequest, audio: URL,
                                               whisper: URL, speaker: URL?, tokenizer: URL,
                                               output: URL) async throws {
        if let closing = speechRuntimeClosing { await closing.value }
        let worker: LocalAISpeechWorker
        if let existing = speechRuntime, existing.process.isRunning {
            worker = existing
        } else {
            if let existing = speechRuntime {
                speechRuntime = nil
                existing.terminate()
                await existing.stop()
            }
            worker = try LocalAISpeechWorker(
                executable: resources.appendingPathComponent("LocalAI/VectaSpeech"),
                eventsRoot: root.appendingPathComponent("LocalAI/WorkerEvents", isDirectory: true))
            speechRuntime = worker
        }
        let eventURL = root.appendingPathComponent("LocalAI/WorkerEvents", isDirectory: true).appendingPathComponent(UUID().uuidString + ".json")
        try store.registerArtifact(eventURL, for: request.id)
        workerEventURL = eventURL
        lastWorkerDraft = nil
        lastSemanticRevision = nil
        speechRequestActive = true
        process = worker.process
        do {
            try await worker.recognize(request: store.requestURL(request.id), audio: audio,
                                       whisper: whisper, speaker: speaker, tokenizer: tokenizer,
                                       output: output, eventURL: eventURL)
            try Task.checkCancellation()
            try await worker.unload()
        } catch {
            worker.terminate()
            if speechRuntime === worker { speechRuntime = nil }
            if process === worker.process { process = nil }
            if workerEventURL == eventURL {
                workerEventURL = nil
                lastWorkerDraft = nil
                lastSemanticRevision = nil
            }
            try? FileManager.default.removeItem(at: eventURL)
            speechRequestActive = false
            closeSpeechAfterActive = false
            await worker.stop()
            throw error
        }
        speechRequestActive = false
        if process === worker.process { process = nil }
        if workerEventURL == eventURL {
            workerEventURL = nil
            lastWorkerDraft = nil
            lastSemanticRevision = nil
        }
        try? FileManager.default.removeItem(at: eventURL)
        if closeSpeechAfterActive || !fastTranscriptionEnabled || stopped {
            await closeSpeechRuntime()
        }
    }

    private func closeLibraryRuntime() async {
        libraryIdleTask?.cancel();libraryIdleTask=nil
        if let closing=libraryRuntimeClosing {await closing.value;return}
        guard let worker=libraryRuntime else {return}
        libraryRuntime=nil
        let closing=Task {
            await worker.stop()
            await manager.release(worker.modelID)
            resourceManager.release()
        }
        libraryRuntimeClosing=closing;await closing.value;libraryRuntimeClosing=nil
    }
    func answerLibrary(question:String,sources:[AILibrarySource],model:AISummaryModelID,
                       onPhase:@escaping(String)->Void,onDraft:@escaping(String)->Void) async throws -> AILibraryAnswer {
        guard supported,!question.isEmpty,question.count<=2000,!sources.isEmpty,sources.count<=16 else {throw AIProcessingError.invalidRequest}
        var lastPhase=""
        func phase(_ value:String) {if value != lastPhase {lastPhase=value;onPhase(value)}}
        libraryWaitingCount+=1
        defer {libraryWaitingCount-=1}
        await cancelSpeechWarmup()
        while activeRequest != nil || operation != nil || isModelBusy(model.rawValue) || libraryRuntimeClosing != nil {
            try Task.checkCancellation();guard !stopped else {throw CancellationError()}
            phase(VL.text("Ожидаем завершения обработки…"));try await Task.sleep(nanoseconds:200_000_000)
        }
        try Task.checkCancellation()
        let id=UUID();libraryAnswerActive=true;activeRequest=id
        defer {libraryAnswerActive=false;if activeRequest==id {activeRequest=nil}}
        libraryIdleTask?.cancel();libraryIdleTask=nil
        if libraryRuntime?.modelID != model.rawValue || libraryRuntime?.process.isRunning != true {await closeLibraryRuntime()}
        try Task.checkCancellation()
        do {
            if libraryRuntime==nil {
                while try !resourceManager.acquire() {
                    try Task.checkCancellation();phase(VL.text("Ожидаем освобождения локального движка…"))
                    try await Task.sleep(nanoseconds:200_000_000)
                }
                phase(VL.text("Загружаем выбранную модель…"))
                do {
                    let directory=try await acquireAnswerModel(model)
                    guard registry.models.first(where:{$0.id==model.rawValue})?.backend=="mlx" else {await manager.release(model.rawValue);throw AIProcessingError.modelsMissing}
                    libraryRuntime=try LocalAIWarmWorker(modelID:model.rawValue,executable:resources.appendingPathComponent("LocalAI/VectaMLX"),directory:directory,root:root)
                } catch {await manager.release(model.rawValue);resourceManager.release();throw error}
            }
            guard let worker=libraryRuntime else {throw AIProcessingError.interrupted}
            let sourceRows=sources.map {s -> [String:Any] in
                ["sourceID":s.id,"title":s.title,"text":s.text]
            }
            let data=try JSONSerialization.data(withJSONObject:["mode":"library_search","output_language":VL.language.rawValue,"requestID":id.uuidString,"question":question,"segments":[[String:Any]](),"sources":sourceRows,"context_tokens":8192])
            let poll=Task {
                var last=""
                while !Task.isCancelled {
                    guard !stopped,activeRequest==id,libraryAnswerActive,libraryRuntime===worker else {return}
                    let value=await mailbox.libraryEvent(worker.eventURL)
                    guard !Task.isCancelled,!stopped,activeRequest==id,libraryAnswerActive,libraryRuntime===worker else {return}
                    if let value,value.requestID==id.uuidString {
                        if value.phase=="generating" {phase(VL.text("Готовлю ответ…"))}
                        if value.phase=="reviewing" {phase(VL.text("Проверяю ответ…"))}
                        // Complete JSON strings only; references stay unclickable until validation.
                        if let draft=value.draft,draft != last {last=draft;onDraft(draft)}
                    }
                    try? await Task.sleep(nanoseconds:100_000_000)
                }
            }
            defer {poll.cancel()}
            let bytes=try await worker.exchange(data)
            try Task.checkCancellation()
            guard !stopped,activeRequest==id,libraryRuntime===worker else {throw CancellationError()}
            guard let object=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],object["requestID"] as? String==id.uuidString else {throw AIProcessingError.invalidSummary}
            let answer=try AILibraryAnswer.decode(bytes,sources:sources)
            if summaryModel != model {await closeLibraryRuntime()}
            else {
                libraryIdleTask=Task { [weak self] in
                    do {try await Task.sleep(nanoseconds:90_000_000_000)} catch {return}
                    guard let self,self.activeRequest==nil else {return};await self.closeLibraryRuntime()
                }
            }
            return answer
        } catch {await closeLibraryRuntime();throw error}
    }
}
