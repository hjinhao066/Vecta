import Foundation
import CoreLocation
import CoreWLAN
import Darwin

/// One explicit Fast-transfer action, not an automatic network policy.
///
/// Call prepareForFastTransfer() from the foreground UI action BEFORE interrupting BLE.
/// The app must supply NSLocationWhenInUseUsageDescription (and the macOS
/// NSLocationUsageDescription) in its packaged Info.plist. No location updates are started.
/// Then pass only the SSID/password received over authenticated BLE to join(). Keep the
/// returned lease and await restore() on every transfer exit, including cancellation.
/// Preparation is not a promise that metadata/permission cannot change before joining.
///
/// Passwords and network identities stay in memory; this controller never logs them,
/// reads saved passwords, changes preferred-network configuration, or invokes a shell.
/// CoreWLAN may itself remember an association; this is not a credential-storage API.
/// All instances share a serial worker and permit only one outstanding lease at a time.
@MainActor
public final class NativeWiFiNetworkController: NSObject, CLLocationManagerDelegate {
    public struct Lease: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let interfaceName: String
        /// IPv4 observed with getifaddrs on this exact interface after association, for
        /// binding the local transfer listener. This is not proof of DHCP provenance or
        /// recorder reachability; the transport must still bound/authenticate its handshake.
        public let localIPv4: String
        public let didSwitchNetwork: Bool
        fileprivate let owner: UUID
        fileprivate let generation: UInt64
        fileprivate let previous: NativeWiFiLink
        fileprivate let recorder: NativeWiFiIdentity
        public var description: String { "WiFi transfer lease (network identity redacted)" }
        public var debugDescription: String { description }
    }

    public enum LeaveOutcome: Sendable, Equatable {
        case restoredPreviousNetwork
        case disconnectedRecorderNetwork
        case unchanged(UnchangedReason)
        case manualRecoveryRequired(RecoveryReason)

        public enum UnchangedReason: Sendable, Equatable {
            case staleLease, alreadyOnRecorderNetwork, currentNetworkChanged
        }
        public enum RecoveryReason: Sendable, Equatable {
            case interfaceUnavailable, metadataUnavailable, recorderStillConnected, notConnected
        }

        /// Contains no SSID, BSSID, credentials or raw framework error text.
        public var message: String {
            switch self {
            case .restoredPreviousNetwork:
                return "The previous WiFi network was restored."
            case .disconnectedRecorderNetwork:
                return "The recorder WiFi was disconnected. Choose your usual network in macOS WiFi settings if needed."
            case .unchanged(.staleLease):
                return "This transfer is no longer active. No WiFi change was made."
            case .unchanged(.alreadyOnRecorderNetwork):
                return "No WiFi switch was needed for this transfer. WiFi was left untouched."
            case .unchanged(.currentNetworkChanged):
                return "The Mac is not on this transfer's recorder WiFi. Its current network was left untouched."
            case .manualRecoveryRequired(.interfaceUnavailable):
                return "The original WiFi interface is unavailable or off. Check macOS WiFi settings."
            case .manualRecoveryRequired(.metadataUnavailable):
                return "The current WiFi network cannot be identified safely. No disconnect was attempted; check macOS WiFi settings."
            case .manualRecoveryRequired(.recorderStillConnected):
                return "The Mac may still be on the recorder WiFi. Choose your usual network in macOS WiFi settings."
            case .manualRecoveryRequired(.notConnected):
                return "WiFi is not connected. Choose your usual network in macOS WiFi settings."
            }
        }
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public enum Reason: Sendable {
            case invalidSSID, invalidPassword, preparationRequired, busy
            case locationDenied, locationRestricted, locationServicesDisabled
            case locationAuthorizationUnknown, locationUsageDescriptionMissing, permissionTimedOut
            case interfaceUnavailable, metadataUnavailable, networkChanged
            case recorderNotFound, unsupportedSecurity, scanFailed, associationFailed, localAddressUnavailable
            case timedOut, cancelled
        }
        public let reason: Reason
        /// A join that might have changed WiFi waits for cleanup before throwing.
        /// Cancellation of such a join is reported as .cancelled, not CancellationError,
        /// so the caller can show this outcome (including a manual-recovery instruction).
        public let cleanup: LeaveOutcome?
        public var errorDescription: String? {
            let message: String
            switch reason {
            case .invalidSSID: message = "The recorder WiFi name must contain 1–32 UTF-8 bytes."
            case .invalidPassword: message = "The recorder WiFi password is not a valid WPA Personal passphrase or key."
            case .preparationRequired: message = "Prepare Fast transfer from its UI action before pausing Bluetooth."
            case .busy: message = "Another WiFi preparation or transfer is still active."
            case .locationDenied: message = "Allow Location access for this app in macOS Privacy & Security before using Fast transfer."
            case .locationRestricted: message = "Location access is restricted on this Mac. Continue using Bluetooth."
            case .locationServicesDisabled: message = "Enable macOS Location Services before using Fast transfer."
            case .locationAuthorizationUnknown: message = "WiFi metadata authorization is not available. Continue using Bluetooth."
            case .locationUsageDescriptionMissing: message = "This app package is missing its Location permission explanation. Continue using Bluetooth."
            case .permissionTimedOut: message = "Location permission was not resolved. Continue using Bluetooth and try again from the app."
            case .interfaceUnavailable: message = "No usable WiFi interface is available. Continue using Bluetooth."
            case .metadataUnavailable: message = "The current WiFi network cannot be identified safely. Continue using Bluetooth."
            case .networkChanged: message = "WiFi changed while preparing the transfer. Your selected network was left untouched."
            case .recorderNotFound: message = "The recorder WiFi was not found."
            case .unsupportedSecurity: message = "The recorder network security does not match its authenticated Bluetooth response."
            case .scanFailed: message = "The recorder WiFi scan failed."
            case .associationFailed: message = "The recorder WiFi connection could not be confirmed."
            case .localAddressUnavailable: message = "A usable local IPv4 address was not available for the recorder WiFi."
            case .timedOut: message = "The WiFi operation took too long."
            case .cancelled: message = "Fast transfer was cancelled."
            }
            return cleanup.map { message + " " + $0.message } ?? message
        }
    }

    private static let worker = NativeWiFiWorker(hardware: NativeCoreWLANHardware())
    private let owner = UUID()
    private var prepared = false
    private var preparing = false
    private var manager: CLLocationManager?
    private var permissionRequest: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var permissionTimer: Task<Void, Never>?

    public override init() { super.init() }

    /// The ONLY method that can request Location permission. Call only on explicit UI action.
    /// Validates authorization, the real WiFi interface and readable current metadata without
    /// scanning or switching networks. Denied/restricted/unknown metadata fail before BLE handover.
    public func prepareForFastTransfer() async throws {
        guard !preparing else { throw Failure(reason: .busy, cleanup: nil) }
        preparing = true
        prepared = false
        defer { preparing = false }
        try Task.checkCancellation()
        if manager == nil {
            let manager = CLLocationManager()
            self.manager = manager
            manager.delegate = self
        }
        // A disabled global service can make the request a no-op; detect that before
        // waiting for a dialog. Check again afterwards in case the setting changed.
        guard await Self.worker.locationServicesEnabled() else {
            throw Failure(reason: .locationServicesDisabled, cleanup: nil)
        }
        try Task.checkCancellation()
        try await requestPermissionIfNeeded()
        try requireAuthorization()
        guard await Self.worker.locationServicesEnabled() else {
            throw Failure(reason: .locationServicesDisabled, cleanup: nil)
        }
        try Task.checkCancellation()
        try await Self.worker.prepare()
        try Task.checkCancellation()
        try requireAuthorization()
        prepared = true
    }

    /// Never prompts for permission and never stops BLE itself. Only authenticated BLE
    /// credentials belong here. An absent password selects only an open recorder AP;
    /// a supplied password selects only WPA Personal. WEP/enterprise are not accepted.
    public func join(ssid: String, password: String) async throws -> Lease {
        try await join(ssidCandidates: [ssid], password: password)
    }

    public func join(ssidCandidates: [String], password: String) async throws -> Lease {
        guard !ssidCandidates.isEmpty, ssidCandidates.count <= 2,
              Set(ssidCandidates).count == ssidCandidates.count else { throw Failure(reason: .invalidSSID, cleanup: nil) }
        for ssid in ssidCandidates { try nativeWiFiValidateCredentials(ssid: ssid, password: password) }
        guard prepared else { throw Failure(reason: .preparationRequired, cleanup: nil) }
        try requireAuthorization()
        guard await Self.worker.locationServicesEnabled() else {
            throw Failure(reason: .locationServicesDisabled, cleanup: nil)
        }
        let control = NativeWiFiAttemptControl(timeout: 55)
        return try await withTaskCancellationHandler {
            if Task.isCancelled { control.cancel() }
            let lease = try await Self.worker.join(owner: owner, ssidCandidates: ssidCandidates.map { Data($0.utf8) }, password: password, control: control)
            // Cancellation can arrive between the queue's last check and continuation delivery.
            if Task.isCancelled {
                let outcome = await Self.worker.restore(lease, owner: owner)
                throw Failure(reason: .cancelled, cleanup: outcome)
            }
            return lease
        } onCancel: { control.cancel() }
    }

    /// Best effort: directed scan of the previous SSID/BSSID and associate(password: nil).
    /// Remembered secure networks may still require a password; enterprise restoration is
    /// not guaranteed. Never extracts credentials or uses enterprise credential APIs.
    /// If restoration fails, disassociates ONLY the exact recorder SSID+BSSID on the original
    /// interface. User-switched networks, unknown metadata and stale leases are untouched.
    /// Mandatory cleanup deliberately continues even when the calling Task is cancelled.
    public func restore(_ lease: Lease) async -> LeaveOutcome {
        await Self.worker.restore(lease, owner: owner)
    }

    public func leave(_ lease: Lease) async -> LeaveOutcome { await restore(lease) }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.authorizationChanged() }
    }

    private func requireAuthorization() throws {
        guard let manager else { throw Failure(reason: .preparationRequired, cleanup: nil) }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return
        case .denied: throw Failure(reason: .locationDenied, cleanup: nil)
        case .restricted: throw Failure(reason: .locationRestricted, cleanup: nil)
        case .notDetermined: throw Failure(reason: .locationAuthorizationUnknown, cleanup: nil)
        @unknown default: throw Failure(reason: .locationAuthorizationUnknown, cleanup: nil)
        }
    }

    private func requestPermissionIfNeeded() async throws {
        guard let manager, manager.authorizationStatus == .notDetermined else { return }
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(reason: .locationUsageDescriptionMissing, cleanup: nil)
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                permissionRequest = (id, continuation)
                permissionTimer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    self?.finishPermission(id: id, error: Failure(reason: .permissionTimedOut, cleanup: nil))
                }
                manager.requestWhenInUseAuthorization()
                authorizationChanged()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishPermission(id: id, error: CancellationError()) }
        }
    }

    private func authorizationChanged() {
        guard let request = permissionRequest, manager?.authorizationStatus != .notDetermined else { return }
        do {
            try requireAuthorization()
            finishPermission(id: request.id, error: nil)
        } catch { finishPermission(id: request.id, error: error) }
    }

    private func finishPermission(id: UUID, error: Error?) {
        guard let request = permissionRequest, request.id == id else { return }
        permissionRequest = nil
        permissionTimer?.cancel()
        permissionTimer = nil
        if let error { request.continuation.resume(throwing: error) }
        else { request.continuation.resume() }
    }
}

