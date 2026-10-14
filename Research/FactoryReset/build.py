#!/usr/bin/env python3
"""Build a separate research app; never overwrite the product or its sources."""
from pathlib import Path
import subprocess,plistlib
root=Path(__file__).resolve().parents[2]; build=root/'.build/reset-research/probe';build.mkdir(parents=True,exist_ok=True)
source=(root/'Packages/VectaTransport/Sources/Bluetooth/NativeBluetoothSession.swift').read_text()
source=source[:source.index('    private func decodeDownloadedAudio(')]+'''    private func decodeDownloadedAudio(_ rawURL: URL) { fail("research-audio-decoding-disabled") }
}
'''
source=source.replace('private var decodingTask: Task<NativeAudioConversion, Error>?','private var decodingTask: Task<Void, Error>?')
(build/'ResearchSession.swift').write_text(source)
def run(args):subprocess.run(args,check=True,cwd=root)
core=sorted((root/'Packages/VectaTransport/Sources/Core').glob('*.swift'))
run(['swiftc','-emit-library','-static','-emit-module','-module-name','NotePinTransport',*map(str,core),'-o',str(build/'libNotePinTransport.a'),'-emit-module-path',str(build/'NotePinTransport.swiftmodule')])
run(['swiftc','-emit-library','-static','-emit-module','-module-name','NotePinAudio',str(root/'Packages/VectaTransport/Sources/Audio/AudioDownloadPacket.swift'),'-o',str(build/'libNotePinAudio.a'),'-emit-module-path',str(build/'NotePinAudio.swiftmodule')])
app=build/'VectaResetResearch.app';contents=app/'Contents';(contents/'MacOS').mkdir(parents=True,exist_ok=True)
run(['swiftc','-I',str(build),'-L',str(build),'-lNotePinTransport','-lNotePinAudio',str(build/'ResearchSession.swift'),str(root/'App/VectaAuthorization.swift'),str(root/'App/VectaOfflineIdentity.swift'),str(root/'Research/FactoryReset/main.swift'),'-o',str(contents/'MacOS/VectaResetResearch')])
(contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'app.vecta.reset-research','CFBundleName':'Vecta Reset Research','CFBundleExecutable':'VectaResetResearch','CFBundleVersion':'1','CFBundlePackageType':'APPL','LSUIElement':True,'NSBluetoothAlwaysUsageDescription':'Connect to your selected NotePin S for the factory reset you requested.','NSBluetoothPeripheralUsageDescription':'Connect to your selected NotePin S for the factory reset you requested.'}))
run(['codesign','--force','--sign','-',str(app)])
print(app)
