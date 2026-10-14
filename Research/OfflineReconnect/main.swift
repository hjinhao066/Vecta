import AppKit
import CoreBluetooth
import Foundation
import NotePinTransport

let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
let evidence = base.appendingPathComponent("VectaOfflineReconnectCheck")
try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let provision = CommandLine.arguments.contains("--provision")
let runID = UUID().uuidString
let logURL = evidence.appendingPathComponent(runID + ".log")
FileManager.default.createFile(atPath: logURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
let output = try FileHandle(forWritingTo: logURL)
func log(_ text: String) {
    try? output.write(contentsOf: Data((ISO8601DateFormatter().string(from: Date()) + " " + text + "\n").utf8))
    try? output.synchronize()
}
func finish(_ message: String, code: Int32 = 0) -> Never { log(message); exit(code) }
var driver: NativeBluetoothSession?
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "app.vecta.mac").isEmpty else { finish("STOP production app running", code: 2) }
        let selected = try JSONDecoder().decode(SavedPlaudDevice.self, from: Data(contentsOf: base.appendingPathComponent("VectaServices/selected-device.json")))
        guard selected.model == .notePinS, selected.protocolVersion == 20 else { finish("STOP unsupported target", code: 2) }
        let cached = try VectaOfflineIdentityStore.load(serial: selected.serialNumber)
        var session: VectaDeviceSession?
        var identity: PreparedPartnerIdentity?
        if provision {
            guard cached == nil else { finish("STOP cached identity already exists; do not replace it", code: 2) }
            let existing = try credentials()
            session = try await VectaPartnerAuthorization(credentials: existing).authorize(expectedUserID: existing.userID)
            log("ONLINE PROVISION: temporary token received; target ****" + selected.serialNumber.suffix(4))
        } else {
            guard let cached else { finish("STOP no local identity; no API requests", code: 2) }
            identity = try cached.prepared(for: selected)
            log("OFFLINE MODE: no token, no credential lookup, no Partner preparation")
        }
        let config = NativeBluetoothSession.Configuration(peripheralID: nil,
            platformDomain: session?.plaudDomain ?? "platform-us.plaud.ai", accessToken: session?.plaudUserAccessToken ?? "",
            userID: session?.userID ?? "", serialNumber: selected.serialNumber, deviceType: "notepins",
            advertisedProtocolVersion: 20, handshakeToken: cached?.ownerToken)
        let next = NativeBluetoothSession(config: config, reportURL: evidence.appendingPathComponent(runID + ".json"), offlineIdentity: identity)
        var prepared: PreparedPartnerIdentity?
        next.onIdentityPrepared = { prepared = $0; log("ONLINE PROVISION: long-term materials prepared") }
        next.onStatus = { log("STATUS " + $0) }
        next.onFailure = { reason in finish("FAILED " + reason + "; no destructive command sent", code: 1) }
        next.onComplete = { entries in
            do {
                if provision {
                    guard let prepared, let pem = prepared.privateKeyPEM, let session else { throw VectaAuthorizationError.invalidResponse }
                    let stored = VectaOfflineIdentity(version: 1, serialNumber: selected.serialNumber, deviceType: "notepins",
                        protocolVersion: 20, ownerToken: session.userID, publicKeyPEM: prepared.publicKeyPEM,
                        privateKeyPEM: pem, serialSignature: prepared.serialSignature)
                    try VectaOfflineIdentityStore.save(stored, device: selected)
                    log("Long-term identity saved in Keychain after authenticated list read")
                } else if prepared != nil { throw VectaAuthorizationError.invalidResponse }
                log("AUTHENTICATED state/list complete; recordings=" + String(entries.count))
                next.stop()
                finish("PASS " + (provision ? "online provision" : "cached-identity reconnect") + "; no recording/download/deletion/reset/unbind commands")
            } catch { next.stop(); finish("FAILED identity persistence/verification", code: 1) }
        }
        next.setMaintainsConnection(true)
        driver = next
        next.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) { driver?.stop(); finish("TIMEOUT", code: 1) }
    } catch { finish("STOP " + error.localizedDescription, code: 2) }
}
app.run()
