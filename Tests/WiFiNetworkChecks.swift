import Foundation

// Isolated executable: compile with App/NativeWiFiNetwork.swift and App/NativeWiFiSocketServer.swift. This never constructs
// a controller, invokes CoreWLAN hardware, requests Location permission or touches real WiFi.
@main
struct WiFiNetworkChecks {
    typealias Controller = NativeWiFiNetworkController
    typealias Failure = Controller.Failure
    private static let owner = UUID()
    private static let password = "synthetic-only-key"
    private static let home = identity("synthetic-home", "02:00:00:00:00:01")
    private static let recorder = identity("synthetic-recorder", "02:00:00:00:00:02")
    private static let userNetwork = identity("synthetic-user", "02:00:00:00:00:03")

    private static func identity(_ ssid: String, _ bssid: String, interface: String = "en9") -> NativeWiFiIdentity {
        NativeWiFiIdentity(interfaceName: interface, ssid: Data(ssid.utf8), bssid: bssid)!
    }

    private static func point(_ identity: NativeWiFiIdentity, personal: Bool = true, open: Bool = false) -> NativeWiFiAccessPoint {
        NativeWiFiAccessPoint(identity: identity, supportsPersonalSecurity: personal, supportsOpenSecurity: open, signal: -40, network: nil)
    }

    private static func fixture(previous: NativeWiFiLink = .associated(home)) -> (SyntheticWiFi, NativeWiFiWorker) {
        let hardware = SyntheticWiFi(link: previous, points: [point(recorder), point(home)])
        return (hardware, NativeWiFiWorker(hardware: hardware, scanRetryDelay: 0.1, apReadyDelay: 0))
    }

    private static func join(_ worker: NativeWiFiWorker, control: NativeWiFiAttemptControl = NativeWiFiAttemptControl(timeout: 10)) async throws -> Controller.Lease {
        try await worker.join(owner: owner, ssid: recorder.ssid, password: password, control: control)
    }

    private static func expectFailure(_ reason: Failure.Reason, _ operation: () async throws -> Void) async throws -> Failure {
        do { try await operation() }
        catch let error as Failure {
            wifiCheck(error.reason == reason, "Wrong safe failure reason")
            return error
        }
        fatalError("Expected a safe WiFi failure")
    }

    static func main() async throws {
        purePolicyChecks()
        credentialChecks()
        listenerBindingChecks()
        try await lifecycleChecks()
        try await openAccessPointChecks()
        try await networkNameVariantChecks()
        try await restorationChecks()
        try await failureChecks()
        try await lateCancellationChecks()
        try await scanRetryChecks()
        print("WiFiNetworkChecks passed: pure policy, credentials, synthetic lifecycle, restoration, late cancellation, fresh-scan retry and deadlines. No real WiFi or permission requests.")
    }

    private static func purePolicyChecks() {
        func decision(active: UInt64? = 7, switched: Bool = true, previous: NativeWiFiLink = .associated(home), current: NativeWiFiLink = .associated(recorder)) -> NativeWiFiRestorationDecision {
            nativeWiFiRestorationDecision(activeGeneration: active, leaseGeneration: 7, didSwitch: switched,
                                          previous: previous, recorder: recorder, current: current)
        }
        wifiCheck(decision() == .restorePreviousNetwork)
        wifiCheck(decision(previous: .disconnected) == .disconnectRecorderNetwork)
        wifiCheck(decision(active: nil) == .staleLease)
        wifiCheck(decision(active: 8) == .staleLease)
        wifiCheck(decision(switched: false) == .preserveExistingAssociation)
        wifiCheck(decision(switched: false, current: .disconnected) == .preserveExistingAssociation)
        wifiCheck(decision(current: .associated(userNetwork)) == .preserveCurrentNetwork)
        wifiCheck(decision(current: .associated(home)) == .preserveCurrentNetwork)
        wifiCheck(decision(current: .associated(identity("synthetic-recorder", "02:00:00:00:00:04"))) == .preserveCurrentNetwork)
        wifiCheck(decision(current: .associated(identity("synthetic-recorder", recorder.bssid, interface: "en8"))) == .preserveCurrentNetwork)
        wifiCheck(decision(current: .unknown) == .metadataUnavailable)
        wifiCheck(decision(current: .unavailable) == .interfaceUnavailable)
        wifiCheck(decision(current: .disconnected) == .restorePreviousNetwork)
        wifiCheck(decision(previous: .disconnected, current: .disconnected) == .notConnected)
        wifiCheck(identity("synthetic-home", "AB:CD:EF:00:00:01") == identity("synthetic-home", "ab:cd:ef:00:00:01"))
        wifiCheck(identity("\u{00e9}", home.bssid) != identity("e\u{0301}", home.bssid))
        wifiCheck(NativeWiFiIdentity(interfaceName: "en9", ssid: nil, bssid: home.bssid) == nil)
        wifiCheck(NativeWiFiIdentity(interfaceName: "en9", ssid: recorder.ssid, bssid: nil) == nil)
        wifiCheck(NativeWiFiIdentity(interfaceName: "en9", ssid: recorder.ssid, bssid: "not-a-bssid") == nil)
        wifiCheck(NativeWiFiIdentity(interfaceName: "en9", ssid: Data(), bssid: home.bssid) == nil)
        wifiCheck(String(describing: recorder) == "WiFi identity (redacted)")
        wifiCheck(!String(reflecting: recorder).contains("synthetic-recorder"))
    }

