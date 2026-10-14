import Foundation

/// Isolated startup-boundary substitute: no timers, inference workers, models,
/// downloads, Keychain reads or networking. Production library/exporter/stores
/// and the production AI-preference decoders remain in the executable.
/// This verifies NativeAppRuntime's failure handling, not full LocalAIHost E2E.
@MainActor final class LocalAIHost {
    private(set) var activeRequest: UUID?
    private(set) var started = false
    init(root: URL, resources: URL) throws {
        let store = LocalAIFileStore(root: root)
        _ = try store.summaryModel()
        _ = try store.automaticAISettings()
    }
    func start() { started = true }
    func stop() { started = false }
}
