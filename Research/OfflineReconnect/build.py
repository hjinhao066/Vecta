#!/usr/bin/env python3
"""Build a bounded state/list-only hardware check without audio codec dependencies."""
from pathlib import Path
import subprocess
import plistlib

root = Path(__file__).resolve().parents[2]
build = root / '.build/offline-reconnect'
build.mkdir(parents=True, exist_ok=True)
source = (root / 'Packages/VectaTransport/Sources/Bluetooth/NativeBluetoothSession.swift').read_text()
source = source[:source.index('    private func decodeDownloadedAudio(')] + '''    private func decodeDownloadedAudio(_ rawURL: URL) { fail("research-download-disabled") }
}
'''
source = source.replace('private var decodingTask: Task<NativeAudioConversion, Error>?', 'private var decodingTask: Task<Void, Error>?')
(build / 'Session.swift').write_text(source)

def run(args):
    subprocess.run([str(arg) for arg in args], check=True, cwd=root)

run(['xcrun', 'swiftc', '-emit-library', '-static', '-emit-module', '-module-name', 'NotePinTransport',
     *sorted((root / 'Packages/VectaTransport/Sources/Core').glob('*.swift')),
     '-o', build / 'libNotePinTransport.a', '-emit-module-path', build / 'NotePinTransport.swiftmodule'])
run(['xcrun', 'swiftc', '-emit-library', '-static', '-emit-module', '-module-name', 'NotePinAudio',
     root / 'Packages/VectaTransport/Sources/Audio/AudioDownloadPacket.swift',
     '-o', build / 'libNotePinAudio.a', '-emit-module-path', build / 'NotePinAudio.swiftmodule'])
app = build / 'VectaOfflineReconnect.app'
contents = app / 'Contents'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
# Reuse the pre-existing credential adapter, not the reset procedure or its entrypoint.
previous = (root / 'Research/FactoryReset/main.swift').read_text()
adapter = previous[previous.index('func credentials()'):previous.index('struct BackupManifest:')]
(build / 'CredentialAdapter.swift').write_text('import Foundation\nimport Security\nimport CryptoKit\n' + adapter)
run(['xcrun', 'swiftc', '-I', build, '-L', build, '-lNotePinTransport', '-lNotePinAudio',
     build / 'Session.swift', root / 'App/VectaAuthorization.swift', root / 'App/VectaOfflineIdentity.swift',
     build / 'CredentialAdapter.swift', root / 'Research/OfflineReconnect/main.swift',
     '-o', contents / 'MacOS/VectaOfflineReconnect'])
(contents / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'app.vecta.offline-reconnect-check', 'CFBundleName': 'Vecta Offline Reconnect Check',
    'CFBundleExecutable': 'VectaOfflineReconnect', 'CFBundleVersion': '1', 'CFBundlePackageType': 'APPL',
    'LSUIElement': True, 'NSBluetoothAlwaysUsageDescription': 'Verify local authorization for your selected PLAUD without recording, deleting or resetting it.'
}))
run(['codesign', '--force', '--sign', '-', app])
print(app)