    private static func listenerBindingChecks() {
        let offline = NativeWiFiListenerAddress(interfaceName: "en9", address: "192.0.2.10", isUp: true)
        func accepts(_ address: String = "192.0.2.10", _ name: String = "en9", _ entries: [NativeWiFiListenerAddress] = [offline]) -> Bool {
            nativeWiFiListenerCanBind(address: address, interfaceName: name, localAddresses: entries)
        }
        wifiCheck(accepts()) // No Internet/path availability is required for a local AP.
        wifiCheck(!accepts("192.0.2.11"))
        wifiCheck(!accepts("192.0.2.10", "en8"))
        wifiCheck(!accepts("192.0.2.10", ""))
        wifiCheck(!accepts("192.0.2.10", "en9", []))
        wifiCheck(!accepts("192.0.2.10", "en9", [.init(interfaceName: "en9", address: "192.0.2.10", isUp: false)]))
        wifiCheck(!accepts("192.0.2.10", "en9", [offline, .init(interfaceName: "en8", address: "192.0.2.10", isUp: true)]))
        for invalid in ["bad", "0.0.0.0", "0.1.2.3", "127.0.0.1", "169.254.1.2", "224.0.0.1", "255.255.255.255", "::1"] {
            wifiCheck(!accepts(invalid, "en9", [.init(interfaceName: "en9", address: invalid, isUp: true)]))
        }
    }

    private static func credentialChecks() {
        func accepted(_ ssid: String, _ password: String) -> Bool {
            do { try nativeWiFiValidateCredentials(ssid: ssid, password: password); return true }
            catch { return false }
        }
        wifiCheck(accepted("x", "12345678"))
        wifiCheck(accepted(String(repeating: "a", count: 32), String(repeating: "p", count: 63)))
        wifiCheck(accepted(String(repeating: "é", count: 16), "12345678"))
        wifiCheck(accepted("x", String(repeating: "aF", count: 32)))
        wifiCheck(!accepted("", "12345678"))
        wifiCheck(!accepted(String(repeating: "a", count: 33), "12345678"))
        wifiCheck(!accepted(String(repeating: "é", count: 17), "12345678"))
        wifiCheck(accepted("x", ""))
        wifiCheck(!accepted("x", "1234567"))
        wifiCheck(!accepted("x", String(repeating: "z", count: 64)))
        wifiCheck(!accepted("x", String(repeating: "a", count: 65)))
        wifiCheck(!accepted("x", "1234567\n"))
        wifiCheck(!accepted("x", "1234567é"))
    }

