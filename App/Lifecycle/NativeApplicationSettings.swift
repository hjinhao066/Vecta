import Combine
import Foundation
import ServiceManagement

@MainActor
enum NativeLoginServiceStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case unavailable
}

@MainActor
protocol NativeLoginServiceAdapter: AnyObject {
    var status: NativeLoginServiceStatus { get }
    func register() throws
    func unregister() throws
    func openLoginSettings()
}

@MainActor
final class NativeApplicationSettings: ObservableObject {
    @Published private(set) var backgroundOperationEnabled: Bool
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var loginStatusMessage: String?

    private enum Key {
        static let backgroundOperationEnabled = "Vecta.backgroundOperationEnabled"
        static let launchAtLoginEnabled = "Vecta.launchAtLoginEnabled"
        static let launchAtLoginInitialized = "Vecta.launchAtLoginInitialized"
    }

    private let defaults: UserDefaults
    private let loginService: any NativeLoginServiceAdapter
    private var requestedLaunchAtLogin: Bool
    private var loginOperationError: String?

    init(defaults: UserDefaults = VL.preferences,
         loginService: (any NativeLoginServiceAdapter)? = nil) {
        self.defaults = defaults
        self.loginService = loginService ?? NativeMainAppLoginService()

        let backgroundOperationEnabled = defaults.object(forKey: Key.backgroundOperationEnabled) as? Bool ?? true
        let requestedLaunchAtLogin = defaults.object(forKey: Key.launchAtLoginEnabled) as? Bool ?? true
        self.backgroundOperationEnabled = backgroundOperationEnabled
        self.requestedLaunchAtLogin = requestedLaunchAtLogin
        launchAtLoginEnabled = requestedLaunchAtLogin
        loginStatusMessage = nil

        if defaults.object(forKey: Key.backgroundOperationEnabled) == nil {
            defaults.set(backgroundOperationEnabled, forKey: Key.backgroundOperationEnabled)
        }
        if defaults.object(forKey: Key.launchAtLoginEnabled) == nil {
            defaults.set(requestedLaunchAtLogin, forKey: Key.launchAtLoginEnabled)
        }
    }

    /// Activates the default request once on a normal launch. Later launches only
    /// observe the state selected in macOS Settings.
    func activate() {
        guard !VectaRuntimePreferences.isVerification else { return }
        guard defaults.bool(forKey: Key.launchAtLoginInitialized) else {
            defaults.set(true, forKey: Key.launchAtLoginInitialized)
            guard requestedLaunchAtLogin else {
                refreshLoginStatus()
                return
            }
            registerLoginItem()
            return
        }
        refreshLoginStatus()
    }

    func setBackgroundOperationEnabled(_ enabled: Bool) {
        backgroundOperationEnabled = enabled
        defaults.set(enabled, forKey: Key.backgroundOperationEnabled)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        requestedLaunchAtLogin = enabled
        defaults.set(enabled, forKey: Key.launchAtLoginEnabled)
        guard !VectaRuntimePreferences.isVerification else {
            launchAtLoginEnabled = enabled
            loginStatusMessage = nil
            return
        }
        defaults.set(true, forKey: Key.launchAtLoginInitialized)
        if enabled {
            registerLoginItem()
        } else {
            unregisterLoginItem()
        }
    }

    func refreshLoginStatus() {
        guard !VectaRuntimePreferences.isVerification else { return }
        let status = loginService.status
        switch status {
        case .enabled:
            launchAtLoginEnabled = true
            loginStatusMessage = nil
        case .notRegistered:
            launchAtLoginEnabled = false
            loginStatusMessage = nil
        case .requiresApproval:
            launchAtLoginEnabled = true
            loginStatusMessage = VL.text("Разрешите запуск Vecta в разделе «Объекты входа» системных настроек macOS.")
        case .unavailable:
            launchAtLoginEnabled = false
            loginStatusMessage = VL.text("macOS не нашла Vecta для автозапуска. Откройте приложение из папки «Программы» и попробуйте снова.")
        }
        if (requestedLaunchAtLogin && status == .enabled) || (!requestedLaunchAtLogin && status == .notRegistered) {
            loginOperationError = nil
        }
        if let loginOperationError { loginStatusMessage = loginOperationError }
    }

    func openLoginSettings() {
        guard !VectaRuntimePreferences.isVerification else { return }
        loginService.openLoginSettings()
    }

    private func registerLoginItem() {
        do {
            try loginService.register()
            loginOperationError = nil
            refreshLoginStatus()
        } catch {
            loginOperationError = VL.text("Не удалось включить автозапуск Vecta. Проверьте раздел «Объекты входа» системных настроек macOS.")
            refreshLoginStatus()
        }
    }

    private func unregisterLoginItem() {
        do {
            try loginService.unregister()
            loginOperationError = nil
            refreshLoginStatus()
        } catch {
            loginOperationError = VL.text("Не удалось выключить автозапуск Vecta. Проверьте раздел «Объекты входа» системных настроек macOS.")
            refreshLoginStatus()
        }
    }
}

@MainActor
private final class NativeMainAppLoginService: NativeLoginServiceAdapter {
    var status: NativeLoginServiceStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
