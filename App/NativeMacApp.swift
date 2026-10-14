import AppKit
import AVFoundation
import Combine
import CoreBluetooth
import Foundation
import SwiftUI
import Security
import UniformTypeIdentifiers
import NotePinTransport

/// Existing account migration reads identity only; access tokens come from the
/// lifecycle-owned local service and never from a bundled research credential.
@MainActor final class NativeMacModel: ObservableObject {
    @Published var status = VL.text("Открываем существующую библиотеку…")
    @Published var library: NativeLibraryController?
    @Published var selected: NativeRecordingIdentity?
    var verificationItem:NativeLibraryItem?
    let libraryQuestionState=NativeLibraryQuestionState()
    let playback=NativePlaybackState()
    @Published var search = ""
    var libraryAnswer:AILibraryAnswer? {get {libraryQuestionState.answer} set {libraryQuestionState.answer=newValue}}
    var libraryAnswerSources:[AILibrarySource] {get {libraryQuestionState.sources} set {libraryQuestionState.sources=newValue}}
    var libraryAnswerDraft:String {get {libraryQuestionState.draft} set {libraryQuestionState.draft=newValue}}
    var libraryQuestionPhase:String {get {libraryQuestionState.phase} set {libraryQuestionState.phase=newValue}}
    var libraryQuestionBusy:Bool {get {libraryQuestionState.busy} set {libraryQuestionState.busy=newValue}}
    @Published var libraryIndexMessage=""
    @Published var libraryIndexStatus:AILibraryIndexStatus?
    @Published var libraryCorpusVersion=0
    var libraryQuestionModel:AISummaryModelID? {get {libraryQuestionState.model} set {libraryQuestionState.model=newValue}}
    var libraryQuestionScroll:Double=0
    var librarySearchSession=AILibrarySearchSession()
    var libraryQuestionTask:Task<Void,Never>?
    var libraryIndexTask:Task<Void,Never>?
    var libraryCorpus:AITranscriptCorpus?
    var libraryIndexGeneration=UUID()
    @Published var searchFocusSignal=UUID()
    @Published var sidebarToggleSignal=UUID()
    @Published var exportRequested=false
    @Published var importingAudio=false
    var importTask: Task<Void,Never>?
    @Published var connected = false
    @Published var transferring = false
    var playing:Bool {get {playback.playing} set {if playback.playing != newValue {playback.playing=newValue}}}
    var progress:Double {get {playback.progress} set {if playback.progress != newValue {playback.progress=newValue}}}
    var duration:Double {get {playback.duration} set {if playback.duration != newValue {playback.duration=newValue}}}
    var waveform:[Float] {get {playback.waveform} set {if playback.waveform != newValue {playback.waveform=newValue}}}
    var playbackRate:Float {get {playback.rate} set {if playback.rate != newValue {playback.rate=newValue}}}
    private var preparingPlayerTask:Task<Void,Never>?
    private var playWhenReady=false
    private var waveformTask: Task<Void, Never>?
    @Published var history = ""
    @Published var candidates: [PlaudCandidate] = []
    @Published var showingDevicePicker = false
    @Published var showingDeviceSetup = false
    @Published var offlineAuthorizationReady = false
    private var setupCredentials: VectaPartnerCredentials?
    @Published var battery: Int?
    @Published var pickerStatus = ""
    @Published var scanning = false
    @Published var destination: NativeDestination = .library
    @Published var languageRestarting=false
    @Published var languageRestartError:String?
    @Published var localAI: LocalAIHost? {
        didSet {
            libraryCorpus=nil;libraryCorpusVersion+=1
            resultSubscription = localAI?.resultUpdates.sink { [weak self] id in
                Task { @MainActor [weak self] in
                    guard let self else{return};self.libraryCorpusVersion+=1
                    if self.verificationItem != nil || self.pendingAnalysis==id || self.analyses.contains(where:{$0.request.id==id}) {await self.reloadAnalysis();return}
                    guard let host=self.localAI,let local=self.selection?.local else{return}
                    let selected=self.selected,names=Set(VectaLocalAudioExporter.filenames(for:local))
                    let result=try? await Task.detached(priority:.utility){try LocalAIFileStore(root:host.root).result(id)}.value
                    if self.selected==selected,let result,names.contains(result.request.audioFilename) {await self.reloadAnalysis()}
                }
            }
            localAISubscriptions.removeAll();localAIUpdateQueued=false
            if let host=localAI {
                let readiness:[AnyPublisher<Void,Never>]=[
                    host.$statuses.map{$0.mapValues(\.state)}.removeDuplicates().dropFirst().map{_ in ()}.eraseToAnyPublisher(),
                    host.$summaryModel.removeDuplicates().dropFirst().map{_ in ()}.eraseToAnyPublisher(),
                    host.$automaticSettings.removeDuplicates().dropFirst().map{_ in ()}.eraseToAnyPublisher(),
                    host.$queuePaused.removeDuplicates().dropFirst().map{_ in ()}.eraseToAnyPublisher(),
                    host.$activeRequest.removeDuplicates().dropFirst().map{_ in ()}.eraseToAnyPublisher(),
                    host.$installingSpeech.removeDuplicates().dropFirst().map{_ in ()}.eraseToAnyPublisher(),
                    host.$removingSpeech.removeDuplicates().dropFirst().map{_ in ()}.eraseToAnyPublisher()
                ]
                Publishers.MergeMany(readiness).sink { [weak self,weak host] in if let host {self?.forwardHostChange(host)} }.store(in:&localAISubscriptions)
                host.$summaryDrafts.map { [weak self] drafts -> String? in guard let id=self?.rawAnalysis?.request.id else{return nil};return drafts[id] }.removeDuplicates().dropFirst()
                    .sink { [weak self,weak host] _ in if let host {self?.forwardHostChange(host)} }.store(in:&localAISubscriptions)
                host.$visualDrafts.map { [weak self] drafts -> AISemanticSummary? in guard let id=self?.rawAnalysis?.request.id else{return nil};return drafts[id] }.removeDuplicates().dropFirst()
                    .sink { [weak self,weak host] _ in if let host {self?.forwardHostChange(host)} }.store(in:&localAISubscriptions)
            }
        }
    }
    private var localAISubscriptions=Set<AnyCancellable>()
    private var localAIUpdateQueued=false
    private func forwardHostChange(_ host:LocalAIHost) {
        guard localAI===host,!localAIUpdateQueued else{return}
        localAIUpdateQueued=true
        DispatchQueue.main.async { [weak self,weak host] in
            guard let self,let host,self.localAI===host else{return}
            self.localAIUpdateQueued=false;self.objectWillChange.send()
        }
    }
    private var resultSubscription: AnyCancellable?
    private var presentationGeneration=0
    var presentationRevision:Int {presentationGeneration}
    let conversationRefresh=NativeConversationRefresh()
    var appliedConversationRevision:String?
    var appliedConversationSegments:[AISpeechSegment]=[]
    var chatRevision=0
    private var cachedPresentation:(Int,AIRecordingSpeakers,AIProcessingResult?)?
    private var cachedWordsGeneration = -1
    private var sortedWords:[AIWordTiming]=[]
    func invalidatePresentation() {presentationGeneration+=1;cachedPresentation=nil}
    func presentation()->(AIRecordingSpeakers,AIProcessingResult?) {
        if let cached=cachedPresentation,cached.0==presentationGeneration {return (cached.1,cached.2)}
        let resolved:AIRecordingSpeakers
        if let result=rawAnalysis,let key=conversationKey {resolved=voiceLibrary.resolving(conversation,result:result,alignment:AISpeakerAlignment(complete:true,words:wordTimings,centroids:speakerCentroids),key:key)} else{resolved=conversation}
        let result=rawAnalysis.map(resolved.rendered);cachedPresentation=(presentationGeneration,resolved,result);return (resolved,result)
    }
    /// Prepare the saved projection before detail content enters layout.
    func preparePresentation() async {
        let generation=presentationGeneration
        if cachedPresentation?.0==generation {return}
        let result=rawAnalysis,key=conversationKey,recording=conversation,voices=voiceLibrary
        let alignment=AISpeakerAlignment(complete:true,words:wordTimings,centroids:speakerCentroids)
        let prepared=await Task.detached(priority:.userInitiated) {
            let resolved:AIRecordingSpeakers
            if let result,let key {resolved=voices.resolving(recording,result:result,alignment:alignment,key:key)} else {resolved=recording}
            return (resolved,result.map(resolved.rendered))
        }.value
        guard !Task.isCancelled,presentationGeneration==generation else{return}
        cachedPresentation=(generation,prepared.0,prepared.1)
    }
    func words(for segment:AISpeechSegment)->[AIWordTiming] {
        if cachedWordsGeneration != presentationGeneration {sortedWords=wordTimings.sorted{$0.start<$1.start};cachedWordsGeneration=presentationGeneration}
        var low=0,high=sortedWords.count
        while low<high {let mid=(low+high)/2;if sortedWords[mid].start<segment.start-0.001{low=mid+1}else{high=mid}}
        var result=[AIWordTiming](),i=low
        while i<sortedWords.count,sortedWords[i].start<=segment.end+0.001 {if sortedWords[i].end<=segment.end+0.001 {result.append(sortedWords[i])};i+=1};return result
    }
    @Published var analyses: [AIProcessingResult] = [] {didSet{invalidatePresentation()}}
    @Published var analysisID: UUID? {didSet{invalidatePresentation()}}
    @Published var analysisMessage: String?
    @Published var chat=AIChatHistory() {didSet{chatRevision+=1}}
    @Published var chatBusy=false
    @Published var chatDraft=""
    @Published var chatDraftKey:String?
    @Published var visualRetryBusy=false
    var visualRetryTask:Task<Void,Never>?
    @Published var chatError:String?
    var chatTask:Task<Void,Never>?
    var loadedChatKey:String?
    @Published var workspace=AIWorkspace()
    @Published var globalSearchHits:[NativeSearchHit]=[]
    @Published var searchingLibrary=false
    @Published var searchError:String?
    @Published var openDetailSignal=UUID()
    @Published var conversation = AIRecordingSpeakers() {didSet{invalidatePresentation()}}
    @Published var voiceLibrary = AIVoiceLibrary() {didSet{invalidatePresentation()}}
    @Published var focusedSegment: Int?
    @Published var playbackNavigationID=UUID()
    @Published var wordTimings: [AIWordTiming] = [] {didSet{invalidatePresentation()}}
    @Published var speakerCentroids: [String:[Float]] = [:] {didSet{invalidatePresentation()}}
    @Published var requestingAnalysis = false
    @Published var transferProgress: VectaTransferProgress?
    var transferMetrics: VectaTransferMetrics?
    var transferTimer: Timer?
    private var analysisTimer: Timer?
    var pendingAnalysis: UUID?
    var loadingHistory = false
    var analysisReloadPending=false
    let services = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VectaServices")
    private var deviceSession: VectaDeviceSession?
    private var runtime: NativeAppRuntime?
    private var runtimeOwnership: RuntimeOwnership?
    var libraryGeneration = UUID()
    var librarySourceTask: Task<Void, Never>?
    var librarySourceGeneration = UUID()
    var workspaceImportTask: Task<Void, Never>?
    var workspaceImportGeneration = UUID()
    func ownsLibraryOperation(_ scope: NativeLibraryOperationScope, checkCancellation: Bool = true) -> Bool {
        scope.isCurrent(library: library, host: localAI, generation: libraryGeneration,
                        cancelled: checkCancellation && Task.isCancelled)
    }
    var processingRoot: URL?
    var voiceStateRoot: URL?
    var conversationStateRoot: URL?
    var conversationLoadedKey: String?
    var workspaceStateRoot: URL?
    var workspaceFileRevision:String?
    private var libraryFolderAccess: NativeLibraryFolderAccess?
    private var processingFolderAccess: NativeRecordingsFolderAccess?
    private var driver: NativeBluetoothSession?
    private var wifiTransfer: NativeWiFiTransfer?
    private var wifiStartTask: Task<Void, Never>?
    private var wifiCleanupTask: Task<Void, Never>?
    @Published var fastTransferPhase: String?
    @Published var showingFastTransferWarning = false
    private var fastTransferAvailability: NativeFastTransferAvailability {
        NativeFastTransferAvailability(supportedDevice: savedDevice?.model == .notePinS && savedDevice?.protocolVersion == 20,
                                       transferring: transferring, hasRecording: transferID != nil,
                                       switching: fastTransferPhase != nil, transportReady: driver?.canUseWiFi == true)
    }
    var showsFastTransfer: Bool { fastTransferAvailability.isVisible }
    var canStartFastTransfer: Bool { fastTransferAvailability.isEnabled }
    #if VECTA_DEVELOPMENT
    func prepareFastTransferVerification(features: Data? = nil, supportsWiFi: Bool = true, queued: Bool = false) throws {
        let serial = "882SYNTHETIC"
        savedDevice = try SavedPlaudDevice(serialNumber: serial, model: .notePinS, protocolVersion: 20)
        transferID = NativeRecordingIdentity(serialNumber: serial, sessionID: 7)
        let config = NativeBluetoothSession.Configuration(peripheralID: nil, platformDomain: "", accessToken: "", userID: "synthetic", serialNumber: serial, deviceType: "notepins")
        let synthetic = NativeBluetoothSession(config: config, reportURL: FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-synthetic-wifi.json"))
        try synthetic.configureWiFiVerification(session: VectaAppChecks.syntheticWiFiSession(), features: features, supportsWiFi: supportsWiFi, queued: queued)
        driver = synthetic; transferring = true; fastTransferPhase = nil; destination = .library
    }
    #endif
    private var serial: String?
    private var files: [ProtocolRecordingFile] = []
    @Published var transferID: NativeRecordingIdentity?
    private var player: AVAudioPlayer?
    private var playbackStopTime: Double?
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private var starting = false
    private var discovery: NativePlaudDiscovery?
    @Published var savedDevice: SavedPlaudDevice?
    @Published var resettingDevice = false
    private var resetCommandRequested = false
    var canFactoryReset: Bool {
        savedDevice?.model == .notePinS && savedDevice?.protocolVersion == 20 &&
        offlineAuthorizationReady && !busy && !scanning && !showingDevicePicker && !showingDeviceSetup
    }
    func factoryReset(confirmedSerial: String) {
        guard canFactoryReset, let device = savedDevice, device.serialNumber == confirmedSerial else { return }
        #if VECTA_DEVELOPMENT
        guard !CommandLine.arguments.contains("--verify-ui"), !CommandLine.arguments.contains("--verify-conversation") else {
            status = VL.text("Проверка UI: команда сброса не отправляется."); return
        }
        #endif
        do {
            guard let identity = try VectaOfflineIdentityStore.load(serial: confirmedSerial) else { throw VectaAuthorizationError.unavailable }
            let prepared = try identity.prepared(for: device)
            disconnect(); autoSyncTimer?.invalidate(); autoSyncTimer = nil
            resettingDevice = true; resetCommandRequested = false
            let attempt = UUID(); connectionAttempt = attempt
            let config = NativeBluetoothSession.Configuration(peripheralID: device.peripheralID,
                platformDomain: "platform-us.plaud.ai", accessToken: "", userID: "", serialNumber: confirmedSerial,
                deviceType: "notepins", advertisedProtocolVersion: device.protocolVersion,
                handshakeToken: identity.ownerToken, useVerifiedPeripheralCache: device.peripheralID != nil)
            let session = NativeBluetoothSession(config: config, reportURL: services.appendingPathComponent("native-reset-session.json"), offlineIdentity: prepared)
            session.onStatus = { [weak self] text in
                guard let self, self.connectionAttempt == attempt else { return }; self.status = text
            }
            session.onAuthenticatedCommandQueueIdle = { [weak self, weak session] in
                guard let self, let session, self.connectionAttempt == attempt, self.resettingDevice else { return }
                do {
                    try session.validateFactoryReset(confirmedSerial: confirmedSerial)
                    // Retire local reconnect BEFORE the write: a missing ATT ack
                    // must never permit a later automatic connection or reset retry.
                    try PlaudSelectionStore(url: self.services.appendingPathComponent("selected-device.json")).forget()
                    self.savedDevice = nil; self.pendingDevice = nil; self.serial = nil; self.offlineAuthorizationReady = false
                    self.setupCredentials = nil; self.deviceSession = nil; self.battery = nil
                    try VectaOfflineIdentityStore.retireAfterReset(serial: confirmedSerial)
                    self.resetCommandRequested = true
                    try session.requestFactoryReset(confirmedSerial: confirmedSerial)
                } catch {
                    self.disconnect()
                    self.status = VL.text("Сброс не отправлен. Записи на Mac сохранены; для подключения может потребоваться повторная настройка PLAUD.")
                }
            }
            session.onFactoryResetAcknowledged = { [weak self] in
                guard let self, self.connectionAttempt == attempt else { return }
                self.status = VL.text("Команда сброса доставлена. Ожидаем отключение PLAUD…")
            }
            session.onFactoryResetFinished = { [weak self] disconnected in
                guard let self, self.connectionAttempt == attempt else { return }
                self.resettingDevice = false; self.resetCommandRequested = false
                self.connected = false; self.driver = nil; self.scheduleAutoSync()
                self.status = (disconnected ? VL.text("Команда сброса доставлена, PLAUD отключился. Проверьте режим сопряжения на устройстве.") : VL.text("Команда сброса доставлена, но отключение не наблюдалось. Проверьте устройство; сброс автоматически не повторяется."))
                    + VL.text(" Копии на Mac сохранены. Отвязка облачного аккаунта не проверена.")
            }
            session.onFailure = { [weak self] _ in
                guard let self, self.connectionAttempt == attempt else { return }
                let requested = self.resetCommandRequested
                self.disconnect(); self.scheduleAutoSync()
                self.status = requested
                    ? VL.text("Сброс не подтверждён. Он мог начаться; автоматического повтора нет. Проверьте PLAUD. Копии на Mac сохранены.")
                    : VL.text("Не удалось подготовить PLAUD; сброс не отправлен. Записи сохранены.")
            }
            driver = session; session.start()
        } catch { status = VL.text("Не удалось открыть локальную авторизацию; сброс не отправлен.") }
    }
    private var pendingDevice: SavedPlaudDevice?
    private var requestedDownload: NativeRecordingIdentity?
    var syncing = false
    @Published var automaticSummary = true
    @Published var voiceFeedback: String?
    private var voiceFeedbackTask: Task<Void, Never>?
    @Published var batchMessage: String?
    @Published var batchCount = 0
    @Published var batchFailures = 0
    @Published var batchActiveRequest: UUID?
    @Published var batchProgress: AIRecognitionProgress?
    @Published var batchTitle: String?
    var analysisQueue: NativeAnalysisQueue?
    @Published var legacyQueueAvailable = false
    var batchChecking = false
    var batchTask: Task<Void, Never>?
    private var summarizeAllAfterSync = false
    private var downloadedForAnalysis: [NativeRecordingIdentity] = []

    func setAutomaticSummary(_ enabled: Bool) {
        automaticSummary = enabled
        UserDefaults.standard.set(enabled, forKey: "Vecta.autoSummaryAfterSync")
    }

    private func finishSyncAnalysis() {
        let targets = NativePostSyncPolicy.targets(manual: summarizeAllAfterSync, automaticSummary: automaticSummary,
            local: library?.items.filter { $0.audioURL != nil }.map(\.identity) ?? [], downloaded: downloadedForAnalysis)
        summarizeAllAfterSync = false; downloadedForAnalysis = []
        do {
            if analysisQueue?.jobs.isEmpty == true { batchFailures = 0 }
            try analysisQueue?.append(targets,settings:localAI?.automaticSettings)
            batchCount = analysisQueue?.jobs.count ?? 0
            if batchCount > 0 { batchMessage = VL.text("В очереди обработки: \(batchCount)") }
        } catch { batchMessage = VL.text("Не удалось сохранить очередь обработки: ") + error.localizedDescription }
    }

    private var syncQueue: [NativeRecordingIdentity] = []
    var connecting = false
    private var connectionAttempt = UUID()
    private var standaloneUserID: String?
    private var legacyOwnerToken: String?
    private var awaitingBluetoothAuthorization = false
    private lazy var autoSchedule = NativeSyncSchedule(defaults: VectaRuntimePreferences.synchronization)
    private var autoSyncTimer: Timer?
    private var automationSleeping = false
    @Published private(set) var autoSyncInterval: NativeSyncInterval = .thirtyMinutes
    @Published private(set) var nextAutoSync: Date?

    func setAutoSyncInterval(_ interval: NativeSyncInterval) {
        autoSchedule.select(interval)
        driver?.setMaintainsConnection(interval.keepsConnection)
        if !interval.keepsConnection,connected,!busy {driver?.stop();driver=nil;connected=false}
        scheduleAutoSync()
        if interval.keepsConnection {runScheduledSync()}
    }

    private func scheduleAutoSync() {
        autoSyncTimer?.invalidate(); autoSyncTimer = nil
        autoSyncInterval = autoSchedule.interval
        nextAutoSync = autoSchedule.nextAttempt
        guard !automationSleeping, savedDevice != nil, library != nil,
              let deadline = nextAutoSync else { return }
        // A due attempt blocked by a user operation is deferred without doing
        // BLE discovery. No overlapping transfer or busy reconnect loop.
        let delay = max(1, deadline.timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.runScheduledSync() }
        }
        autoSyncTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func runScheduledSync() {
        guard !automationSleeping else { return }
        let eligible = savedDevice != nil && library != nil && !busy && !scanning && !showingDevicePicker && !showingDeviceSetup && setupCredentials == nil && pendingDevice == nil
        if autoSchedule.takeDueAttempt(eligible: eligible) {
            beginSync(automatic: true)
            scheduleAutoSync()
        } else if autoSchedule.interval != .off, savedDevice != nil,
                  let deadline = autoSchedule.nextAttempt, deadline <= Date(), !eligible {
            // Keep one deferred deadline while an operation is busy. This timer
            // checks local state only; it never scans or connects a device.
            autoSyncTimer?.invalidate()
            let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.runScheduledSync() }
            }
            autoSyncTimer = timer; RunLoop.main.add(timer, forMode: .common)
        } else { scheduleAutoSync() }
    }

    func suspendAutomation() {
        automationSleeping = true; autoSyncTimer?.invalidate(); autoSyncTimer = nil
        closePicker(); disconnect()
    }

    func resumeAutomation() {
        guard automationSleeping else { return }
        automationSleeping = false; runScheduledSync()
    }

    init() {
        autoSyncInterval = autoSchedule.interval
        nextAutoSync = autoSchedule.nextAttempt
    }

    var librarySourceNavigation=false
    @Published var libraryAssetsMissing=false
    var items: [NativeLibraryItem] {
        verificationItem.map {[$0]} ?? library?.items ?? []
    }
    func orderedItems(oldestFirst:Bool)->[NativeLibraryItem] {verificationItem.map{[$0]} ?? (oldestFirst ? library?.oldestFirstItems:library?.items) ?? []}
    var selection: NativeLibraryItem? {verificationItem ?? selected.flatMap {library?.item(for:$0)}}

    func start() async {
        guard !starting, runtime == nil, library == nil else { return }
        starting = true
        defer { starting = false }
        do {
            if runtimeOwnership == nil { runtimeOwnership = try RuntimeOwnership(directory: services) }
            let home = FileManager.default.homeDirectoryForCurrentUser
            libraryGeneration = UUID()
            try VectaMigration.prepareServices(services)
            try VectaMigration.migratePreferences(defaults: .standard)
            automaticSummary = NativeBranding.automaticSummary()
            let legacySession = try NativeLegacySessionReader.read()
            let loaded: NativeLibraryController
            if VectaLegacyAuthorization.hasLegacyConfiguration() || legacySession != nil {
                let identity = try legacySession?.userID ?? VectaLegacyAuthorization.identity()
                let next = NativeAppRuntime(resources: Bundle.main.resourceURL!, servicesDirectory: services, ownershipLease: runtimeOwnership)
                runtime = next
                libraryFolderAccess = try NativeLibraryFolderAccess.restore(servicesDirectory: services)
                let bases = NativeStorageLayout.candidateBases(home: home) + (libraryFolderAccess.map { [$0.root] } ?? [])
                let source: NativeAppRuntime.LibrarySource
                if let selectedBase = libraryFolderAccess?.root {
                    let selected = selectedBase.resolvingSymlinksInPath().standardizedFileURL
                    let archived = VectaLegacyPaths.libraryBases(home: home).contains { $0.resolvingSymlinksInPath().standardizedFileURL == selected }
                    source = archived ? .archivedMigration(candidateBases: [selectedBase], destinationBase: home.appendingPathComponent("Library/Application Support/Vecta")) : .selectedLibrary(base: selectedBase)
                } else {
                    source = .archivedMigration(candidateBases: bases, destinationBase: home.appendingPathComponent("Library/Application Support/Vecta"))
                }
                try await next.start(expectedUserID: identity, librarySource: source)
                guard let existing = next.library else { throw NativeRuntimeError.runtimeUnavailable }
                loaded = existing
                processingRoot = next.processingRoot
                if let message = next.aiErrorMessage { analysisMessage = message }
            } else {
                // Fresh installs use a separate local namespace. Never create
                // or replace a legacy account's library after a migration error.
                let defaultBase = try VectaMigration.standaloneRoot(home: home)
                libraryFolderAccess = try NativeLibraryFolderAccess.restore(servicesDirectory: services)
                let base = libraryFolderAccess?.root ?? defaultBase
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let identityURL = defaultBase.appendingPathComponent("local-identity.json")
                let identity: String
                if FileManager.default.fileExists(atPath: identityURL.path) {
                    identity = try JSONDecoder().decode(String.self, from: Data(contentsOf: identityURL))
                    guard !identity.isEmpty, identity.utf8.count < 256 else { throw NativeRuntimeError.identityChanged }
                } else {
                    identity = UUID().uuidString
                    try JSONEncoder().encode(identity).write(to: identityURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
                }
                if libraryFolderAccess != nil {
                    _ = try NativeStorageLayout.resolveExisting(userID: identity, servicesDirectory: services, candidateBases: [base], selectedBase: base)
                }
                standaloneUserID = identity
                let layout = NativeStorageLayout(recordingBase: base,
                    userDirectory: base.appendingPathComponent("Users/" + VectaRecordingStore.userDirectoryName(for: identity)), servicesDirectory: services)
                let exporter = VectaLocalAudioExporter(userID: identity, defaults: UserDefaults.standard)
                let access = try NativeRecordingsFolderAccess.openForLibrary(layout: layout, userID: identity)
                processingFolderAccess = access
                let folder = access.root
                try exporter.configureFolder(folder)
                loaded = try NativeLibraryController(userID: identity, layout: layout, exporter: exporter)
                processingRoot = folder
            }
            library = loaded
            legacyQueueAvailable = false
            do {
                guard let processingRoot else { throw NativeRuntimeError.configurationMissing }
                let queue = try NativeAnalysisQueue(url: NativeAnalysisQueue.scopedURL(processingRoot: processingRoot))
                analysisQueue = queue
                do { legacyQueueAvailable = try queue.hasUnclaimedLegacySnapshot(at: services.appendingPathComponent("native-analysis-queue.json")) }
                catch { batchMessage = VL.text("Прежняя очередь сохранена отдельно, но её не удалось проверить. Очередь этой библиотеки продолжает работать.") }
            } catch { batchMessage = VL.text("Сохранённая очередь повреждена. Библиотека и записи сохранены; очередь не перезаписана.") }
            batchCount = analysisQueue?.jobs.count ?? 0
            if let host = runtime?.localAI { localAI = host }
            else if let standaloneUserID {
                guard let root = processingRoot else { throw NativeRuntimeError.configurationMissing }
                do {
                    guard let resources = Bundle.main.resourceURL else { throw NativeRuntimeError.configurationMissing }
                    localAI = try LocalAIHost(root: root, resources: resources)
                    localAI?.start()
                } catch {
                    analysisMessage = VL.text("Компоненты локального ИИ недоступны. Подключение и библиотека продолжают работать.")
                }
                _ = standaloneUserID
            }
            reloadRootScopedState()
            localAI?.onOpenSettings = { [weak self] in self?.destination = .ai }
            analysisTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.batchTask == nil, self.batchCount > 0 {
                        let generation = self.libraryGeneration
                        self.batchTask = Task {
                            await self.pumpAnalysisQueue()
                            if self.libraryGeneration == generation { self.batchTask = nil }
                        }
                    }
                    if self.pendingAnalysis != nil || self.localAI?.recordingOperationActive == true || self.rawAnalysis?.stage.isActive == true { await self.reloadAnalysis() }
                }
            }
            subscription = loaded.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async { self?.objectWillChange.send() }
            }
            select(loaded.items.first?.identity)
            let targets = Set(loaded.recordingStore.all.map(\.deviceSerialNumber).filter { VectaDeviceModel(serialNumber:$0) != nil })
            serial = loaded.recordingStore.recorderAssociation()?.serialNumber ?? (targets.count == 1 ? targets.first : nil)
            savedDevice = try? PlaudSelectionStore(url: services.appendingPathComponent("selected-device.json")).load()
            status = VL.text("Библиотека открыта · \(loaded.items.count) записей")
            if let savedDevice {
                serial = savedDevice.serialNumber
                if let identity = try? VectaOfflineIdentityStore.load(serial: savedDevice.serialNumber) {
                    offlineAuthorizationReady = (try? identity.prepared(for: savedDevice)) != nil
                }
            } else { showingDeviceSetup = true }
            runScheduledSync()
        } catch { status = error.localizedDescription; await runtime?.stop(); runtime = nil }
    }

    func chooseAudioImport() {
        guard library != nil, !importingAudio else { return }
        let panel = NSOpenPanel()
        panel.title = VL.text("Импорт аудиозаписи")
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff, .audio]+[UTType(filenameExtension:"ogg"),UTType(filenameExtension:"opus")].compactMap{$0}
        panel.allowsMultipleSelection = false
        panel.message = VL.text("MP3, M4A, WAV, AIFF, CAF, OGG / Opus. Оригинал сохранится; обработка AI запускается отдельно.")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self, let library = self.library else { return }
            self.importingAudio = true
            self.importTask = Task {
                defer { self.importingAudio = false; self.importTask = nil }
                do {
                    let identity = try await library.importAudio(url)
                    self.verificationItem = nil
                    self.destination = .library; self.select(identity)
                    self.status = VL.text("Аудиозапись сохранена на Mac")
                } catch is CancellationError { self.status = VL.text("Импорт отменён") }
                catch { self.status = error.localizedDescription }
            }
        }
    }

    func selectExistingLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = VL.text("Открыть существующую библиотеку Vecta")
        panel.message = VL.text("Выберите папку существующей библиотеки, содержащую Users. Записи сохранятся в прежнем месте.")
        panel.prompt = VL.text("Открыть библиотеку")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                guard !busy, !analysisBusy, localAI?.recordingOperationActive != true else {
                    status = VL.text("Дождитесь окончания передачи и обработки перед сменой библиотеки"); return
                }
                let identity = try standaloneUserID ?? NativeLegacySessionReader.read()?.userID ?? VectaLegacyAuthorization.identity()
                _ = try NativeStorageLayout.resolveExisting(userID: identity, servicesDirectory: services, candidateBases: [url], selectedBase: url)
                let bookmark = services.appendingPathComponent("native-library.bookmark")
                if FileManager.default.fileExists(atPath: bookmark.path) {
                    try FileManager.default.copyItem(at: bookmark, to: services.appendingPathComponent("native-library-" + UUID().uuidString + ".bookmark.backup"))
                }
                try NativeLibraryFolderAccess.save(url, servicesDirectory: services)
                Task {
                    self.disconnect()
                    await self.stop()
                    self.runtime = nil; self.localAI = nil; self.library = nil; self.libraryFolderAccess = nil
                    self.subscription = nil; self.resultSubscription = nil; self.analysisQueue = nil; self.standaloneUserID = nil
                    self.selected = nil; self.analyses = []; self.analysisID = nil; self.automationSleeping = false
                    await self.start()
                }
            } catch { status = VL.text("Не удалось сохранить доступ к существующей библиотеке") }
        }
    }

    func configureDeviceAccess(_ credentials: VectaPartnerCredentials) throws {
        try credentials.validate()
        setupCredentials = credentials
        deviceSession = nil
        showingDeviceSetup = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.scan() }
    }
    func useSavedDeviceAccess() throws {
        if let credentials = try VectaCredentialStore.load() {
            try configureDeviceAccess(credentials)
        } else {
            let owner = try NativeLegacySessionReader.read()?.userID ?? VectaLegacyAuthorization.identity()
            try configureDeviceAccess(VectaLegacyAuthorization.credentials(services: services, userID: owner))
        }
    }
    func beginDeviceSetup() { showingDeviceSetup = true }

    func scan() {
        if savedDevice == nil && setupCredentials == nil { showingDeviceSetup = true; return }
        startDeviceDiscovery()
    }
    func findPreviouslyAuthorizedDevice() {
        showingDeviceSetup = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.startDeviceDiscovery() }
    }
    private func startDeviceDiscovery() {
        discovery?.stop(); candidates = []; scanning = true
        let next = NativePlaudDiscovery()
        next.onCandidates = { [weak self] value in self?.candidates = value }
        next.onState = { [weak self] value in self?.pickerStatus = value }
        next.onFinished = { [weak self] in self?.scanning = false }
        next.onDiagnostics = { [weak self] counts in
            guard let self, let data = try? JSONSerialization.data(withJSONObject: counts, options: .sortedKeys) else { return }
            let url = self.services.appendingPathComponent("discovery-counts.json")
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        discovery = next; showingDevicePicker = true; next.start()
    }
    func closePicker() { discovery?.stop(); discovery = nil; showingDevicePicker = false }

    func choose(_ candidate: PlaudCandidate) {
        guard library != nil else { pickerStatus = VL.text("Локальная библиотека не открыта. Сначала исправьте ошибку её запуска."); return }
        guard let ad = candidate.advertisement, let model = candidate.model else { return }
        guard let version = ad.protocolVersion else {
            status = VL.text("Устройство распознано, но версия протокола не объявлена. Команды не отправлялись."); return
        }
        if version >= 20 && model.partnerType == nil { pickerStatus = VL.text("Устройство обнаружено, но для этого поколения не подтверждён провайдер авторизации. Команды не отправлялись."); return }
        if version >= 20 && setupCredentials == nil {
            do {
                if try VectaOfflineIdentityStore.load(serial: ad.serialNumber) == nil {
                    closePicker(); showingDeviceSetup = true; return
                }
            } catch { pickerStatus = VL.text("Не удалось прочитать локальную авторизацию. Интернет-запросы не выполнялись."); return }
        }
        discovery?.stop(); discovery = nil; showingDevicePicker = false
        serial = ad.serialNumber
        do { pendingDevice = try SavedPlaudDevice(serialNumber: ad.serialNumber, model: model, protocolVersion: version) } catch { status = VL.text("Некорректная идентичность устройства"); return }
        autoSchedule.recordAttempt(); scheduleAutoSync()
        syncing = true; connect(candidate: candidate)
    }

    private func connect(candidate: PlaudCandidate? = nil, session: VectaDeviceSession? = nil) {
        guard let serial,
              let saved = pendingDevice ?? savedDevice, saved.serialNumber == serial else {
            syncing = false; status = VL.text("Выберите Plaud в списке устройств"); finishSyncAnalysis(); return
        }
        guard !connecting, !transferring else { return }
        connecting = true
        driver?.stop()
        connected = false
        var cachedIdentity: VectaOfflineIdentity?
        var preparedIdentity: PreparedPartnerIdentity?
        do {
            if saved.protocolVersion >= 20 {
                cachedIdentity = try VectaOfflineIdentityStore.load(serial: serial)
                if let cachedIdentity { preparedIdentity = try cachedIdentity.prepared(for: saved) }
            }
        } catch {
            connecting = false; syncing = false; status = VL.text("Сохранённая локальная авторизация не соответствует устройству или недоступна. Сетевой откат не выполнялся; ключи сохранены. Обычная настройка не заменяет их автоматически.")
            finishSyncAnalysis(); return
        }
        let session = session ?? deviceSession
        if saved.protocolVersion >= 20 && cachedIdentity == nil {
            guard let credentials = setupCredentials else {
                connecting = false; syncing = false; status = VL.text("Нужна первоначальная настройка авторизации устройства")
                showingDeviceSetup = true; finishSyncAnalysis(); return
            }
            if session == nil || session?.canResumeWithoutRefresh == false {
                let attempt = UUID(); connectionAttempt = attempt
                status = VL.text("Первоначальная авторизация через PLAUD…")
                Task {
                    do {
                        let provider = try VectaPartnerAuthorization(credentials: credentials)
                        let authorized = try await provider.authorize(expectedUserID: credentials.userID)
                        guard connectionAttempt == attempt else { return }
                        deviceSession = authorized
                        connecting = false; connect(candidate: candidate, session: authorized)
                    } catch {
                        guard connectionAttempt == attempt else { return }
                        connecting = false; syncing = false; status = error.localizedDescription; finishSyncAnalysis()
                    }
                }
                return
            }
        }
        do {
            legacyOwnerToken = saved.protocolVersion < 20 ? (try NativeOwnerTokenStore.load(serial: serial) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")) : nil
        } catch { connecting = false; syncing = false; status = VL.text("Не удалось открыть защищённую привязку устройства"); finishSyncAnalysis(); return }
        let config = NativeBluetoothSession.Configuration(peripheralID: candidate?.id ?? saved.peripheralID,
            platformDomain: session?.plaudDomain ?? "platform-us.plaud.ai", accessToken: session?.plaudUserAccessToken ?? "",
            userID: session?.userID ?? "", serialNumber: serial, deviceType: saved.model.partnerType ?? saved.model.rawValue,
            advertisedProtocolVersion: saved.protocolVersion,
            handshakeToken: cachedIdentity?.ownerToken ?? legacyOwnerToken,
            useVerifiedPeripheralCache: candidate == nil && saved.peripheralID != nil)
        let driverAttempt = UUID(); connectionAttempt = driverAttempt
        let report = services.appendingPathComponent("native-session.json")
        let next = NativeBluetoothSession(config: config, reportURL: report, offlineIdentity: preparedIdentity)
        next.onIdentityPrepared = { [weak self] prepared in
            guard let self, self.connectionAttempt == driverAttempt, let session,
                  let privatePEM = prepared.privateKeyPEM else { throw VectaAuthorizationError.invalidResponse }
            let identity = VectaOfflineIdentity(version: 1, serialNumber: serial,
                deviceType: saved.model.partnerType ?? saved.model.rawValue, protocolVersion: saved.protocolVersion,
                ownerToken: session.userID, publicKeyPEM: prepared.publicKeyPEM,
                privateKeyPEM: privatePEM, serialSignature: prepared.serialSignature)
            // Persist before the recorder can enroll the public key. A crash or
            // timeout must not lose the matching private identity and force a reset.
            try VectaOfflineIdentityStore.save(identity, device: saved)
            self.setupCredentials = nil; self.deviceSession = nil
        }
        next.setMaintainsConnection(autoSyncInterval.keepsConnection)
        next.onStatus = { [weak self] value in guard self?.connectionAttempt == driverAttempt else { return }; if self?.status != value { self?.status = value } }
        next.onBattery = { [weak self] level, _ in self?.battery = level }
        next.onComplete = { [weak self, weak next] entries in
            guard let self, self.connectionAttempt == driverAttempt else { return }
            files = entries; connected = true; connecting = false
            do {
                let confirmed = try SavedPlaudDevice(serialNumber: serial, model: saved.model,
                    protocolVersion: saved.protocolVersion, lastSynchronized: saved.lastSynchronized, peripheralID: next?.authenticatedPeripheralID)
                if saved.protocolVersion >= 20 {
                    guard let persisted = try VectaOfflineIdentityStore.load(serial: serial) else { throw VectaAuthorizationError.unavailable }
                    _ = try persisted.prepared(for: confirmed)
                    if cachedIdentity == nil { setupCredentials = nil; deviceSession = nil }
                }
                offlineAuthorizationReady = saved.protocolVersion >= 20
                if let legacyOwnerToken { try NativeOwnerTokenStore.save(legacyOwnerToken, serial: serial) }
                try PlaudSelectionStore(url: services.appendingPathComponent("selected-device.json")).save(confirmed)
                savedDevice = confirmed; pendingDevice = nil
                scheduleAutoSync()
            } catch {
                status = VL.text("Не удалось сохранить локальную авторизацию. Повторное офлайн-подключение не готово.")
                offlineAuthorizationReady = false
                next?.stop(); connected = false; syncing = false
                finishSyncAnalysis(); return
            }
            do {
                try library?.replaceRemoteList(entries.filter { $0.byteSize > 0 }.map {
                    NativeRemoteRecording(identity: .init(serialNumber: serial, sessionID: Int($0.sessionID)), duration: 0, byteSize: $0.byteSize)
                })
                if selected == nil { selected = library?.items.first?.identity }
            } catch { status = error.localizedDescription }
            if let requestedDownload {
                self.requestedDownload = nil
                download(identity: requestedDownload)
            } else if syncing {
                syncQueue = library?.items.filter { $0.identity.serialNumber == serial && $0.remote != nil && $0.audioURL == nil }.map(\.identity) ?? []
                downloadNext()
            } else {
                releaseConnectionAfterSync()
                status = autoSyncInterval.keepsConnection ? VL.text("Список обновлён. Соединение с Plaud поддерживается."):VL.text("Список обновлён. Bluetooth-соединение освобождено.")
            }
        }
        next.onWiFiAvailabilityChanged = { [weak self] in
            guard let self, self.connectionAttempt == driverAttempt else { return }
            self.objectWillChange.send()
        }
        next.onFailure = { [weak self] reason in
            guard let self, self.connectionAttempt == driverAttempt else { return }
            if self.wifiTransfer != nil {
                self.finishFastTransfer(message: NativeConnectionMessage.failure(reason), cancel: true)
                return
            }
            awaitingBluetoothAuthorization = reason == "timeout-bluetooth" && CBManager.authorization == .notDetermined
            clearTransferProgress()
            connected = false; connecting = false; transferring = false; syncing = false; syncQueue = []; status = NativeConnectionMessage.failure(reason)
            if reason == "owner-handshake-rejected-1" { status = VL.text("Диктофон отклонил привязку: он связан с другим клиентом. Автоматическая отвязка не выполнялась.") }
            pendingDevice = nil; self.serial = savedDevice?.serialNumber; requestedDownload = nil
            finishSyncAnalysis()
            if let transferID { library?.failTransfer(transferID, message: status); self.transferID = nil }
        }
        next.onTransferProgress = { [weak self] received, total in
            guard let self, total > 0 else { return }
            self.transferMetrics?.observe(percent: min(99, Int(Double(received) / Double(total) * 100)), sdkBytesPerSecond: nil, at: ProcessInfo.processInfo.systemUptime)
            self.updateTransferProgress()
        }
        next.onTransferValidated = { [weak self] in
            self?.transferMetrics?.observe(percent: 100, sdkBytesPerSecond: nil, at: ProcessInfo.processInfo.systemUptime)
            self?.updateTransferProgress()
        }
        next.onDownloadComplete = { [weak self] url in
            Task { @MainActor in
                guard let self, self.connectionAttempt == driverAttempt, let id = self.transferID else { return }
                do {
                    _ = try await self.library?.publishCompletedMP3(url, for: id)
                    self.downloadedForAnalysis.append(id)
                    self.status = VL.text("Запись сохранена на Mac")
                } catch {
                    self.library?.failTransfer(id, message: error.localizedDescription); self.status = error.localizedDescription
                    self.syncing = false; self.syncQueue = []
                }
                self.transferID = nil; self.transferring = false; self.clearTransferProgress()
                if self.syncing { self.downloadNext() }
                else { self.releaseConnectionAfterSync(); self.finishSyncAnalysis() }
            }
        }
        driver = next; next.start()
    }

    private func downloadNext() {
        guard syncing else { return }
        while !syncQueue.isEmpty {
            let next = syncQueue.removeFirst()
            guard library?.items.first(where: { $0.identity == next })?.audioURL == nil else { continue }
            download(identity: next); return
        }
        if let device = savedDevice,
           let completed = try? SavedPlaudDevice(serialNumber: device.serialNumber, model: device.model, protocolVersion: device.protocolVersion, lastSynchronized: Date(), peripheralID: device.peripheralID) {
            do { try PlaudSelectionStore(url: services.appendingPathComponent("selected-device.json")).save(completed); savedDevice = completed }
            catch { status = VL.text("Записи сохранены, но время синхронизации не удалось сохранить") }
        }
        syncing = false; releaseConnectionAfterSync()
        if selected == nil { select(library?.items.first(where: { $0.identity.serialNumber == savedDevice?.serialNumber })?.identity) }
        status = autoSyncInterval.keepsConnection ? VL.text("Синхронизация завершена. Соединение с Plaud поддерживается."):VL.text("Синхронизация завершена. Все записи сохранены на Mac.")
        finishSyncAnalysis()
    }
    /// Executable regression check: no Bluetooth, production library or models.
    func verifySyncPreservesDetail() {
        let id=NativeRecordingIdentity(serialNumber:"fixture",sessionID:123)
        selected=id; analysisID=UUID(); history="saved"; progress=17; duration=47
        focusedSegment=3; waveform=[0.2,0.8]
        let version=analysisID, navigation=playbackNavigationID
        let person=AISpeakerIdentity(id:"speaker_001",name:"Fixture",origin:"manual",profileID:nil)
        conversation.identities[person.id]=person
        select(id)
        precondition(analysisID==version && history=="saved" && progress==17 && focusedSegment==3)
        syncing=true; downloadNext()
        precondition(selected==id && analysisID==version && history=="saved")
        precondition(progress==17 && duration==47 && waveform==[0.2,0.8])
        precondition(conversation.identities[person.id]==person && playbackNavigationID==navigation)
        print("PASS: synchronization and same-recording selection preserve detail, version, playback and speakers")
    }
    private func releaseConnectionAfterSync() {
        if wifiTransfer != nil {
            let message = driver?.isWiFiHandoverActive == true ? VL.text("Передача по Wi‑Fi завершена. Проверенные записи сохранены на Mac.") : VL.text("Записи сохранены на Mac. Переключение на Wi‑Fi не потребовалось.")
            finishFastTransfer(message: message, cancel: false)
            return
        }
        if !autoSyncInterval.keepsConnection {driver?.stop();driver=nil;connected=false}
    }
    func refresh() { beginSync(automatic: false) }
    private func beginSync(automatic: Bool) {
        guard !busy else { return }
        summarizeAllAfterSync = !automatic
        downloadedForAnalysis = []
        if let savedDevice {
            autoSchedule.recordAttempt(); scheduleAutoSync()
            serial = savedDevice.serialNumber; syncing = true
            if connected,autoSyncInterval.keepsConnection,let driver {driver.refreshRecordings()} else {connect()}
        }
        else { finishSyncAnalysis(); scan() }
    }
    func resumeAfterBluetoothAuthorization() {
        guard awaitingBluetoothAuthorization, CBManager.authorization == .allowedAlways,
              savedDevice != nil, !connecting, !transferring else { return }
        // One retry after the initial OS permission, triggered by activation.
        // There is no Bluetooth polling or retry loop after connection errors.
        awaitingBluetoothAuthorization = false
        syncing = true; connect()
    }
    func disconnect() {
        if wifiTransfer != nil || wifiStartTask != nil {
            finishFastTransfer(message: VL.text("Передача отменена пользователем. Сохранённые записи не изменены."), cancel: true)
            return
        }
        summarizeAllAfterSync = false; downloadedForAnalysis = []
        awaitingBluetoothAuthorization = false
        connectionAttempt = UUID()
        clearTransferProgress()
        let interruptedReset = resettingDevice && resetCommandRequested
        resettingDevice = false; resetCommandRequested = false
        driver?.stop(); driver = nil; connected = false; connecting = false; transferring = false; syncing = false; syncQueue = []
        requestedDownload = nil; pendingDevice = nil; serial = savedDevice?.serialNumber
        if let transferID { library?.failTransfer(transferID, message: VL.text("Передача отменена пользователем")); self.transferID = nil }
        status = interruptedReset
            ? VL.text("Ожидание остановлено. Уже отправленную команду сброса отменить нельзя; проверьте PLAUD. Копии на Mac сохранены.")
            : VL.text("Bluetooth-соединение освобождено")
    }
    func forgetDevice() {
        disconnect()
        do {
            try PlaudSelectionStore(url: services.appendingPathComponent("selected-device.json")).forget()
            serial = nil; savedDevice = nil; pendingDevice = nil; offlineAuthorizationReady = false
            scheduleAutoSync()
            // Preserve cached identity, device ownership and all recordings.
            status = VL.text("Выбранное устройство забыто только в Vecta")
        } catch { status = VL.text("Не удалось удалить локальный выбор устройства") }
    }
    func download() {
        guard let selected else { return }; download(identity: selected)
    }
    private func download(identity: NativeRecordingIdentity) {
        guard let item = library?.items.first(where: {$0.identity == identity}), let library else { return }
        guard item.identity.serialNumber == savedDevice?.serialNumber else { status = VL.text("Выберите диктофон, которому принадлежит запись"); return }
        if !connected { requestedDownload = item.identity; connect(); return }
        guard
              let file = files.first(where: { Int($0.sessionID) == item.identity.sessionID }) else { return }
        do {
            try library.beginTransfer(item.identity)
            transferID = item.identity; transferring = true
            transferMetrics = VectaTransferMetrics(sourceByteCount: Int(file.byteSize), startedAt: ProcessInfo.processInfo.systemUptime)
            updateTransferProgress()
            transferTimer?.invalidate()
            transferTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateTransferProgress() }
            }
            let root = services.appendingPathComponent("NativeTransfers/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let wifiTransfer, wifiTransfer.isReady {
                try wifiTransfer.download(file, to: root.appendingPathComponent("recording.plaudaudio"))
            } else {
                driver?.download(recording: file, to: root.appendingPathComponent("recording.plaudaudio"))
            }
        } catch {
            if wifiTransfer != nil {
                finishFastTransfer(message: VL.text("Не удалось начать передачу записи по Wi‑Fi. Незавершённый файл не опубликован."), cancel: true)
                return
            }
            clearTransferProgress(); status = error.localizedDescription; syncing = false; syncQueue = []; transferring = false; driver?.stop(); connected = false; finishSyncAnalysis()
        }
    }
    func canDeleteRecording(_ identity: NativeRecordingIdentity) -> Bool {
        !busy && !importingAudio && !requestingAnalysis && !visualRetryBusy && !chatBusy && !batchChecking && batchActiveRequest == nil
            && !(analysisQueue?.jobs.contains(where: { $0.identity == identity && $0.requestID != nil }) ?? false)
            && !(selected == identity && analysisBusy)
    }
    func deleteRecording(_ identity: NativeRecordingIdentity) {
        guard canDeleteRecording(identity), let library else { status = VL.text("Дождитесь завершения обработки или синхронизации."); return }
        do {
            // Remove only an unsubmitted job before hiding the recording.
            try analysisQueue?.remove(identity)
            try library.deleteRecording(identity)
            libraryCorpusVersion+=1
            batchCount = analysisQueue?.jobs.count ?? 0
            if selected == identity { select(nil) }
            globalSearchHits.removeAll { $0.recording == identity }
            objectWillChange.send()
            status = VL.text("Запись перемещена в корзину Vecta. На Plaud она сохранена.")
        } catch { status = VL.text("Не удалось завершить удаление: ") + error.localizedDescription; objectWillChange.send() }
    }
    func restoreRecording(_ identity: NativeRecordingIdentity) {
        do { try library?.restoreRecording(identity);libraryCorpusVersion+=1; objectWillChange.send(); status = VL.text("Запись восстановлена.") }
        catch { status = VL.text("Не удалось восстановить запись: ") + error.localizedDescription }
    }
    func select(_ id: NativeRecordingIdentity?) {
        guard id != selected else { return }
        chatTask?.cancel();chat=AIChatHistory();loadedChatKey=nil;chatError=nil
        waveformTask?.cancel();preparingPlayerTask?.cancel();playWhenReady=false;playback.preparing=false; waveform = []
        timer?.invalidate(); timer=nil; playbackStopTime=nil; focusedSegment=nil
        appliedConversationRevision=nil;appliedConversationSegments=[]
        conversation=AIRecordingSpeakers(); conversationStateRoot=nil; conversationLoadedKey=nil; wordTimings=[];speakerCentroids=[:]
        player?.stop(); player = nil; playing = false; progress = 0; duration = 0; history = ""
        selected = id; analyses = []; analysisID = nil; analysisMessage = nil
        if let url = selection?.audioURL {
            duration=selection?.duration ?? 0;playback.preparing=true
            preparingPlayerTask=Task { [weak self] in
                let prepared=try? await Task.detached(priority:.utility){try AVAudioPlayer(contentsOf:url)}.value
                guard let self,!Task.isCancelled,self.selected==id else{return}
                self.preparingPlayerTask=nil;self.playback.preparing=false
                guard let prepared else{self.status=VL.text("Не удалось подготовить аудио.");self.playWhenReady=false;return}
                prepared.enableRate=true;prepared.rate=self.playbackRate;prepared.currentTime=self.progress
                self.duration=prepared.duration;self.player=prepared
                if self.playWhenReady {self.playWhenReady=false;let end=self.playbackStopTime;self.togglePlayback();self.playbackStopTime=end}
            }
            waveformTask = Task {
                let worker = Task.detached(priority: .utility) { try await NativeWaveformCache.shared.amplitudes(at: url) }
                let result = await withTaskCancellationHandler(operation: { try? await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, selected == id else { return }
                waveform = result ?? []
            }
        }
        guard let id, let library else { return }
        let generation = libraryGeneration
        Task {
            await reloadAnalysis()
            do {
                let saved = try await library.legacyHistory(for: id)
                guard selected == id, libraryGeneration == generation, self.library === library else { return }
                history = saved.results.sorted { $0.completedAt > $1.completedAt }.first?.body ?? ""
            } catch { /* A new recorder entry need not have a saved analysis. */ }
        }
    }
    func togglePlayback() {
        playbackStopTime=nil
            if player==nil {playWhenReady.toggle();return}
            guard let player else { return }
            if player.isPlaying { player.pause(); playing = false }
            else { playing = player.play() }
            timer?.invalidate()
            guard playing else { timer=nil;return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let player = self.player else { return }
                    if let end=self.playbackStopTime,player.currentTime>=end { player.pause();player.currentTime=end;self.playbackStopTime=nil }
                    self.progress = player.currentTime; self.playing = player.isPlaying
                    if !self.playing { self.timer?.invalidate();self.timer=nil }
                }
            }
    }
    func setPlaybackRate(_ rate: Float) { guard [Float(0.75), 1, 1.25, 1.5, 2].contains(rate) else { return }; playbackRate = rate; player?.rate = rate }
    func seek(_ value: Double) { playbackStopTime=nil;let value=min(duration,max(0,value));player?.currentTime = value; progress = value }
    func playExcerpt(start:Double,end:Double,segment:Int?=nil) {
        guard let excerpt=AIAudioExcerpt(start:start,end:end,duration:duration) else { return }
        player?.pause();player?.currentTime=excerpt.start;focusedSegment=segment;progress=excerpt.start
        togglePlayback();playbackStopTime=excerpt.end
        playbackNavigationID=UUID()
    }
    func stop() async {
        automationSleeping = true
        librarySourceTask?.cancel(); librarySourceTask = nil
        workspaceImportTask?.cancel(); workspaceImportTask = nil
        batchTask?.cancel(); batchTask = nil
        resetLibraryPresentation()
        await awaitFastTransferCleanup(); connectionAttempt = UUID(); librarySearchSession.clear();libraryQuestionTask?.cancel();libraryIndexTask?.cancel(); importTask?.cancel(); await importTask?.value; chatTask?.cancel();visualRetryTask?.cancel();automationSleeping = true; batchTask?.cancel(); autoSyncTimer?.invalidate(); autoSyncTimer = nil; analysisTimer?.invalidate(); waveformTask?.cancel();preparingPlayerTask?.cancel(); clearTransferProgress(); if runtime == nil { localAI?.stop() }; discovery?.stop(); timer?.invalidate(); player?.stop(); driver?.stop(); await runtime?.stop() }
}

