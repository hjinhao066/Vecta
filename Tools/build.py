#!/usr/bin/env python3
"""macOS-only source build. No installed application or private configuration is read."""
from pathlib import Path
import argparse,hashlib,json,os,plistlib,shutil,subprocess
ROOT=Path(__file__).resolve().parents[1]
def run(*args,cwd=ROOT): subprocess.run([str(a) for a in args],cwd=cwd,check=True)
def modules(out):
    transport=ROOT/'Packages/VectaTransport/Sources'; out.mkdir(parents=True)
    codec=Path(os.environ.get('VECTA_CODEC_BUILD_ROOT',str(ROOT/'.build/native-codecs')))/'install'
    run('bash',ROOT/'Packages/VectaTransport/build-native-codecs.sh')
    # Capture the verified complete-input identity before consuming codec headers/archives.
    shutil.copy2(codec/'archive-integrity.json',out.parent/'codec-integrity.json')
    run('xcrun','swiftc','-O','-module-cache-path',out.parent/'ModuleCache','-file-prefix-map',f'{ROOT}=Vecta','-debug-prefix-map',f'{ROOT}=Vecta','-parse-as-library','-emit-library','-static','-emit-module','-module-name','NotePinTransport','-target','arm64-apple-macosx13.0',*sorted((transport/'Core').glob('*.swift')),'-emit-module-path',out/'NotePinTransport.swiftmodule','-o',out/'libNotePinTransport.a')
    inc=out/'CNativeAudio';inc.mkdir();shutil.copy2(transport/'CNativeAudio/include/NativeAudioCodec.h',inc/'NativeAudioCodec.h')
    (inc/'module.modulemap').write_text('module CNativeAudio { header "NativeAudioCodec.h" export * }\n')
    sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
    run('xcrun','clang','-O2','-target','arm64-apple-macosx13.0','-isysroot',sdk,'-I',codec/'include','-I',transport/'CNativeAudio/include','-c',transport/'CNativeAudio/NativeAudioCodec.c','-o',out/'NativeAudioCodec.o')
    run('xcrun','ar','rcs',out/'libCNativeAudio.a',out/'NativeAudioCodec.o')
    run('xcrun','swiftc','-O','-module-cache-path',out.parent/'ModuleCache','-file-prefix-map',f'{ROOT}=Vecta','-debug-prefix-map',f'{ROOT}=Vecta','-parse-as-library','-emit-library','-static','-emit-module','-module-name','NotePinAudio','-target','arm64-apple-macosx13.0','-I',out,'-I',inc,*sorted((transport/'Audio').glob('*.swift')),'-emit-module-path',out/'NotePinAudio.swiftmodule','-o',out/'libNotePinAudio.a')
    return codec

def source_snapshot():
    skip={'.git','.build','.swiftpm','.vendor','build','dist','work','outputs','__pycache__'}
    values={}
    for path in sorted(ROOT.rglob('*')):
        relative=path.relative_to(ROOT)
        if any(part in skip for part in relative.parts) or not path.is_file():continue
        if relative.parts[0] not in {'App','Domain','Storage','AI','Packages','Tools','Tests'} and path.name not in {'Package.swift','Package.resolved'}:continue
        values[str(relative)]=hashlib.sha256(path.read_bytes()).hexdigest()
    return values

LINK_MODULES=('Vecta.o','libNotePinTransport.a','libNotePinAudio.a','libCNativeAudio.a')
LINK_CODECS=('libopus.a','libmp3lame.a','libvorbisfile.a','libvorbis.a','libogg.a')

def link_inputs(build,codec):
    paths={**{'modules/'+name:Path(build)/'modules'/name for name in LINK_MODULES},
           **{'codec-libs/'+name:Path(codec)/'lib'/name for name in LINK_CODECS}}
    values={}
    for name,path in paths.items():
        if path.is_symlink() or any(p.is_symlink() for p in path.parents) or not path.is_file():
            raise ValueError('Missing/linked linker input: '+name)
        values[name]=hashlib.sha256(path.read_bytes()).hexdigest()
    return values

def capture_link_identity(build,codec,before,command,configuration):
    if link_inputs(build,codec)!=before:raise ValueError('Linker inputs changed during build; rebuild')
    build=Path(build)
    files={name:hashlib.sha256((build/name).read_bytes()).hexdigest() for name in
           ('Vecta.app/Contents/MacOS/Vecta','Vecta.app/Contents/Info.plist','source-manifest.json','codec-integrity.json')}
    # Export command identity without leaking the builder's home paths.
    replacements=((str(build),'$BUILD'),(str(codec),'$CODEC'),(str(ROOT),'$ROOT'))
    normalized=[]
    for argument in command:
        argument=str(argument)
        for old,new in replacements:argument=argument.replace(old,new)
        normalized.append(argument)
    value={'version':1,'inputs':before,'files':files,'command':normalized,
           'configuration':configuration,'toolchain':subprocess.check_output(['xcrun','swiftc','--version'],text=True).strip()}
    (build/'link-integrity.json').write_text(json.dumps(value,indent=2)+'\n')
    return value