    private static func lifecycleChecks() async throws {
        let (hardware, worker) = fixture()
        try await worker.prepare()
        wifiCheck(hardware.scans.isEmpty && hardware.associations.isEmpty)
        let first = try await join(worker)
        wifiCheck(first.interfaceName == "en9" && first.localIPv4 == "192.0.2.10" && first.didSwitchNetwork)
        wifiCheck(!String(reflecting: first).contains("synthetic"))
        wifiCheck(hardware.scans == [recorder.ssid])
        wifiCheck(hardware.associations == [true])
        _ = try await expectFailure(.busy) { _ = try await join(worker) }
        wifiCheck(await worker.restore(first, owner: UUID()) == .unchanged(.staleLease))
        wifiCheck(hardware.link == .associated(recorder))
        wifiCheck(await worker.restore(first, owner: owner) == .restoredPreviousNetwork)
        wifiCheck(hardware.associations == [true, false]) // Restore never supplies a password.
        wifiCheck(hardware.link == .associated(home))
        let second = try await join(worker)
        let mutations = hardware.associations.count
        wifiCheck(await worker.restore(first, owner: owner) == .unchanged(.staleLease))
        wifiCheck(hardware.associations.count == mutations && hardware.disconnects == 0)
        wifiCheck(hardware.link == .associated(recorder))
        wifiCheck(await worker.restore(second, owner: owner) == .restoredPreviousNetwork)
        wifiCheck(await worker.restore(second, owner: owner) == .unchanged(.staleLease))

        let (same, sameWorker) = fixture(previous: .associated(recorder))
        let unchanged = try await join(sameWorker)
        wifiCheck(!unchanged.didSwitchNetwork && same.scans.isEmpty && same.associations.isEmpty)
        wifiCheck(await sameWorker.restore(unchanged, owner: owner) == .unchanged(.alreadyOnRecorderNetwork))
        wifiCheck(same.disconnects == 0)

        let (empty, emptyWorker) = fixture(previous: .disconnected)
        let noPrevious = try await join(emptyWorker)
        wifiCheck(await emptyWorker.restore(noPrevious, owner: owner) == .disconnectedRecorderNetwork)
        wifiCheck(empty.disconnects == 1 && empty.link == .disconnected)
        wifiCheck(empty.scans == [recorder.ssid])

        let (_, cancelledRestoreWorker) = fixture()
        let cancelledLease = try await join(cancelledRestoreWorker)
        let restoreTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cancelledRestoreWorker.restore(cancelledLease, owner: owner)
        }
        wifiCheck(await restoreTask.value == .restoredPreviousNetwork)
    }

    private static func openAccessPointChecks() async throws {
        let (hardware, worker) = fixture()
        hardware.points = [point(recorder, personal: false, open: true), point(home)]
        let lease = try await worker.join(owner: owner, ssid: recorder.ssid, password: "", control: NativeWiFiAttemptControl(timeout: 10))
        wifiCheck(hardware.associations == [false] && hardware.link == .associated(recorder))
        wifiCheck(lease.localIPv4 == "192.0.2.10")
        wifiCheck(await worker.restore(lease, owner: owner) == .restoredPreviousNetwork)
        wifiCheck(hardware.link == .associated(home))

        let (secured, securedWorker) = fixture()
        _ = try await expectFailure(.unsupportedSecurity) {
            _ = try await securedWorker.join(owner: owner, ssid: recorder.ssid, password: "", control: NativeWiFiAttemptControl(timeout: 10))
        }
        wifiCheck(secured.associations.isEmpty && secured.disconnects == 0)
        let (open, openWorker) = fixture()
        open.points = [point(recorder, personal: false, open: true)]
        _ = try await expectFailure(.unsupportedSecurity) { _ = try await join(openWorker) }
        wifiCheck(open.associations.isEmpty && open.disconnects == 0)

        let (changed, changedWorker) = fixture()
        changed.points = [point(recorder, personal: false, open: true), point(home)]
        let changedLease = try await changedWorker.join(owner: owner, ssid: recorder.ssid, password: "", control: NativeWiFiAttemptControl(timeout: 10))
        changed.link = .associated(userNetwork)
        wifiCheck(await changedWorker.restore(changedLease, owner: owner) == .unchanged(.currentNetworkChanged))
        wifiCheck(changed.associations == [false] && changed.disconnects == 0)
    }

    private static func networkNameVariantChecks() async throws {
        let names = [Data("PlaudTEST".utf8), Data("PLAUDTEST".utf8)]
        for name in names {
            let target = NativeWiFiIdentity(interfaceName: "en9", ssid: name, bssid: recorder.bssid)!
            let hardware = SyntheticWiFi(link: .associated(home), points: [point(target), point(home)])
            let worker = NativeWiFiWorker(hardware: hardware, scanRetryDelay: 0.1, apReadyDelay: 0)
            let lease = try await worker.join(owner: owner, ssidCandidates: names, password: password, control: NativeWiFiAttemptControl(timeout: 10))
            wifiCheck(hardware.link == .associated(target) && hardware.associations == [true])
            wifiCheck(hardware.scans == (name == names[0] ? [names[0]] : names))
            wifiCheck(await worker.restore(lease, owner: owner) == .restoredPreviousNetwork)

            let existing = SyntheticWiFi(link: .associated(target), points: [])
            let existingWorker = NativeWiFiWorker(hardware: existing, scanRetryDelay: 0.1, apReadyDelay: 0)
            let unchanged = try await existingWorker.join(owner: owner, ssidCandidates: names, password: password, control: NativeWiFiAttemptControl(timeout: 10))
            wifiCheck(!unchanged.didSwitchNetwork && existing.scans.isEmpty)
            wifiCheck(await existingWorker.restore(unchanged, owner: owner) == .unchanged(.alreadyOnRecorderNetwork))
        }
        let unrelated = identity("PlaudOTHER", "02:00:00:00:00:05")
        let hardware = SyntheticWiFi(link: .associated(home), points: [point(unrelated), point(home)])
        let worker = NativeWiFiWorker(hardware: hardware, scanRetryDelay: 0.1, apReadyDelay: 0)
        _ = try await expectFailure(.recorderNotFound) {
            _ = try await worker.join(owner: owner, ssidCandidates: names, password: password, control: NativeWiFiAttemptControl(timeout: 10))
        }
        wifiCheck(hardware.associations.isEmpty && hardware.link == .associated(home))
        for invalid in [[Data](), [names[0], names[0]], names + [Data("third".utf8)]] {
            _ = try await expectFailure(.invalidSSID) {
                _ = try await worker.join(owner: owner, ssidCandidates: invalid, password: password, control: NativeWiFiAttemptControl(timeout: 10))
            }
        }
    }

    private static func restorationChecks() async throws {
        // A remembered secure/enterprise network is not assumed to restore with nil password.
        let (failed, failedWorker) = fixture()
        let failedLease = try await join(failedWorker)
        failed.onAssociate = { _, hasPassword in if !hasPassword { throw SyntheticFault.failed } }
        wifiCheck(await failedWorker.restore(failedLease, owner: owner) == .disconnectedRecorderNetwork)
        wifiCheck(failed.associations == [true, false] && failed.disconnects == 1)

        let (missing, missingWorker) = fixture()
        let missingLease = try await join(missingWorker)
        missing.points = [point(recorder)]
        wifiCheck(await missingWorker.restore(missingLease, owner: owner) == .disconnectedRecorderNetwork)
        wifiCheck(missing.associations == [true])

        let (changed, changedWorker) = fixture()
        let changedLease = try await join(changedWorker)
        changed.link = .associated(userNetwork)
        wifiCheck(await changedWorker.restore(changedLease, owner: owner) == .unchanged(.currentNetworkChanged))
        wifiCheck(changed.scans.count == 1 && changed.associations.count == 1 && changed.disconnects == 0)

        let (duringScan, duringScanWorker) = fixture()
        let duringScanLease = try await join(duringScanWorker)
        duringScan.onScan = { _ in duringScan.link = .associated(userNetwork) }
        wifiCheck(await duringScanWorker.restore(duringScanLease, owner: owner) == .unchanged(.currentNetworkChanged))
        wifiCheck(duringScan.associations.count == 1 && duringScan.disconnects == 0)

        let (duringAssociate, duringAssociateWorker) = fixture()
        let duringAssociateLease = try await join(duringAssociateWorker)
        duringAssociate.onAssociate = { _, hasPassword in
            if !hasPassword { duringAssociate.link = .associated(userNetwork); throw SyntheticFault.failed }
        }
        wifiCheck(await duringAssociateWorker.restore(duringAssociateLease, owner: owner) == .unchanged(.currentNetworkChanged))
        wifiCheck(duringAssociate.disconnects == 0)

        for current in [NativeWiFiLink.unknown, .unavailable,
                        .associated(identity("synthetic-recorder", "02:00:00:00:00:04"))] {
            let (hardware, worker) = fixture()
            let lease = try await join(worker)
            hardware.link = current
            let outcome = await worker.restore(lease, owner: owner)
            switch current {
            case .unknown: wifiCheck(outcome == .manualRecoveryRequired(.metadataUnavailable))
            case .unavailable: wifiCheck(outcome == .manualRecoveryRequired(.interfaceUnavailable))
            default: wifiCheck(outcome == .unchanged(.currentNetworkChanged))
            }
            wifiCheck(hardware.scans.count == 1 && hardware.disconnects == 0)
        }

        // The recorder ended its access point after delivering a file: rejoin the previous network.
        let (ended, endedWorker) = fixture()
        let endedLease = try await join(endedWorker)
        ended.link = .disconnected
        wifiCheck(await endedWorker.restore(endedLease, owner: owner) == .restoredPreviousNetwork)
        wifiCheck(ended.scans == [recorder.ssid, home.ssid] && ended.associations == [true, false] && ended.disconnects == 0)

        let (endedFailed, endedFailedWorker) = fixture()
        let endedFailedLease = try await join(endedFailedWorker)
        endedFailed.link = .disconnected
        endedFailed.onAssociate = { _, hasPassword in if !hasPassword { throw SyntheticFault.failed } }
        wifiCheck(await endedFailedWorker.restore(endedFailedLease, owner: owner) == .manualRecoveryRequired(.notConnected))
        wifiCheck(endedFailed.associations == [true, false] && endedFailed.disconnects == 0)

        let (stuck, stuckWorker) = fixture(previous: .disconnected)
        let stuckLease = try await join(stuckWorker)
        stuck.ignoreDisassociate = true
        wifiCheck(await stuckWorker.restore(stuckLease, owner: owner) == .manualRecoveryRequired(.recorderStillConnected))
    }

    private static func failureChecks() async throws {
        for previous in [NativeWiFiLink.unknown, .unavailable] {
            let (hardware, worker) = fixture(previous: previous)
            let reason: Failure.Reason = previous == .unknown ? .metadataUnavailable : .interfaceUnavailable
            _ = try await expectFailure(reason) { try await worker.prepare() }
            _ = try await expectFailure(reason) { _ = try await join(worker) }
            wifiCheck(hardware.scans.isEmpty && hardware.associations.isEmpty && hardware.disconnects == 0)
        }
        let (absent, absentWorker) = fixture()
        absent.points = []
        _ = try await expectFailure(.recorderNotFound) { _ = try await join(absentWorker) }
        wifiCheck(absent.scans.count == 2 && absent.associations.isEmpty)

        let (open, openWorker) = fixture()
        open.points = [point(recorder, personal: false)]
        _ = try await expectFailure(.unsupportedSecurity) { _ = try await join(openWorker) }
        wifiCheck(open.scans.count == 1 && open.associations.isEmpty)

        let (changed, changedWorker) = fixture()
        changed.onScan = { _ in changed.link = .associated(userNetwork) }
        _ = try await expectFailure(.networkChanged) { _ = try await join(changedWorker) }
        wifiCheck(changed.associations.isEmpty && changed.disconnects == 0)

        // Association can report failure AFTER it changed the network. Cleanup must still run.
        let (late, lateWorker) = fixture()
        late.onAssociate = { _, hasPassword in
            if hasPassword { late.link = .associated(recorder); throw SyntheticFault.failed }
        }
        let failure = try await expectFailure(.associationFailed) { _ = try await join(lateWorker) }
        wifiCheck(failure.cleanup == .restoredPreviousNetwork && late.link == .associated(home))
        wifiCheck(!(failure.errorDescription ?? "").contains("synthetic"))
        late.onAssociate = nil
        let next = try await join(lateWorker) // Failed attempt released only after cleanup.
        wifiCheck(await lateWorker.restore(next, owner: owner) == .restoredPreviousNetwork)

        let (addressCancel, addressCancelWorker) = fixture()
        let addressControl = NativeWiFiAttemptControl(timeout: 10)
        addressCancel.ipv4 = nil
        addressCancel.onLocalIPv4 = { addressControl.cancel() }
        let addressFailure = try await expectFailure(.cancelled) { _ = try await join(addressCancelWorker, control: addressControl) }
        wifiCheck(addressFailure.cleanup == .restoredPreviousNetwork && addressCancel.link == .associated(home))

        let (addressChanged, addressChangedWorker) = fixture()
        addressChanged.onLocalIPv4 = { addressChanged.link = .associated(userNetwork) }
        let addressChangedFailure = try await expectFailure(.networkChanged) { _ = try await join(addressChangedWorker) }
        wifiCheck(addressChangedFailure.cleanup == .unchanged(.currentNetworkChanged) && addressChanged.disconnects == 0)
    }

    private static func scanRetryChecks() async throws {
        let preparing = SyntheticWiFi(link: .associated(home), points: [point(recorder)])
        let preparingWorker = NativeWiFiWorker(hardware: preparing, scanRetryDelay: 0.1, apReadyDelay: 0.1)
        _ = try await expectFailure(.timedOut) {
            _ = try await join(preparingWorker, control: NativeWiFiAttemptControl(timeout: 0.02))
        }
        wifiCheck(preparing.scans.isEmpty && preparing.associations.isEmpty)

        let (delayed, delayedWorker) = fixture()
        delayed.points = []
        var firstScanEnded: UInt64 = 0
        delayed.onScan = { _ in
            if delayed.scans.count == 1 { firstScanEnded = DispatchTime.now().uptimeNanoseconds }
            else {
                // Model airportd returning its empty cache until the retry interval expires.
                wifiCheck(DispatchTime.now().uptimeNanoseconds - firstScanEnded >= 100_000_000)
                delayed.points = [point(recorder), point(home)]
            }
        }
        let lease = try await join(delayedWorker)
        wifiCheck(delayed.scans.count == 2 && delayed.associations == [true])
        wifiCheck(await delayedWorker.restore(lease, owner: owner) == .restoredPreviousNetwork)

        let (expired, expiredWorker) = fixture()
        expired.points = []
        _ = try await expectFailure(.timedOut) {
            _ = try await join(expiredWorker, control: NativeWiFiAttemptControl(timeout: 0.02))
        }
        wifiCheck(expired.scans.count == 1 && expired.associations.isEmpty && expired.disconnects == 0)

        let (cancelled, cancelledWorker) = fixture()
        cancelled.points = []
        let gate = BlockingGate()
        let control = NativeWiFiAttemptControl(timeout: 10)
        cancelled.onScan = { _ in gate.block() }
        let task = Task { try await join(cancelledWorker, control: control) }
        await gate.waitUntilEntered()
        gate.release()
        try await Task.sleep(nanoseconds: 20_000_000)
        control.cancel()
        _ = try await expectFailure(.cancelled) { _ = try await task.value }
        wifiCheck(cancelled.scans.count == 1 && cancelled.associations.isEmpty && cancelled.disconnects == 0)

        let (changed, changedWorker) = fixture()
        changed.points = []
        changed.onScan = { _ in changed.link = .associated(userNetwork) }
        _ = try await expectFailure(.networkChanged) { _ = try await join(changedWorker) }
        wifiCheck(changed.scans.count == 1 && changed.associations.isEmpty && changed.disconnects == 0)
    }

    private static func lateCancellationChecks() async throws {
        let (before, beforeWorker) = fixture()
        let cancelled = NativeWiFiAttemptControl(timeout: 10)
        cancelled.cancel()
        _ = try await expectFailure(.cancelled) { _ = try await join(beforeWorker, control: cancelled) }
        wifiCheck(before.scans.isEmpty && before.associations.isEmpty)
        _ = try await expectFailure(.timedOut) { _ = try await join(beforeWorker, control: NativeWiFiAttemptControl(timeout: 0)) }

        let (scan, scanWorker) = fixture()
        let scanGate = BlockingGate()
        let scanControl = NativeWiFiAttemptControl(timeout: 10)
        scan.onScan = { _ in scanGate.block() }
        let scanTask = Task { try await join(scanWorker, control: scanControl) }
        await scanGate.waitUntilEntered()
        scanControl.cancel()
        scanGate.release()
        _ = try await expectFailure(.cancelled) { _ = try await scanTask.value }
        wifiCheck(scan.associations.isEmpty && scan.disconnects == 0 && scan.link == .associated(home))

        // Hold a native-style blocking association past cancellation. Queue a newer attempt
        // while it is blocked: it must not start until the late old association is cleaned up.
        let (late, lateWorker) = fixture()
        let gate = BlockingGate()
        let control = NativeWiFiAttemptControl(timeout: 10)
        let finished = LockedFlag()
        late.onAssociate = { point, hasPassword in
            if hasPassword && point.identity == recorder {
                late.link = .associated(recorder)
                late.onAssociate = nil // Only the first attempt blocks.
                gate.block()
            }
        }
        let oldTask = Task {
            defer { finished.set() }
            return try await join(lateWorker, control: control)
        }
        await gate.waitUntilEntered()
        control.cancel()
        wifiCheck(!finished.get()) // Cancellation cannot abandon a call that can still switch WiFi.
        let newTask = Task { try await join(lateWorker) }
        gate.release()
        let failure = try await expectFailure(.cancelled) { _ = try await oldTask.value }
        wifiCheck(failure.cleanup == .restoredPreviousNetwork)
        let newLease = try await newTask.value
        wifiCheck(late.link == .associated(recorder) && late.associations == [true, false, true])
        wifiCheck(await lateWorker.restore(newLease, owner: owner) == .restoredPreviousNetwork)

        // Monotonic deadline after a late scan: no association is allowed.
        let (timeout, timeoutWorker) = fixture()
        let timeoutGate = BlockingGate()
        let deadline = NativeWiFiAttemptControl(timeout: 1)
        timeout.onScan = { _ in timeoutGate.block() }
        let timeoutTask = Task { try await join(timeoutWorker, control: deadline) }
        await timeoutGate.waitUntilEntered()
        try await Task.sleep(nanoseconds: 1_050_000_000)
        timeoutGate.release()
        _ = try await expectFailure(.timedOut) { _ = try await timeoutTask.value }
        wifiCheck(timeout.associations.isEmpty && timeout.link == .associated(home))
    }
}