extension NativeMacModel {
    func showVoiceFeedback(_ text: String) {
        voiceFeedbackTask?.cancel()
        voiceFeedback = text
        voiceFeedbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) }
            catch { return }
            self?.voiceFeedback = nil; self?.voiceFeedbackTask = nil
        }
    }
    private func reloadRootScopedState() {
        voiceStateRoot = nil; workspaceStateRoot = nil
        voiceLibrary = AIVoiceLibrary(); workspace = AIWorkspace()
        guard let root = processingRoot?.standardizedFileURL else { return }
        do {
            voiceLibrary = try AIConversationStore(root: root).voices()
            voiceStateRoot = root
        } catch { analysisMessage = VL.text("Не удалось открыть библиотеку голосов. Её файлы сохранены; изменения отключены до восстановления.") }
        loadWorkspace()
    }
    private func resetLibraryPresentation() {
        appliedConversationRevision=nil;appliedConversationSegments=[]
        libraryGeneration = UUID(); loadingHistory = false;analysisReloadPending=false
        voiceStateRoot = nil; workspaceStateRoot = nil; conversationStateRoot = nil; conversationLoadedKey = nil
        voiceFeedbackTask?.cancel(); voiceFeedbackTask = nil; voiceFeedback = nil
        conversation = AIRecordingSpeakers(); voiceLibrary = AIVoiceLibrary(); workspace = AIWorkspace()
        wordTimings = []; speakerCentroids = [:]; history = ""; analyses = []; analysisID = nil; pendingAnalysis = nil
        requestingAnalysis = false; analysisMessage = nil
        chat = AIChatHistory(); loadedChatKey = nil; chatError = nil; chatDraft = ""; chatDraftKey = nil
        librarySourceGeneration = UUID(); workspaceImportGeneration = UUID()
        libraryIndexGeneration = UUID(); libraryCorpus = nil; globalSearchHits = []; searchingLibrary = false; clearLibraryQuestion()
        libraryCorpusVersion += 1; batchMessage = nil; batchCount = 0; batchFailures = 0; batchActiveRequest = nil
        batchProgress = nil; batchTitle = nil; batchChecking = false
    }
    func requestFastTransfer() {
        guard canStartFastTransfer else { return }
        if VectaRuntimePreferences.synchronization.bool(forKey: "Vecta.fastTransfer.skipNetworkWarning") {
            beginFastTransfer()
        } else { showingFastTransferWarning = true }
    }
    func confirmFastTransfer(_ doNotShowAgain: Bool) {
        showingFastTransferWarning = false
        guard canStartFastTransfer else { return }
        if doNotShowAgain { VectaRuntimePreferences.synchronization.set(true, forKey: "Vecta.fastTransfer.skipNetworkWarning") }
        beginFastTransfer()
    }
    private func beginFastTransfer() {
        #if VECTA_DEVELOPMENT
        guard !CommandLine.arguments.contains("--verify-ui"), !CommandLine.arguments.contains("--verify-conversation") else {
            status = VL.text("Проверка UI: Wi‑Fi и транспорт отключены."); return
        }
        #endif
        guard canStartFastTransfer, let driver, let device = savedDevice, let id = transferID,
              let file = files.first(where: { Int($0.sessionID) == id.sessionID }) else { return }
        let attempt = connectionAttempt
        let transfer = NativeWiFiTransfer(driver: driver, serial: device.serialNumber, baseline: files)
        wifiTransfer = transfer; fastTransferPhase = VL.text("Проверяем разрешение macOS для Wi‑Fi…")
        transfer.onStatus = { [weak self, weak transfer] text in
            guard let self, self.connectionAttempt == attempt, self.wifiTransfer === transfer, self.wifiCleanupTask == nil else { return }
            self.fastTransferPhase = text; self.status = text
        }
        transfer.onProgress = { [weak self] bytes, total in
            guard let self, self.connectionAttempt == attempt, self.wifiCleanupTask == nil, total > 0 else { return }
            self.transferMetrics?.observe(percent: min(99, Int(Double(bytes) / Double(total) * 100)), sdkBytesPerSecond: nil, at: ProcessInfo.processInfo.systemUptime)
            self.updateTransferProgress()
        }
        transfer.onFileReceived = { [weak self, weak driver] rawURL in
            guard let self, let driver, self.connectionAttempt == attempt, self.wifiCleanupTask == nil else { return }
            do { try driver.finishWiFiRecording(rawURL) }
            catch { self.finishFastTransfer(message: VL.text("Не удалось подготовить переданную запись. Исходный файл на PLAUD сохранён."), cancel: true) }
        }
        transfer.onFailure = { [weak self] message in
            guard let self, self.connectionAttempt == attempt else { return }
            self.finishFastTransfer(message: message, cancel: true)
        }
        transfer.onReady = { [weak self, weak transfer] in
            guard let self, let transfer, self.connectionAttempt == attempt, self.transferID == id, self.wifiCleanupTask == nil else { return }
            do {
                let root = self.services.appendingPathComponent("NativeTransfers/" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                self.transferMetrics = VectaTransferMetrics(sourceByteCount: Int(file.byteSize), startedAt: ProcessInfo.processInfo.systemUptime)
                self.updateTransferProgress()
                try transfer.download(file, to: root.appendingPathComponent("recording.plaudaudio"))
            } catch { self.finishFastTransfer(message: VL.text("Не удалось начать Wi‑Fi-передачу. Файлы на PLAUD не изменены."), cancel: true) }
        }
        wifiStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Permission denial and a cancelled warning must not interrupt BLE.
                try await transfer.prepare()
                try Task.checkCancellation()
                guard self.connectionAttempt == attempt, self.transferID == id, driver.canUseWiFi else { throw CancellationError() }
                try await transfer.start()
                self.wifiStartTask = nil
            } catch {
                self.wifiStartTask = nil
                guard self.wifiCleanupTask == nil, self.connectionAttempt == attempt else { return }
                let message: String
                if let failure = error as? NativeWiFiNetworkController.Failure {
                    message = NativeWiFiNetworkController.Failure(reason: failure.reason, cleanup: nil).localizedDescription
                } else {
                    message = VL.text("Fast transfer не завершён. Сохранённые записи и привязка не изменены.")
                }
                self.finishFastTransfer(message: message, cancel: driver.isWiFiHandoverActive || driver.stage == .failed)
            }
        }
    }
    private func finishFastTransfer(message: String, cancel: Bool) {
        guard wifiCleanupTask == nil, let transfer = wifiTransfer else { return }
        let start = wifiStartTask
        start?.cancel()
        fastTransferPhase = VL.text("Возвращаем Wi‑Fi-сеть…")
        wifiCleanupTask = Task { @MainActor [weak self] in
            await start?.value
            let networkMessage = await transfer.finish()
            guard let self else { return }
            let handoverOccurred = self.driver?.isWiFiHandoverActive == true
            self.wifiTransfer = nil; self.wifiStartTask = nil; self.fastTransferPhase = nil
            if cancel || handoverOccurred { self.disconnect() }
            else if !self.transferring && !self.syncing { self.releaseConnectionAfterSync() }
            self.wifiCleanupTask = nil
            self.status = message + (networkMessage.map { " " + $0 } ?? "")
            if cancel { self.finishSyncAnalysis() }
            self.scheduleAutoSync()
        }
    }
    private func awaitFastTransferCleanup() async {
        if wifiCleanupTask == nil, wifiTransfer != nil {
            finishFastTransfer(message: VL.text("Передача остановлена перед закрытием приложения."), cancel: true)
        }
        await wifiCleanupTask?.value
    }
}

