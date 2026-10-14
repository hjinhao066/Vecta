import Foundation

enum NativeSyncInterval: Int, CaseIterable, Identifiable {
    case continuous = -1
    case off = 0
    case thirtyMinutes = 1800
    case twoHours = 7200

    var attemptSeconds:TimeInterval {self == .continuous ? 30:TimeInterval(rawValue)}
    var keepsConnection:Bool {self == .continuous}
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .continuous: return VL.text("Постоянно")
        case .off: return VL.text("Выкл")
        case .thirtyMinutes: return VL.text("Раз в 30 минут")
        case .twoHours: return VL.text("Раз в 2 часа")
        }
    }
}

/// A persisted deadline, independent of Bluetooth. Only the app's lifecycle
/// invokes a due attempt. Missed periods coalesce; failure never retries early.
final class NativeSyncSchedule {
    private let defaults: UserDefaults
    private let intervalKey = "Vecta.nativeAutoSync.interval"
    private let deadlineKey = "Vecta.nativeAutoSync.nextAttempt"
    private(set) var interval: NativeSyncInterval
    private(set) var nextAttempt: Date?

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        VectaLegacyPaths.migrateSyncPreferences(defaults)
        if defaults.object(forKey: intervalKey) == nil {
            // Preserve automatic reconnection for existing native users.
            interval = .thirtyMinutes
        } else {
            interval = NativeSyncInterval(rawValue: defaults.integer(forKey: intervalKey)) ?? .off
        }
        nextAttempt = interval == .off ? nil : (defaults.object(forKey: deadlineKey) as? Date ?? now)
    }

    func select(_ value: NativeSyncInterval, now: Date = Date()) {
        interval = value
        defaults.set(value.rawValue, forKey: intervalKey)
        nextAttempt = value == .off ? nil : (value == .continuous ? now:now.addingTimeInterval(value.attemptSeconds))
        persistDeadline()
    }

    /// Returns true once for an eligible due attempt, and persists the next
    /// deadline before I/O. A crash or authorization failure cannot hot-loop.
    func takeDueAttempt(now: Date = Date(), eligible: Bool) -> Bool {
        guard interval != .off, eligible, let deadline = nextAttempt, now >= deadline else { return false }
        recordAttempt(now: now)
        return true
    }

    func recordAttempt(now: Date = Date()) {
        guard interval != .off else { return }
        nextAttempt = now.addingTimeInterval(interval.attemptSeconds)
        persistDeadline()
    }

    private func persistDeadline() {
        if let nextAttempt { defaults.set(nextAttempt, forKey: deadlineKey) }
        else { defaults.removeObject(forKey: deadlineKey) }
    }
}