// Internal, synthetic-testable policy. Equality is byte-exact for SSIDs (not Swift String's
// Unicode canonical equivalence); BSSIDs are canonicalized. No identity is logged or Codable.
struct NativeWiFiIdentity: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let interfaceName: String
    let ssid: Data
    let bssid: String
    var description: String { "WiFi identity (redacted)" }
    var debugDescription: String { description }

    init?(interfaceName: String, ssid: Data?, bssid: String?) {
        guard let ssid, (1...32).contains(ssid.count), let bssid else { return nil }
        let parts = bssid.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.utf8.count == 2 && $0.utf8.allSatisfy(nativeWiFiIsHex) }) else { return nil }
        self.interfaceName = interfaceName
        self.ssid = ssid
        self.bssid = bssid.lowercased()
    }
}

enum NativeWiFiLink: Equatable, Sendable {
    case associated(NativeWiFiIdentity), disconnected, unknown, unavailable
}

enum NativeWiFiRestorationDecision: Equatable {
    case staleLease, preserveExistingAssociation, preserveCurrentNetwork
    case interfaceUnavailable, metadataUnavailable, notConnected
    case restorePreviousNetwork, disconnectRecorderNetwork
}

/// Pure policy used before ANY restore/disconnect, and again after blocking scans.
func nativeWiFiRestorationDecision(activeGeneration: UInt64?, leaseGeneration: UInt64,
                                  didSwitch: Bool, previous: NativeWiFiLink,
                                  recorder: NativeWiFiIdentity, current: NativeWiFiLink) -> NativeWiFiRestorationDecision {
    guard activeGeneration == leaseGeneration else { return .staleLease }
    guard didSwitch else { return .preserveExistingAssociation }
    switch current {
    case .unavailable: return .interfaceUnavailable
    case .unknown: return .metadataUnavailable
    case .disconnected:
        // The recorder switches its access point off once it has delivered a file, leaving the Mac
        // on no network at all; nobody else chose that, so rejoining the previous network is still ours.
        if case .associated = previous { return .restorePreviousNetwork }
        return .notConnected
    case .associated(let identity):
        guard identity == recorder else { return .preserveCurrentNetwork }
        if case .associated = previous { return .restorePreviousNetwork }
        return .disconnectRecorderNetwork
    }
}

