#!/usr/bin/env python3
from pathlib import Path
import subprocess,plistlib
root=Path(__file__).resolve().parents[2]; build=root/'.build/offline-pairing';build.mkdir(parents=True,exist_ok=True)
source=(root/'Packages/VectaTransport/Sources/Bluetooth/NativeBluetoothSession.swift').read_text()
start=source.index('    func start() {');end=source.index('    func stop() {',start)
source=source[:start]+'''    var researchMode = "direct-rsa"
    func start() {
        guard stage == .idle, config.deviceType == "notepins", config.advertisedProtocolVersion ?? 0 >= 20 else { return }
        do { identity = try LocalResearchIdentity.generate() }
        catch { fail("local-key-generation-failed"); return }
        if researchMode.hasPrefix("plain-") { plaintextProfile = try? PlaudProtocolProfile(version: 20); protocolVersion = 20 }
        transition(.bluetooth, "Local RSA generated; starting Bluetooth without network or credentials")
        central = CBCentralManager(delegate: self, queue: .main)
    }
'''+source[end:]
start=source.index('    private func decodeDownloadedAudio(')
source=source[:start]+'''    private func decodeDownloadedAudio(_ rawURL: URL) { fail("research-audio-decoding-disabled") }
}
'''
source=source.replace('private var decodingTask: Task<NativeAudioConversion, Error>?','private var decodingTask: Task<Void, Error>?')
start=source.index('                transition(.signature, config.explicitlyConfirmedRecovery')
end=source.index('                enqueue(packets)',start)+len('                enqueue(packets)')
source=source[:start]+'''                if researchMode == "direct-rsa" {
                    transition(.rsa, "Offline: sending locally generated RSA public key without serial signature")
                    enqueue(try ProtocolBootstrap.publicKeyPackets(identity.publicKeyPEM))
                } else if ["empty-signature", "empty-recovery", "zero-count-signature", "null-signature"].contains(researchMode) {
                    transition(.signature, "Offline pre-handshake boundary experiment: " + researchMode)
                    if researchMode == "null-signature" { enqueue(try ProtocolBootstrap.signaturePackets(Data(repeating: 0, count: 256))) }
                    else { enqueue([Data([researchMode == "empty-recovery" ? 0x20 : 0x10, 0xfe, researchMode == "zero-count-signature" ? 0 : 1, 0])]) }
                } else { fail("unknown-research-mode") }
'''+source[end:]
source=source.replace('enqueue([try profile.ownerHandshake(token: config.handshakeToken!, checked: false)])', 'enqueue([try (researchMode == "plain-apple" ? ProtocolBootstrap.ownerHandshake(token: config.handshakeToken!, checked: false) : profile.ownerHandshake(token: config.handshakeToken!, checked: false))])')
source=source.replace('try send(profile.ownerHandshake(token: config.handshakeToken!, checked: true))', 'try send(researchMode == "plain-apple" ? ProtocolBootstrap.ownerConfirmation(token: config.handshakeToken!) : profile.ownerHandshake(token: config.handshakeToken!, checked: true))')
source=source.replace('(plaintextProfile == nil ? status.protocolVersion >= 20 : status.protocolVersion < 20)', '(researchMode.hasPrefix("plain-") ? status.protocolVersion >= 20 : (plaintextProfile == nil ? status.protocolVersion >= 20 : status.protocolVersion < 20))')
source=source.replace('peripheral.discoverServices([CBUUID(string: "1910"), CBUUID(string: "180F")])', 'peripheral.discoverServices(nil)')
source=source.replace('        pendingServices -= 1', '        onStatus?("GATT " + service.uuid.uuidString + ": " + (service.characteristics ?? []).map { $0.uuid.uuidString + "(properties=" + String($0.properties.rawValue) + ")" }.joined(separator:", "))\n        pendingServices -= 1')
source=source.replace('        guard pendingServices == 0 else { return }', '        guard pendingServices == 0 else { return }\n        if researchMode == "gatt-only" { onResearchInventory?(); return }')
source=source.replace('    var onStatus:', '    var onResearchInventory: (() -> Void)?\n    var onStatus:')
# Research executable has no mutation entrypoints except normal owner pairing.
source=source.replace('        if plaintextProfile != nil { enqueue([payload]); return }','''        guard [[UInt8](arrayLiteral:1,1,0), [1,3,0], [1,9,0], [1,0x1a,0]].contains(Array(payload.prefix(3))) else { throw ProtocolWireError.invalidInput }
        if plaintextProfile != nil { enqueue([payload]); return }''')
source=source.replace('            if Array(payload.prefix(3)) == [1, 9, 0]', '            onResearchControl?(Array(payload.prefix(4)).map { String(format:"%02x",$0) }.joined())\n            if Array(payload.prefix(3)) == [1, 9, 0]')
source=source.replace('    var onStatus:', '    var onResearchControl: ((String) -> Void)?\n    var onStatus:')
assert 'PartnerPlatform(' not in source and 'URLSession' not in source
(build/'OfflineSession.swift').write_text(source)
def run(args):subprocess.run(args,check=True,cwd=root)
core=sorted(p for p in (root/'Packages/VectaTransport/Sources/Core').glob('*.swift') if p.name!='PartnerPlatform.swift')
core.append(root/'Research/OfflinePairing/LocalIdentity.swift')
run(['swiftc','-emit-library','-static','-emit-module','-module-name','NotePinTransport',*map(str,core),'-o',str(build/'libNotePinTransport.a'),'-emit-module-path',str(build/'NotePinTransport.swiftmodule')])
run(['swiftc','-emit-library','-static','-emit-module','-module-name','NotePinAudio',str(root/'Packages/VectaTransport/Sources/Audio/AudioDownloadPacket.swift'),'-o',str(build/'libNotePinAudio.a'),'-emit-module-path',str(build/'NotePinAudio.swiftmodule')])
app=build/'VectaOfflinePairing.app';contents=app/'Contents';(contents/'MacOS').mkdir(parents=True,exist_ok=True)
run(['swiftc','-I',str(build),'-L',str(build),'-lNotePinTransport','-lNotePinAudio',str(build/'OfflineSession.swift'),str(root/'Research/OfflinePairing/main.swift'),'-o',str(contents/'MacOS/VectaOfflinePairing')])
(contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'app.vecta.offline-pairing-research','CFBundleName':'Vecta Offline Pairing','CFBundleExecutable':'VectaOfflinePairing','CFBundleVersion':'1','CFBundlePackageType':'APPL','LSUIElement':True,'NSBluetoothAlwaysUsageDescription':'Test fully local pairing with your NotePin S without PLAUD services.'}))
run(['codesign','--force','--sign','-',str(app)])
(build/'source-files.txt').write_text('\n'.join(str(p.relative_to(root)) for p in core)+'\nOfflineSession.swift (generated)\nResearch/OfflinePairing/main.swift\n')
print(app)
