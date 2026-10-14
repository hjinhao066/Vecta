import AppKit
import CoreBluetooth
import Foundation
import Security
import CryptoKit
import NotePinTransport

let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
let evidence = base.appendingPathComponent("VectaResetResearch")
try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let runID = UUID().uuidString
let logURL = evidence.appendingPathComponent(runID + ".log")
FileManager.default.createFile(atPath: logURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
let output = try FileHandle(forWritingTo: logURL)
func log(_ text: String) { try? output.write(contentsOf: Data((ISO8601DateFormatter().string(from: Date()) + " " + text + "\n").utf8)); try? output.synchronize() }
func finish(_ message: String, _ code: Int32 = 0) -> Never { log(message); exit(code) }
func legacySession() throws -> VectaDeviceSession {
    var result: CFTypeRef?
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.codex.plaudreceiver.a01a11651.session",
        kSecAttrAccount as String: "public-beta-session", kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne]
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { throw VectaAuthorizationError.unavailable }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(VectaDeviceSession.self, from: data)
}
func credentials() throws -> VectaPartnerCredentials {
    if let saved = try? VectaCredentialStore.load() { return saved }
    let file = base.appendingPathComponent("PinPointServices/backend.env")
    let text = try String(contentsOf: file, encoding: .utf8)
    var fields: [String:String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        guard let index = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<index]).trimmingCharacters(in: .whitespaces)
        guard ["PLAUD_CLIENT_ID", "PLAUD_CLIENT_SECRET", "PLAUD_API_DOMAIN", "PINPOINT_USER_ID_SECRET_V1"].contains(key) else { continue }
        var value = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value.removeFirst(); value.removeLast() }
        fields[key] = value
    }
    guard let secret = fields["PINPOINT_USER_ID_SECRET_V1"], secret.utf8.count >= 32 else { throw VectaAuthorizationError.invalidCredentials }
    let bytes = HMAC<SHA256>.authenticationCode(for: Data("v1:local:primary".utf8), using: SymmetricKey(data: Data(secret.utf8)))
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
    var encoded: [UInt8] = []; var accumulator: UInt32 = 0; var bits = 0
    for byte in bytes {
        accumulator = (accumulator << 8) | UInt32(byte); bits += 8
        while bits >= 5 { bits -= 5; encoded.append(alphabet[Int((accumulator >> bits) & 31)]) }
    }
    if bits > 0 { encoded.append(alphabet[Int((accumulator << (5 - bits)) & 31)]) }
    let owner = "pinpoint_" + String(decoding: encoded.prefix(32), as: UTF8.self)
    let c = VectaPartnerCredentials(clientID: fields["PLAUD_CLIENT_ID"] ?? "", clientSecret: fields["PLAUD_CLIENT_SECRET"] ?? "", domain: fields["PLAUD_API_DOMAIN"] ?? "platform-us.plaud.ai", userID: owner)
    try c.validate(); return c
}
let args = CommandLine.arguments
final class ResetObservation: NSObject, CBCentralManagerDelegate {
    let selected: SavedPlaudDevice
    var central: CBCentralManager!
    var seen = false
    init(_ selected: SavedPlaudDevice) { self.selected = selected; super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { log("Scan Bluetooth state=" + String(central.state.rawValue)); return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !seen, let bytes = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let ad = try? NativeAdvertisement.decodeManufacturerData(bytes), ad.serialNumber == selected.serialNumber else { return }
        seen = true
        log("TARGET ADVERTISEMENT firmware=" + String(ad.firmwareVersion) + " protocol=" + String(ad.protocolVersion ?? 0) + " bindState=" + String(ad.bindState ?? 255) + " cachedUUIDMatches=" + String(peripheral.identifier == selected.peripheralID))
        // Private evidence; no connect, authentication, cloud call or automatic rebinding.
        let value: [String: Any] = ["manufacturer": bytes.base64EncodedString(), "peripheralID": peripheral.identifier.uuidString]
        let url = evidence.appendingPathComponent(runID + "-advertisement.json")
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        central.stopScan(); finish("SCAN COMPLETE; no device commands sent")
    }
}
var observer: ResetObservation?
var driver: NativeBluetoothSession?
log("START mode=inventory")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "app.vecta.mac").isEmpty else { finish("STOP production app is running", 2) }
        let selected = try JSONDecoder().decode(SavedPlaudDevice.self, from: Data(contentsOf: base.appendingPathComponent("VectaServices/selected-device.json")))
        guard selected.model == .notePinS, selected.protocolVersion >= 20 else { finish("STOP wrong device model", 2) }
        if args.contains("--scan-only") {
            log("Passive observation only")
            observer = ResetObservation(selected)
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { observer?.central.stopScan(); finish("SCAN TIMEOUT; target not observed", 2) }
            return
        }
        let config: NativeBluetoothSession.Configuration
        let identity: PreparedPartnerIdentity?
        if args.contains("--cached-identity") {
            guard let cached = try VectaOfflineIdentityStore.load(serial: selected.serialNumber) else { finish("STOP no cached identity; no online fallback", 2) }
            identity = try cached.prepared(for: selected)
            config = NativeBluetoothSession.Configuration(peripheralID: nil, platformDomain: "platform-us.plaud.ai", accessToken: "", userID: "", serialNumber: selected.serialNumber, deviceType: "notepins", advertisedProtocolVersion: selected.protocolVersion, handshakeToken: cached.ownerToken)
            log("Cached-identity connection; no credentials or Partner requests")
        } else {
            let c = try credentials()
            log("Existing owner credentials loaded in memory; refreshing legitimate authorization")
            let session = try await VectaPartnerAuthorization(credentials: c).authorize(expectedUserID: c.userID)
            identity = nil
            config = NativeBluetoothSession.Configuration(peripheralID: selected.peripheralID, platformDomain: session.plaudDomain, accessToken: session.plaudUserAccessToken, userID: session.userID, serialNumber: selected.serialNumber, deviceType: "notepins", advertisedProtocolVersion: selected.protocolVersion, useVerifiedPeripheralCache: true)
        }
        let d = NativeBluetoothSession(config: config, reportURL: evidence.appendingPathComponent(runID + ".json"), offlineIdentity: identity); driver = d
        d.setMaintainsConnection(true)
        d.onStatus = { log($0) }
        d.onFailure = { reason in finish("Session ended: " + reason, 2) }
        d.onComplete = { files in
            log("Fresh authenticated inventory count=" + String(files.count) + " state=" + String(d.recorderState?.state ?? 99999) + " keyState=" + String(d.recorderState?.keyStateValue ?? 255))
            d.stop(); finish("INVENTORY COMPLETE")
        }
        d.start()
    } catch let error as VectaAuthorizationError { finish("STOP authorization: " + error.localizedDescription, 2) } catch { finish("STOP preparation failed (" + String(describing: type(of: error)) + ")", 2) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 150) { driver?.stop(); finish("GLOBAL TIMEOUT", 2) }
app.run()