private func nativeWiFiIsHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
}

func nativeWiFiValidateCredentials(ssid: String, password: String) throws {
    typealias Failure = NativeWiFiNetworkController.Failure
    guard (1...32).contains(ssid.utf8.count) else { throw Failure(reason: .invalidSSID, cleanup: nil) }
    if password.isEmpty { return } // Explicit open-AP mode, not an inference from a missing password echo.
    let bytes = password.utf8
    let passphrase = (8...63).contains(bytes.count) && bytes.allSatisfy { (32...126).contains($0) }
    let rawPSK = bytes.count == 64 && bytes.allSatisfy(nativeWiFiIsHex)
    guard passphrase || rawPSK else { throw Failure(reason: .invalidPassword, cleanup: nil) }
}

// CoreWLAN objects stay on the worker; the protocol is for isolated synthetic tests only.
struct NativeWiFiAccessPoint {
    let identity: NativeWiFiIdentity
    let supportsPersonalSecurity: Bool
    let supportsOpenSecurity: Bool
    let signal: Int
    let network: CWNetwork?
}

protocol NativeWiFiHardware: AnyObject {
    func preferredInterfaceName() throws -> String
    func current(on interfaceName: String) -> NativeWiFiLink
    func localIPv4(on interfaceName: String) -> String?
    func scan(ssidCandidates: [Data], on interfaceName: String) throws -> [NativeWiFiAccessPoint]
    func associate(_ point: NativeWiFiAccessPoint, password: String?, on interfaceName: String) throws
    func disassociate(on interfaceName: String)
}