private enum NativeOwnerTokenStore {
    static func query(_ serial: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: VectaLegacyPaths.ownerKeychainService,
         kSecAttrAccount as String: serial]
    }
    static func load(serial: String) throws -> String? {
        var request = query(serial)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), token.count == 32 else { throw NativeRuntimeError.sessionUnavailable }
        return token
    }
    static func save(_ token: String, serial: String) throws {
        let data = Data(token.utf8)
        var request = query(serial)
        let status: OSStatus
        if try load(serial: serial) != nil { status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary) }
        else { request[kSecValueData as String] = data; status = SecItemAdd(request as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NativeRuntimeError.sessionUnavailable }
    }
}

@MainActor final class NativeMacDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = NativeMacModel()
    private var window: NSWindow?
    private var quitting = false
    private var cleanupFinished = false
    private var languageRestartHelper:Process?
    private var terminationSignals: [DispatchSourceSignal] = []
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if VECTA_DEVELOPMENT
        if (CommandLine.arguments.contains("--verify-ui") || CommandLine.arguments.contains("--verify-conversation")) && !CommandLine.arguments.contains("--verify-welcome"),let resources=Bundle.main.resourceURL {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("Vecta-visual-"+UUID().uuidString)
            try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            model.localAI=try? LocalAIHost(root:root,resources:resources)
            model.destination = .ai; model.status = VL.text("Визуальная проверка: библиотека не открывается.")
            if !CommandLine.arguments.contains("--verify-speaker-ui") && !CommandLine.arguments.contains("--verify-public-demo") {Task { await model.localAI?.refreshModels() }}
            if CommandLine.arguments.contains("--verify-reset-ui") {
                model.savedDevice = try? SavedPlaudDevice(serialNumber: "882SYNTHETIC", model: .notePinS, protocolVersion: 20)
                model.offlineAuthorizationReady = true; model.destination = .device
                model.status = VL.text("Проверка UI: синтетическое устройство, сброс и транспорт отключены.")
            }
            if CommandLine.arguments.contains("--verify-conversation") {
                if CommandLine.arguments.contains("--verify-speaker-ui") {try? model.prepareSpeakerMergeVerification(root:root)}
                else {try? model.prepareConversationVerification(root:root)}
                model.destination = .library
            }
            if CommandLine.arguments.contains("--verify-fast-transfer-ui") {
                try? model.prepareConversationVerification(root: root)
                try? model.prepareFastTransferVerification()
                model.status = VL.text("Проверка UI: Fast transfer без сообщения 8A; устройство и Wi‑Fi отключены.")
            }
            if let index=CommandLine.arguments.firstIndex(of:"--verify-library-copy"),CommandLine.arguments.indices.contains(index+1) {
                do {
                    let privateRoot=URL(fileURLWithPath:CommandLine.arguments[index+1])
                    guard privateRoot.lastPathComponent.hasPrefix("Vecta-private-validation-"),FileManager.default.fileExists(atPath:privateRoot.appendingPathComponent("before.json").path) else {throw NativeStorageError.invalidIdentity}
                    // The test copy uses its own account namespace; no Keychain or
                    // legacy backend activation is needed to inspect copied data.
                    let user="Vecta-private-ui-verification",base=privateRoot.appendingPathComponent("native-ui-catalog"),processing=privateRoot.appendingPathComponent("copy-1")
                    if !FileManager.default.fileExists(atPath:base.path) {
                        try FileManager.default.copyItem(at:privateRoot.appendingPathComponent("copy-0"),to:base)
                        let users=base.appendingPathComponent("Users")
                        let accounts=try FileManager.default.contentsOfDirectory(at:users,includingPropertiesForKeys:nil).filter {FileManager.default.fileExists(atPath:$0.appendingPathComponent("recordings.json").path)}
                        guard accounts.count==1 else {throw NativeStorageError.ambiguousLibrary}
                        try FileManager.default.moveItem(at:accounts[0],to:users.appendingPathComponent(VectaRecordingStore.userDirectoryName(for:user)))
                    }
                    let preferences=UserDefaults(suiteName:"Vecta.PrivateLibraryVerification")!
                    let exporter=VectaLocalAudioExporter(userID:user,defaults:preferences);try exporter.configureFolder(processing)
                    let layout=NativeStorageLayout(recordingBase:base,userDirectory:base.appendingPathComponent("Users/"+VectaRecordingStore.userDirectoryName(for:user)),servicesDirectory:privateRoot.appendingPathComponent("services"))
                    model.library=try NativeLibraryController(userID:user,layout:layout,exporter:exporter)
                    model.localAI=try LocalAIHost(root:processing,resources:resources)
                    model.destination = .library;model.status=VL.text("Проверка приватной копии · транспорт и автообработка не запущены")
                    model.loadWorkspace();Task {await model.localAI?.refreshModels()}
                } catch {model.status=VL.text("Не удалось открыть приватную тестовую копию.")}
            }

        }
        #endif
        #if VECTA_DEVELOPMENT
        let compactVerification=CommandLine.arguments.contains("--verify-compact")
        let mediumVerification=CommandLine.arguments.contains("--verify-medium")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: compactVerification ? 760:mediumVerification ? 1040:1100, height: compactVerification ? 560:mediumVerification ? 760:740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = CommandLine.arguments.contains("--verify-visual4") || CommandLine.arguments.contains("--verify-visual-gallery") ? VL.text("Vecta · проверка Visual Summary 4"):"Vecta"; window.minSize = NSSize(width: 760, height: 560)
        let verifying=VectaRuntimePreferences.isVerification
        let preferences=VL.preferences
        if verifying {preferences.set(CommandLine.arguments.contains("--verify-light") ? "light":"dark",forKey:"vecta.appearance")}
        if verifying && CommandLine.arguments.contains("--verify-visual-gallery") {
            window.contentView=NSHostingView(rootView:NativeVisualComponentGallery().defaultAppStorage(preferences).preferredColorScheme(CommandLine.arguments.contains("--verify-light") ? .light:.dark))
        } else {
            window.contentView = NSHostingView(rootView: NativeAppRoot(model: model).defaultAppStorage(preferences))
        }
        #else
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Vecta"; window.minSize = NSSize(width: 760, height: 560)
        window.contentView = NSHostingView(rootView: NativeAppRoot(model: model).defaultAppStorage(UserDefaults.standard))
        #endif
        window.center(); window.makeKeyAndOrderFront(nil); self.window = window
        let menu=NSMenu()
        func section(_ title:String)->NSMenu {
            let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");let submenu=NSMenu(title:title);item.submenu=submenu;menu.addItem(item);return submenu
        }
        let app=section("Vecta")
        app.addItem(withTitle:VL.text("Настройки…"),action:#selector(openSettings),keyEquivalent:",")
        app.addItem(.separator())
        app.addItem(withTitle:VL.text("Завершить Vecta"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let file=section(VL.text("Файл"))
        file.addItem(withTitle:VL.text("Все записи"),action:#selector(openLibrary),keyEquivalent:"1")
        file.addItem(withTitle:VL.text("Импорт аудио…"),action:#selector(importAudio),keyEquivalent:"i")
        let export=file.addItem(withTitle:VL.text("Экспорт записи…"),action:#selector(exportRecording),keyEquivalent:"e");export.keyEquivalentModifierMask=[.command,.shift]
        file.addItem(withTitle:VL.text("Закрыть окно"),action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        let edit=section(VL.text("Правка"))
        edit.addItem(withTitle:VL.text("Отменить"),action:Selector(("undo:")),keyEquivalent:"z")
        let redo=edit.addItem(withTitle:VL.text("Повторить"),action:Selector(("redo:")),keyEquivalent:"z");redo.keyEquivalentModifierMask=[.command,.shift]
        edit.addItem(.separator())
        edit.addItem(withTitle:VL.text("Вырезать"),action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:VL.text("Копировать"),action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:VL.text("Вставить"),action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:VL.text("Выбрать всё"),action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        edit.addItem(.separator())
        edit.addItem(withTitle:VL.text("Поиск по библиотеке"),action:#selector(searchLibrary),keyEquivalent:"f")
        let viewMenu=section(VL.text("Вид"))
        let sidebar=viewMenu.addItem(withTitle:VL.text("Показать / скрыть боковую панель"),action:#selector(toggleSidebar),keyEquivalent:"s");sidebar.keyEquivalentModifierMask=[.command,.control]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle:VL.text("Компактное окно"),action:#selector(compactWindow),keyEquivalent:"")
        viewMenu.addItem(withTitle:VL.text("Обычное окно"),action:#selector(regularWindow),keyEquivalent:"")
        viewMenu.addItem(withTitle:VL.text("Большое окно"),action:#selector(largeWindow),keyEquivalent:"")
        let playback=section(VL.text("Воспроизведение"))
        let play=playback.addItem(withTitle:VL.text("Воспроизвести / пауза"),action:#selector(playPause),keyEquivalent:"p");play.keyEquivalentModifierMask=[.command,.option]
        let previous=playback.addItem(withTitle:VL.text("Назад на 10 секунд"),action:#selector(skipBackward),keyEquivalent:"\u{F702}");previous.keyEquivalentModifierMask=[.command,.option]
        let next=playback.addItem(withTitle:VL.text("Вперёд на 10 секунд"),action:#selector(skipForward),keyEquivalent:"\u{F703}");next.keyEquivalentModifierMask=[.command,.option]
        let windows=section(VL.text("Окно"));NSApp.windowsMenu=windows
        windows.addItem(withTitle:VL.text("Свернуть"),action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        let fullscreen=windows.addItem(withTitle:VL.text("Полноэкранный режим"),action:#selector(NSWindow.toggleFullScreen(_:)),keyEquivalent:"f");fullscreen.keyEquivalentModifierMask=[.command,.control]
        NSApp.mainMenu = menu
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                // Dispatch the normal termination path outside the signal callback.
                RunLoop.main.perform(inModes: [.common]) { NSApplication.shared.terminate(nil) }
            }
            source.resume(); terminationSignals.append(source)
        }
        NSApp.activate(ignoringOtherApps: true)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.model.suspendAutomation() }
            }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.model.resumeAutomation() }
            }
    }
    @objc func importAudio() {model.chooseAudioImport()}
    @objc func openLibrary() {model.destination = .library;model.searchFocusSignal=UUID()}
    @objc func searchLibrary() {openLibrary()}
    @objc func exportRecording() {model.destination = .library;model.openDetailSignal=UUID();model.exportRequested=true}
    @objc func toggleSidebar() {model.sidebarToggleSignal=UUID()}
    @objc func playPause() {model.togglePlayback()}
    @objc func skipBackward() {model.seek(model.progress-10)}
    @objc func skipForward() {model.seek(model.progress+10)}
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        switch item.action {
        case #selector(exportRecording):return model.analysis != nil
        case #selector(playPause),#selector(skipBackward),#selector(skipForward):return model.selection?.audioURL != nil
        default:return true
        }
    }
    @objc func compactWindow() { window?.setContentSize(NSSize(width: 760, height: 560)) }
    @objc func largeWindow() { window?.setContentSize(NSSize(width:1440,height:900)) }
    @objc func regularWindow() { window?.setContentSize(NSSize(width: 1100, height: 740)) }
    @objc func openSettings() { model.destination = .settings }
    func restartForLanguage(_ language:VectaLanguage) {
        guard language != VL.language,model.canRestartForLanguage,!quitting else{return}
        let defaults=VL.preferences,previous=defaults.object(forKey:"Vecta.interfaceLanguage")
        model.languageRestartError=nil
        do {
            defaults.set(language.rawValue,forKey:"Vecta.interfaceLanguage")
            guard defaults.synchronize() else {throw CocoaError(.fileWriteUnknown)}
            let helper=NativeLanguageRestart.helper(bundle:Bundle.main.bundleURL,pid:ProcessInfo.processInfo.processIdentifier,
                arguments:Array(CommandLine.arguments.dropFirst()),environment:ProcessInfo.processInfo.environment)
            try helper.run();languageRestartHelper=helper;model.languageRestarting=true
            NSApp.terminate(nil)
        } catch {
            if let previous {defaults.set(previous,forKey:"Vecta.interfaceLanguage")} else {defaults.removeObject(forKey:"Vecta.interfaceLanguage")}
            model.languageRestarting=false
            model.languageRestartError=VL.text("Не удалось перезапустить Vecta. Закройте приложение и откройте его снова.")
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.resumeAfterBluetoothAuthorization() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if cleanupFinished { return .terminateNow }
        guard !quitting else { return .terminateCancel }
        quitting = true
        // Keep the normal event loop running while Swift concurrency releases
        // workers and transport. AppKit's terminateLater loop can starve this Task.
        Task { @MainActor in
            await model.stop()
            cleanupFinished = true
            sender.terminate(nil)
        }
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct NativeMacMain {
    @MainActor static func main() {
        #if VECTA_DEVELOPMENT
        if VectaAppChecks.run() { return }
        #endif
        VL.prepareApplicationPreferences()
        let app = NSApplication.shared; let delegate = NativeMacDelegate()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run(); withExtendedLifetime(delegate) {}
    }
}