private func wifiCheck(_ condition: Bool, _ message: String = "Synthetic WiFi check failed", file: StaticString = #file, line: UInt = #line) {
    precondition(condition, message, file: file, line: line)
}

private enum SyntheticFault: Error { case failed }

/// State is configured before each operation or read after its awaited completion. Hooks run
/// only on the worker queue. No synthetic credential values are retained in the observations.
private final class SyntheticWiFi: NativeWiFiHardware, @unchecked Sendable {
    var link: NativeWiFiLink
    var points: [NativeWiFiAccessPoint]
    var scans: [Data] = []
    var associations: [Bool] = []
    var disconnects = 0
    var ignoreDisassociate = false
    var ipv4: String? = "192.0.2.10"
    var onLocalIPv4: (() -> Void)?
    var onScan: ((Data) throws -> Void)?
    var onAssociate: ((NativeWiFiAccessPoint, Bool) throws -> Void)?

    init(link: NativeWiFiLink, points: [NativeWiFiAccessPoint]) { self.link = link; self.points = points }
    func preferredInterfaceName() throws -> String { wifiCheck(!Thread.isMainThread); return "en9" }
    func current(on interfaceName: String) -> NativeWiFiLink {
        wifiCheck(!Thread.isMainThread && interfaceName == "en9")
        return link
    }
    func localIPv4(on interfaceName: String) -> String? {
        wifiCheck(!Thread.isMainThread && interfaceName == "en9")
        onLocalIPv4?()
        return ipv4
    }
    func scan(ssidCandidates: [Data], on interfaceName: String) throws -> [NativeWiFiAccessPoint] {
        wifiCheck(!Thread.isMainThread && interfaceName == "en9")
        wifiCheck(ssidCandidates.count == 1, "Each discovery operation must probe one exact recorder SSID")
        scans.append(contentsOf: ssidCandidates)
        for ssid in ssidCandidates { try onScan?(ssid) }
        return points.filter { ssidCandidates.contains($0.identity.ssid) }
    }
    func associate(_ point: NativeWiFiAccessPoint, password: String?, on interfaceName: String) throws {
        wifiCheck(!Thread.isMainThread && interfaceName == "en9")
        associations.append(password != nil)
        try onAssociate?(point, password != nil)
        link = .associated(point.identity)
    }
    func disassociate(on interfaceName: String) {
        wifiCheck(!Thread.isMainThread && interfaceName == "en9")
        disconnects += 1
        if !ignoreDisassociate { link = .disconnected }
    }
}

private final class BlockingGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    func block() {
        entered.signal()
        wifiCheck(released.wait(timeout: .now() + 5) == .success, "Synthetic worker gate timed out")
    }
    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                wifiCheck(self.entered.wait(timeout: .now() + 5) == .success, "Synthetic call never began")
                continuation.resume()
            }
        }
    }
    func release() { released.signal() }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