private final class NativeCoreWLANHardware: NativeWiFiHardware {
    // Lazily created on the serial worker, never in controller init or the UI.
    private lazy var client = CWWiFiClient.shared()

    func preferredInterfaceName() throws -> String {
        if let interface = client.interface(), let name = interface.interfaceName,
           interface.powerOn(), interface.serviceActive() { return name }
        let usable = (client.interfaces() ?? []).filter { $0.powerOn() && $0.serviceActive() }
        guard usable.count == 1, let name = usable.first?.interfaceName else {
            throw NativeWiFiNetworkController.Failure(reason: .interfaceUnavailable, cleanup: nil)
        }
        return name
    }

    private func interface(named name: String) -> CWInterface? {
        guard client.interfaceNames()?.contains(name) == true,
              let interface = client.interface(withName: name),
              interface.interfaceName == name, interface.powerOn(), interface.serviceActive() else { return nil }
        return interface
    }

    func current(on interfaceName: String) -> NativeWiFiLink {
        guard let interface = interface(named: interfaceName) else { return .unavailable }
        let ssid = interface.ssidData()
        let bssid = interface.bssid()
        if let identity = NativeWiFiIdentity(interfaceName: interfaceName, ssid: ssid, bssid: bssid),
           interface.interfaceMode() == .station { return .associated(identity) }
        // Missing/redacted names on an associated interface are NOT "no previous network".
        if ssid == nil, bssid == nil, interface.interfaceMode() == .none { return .disconnected }
        return .unknown
    }

