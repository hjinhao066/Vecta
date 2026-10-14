import AppKit
import Combine
import Foundation
import Security
import Darwin

/// The legacy session is queried without deletion or rewriting. A Keychain
/// decode/access failure must never invoke the SDK store's clearing behavior.
enum NativeLegacySessionReader {
    static func read(bundleIdentifier: String = NativeStorageLayout.recorderBundleIdentifier) throws -> VectaDeviceSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: bundleIdentifier + ".session",
            kSecAttrAccount as String: "public-beta-session",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let session = try? JSONDecoder.vectaStorage.decode(VectaDeviceSession.self, from: data) else {
            throw NativeRuntimeError.sessionUnavailable
        }
        return session
    }
}

/// Owns library access and local inference. Device authorization uses HTTPS
/// directly; this application has no backend process or listening HTTP port.
@MainActor final class NativeAppRuntime: ObservableObject {
    @Published private(set) var state: State = .stopped
    @Published private(set) var message: String?
    /// Optional AI startup failures never close a successfully opened library.
    /// Do not expose decoder details, file paths or preference contents in UI.
    @Published private(set) var aiErrorMessage: String?
    @Published private(set) var session: VectaDeviceSession?
    private(set) var library: NativeLibraryController?
    private(set) var localAI: LocalAIHost?
    /// Authoritative workspace scope, available even in library-only mode.
    private(set) var processingRoot: URL?
    private var ownership: RuntimeOwnership?
    /// A parent-owned lease locks this same servicesDirectory before mutable
    /// model initialization. It outlives runtime stops and library switches.
    /// Never acquire another flock when this lease has been supplied.
    private let ownershipLease: RuntimeOwnership?
    private var folderAccess: NativeRecordingsFolderAccess?
    private let resources: URL
    private let servicesDirectory: URL
    private let defaults: UserDefaults
    private let cachedSessionReader: () throws -> VectaDeviceSession?
    private var generation = UUID()
    private var migrationTask: Task<Void, Error>?
    private var userID: String?
    enum State: Equatable { case stopped, starting, ready, failed, stopping }
    enum LibrarySource {
        /// Only for a known local identity at its declared default namespace.
        /// This is the only mode permitting a missing exact-owner directory.
        case freshDefault(base: URL)
        /// User explicitly chose an existing library: open it in place, even
        /// if it carries an older migration manifest and has since changed.
        case selectedLibrary(base: URL)
        /// Predecessor discovery retains the copy-first snapshot contract.
        case archivedMigration(candidateBases: [URL], destinationBase: URL)
    }
    init(resources: URL, servicesDirectory: URL, ownershipLease: RuntimeOwnership? = nil,
         defaults: UserDefaults = .standard,
         cachedSessionReader: @escaping () throws -> VectaDeviceSession? = { try NativeLegacySessionReader.read() }) {
        self.resources = resources
        self.servicesDirectory = servicesDirectory
        self.ownershipLease = ownershipLease
        self.defaults = defaults
        self.cachedSessionReader = cachedSessionReader
    }
    /// Compatibility entrypoint. Explicit selection is not predecessor
    /// migration, and must never be redirected into the fixed destination.
    func start(expectedUserID: String? = nil, candidateBases: [URL], selectedBase: URL? = nil) async throws {
        let source: LibrarySource
        if let selectedBase { source = .selectedLibrary(base: selectedBase) }
        else {
            source = .archivedMigration(candidateBases: candidateBases,
                destinationBase: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vecta"))
        }
        try await start(expectedUserID: expectedUserID, librarySource: source)
    }
    func start(expectedUserID: String?, librarySource: LibrarySource) async throws {
        guard state == .stopped else { throw NativeRuntimeError.alreadyStarted }
        state = .starting
        message = nil; aiErrorMessage = nil
        let attempt = UUID(); generation = attempt
        do {
            guard let identity = expectedUserID, !identity.isEmpty else { throw NativeRuntimeError.identityChanged }
            userID = identity
            if ownershipLease == nil { ownership = try RuntimeOwnership(directory: servicesDirectory) }
            let layout: NativeStorageLayout
            let inheritGlobalRoot: Bool
            switch librarySource {
            case .freshDefault(let base):
                layout = try NativeStorageLayout.resolveFreshDefault(userID: identity,
                    servicesDirectory: servicesDirectory, base: base)
                inheritGlobalRoot = false
            case .selectedLibrary(let base):
                layout = try NativeStorageLayout.resolveExisting(userID: identity,
                    servicesDirectory: servicesDirectory, candidateBases: [base], selectedBase: base)
                inheritGlobalRoot = false
            case .archivedMigration(let candidates, let destination):
                inheritGlobalRoot = true
                let previous = try NativeStorageLayout.resolveExisting(userID: identity,
                    servicesDirectory: servicesDirectory, candidateBases: candidates)
                let target = try NativeStorageLayout.resolveFreshDefault(userID: identity,
                    servicesDirectory: servicesDirectory, base: destination)
                let migration = Task.detached(priority: .utility) {
                    try VectaMigration.copyVerified(from: previous.userDirectory, to: target.userDirectory)
                }
                migrationTask = migration
                try await migration.value
                migrationTask = nil
                guard generation == attempt, state == .starting else { throw CancellationError() }
                layout = target
            }
            let access = try NativeRecordingsFolderAccess.openForLibrary(layout: layout, userID: identity,
                                                                         inheritGlobalRoot: inheritGlobalRoot)
            folderAccess = access
            let exporter = VectaLocalAudioExporter(userID: identity, defaults: defaults)
            try exporter.configureFolder(access.root)
            processingRoot = access.root
            library = try NativeLibraryController(userID: identity, layout: layout, exporter: exporter)
            // Open the library independently of network availability. Token
            // renewal happens only when connecting to a modern recorder.
            if let cached = try cachedSessionReader(), cached.userID == identity, cached.canResumeWithoutRefresh { session = cached }
            do {
                let host = try LocalAIHost(root: access.root, resources: resources)
                localAI = host
                host.start()
            } catch {
                // Never retry with default preferences or overwrite malformed
                // bytes. The owner can repair AI separately and reopen later.
                localAI = nil
                aiErrorMessage = VL.text("Компоненты локального ИИ недоступны. Подключение и библиотека продолжают работать; сохранённые настройки ИИ не перезаписаны.")
            }
            state = .ready
        } catch {
            guard generation == attempt else { throw CancellationError() }
            message = error.localizedDescription
            await stop()
            state = .failed
            throw error
        }
    }
    func refreshAuthorization() async throws -> VectaDeviceSession {
        guard state == .ready, let identity = userID else { throw NativeRuntimeError.sessionUnavailable }
        let attempt = generation
        let credentials = try VectaLegacyAuthorization.credentials(services: servicesDirectory, userID: identity)
        let provider = try VectaPartnerAuthorization(credentials: credentials)
        let refreshed = try await provider.authorize(expectedUserID: identity)
        guard generation == attempt, state == .ready else { throw CancellationError() }
        session = refreshed
        return refreshed
    }
    func stop() async {
        generation = UUID()
        state = .stopping
        migrationTask?.cancel()
        if let migrationTask { _ = await migrationTask.result }
        migrationTask = nil
        localAI?.stop()
        for _ in 0..<50 {
            if localAI?.activeRequest == nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard localAI?.activeRequest == nil else { message = NativeRuntimeError.shutdownPending.localizedDescription; return }
        localAI = nil; library = nil; session = nil; userID = nil
        // Only runtime-owned ownership is released. A supplied model lease is
        // retained until this runtime is destroyed, and by the model thereafter.
        folderAccess = nil; processingRoot = nil; ownership = nil; state = .stopped
    }
}
enum NativeRuntimeError: LocalizedError {
    case alreadyStarted, configurationMissing, runtimeMissing, runtimeUnavailable
    case sessionUnavailable, identityChanged, shutdownPending
    var errorDescription: String? {
        switch self {
        case .alreadyStarted: return VL.text("Локальные компоненты уже запущены или обновляются.")
        case .configurationMissing: return VL.text("Существующая конфигурация Vecta не найдена.")
        case .runtimeMissing: return VL.text("В приложении отсутствует локальный компонент авторизации.")
        case .runtimeUnavailable: return VL.text("Не удалось запустить локальный компонент авторизации.")
        case .sessionUnavailable: return VL.text("Не удалось открыть сохранённую авторизацию. Данные аккаунта не изменены.")
        case .identityChanged: return VL.text("Авторизация не совпала с существующим аккаунтом. Библиотека не переключена.")
        case .shutdownPending: return VL.text("Локальный компонент завершает работу. Дождитесь остановки перед повторным запуском.")
        }
    }
}
