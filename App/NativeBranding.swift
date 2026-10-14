import Foundation

/// Brand migration retains account identity, preferences and existing files.
enum NativeBranding {
    static func automaticSummary(defaults: UserDefaults = .standard) -> Bool {
        let key = "Vecta.autoSummaryAfterSync"
        VectaLegacyPaths.migrateAutomaticSummary(defaults)
        return defaults.object(forKey: key) as? Bool ?? true
    }
    static func standaloneRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/VectaNative")
    }
}

enum VectaRuntimePreferences {
    static var isVerification: Bool {
        #if VECTA_DEVELOPMENT
        return CommandLine.arguments.contains(where: { $0.hasPrefix("--verify-") })
        #else
        return false
        #endif
    }
    static var synchronization: UserDefaults {
        #if VECTA_DEVELOPMENT
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--verify-") }) { return UserDefaults(suiteName: "Vecta.Verification")! }
        #endif
        try? VectaMigration.migratePreferences(defaults: .standard)
        return .standard
    }
}