    func localIPv4(on interfaceName: String) -> String? {
        // Local kernel interface metadata only: no connection, route probe or network request.
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let value = entry.pointee
            cursor = value.ifa_next
            guard String(cString: value.ifa_name) == interfaceName,
                  value.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = value.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let result = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard result != "0.0.0.0", !result.hasPrefix("127."), !result.hasPrefix("169.254.") else { continue }
            return result
        }
        return nil
    }

    func scan(ssidCandidates: [Data], on interfaceName: String) throws -> [NativeWiFiAccessPoint] {
        guard let interface = interface(named: interfaceName) else {
            throw NativeWiFiNetworkController.Failure(reason: .interfaceUnavailable, cleanup: nil)
        }
        guard ssidCandidates.count == 1 else { throw NativeWiFiNetworkController.Failure(reason: .invalidSSID, cleanup: nil) }
        let networks: Set<CWNetwork>
        do { networks = try interface.scanForNetworks(withSSID: ssidCandidates[0], includeHidden: true) }
        catch { throw NativeWiFiNetworkController.Failure(reason: .scanFailed, cleanup: nil) }
        var points: [NativeWiFiAccessPoint] = []
        for network in networks {
            // Probe this exact known SSID, including recorder APs omitted by broad scans.
            // Unrelated networks are excluded before their metadata is considered.
            guard let ssid = network.ssidData, ssidCandidates.contains(ssid) else { continue }
            guard let identity = NativeWiFiIdentity(interfaceName: interfaceName, ssid: ssid, bssid: network.bssid) else {
                throw NativeWiFiNetworkController.Failure(reason: .metadataUnavailable, cleanup: nil)
            }
            let personal = [CWSecurity.wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .wpa3Personal, .wpa3Transition]
                .contains { network.supportsSecurity($0) }
            points.append(NativeWiFiAccessPoint(identity: identity, supportsPersonalSecurity: personal,
                                               supportsOpenSecurity: network.supportsSecurity(.none),
                                               signal: network.rssiValue, network: network))
        }
        return points.sorted {
            $0.signal == $1.signal ? $0.identity.bssid < $1.identity.bssid : $0.signal > $1.signal
        }
    }

    func associate(_ point: NativeWiFiAccessPoint, password: String?, on interfaceName: String) throws {
        guard let interface = interface(named: interfaceName), let network = point.network else {
            throw NativeWiFiNetworkController.Failure(reason: .interfaceUnavailable, cleanup: nil)
        }
        do { try interface.associate(to: network, password: password) }
        catch { throw NativeWiFiNetworkController.Failure(reason: .associationFailed, cleanup: nil) }
    }

    func disassociate(on interfaceName: String) { interface(named: interfaceName)?.disassociate() }
}

