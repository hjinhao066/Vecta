import Foundation

// This mirrors the development-only verification switch while keeping the test
// executable independent from migration, app startup, and production defaults.
enum VectaRuntimePreferences {
    static var isVerification: Bool {
        CommandLine.arguments.contains(where: { $0.hasPrefix("--verify-") })
    }
}

@MainActor
private final class FakeLoginService: NativeLoginServiceAdapter {
    private var currentStatus: NativeLoginServiceStatus
    private(set) var statusReads = 0
    var status: NativeLoginServiceStatus {
        get {
            statusReads += 1
            return currentStatus
        }
        set { currentStatus = newValue }
    }
    var registerError: Error?
    var unregisterError: Error?
    var statusAfterRegister: NativeLoginServiceStatus?
    var statusAfterUnregister: NativeLoginServiceStatus?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var openSettingsCalls = 0

    init(status: NativeLoginServiceStatus) {
        self.currentStatus = status
    }

    func register() throws {
        registerCalls += 1
        if let registerError { throw registerError }
        if let statusAfterRegister { status = statusAfterRegister }
    }

    func unregister() throws {
        unregisterCalls += 1
        if let unregisterError { throw unregisterError }
        if let statusAfterUnregister { status = statusAfterUnregister }
    }

    func openLoginSettings() {
        openSettingsCalls += 1
    }
}

