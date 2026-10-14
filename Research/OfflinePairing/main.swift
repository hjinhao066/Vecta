import AppKit
import Foundation
import NotePinTransport

let fm = FileManager.default
let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
let evidence = base.appendingPathComponent("VectaOfflinePairingResearch")
try fm.createDirectory(at: evidence, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let runID = UUID().uuidString
let logURL = evidence.appendingPathComponent(runID + ".log")
fm.createFile(atPath: logURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
let handle = try FileHandle(forWritingTo: logURL)
func log(_ line: String) { try? handle.write(contentsOf: Data((ISO8601DateFormatter().string(from:Date()) + " " + line + "\n").utf8)); try? handle.synchronize() }
func finish(_ message: String, code: Int32 = 0) -> Never { log(message); exit(code) }
let ownerURL = evidence.appendingPathComponent("local-owner.txt")
let owner: String
if fm.fileExists(atPath: ownerURL.path) { owner = try String(contentsOf: ownerURL, encoding: .utf8) }
else {
    owner = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    fm.createFile(atPath: ownerURL.path, contents: Data(owner.utf8), attributes: [.posixPermissions: 0o600])
}
let mode = ["empty-signature", "plain-apple", "plain-android", "empty-recovery", "zero-count-signature", "null-signature", "gatt-only"].first { CommandLine.arguments.contains("--" + $0) } ?? "direct-rsa"
let selected = try JSONDecoder().decode(SavedPlaudDevice.self, from: Data(contentsOf: base.appendingPathComponent("VectaServices/selected-device.json")))
guard selected.model == .notePinS else { finish("Wrong target model", code: 2) }
log("START mode=" + mode + "; local random owner; no PartnerPlatform compiled; no Keychain or legacy auth reads")
let config = NativeBluetoothSession.Configuration(peripheralID: nil, platformDomain: "", accessToken: "", userID: owner, serialNumber: selected.serialNumber, deviceType: "notepins", advertisedProtocolVersion: selected.protocolVersion, handshakeToken: owner, capturePrivateAdvertisements: true)
let driver = NativeBluetoothSession(config: config, reportURL: evidence.appendingPathComponent(runID + ".json"))
driver.researchMode = mode
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
driver.onResearchInventory = { driver.stop(); finish("READ-ONLY GATT enumeration complete; no handshake sent") }
driver.onStatus = { log($0) }
driver.onResearchControl = { log("Control response prefix=" + $0) }
driver.onFailure = { finish("FAILED " + $0, code: 2) }
driver.onComplete = { files in driver.stop(); finish("SUCCESS local owner handshake and file inventory count=" + String(files.count)) }
DispatchQueue.main.async { driver.start() }
DispatchQueue.main.asyncAfter(deadline:.now()+75) { driver.stop(); finish("GLOBAL TIMEOUT", code:2) }
app.run()