/// CoreWLAN has no cancellation/timeout API for a blocking scan or association. Bounds here
/// are TWO directed scans per exact naming variant, ONE restore scan, and deadlines checked before and
/// after calls. A late call cannot be killed: we wait for it and run cleanup before resuming.
/// Never release a lease/start another attempt while an older hardware call can still finish.
/// @unchecked Sendable is limited to queue-confined hardware/state, and the locked control.
final class NativeWiFiAttemptControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: UInt64
    init(timeout: TimeInterval) {
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func wait(seconds: TimeInterval) throws {
        let until = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, seconds) * 1_000_000_000)
        while true {
            try check()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < until else { return }
            Thread.sleep(forTimeInterval: min(0.05, Double(until - now) / 1_000_000_000))
        }
    }
    func check() throws {
        lock.lock(); let cancelled = cancelled; lock.unlock()
        if cancelled { throw NativeWiFiNetworkController.Failure(reason: .cancelled, cleanup: nil) }
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            throw NativeWiFiNetworkController.Failure(reason: .timedOut, cleanup: nil)
        }
    }
}

final class NativeWiFiWorker: @unchecked Sendable {
    typealias Controller = NativeWiFiNetworkController
    typealias Failure = Controller.Failure
    typealias Lease = Controller.Lease
    typealias Outcome = Controller.LeaveOutcome
    private let queue = DispatchQueue(label: "app.vecta.explicit-wifi", qos: .userInitiated)
    private let hardware: NativeWiFiHardware
    private let scanRetryDelay: TimeInterval
    private let apReadyDelay: TimeInterval
    private var generation: UInt64 = 0
    private var active: Lease?

    // airportd can return the previous empty scan for ten seconds after it completes.
    // Leave time for AP startup and a fresh directed scan, not another cached result.
    init(hardware: NativeWiFiHardware, scanRetryDelay: TimeInterval = 10.5, apReadyDelay: TimeInterval = 3) {
        self.hardware = hardware; self.scanRetryDelay = max(0, scanRetryDelay)
        self.apReadyDelay = max(0, apReadyDelay)
    }