def main():
    parser=argparse.ArgumentParser();parser.add_argument('output',type=Path);parser.add_argument('--frontend-only',action='store_true',help='Development app without inference workers; never a release.');parser.add_argument('--development',action='store_true',help='Include executable regression/UI fixture harnesses.');parser.add_argument('--version',default='0.1.0');parser.add_argument('--build',default='1');args=parser.parse_args()
    out=args.output.resolve()
    if out.exists(): raise SystemExit('Use a new output directory; existing artifacts are preserved.')
    out.mkdir(parents=True);app=out/'Vecta.app';mac=app/'Contents/MacOS';res=app/'Contents/Resources';mac.mkdir(parents=True);res.mkdir(parents=True)
    snapshot=source_snapshot()
    (out/'source-manifest.json').write_text(json.dumps(snapshot,indent=2)+'\n')
    if not args.frontend_only: run('python3','-I',ROOT/'Tools/build-workers.py')
    module=out/'modules';codec=modules(module)
    sources=[ROOT/p for p in json.loads((ROOT/'Tools/app-sources.json').read_text())]
    if args.development: sources.append(ROOT/'Tests/VectaAppChecks.swift')
    defines=['-D','VECTA_DEVELOPMENT'] if args.development else []
    archives=[codec/'lib'/name for name in ['libopus.a','libmp3lame.a','libvorbisfile.a','libvorbis.a','libogg.a']]
    # Preserve a relinkable application object for static LGPL dependencies.
    run('xcrun','swiftc','-O','-module-cache-path',out/'ModuleCache','-whole-module-optimization','-emit-object','-file-prefix-map',f'{ROOT}=Vecta','-debug-prefix-map',f'{ROOT}=Vecta','-swift-version','5','-target','arm64-apple-macosx13.0','-I',module,'-I',module/'CNativeAudio',*defines,*sources,'-o',module/'Vecta.o')
    linked_inputs=link_inputs(out,codec)
    link_command=['xcrun','swiftc','-target','arm64-apple-macosx13.0','-I',module,'-I',module/'CNativeAudio','-L',module,'-lsqlite3','-framework','NaturalLanguage',module/'libNotePinTransport.a',module/'libNotePinAudio.a',module/'libCNativeAudio.a',*archives,module/'Vecta.o','-o',mac/'Vecta']
    run(*link_command)
    if link_inputs(out,codec)!=linked_inputs:raise ValueError('Linker inputs changed during linking; rebuild')
    metadata=dict(CFBundleDevelopmentRegion='en',CFBundleLocalizations=['en','ru'],CFBundleIdentifier='app.vecta.mac',CFBundleExecutable='Vecta',CFBundleName='Vecta',CFBundleDisplayName='Vecta',CFBundlePackageType='APPL',CFBundleShortVersionString=args.version,CFBundleVersion=args.build,LSMinimumSystemVersion='13.0' if args.frontend_only else '15.0',CFBundleIconFile='Vecta.icns',NSBluetoothAlwaysUsageDescription='Vecta connects to your selected PLAUD recorder and downloads recordings to this Mac.',NSLocationUsageDescription='For Fast transfer, macOS requires location access to identify the recorder’s Wi-Fi network and restore your previous connection. Vecta does not request coordinates or transmit location data.',NSLocationWhenInUseUsageDescription='For Fast transfer, macOS requires location access to identify the recorder’s Wi-Fi network and restore your previous connection. Vecta does not request coordinates or transmit location data.',NSLocalNetworkUsageDescription='Fast transfer receives recordings from your selected PLAUD over its local Wi-Fi network, without cloud transfer.',NSHighResolutionCapable=True,LSApplicationCategoryType='public.app-category.productivity')
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(metadata));shutil.copy2(ROOT/'App/Resources/Vecta.icns',res/'Vecta.icns')
    if not args.frontend_only: run('python3','-I',ROOT/'Tools/package-workers.py',res/'LocalAI')
    else:
        local=res/'LocalAI';local.mkdir()
        shutil.copy2(ROOT/'AI/Resources/models-mlx.json',local/'models.json')
        (res/'DEVELOPMENT-ONLY.txt').write_text('Inference workers are omitted. This is not a release package.\n')
    shutil.copy2(ROOT/'NOTICE',res/'NOTICE')
    shutil.copy2(ROOT/'LICENSE',res/'LICENSE')
    for name in ('Localization','en.lproj','ru.lproj'):
        shutil.copytree(ROOT/'App/Resources'/name,res/name)
    run('xcrun','strip','-S',mac/'Vecta')
    if (b'/' + b'Users/') in (mac/'Vecta').read_bytes(): raise SystemExit('Application contains personal absolute paths; do not distribute this package.')
    identity=os.environ.get('VECTA_SIGNING_IDENTITY','-')
    run('codesign','--force','--sign',identity,app);run('codesign','--verify','--strict',app)
    if source_snapshot()!=snapshot: raise SystemExit('Product source changed during build. Preserve this artifact for diagnostics, then rebuild from a stable tree.')
    capture_link_identity(out,codec,linked_inputs,link_command,{'development':args.development,'frontendOnly':args.frontend_only,'version':args.version,'build':args.build,'target':'arm64-apple-macosx13.0'})
    if not args.frontend_only:run('python3','-I',ROOT/'Tools/make-relink-kit.py',out,out/'relink-kit')
    print(app)
if __name__=='__main__':main()