private struct FixtureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
@MainActor
struct ApplicationSettingsChecks {
    private static var count = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "ApplicationSettingsChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        count += 1
    }

    private static let suiteNameKey = "Vecta.Verification.ApplicationSettings.suiteName"

    private static func suite(_ name: String = UUID().uuidString) -> UserDefaults {
        let suiteName = "Vecta.Verification.ApplicationSettings." + name
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(suiteName, forKey: suiteNameKey)
        return defaults
    }

    private static func clear(_ defaults: UserDefaults) {
        guard let name = defaults.string(forKey: suiteNameKey) else { return }
        defaults.removePersistentDomain(forName: name)
    }

    private static func constructorAndDefaultActivation() throws {
        let defaults = suite()
        defer { clear(defaults) }
        let service = FakeLoginService(status: .notRegistered)
        service.statusAfterRegister = .enabled
        let settings = NativeApplicationSettings(defaults: defaults, loginService: service)

        try check(settings.backgroundOperationEnabled, "missing background preference defaults to enabled")
        try check(settings.launchAtLoginEnabled, "missing login preference defaults to enabled")
        try check(defaults.object(forKey: "Vecta.backgroundOperationEnabled") as? Bool == true &&
                  defaults.object(forKey: "Vecta.launchAtLoginEnabled") as? Bool == true,
                  "default preferences are persisted in the injected suite")
        try check(service.registerCalls == 0 && service.unregisterCalls == 0 && service.openSettingsCalls == 0,
                  "constructing settings does not invoke the login service")

        settings.activate()
        try check(service.registerCalls == 1 && service.unregisterCalls == 0,
                  "first normal activation registers the default login request once")
        try check(settings.launchAtLoginEnabled && settings.loginStatusMessage == nil,
                  "a successful registration displays the enabled system state")
        try check(defaults.bool(forKey: "Vecta.launchAtLoginInitialized"),
                  "first normal activation records that the default request was attempted")

        settings.activate()
        try check(service.registerCalls == 1,
                  "repeated activation does not register the login item again")
    }

    private static func persistedOffAndSystemDisable() throws {
        let defaults = suite()
        defer { clear(defaults) }
        defaults.set(false, forKey: "Vecta.backgroundOperationEnabled")
        defaults.set(false, forKey: "Vecta.launchAtLoginEnabled")
        let firstService = FakeLoginService(status: .notRegistered)
        let first = NativeApplicationSettings(defaults: defaults, loginService: firstService)

        try check(!first.backgroundOperationEnabled && !first.launchAtLoginEnabled,
                  "an explicit off preference is restored")
        try check(firstService.registerCalls == 0 && firstService.unregisterCalls == 0,
                  "restoring explicit off does not change system login registration")
        first.activate()
        try check(firstService.registerCalls == 0 && firstService.unregisterCalls == 0,
                  "first activation respects persisted login off")
        try check(defaults.bool(forKey: "Vecta.launchAtLoginInitialized"),
                  "activation records an explicit-off launch without registering")

        defaults.set(true, forKey: "Vecta.launchAtLoginEnabled")
        let disabledBySystem = FakeLoginService(status: .notRegistered)
        let laterLaunch = NativeApplicationSettings(defaults: defaults, loginService: disabledBySystem)
        laterLaunch.activate()
        try check(!laterLaunch.launchAtLoginEnabled && laterLaunch.loginStatusMessage == nil,
                  "a later launch displays a login item disabled in macOS")
        try check(disabledBySystem.registerCalls == 0 && disabledBySystem.unregisterCalls == 0,
                  "a system-disabled login item is never silently re-registered")
    }

    private static func explicitChangesAndRefresh() throws {
        let defaults = suite()
        defer { clear(defaults) }
        defaults.set(true, forKey: "Vecta.launchAtLoginInitialized")
        let service = FakeLoginService(status: .notRegistered)
        service.statusAfterRegister = .enabled
        service.statusAfterUnregister = .notRegistered
        let settings = NativeApplicationSettings(defaults: defaults, loginService: service)

        settings.setBackgroundOperationEnabled(false)
        let reopened = NativeApplicationSettings(defaults: defaults, loginService: service)
        try check(!reopened.backgroundOperationEnabled &&
                  defaults.object(forKey: "Vecta.backgroundOperationEnabled") as? Bool == false,
                  "background off persists in the isolated suite")

        settings.setLaunchAtLoginEnabled(true)
        try check(service.registerCalls == 1 && settings.launchAtLoginEnabled &&
                  settings.loginStatusMessage == nil && defaults.bool(forKey: "Vecta.launchAtLoginEnabled"),
                  "explicit login on registers and displays the enabled system state")

        settings.setLaunchAtLoginEnabled(false)
        try check(service.unregisterCalls == 1 && !settings.launchAtLoginEnabled &&
                  settings.loginStatusMessage == nil && !defaults.bool(forKey: "Vecta.launchAtLoginEnabled"),
                  "explicit login off unregisters and displays the unregistered system state")

        service.status = .requiresApproval
        service.statusAfterRegister = .requiresApproval
        settings.setLaunchAtLoginEnabled(true)
        try check(service.registerCalls == 2, "approval request registers once")
        try check(settings.launchAtLoginEnabled, "approval request remains selected")
        try check(settings.loginStatusMessage == VL.text("Разрешите запуск Vecta в разделе «Объекты входа» системных настроек macOS."),
                  "approval request displays the accurate macOS guidance")

        service.status = .unavailable
        settings.refreshLoginStatus()
        try check(!settings.launchAtLoginEnabled &&
                  settings.loginStatusMessage == VL.text("macOS не нашла Vecta для автозапуска. Откройте приложение из папки «Программы» и попробуйте снова."),
                  "macOS notFound state displays accurate recovery guidance")

        settings.openLoginSettings()
        try check(service.openSettingsCalls == 1,
                  "opening Login Items delegates only after an explicit request")
    }

    private static func errorPresentation() throws {
        let defaults = suite()
        defer { clear(defaults) }
        defaults.set(true, forKey: "Vecta.launchAtLoginInitialized")
        let registration = FakeLoginService(status: .notRegistered)
        registration.registerError = FixtureError(message: "registration failed")
        let settings = NativeApplicationSettings(defaults: defaults, loginService: registration)
        settings.setLaunchAtLoginEnabled(true)
        try check(registration.registerCalls == 1 && !settings.launchAtLoginEnabled &&
                  settings.loginStatusMessage == VL.text("Не удалось включить автозапуск Vecta. Проверьте раздел «Объекты входа» системных настроек macOS.") &&
                  defaults.bool(forKey: "Vecta.launchAtLoginEnabled"),
                  "registration failure preserves the request and displays recovery guidance")

        let unregistration = FakeLoginService(status: .enabled)
        unregistration.unregisterError = FixtureError(message: "unregistration failed")
        let failedOff = NativeApplicationSettings(defaults: defaults, loginService: unregistration)
        failedOff.setLaunchAtLoginEnabled(false)
        try check(unregistration.unregisterCalls == 1 && failedOff.launchAtLoginEnabled &&
                  failedOff.loginStatusMessage == VL.text("Не удалось выключить автозапуск Vecta. Проверьте раздел «Объекты входа» системных настроек macOS.") &&
                  !defaults.bool(forKey: "Vecta.launchAtLoginEnabled"),
                  "unregistration failure displays the still-enabled system state and recovery guidance")
    }

    private static func preactivationAndErrorRefresh() throws {
        let defaults = suite()
        defer { clear(defaults) }
        let service = FakeLoginService(status: .notRegistered)
        service.statusAfterRegister = .enabled
        let settings = NativeApplicationSettings(defaults: defaults, loginService: service)
        settings.setLaunchAtLoginEnabled(true)
        settings.activate()
        try check(service.registerCalls == 1, "an explicit preactivation choice is not registered twice")
        service.unregisterError = FixtureError(message: "private diagnostic must not be displayed")
        settings.setLaunchAtLoginEnabled(false)
        let failure = settings.loginStatusMessage
        settings.refreshLoginStatus()
        try check(failure != nil && settings.loginStatusMessage == failure && settings.launchAtLoginEnabled,
                  "failed disable stays actionable after activation refresh")
        try check(!(failure ?? "").contains("private diagnostic"), "system error details are redacted")
        service.status = .notRegistered
        settings.refreshLoginStatus()
        try check(settings.loginStatusMessage == nil && !settings.launchAtLoginEnabled,
                  "a matching system state clears stale operation errors")
    }

    private static func verificationExclusion() throws {
        let defaults = suite()
        defer { clear(defaults) }
        let service = FakeLoginService(status: .notRegistered)
        let settings = NativeApplicationSettings(defaults: defaults, loginService: service)
        settings.activate()
        settings.setBackgroundOperationEnabled(false)
        settings.setLaunchAtLoginEnabled(false)
        settings.setLaunchAtLoginEnabled(true)
        settings.refreshLoginStatus()
        settings.openLoginSettings()

        try check(!settings.backgroundOperationEnabled && settings.launchAtLoginEnabled,
                  "verification changes only the injected preference presentation")
        try check(service.registerCalls == 0 && service.unregisterCalls == 0 && service.openSettingsCalls == 0,
                  "verification never registers, unregisters, reads status, or opens system login settings")
        try check(!defaults.bool(forKey: "Vecta.launchAtLoginInitialized"),
                  "verification activation does not mark the first normal launch complete")
    }

    static func main() {
        do {
            if VectaRuntimePreferences.isVerification {
                try verificationExclusion()
                print("PASS: \(count) isolated application-settings verification exclusion checks")
            } else {
                try constructorAndDefaultActivation()
                try persistedOffAndSystemDisable()
                try explicitChangesAndRefresh()
                try errorPresentation()
                try preactivationAndErrorRefresh()
                print("PASS: \(count) isolated application-settings login/background checks")
            }
        } catch {
            fputs("FAIL after \(count) checks: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