    func locationServicesEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: CLLocationManager.locationServicesEnabled()) }
        }
    }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.active == nil else { throw Failure(reason: .busy, cleanup: nil) }
                    let name = try self.hardware.preferredInterfaceName()
                    _ = try self.knownCurrent(on: name)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func join(owner: UUID, ssid: Data, password: String, control: NativeWiFiAttemptControl) async throws -> Lease {
        try await join(owner: owner, ssidCandidates: [ssid], password: password, control: control)
    }

    func join(owner: UUID, ssidCandidates: [Data], password: String, control: NativeWiFiAttemptControl) async throws -> Lease {
        guard !ssidCandidates.isEmpty, ssidCandidates.count <= 2,
              Set(ssidCandidates).count == ssidCandidates.count else { throw Failure(reason: .invalidSSID, cleanup: nil) }
        for ssid in ssidCandidates {
            guard let value = String(data: ssid, encoding: .utf8) else { throw Failure(reason: .invalidSSID, cleanup: nil) }
            try nativeWiFiValidateCredentials(ssid: value, password: password)
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                // The captured password exists only for this queued operation, not in the lease.
                continuation.resume(with: Result { try self.performJoin(owner: owner, ssidCandidates: ssidCandidates, password: password, control: control) })
            }
        }
    }

    func restore(_ lease: Lease, owner: UUID) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                guard lease.owner == owner, self.active?.owner == owner,
                      self.active?.generation == lease.generation else {
                    continuation.resume(returning: .unchanged(.staleLease)); return
                }
                let outcome = self.performRestore(lease)
                self.active = nil
                continuation.resume(returning: outcome)
            }
        }
    }

    private func knownCurrent(on name: String) throws -> NativeWiFiLink {
        let current = hardware.current(on: name)
        switch current {
        case .unknown: throw Failure(reason: .metadataUnavailable, cleanup: nil)
        case .unavailable: throw Failure(reason: .interfaceUnavailable, cleanup: nil)
        default: return current
        }
    }

    private func performJoin(owner: UUID, ssidCandidates: [Data], password: String, control: NativeWiFiAttemptControl) throws -> Lease {
        try control.check()
        guard active == nil else { throw Failure(reason: .busy, cleanup: nil) }
        generation += 1
        let name = try hardware.preferredInterfaceName()
        let previous = try knownCurrent(on: name) // Snapshot BEFORE any association.
        try control.check()
        if case .associated(let existing) = previous, ssidCandidates.contains(existing.ssid) {
            let address = try waitForLocalIPv4(on: name, recorder: existing, control: control)
            let lease = Lease(interfaceName: name, localIPv4: address, didSwitchNetwork: false, owner: owner,
                              generation: generation, previous: previous, recorder: existing)
            active = lease
            return lease
        }
        // An AP-open acknowledgement precedes radio readiness; the official sample
        // waits three seconds. Only this worker waits, with cancellation/deadline checks.
        try control.wait(seconds: apReadyDelay)
        var selected: NativeWiFiAccessPoint?
        let scanPlan = ssidCandidates + ssidCandidates
        for (attempt, candidate) in scanPlan.enumerated() {
            try control.check()
            if attempt > 0 { try control.wait(seconds: scanRetryDelay) }
            guard try knownCurrent(on: name) == previous else { throw Failure(reason: .networkChanged, cleanup: nil) }
            let points: [NativeWiFiAccessPoint]
            do { points = try hardware.scan(ssidCandidates: [candidate], on: name) }
            catch {
                try control.check() // Cancellation/deadline wins over a late scan error.
                throw (error as? Failure) ?? Failure(reason: .scanFailed, cleanup: nil)
            }
            try control.check()
            // Defend the protocol boundary as well as the production backend's filter.
            let matches = points.filter { $0.identity.interfaceName == name && ssidCandidates.contains($0.identity.ssid) }
            selected = matches.first { password.isEmpty ? $0.supportsOpenSecurity : $0.supportsPersonalSecurity }
            if selected != nil { break }
            if !matches.isEmpty { throw Failure(reason: .unsupportedSecurity, cleanup: nil) }
        }
        guard let selected else { throw Failure(reason: .recorderNotFound, cleanup: nil) }
        guard try knownCurrent(on: name) == previous else { throw Failure(reason: .networkChanged, cleanup: nil) }
        try control.check()
        // Provisional internal lease reserves cleanup ownership before association. Its empty
        // address is never returned; only the verified, address-ready lease below is public.
        let lease = Lease(interfaceName: name, localIPv4: "", didSwitchNetwork: true, owner: owner,
                          generation: generation, previous: previous, recorder: selected.identity)
        active = lease // Reserve before a blocking call that can succeed late or throw after switching.
        do {
            try hardware.associate(selected, password: password.isEmpty ? nil : password, on: name)
            try control.check()
            guard try knownCurrent(on: name) == .associated(selected.identity) else {
                throw Failure(reason: .associationFailed, cleanup: nil)
            }
            let address = try waitForLocalIPv4(on: name, recorder: selected.identity, control: control)
            let ready = Lease(interfaceName: name, localIPv4: address, didSwitchNetwork: true, owner: owner,
                              generation: generation, previous: previous, recorder: selected.identity)
            active = ready
            return ready
        } catch {
            let outcome = performRestore(lease)
            active = nil
            let reason = (error as? Failure)?.reason ?? .associationFailed
            // Prefer cancellation/deadline even if CoreWLAN threw its own late error.
            do { try control.check() }
            catch let controlError as Failure { throw Failure(reason: controlError.reason, cleanup: outcome) }
            catch { /* No other errors are produced by the control. */ }
            throw Failure(reason: reason, cleanup: outcome)
        }
    }

    private func waitForLocalIPv4(on name: String, recorder: NativeWiFiIdentity, control: NativeWiFiAttemptControl) throws -> String {
        // DHCP is asynchronous after association. Observe local addresses for at most 10s;
        // no traffic is generated. Sleep only this dedicated worker, checking cancellation
        // and exact association throughout. A user selection aborts rather than being replaced.
        for _ in 0..<40 {
            try control.check()
            guard try knownCurrent(on: name) == .associated(recorder) else {
                throw Failure(reason: .networkChanged, cleanup: nil)
            }
            if let address = hardware.localIPv4(on: name) {
                try control.check()
                guard try knownCurrent(on: name) == .associated(recorder) else {
                    throw Failure(reason: .networkChanged, cleanup: nil)
                }
                return address
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        try control.check()
        throw Failure(reason: .localAddressUnavailable, cleanup: nil)
    }

    private func decision(for lease: Lease) -> NativeWiFiRestorationDecision {
        nativeWiFiRestorationDecision(activeGeneration: active?.generation, leaseGeneration: lease.generation,
                                     didSwitch: lease.didSwitchNetwork, previous: lease.previous,
                                     recorder: lease.recorder, current: hardware.current(on: lease.interfaceName))
    }

    private func outcome(for decision: NativeWiFiRestorationDecision) -> Outcome? {
        switch decision {
        case .staleLease: return .unchanged(.staleLease)
        case .preserveExistingAssociation: return .unchanged(.alreadyOnRecorderNetwork)
        case .preserveCurrentNetwork: return .unchanged(.currentNetworkChanged)
        case .interfaceUnavailable: return .manualRecoveryRequired(.interfaceUnavailable)
        case .metadataUnavailable: return .manualRecoveryRequired(.metadataUnavailable)
        case .notConnected: return .manualRecoveryRequired(.notConnected)
        case .restorePreviousNetwork, .disconnectRecorderNetwork: return nil
        }
    }

    private func performRestore(_ lease: Lease) -> Outcome {
        if let outcome = outcome(for: decision(for: lease)) { return outcome }
        let control = NativeWiFiAttemptControl(timeout: 15)
        if case .associated(let previous) = lease.previous {
            do {
                try control.check()
                let points = try hardware.scan(ssidCandidates: [previous.ssid], on: lease.interfaceName)
                try control.check()
                // A scan can take seconds; do not override a user's intervening selection.
                if let outcome = outcome(for: decision(for: lease)) { return outcome }
                if let point = points.first(where: { $0.identity == previous }) {
                    try hardware.associate(point, password: nil, on: lease.interfaceName)
                    // Even a late/throwing restore may have succeeded: verify actual metadata below.
                }
            } catch { /* Best effort only. Never surface raw errors, which may contain identities. */ }
            if hardware.current(on: lease.interfaceName) == .associated(previous) { return .restoredPreviousNetwork }
        }
        // Re-evaluate after both scan and association, even when either failed or finished late.
        if let outcome = outcome(for: decision(for: lease)) { return outcome }
        if hardware.current(on: lease.interfaceName) == .disconnected { return .manualRecoveryRequired(.notConnected) }
        // The pure predicate authorizes this ONLY for our exact recorder association. Re-read
        // immediately before disassociation; CoreWLAN has no atomic compare-and-disassociate API.
        guard hardware.current(on: lease.interfaceName) == .associated(lease.recorder),
              active?.generation == lease.generation else {
            return outcome(for: decision(for: lease)) ?? .manualRecoveryRequired(.metadataUnavailable)
        }
        hardware.disassociate(on: lease.interfaceName)
        switch hardware.current(on: lease.interfaceName) {
        case .disconnected: return .disconnectedRecorderNetwork
        case .associated(let current) where current == lease.recorder: return .manualRecoveryRequired(.recorderStillConnected)
        case .associated: return .unchanged(.currentNetworkChanged)
        case .unknown: return .manualRecoveryRequired(.metadataUnavailable)
        case .unavailable: return .manualRecoveryRequired(.interfaceUnavailable)
        }
    }
}
