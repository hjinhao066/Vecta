#!/usr/bin/env python3
"""Package only build outputs and licenses for dependencies actually used."""
from pathlib import Path
import hashlib,json,os,re,runpy,shutil,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]

def check_profiles(folder):
    for path in Path(folder).rglob('*'):
        if path.is_file() and path.suffix in {'.profraw','.profdata'} and path.stat().st_size:
            raise ValueError('Nonempty LLVM profile is not a release resource: '+path.name)

def check_binary(path, check_paths=True):
    path=Path(path)
    if not path.is_file():raise ValueError('Missing source-built worker: '+str(path))
    sections=subprocess.check_output(['xcrun','otool','-l',str(path)],text=True)
    section=None
    for line in sections.splitlines():
        fields=line.split()
        if fields[:1]==['sectname']:section=fields[1]
        if fields[:1]==['size'] and section and section.startswith(('__llvm_cov','__llvm_prf')):
            if int(fields[1],0):raise ValueError('Nonempty LLVM coverage/profile section in '+path.name+': '+section)
    if check_paths and (b'/' + b'Users/') in path.read_bytes():raise ValueError('Binary contains personal absolute paths: '+path.name)
    if b'default.profraw' in path.read_bytes():raise ValueError('LLVM profile runtime remains in '+path.name)

def normalize_rpaths(binary):
    # SwiftPM can embed developer-toolchain/cryptex paths in release workers.
    # Compatibility runtimes are shipped adjacent; no other Mac needs those
    # machine-specific fallback paths. Dynamic load identities are checked later.
    commands=subprocess.check_output(['xcrun','otool','-l',str(binary)],text=True)
    for path in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset',commands):
        if path.startswith('/') and path!='/usr/lib/swift':
            subprocess.run(['xcrun','install_name_tool','-delete_rpath',path,str(binary)],check=True)

def verify_runtime(out,workers):
    # swift-stdlib-tool copies deployment-required Swift runtimes. Verify every
    # compatibility dependency is loader-visible rather than trusting copy success.
    binaries=[*(out/p.name for p in workers),*(out/'SwiftRuntime').glob('*.dylib')]
    for binary in binaries:
        loads=subprocess.check_output(['xcrun','otool','-L',str(binary)],text=True)
        for name in re.findall(r'@rpath/(libswiftCompatibility[^\s/]+\.dylib)',loads):
            if not (out/'SwiftRuntime'/name).is_file():
                raise ValueError('Missing loader-visible Swift compatibility runtime: '+name)

def main():
    out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=False)
    record=json.loads((ROOT/'.build/worker-build.json').read_text())
    mlx=Path(record['mlxDerivedData'])/'Build/Products/Release/VectaMLX'
    workers=[Path(record['speechBuild'])/'release/VectaSpeech',mlx]
    verifier=runpy.run_path(str(ROOT/'Tools/build-workers.py'),run_name='vecta_worker_verifier')
    for identity,inputs in record['speechInputs'].items():
        pin=next(p['state']['revision'] for p in json.loads((ROOT/'Package.resolved').read_text())['pins'] if p['identity']==identity)
        if verifier['verify_checkout'](Path(record['speechBuild'])/'checkouts'/identity,pin)!=inputs:
            raise ValueError('Speech dependency differs from matching compilation')
    verifier['verify_mlx_sources'](Path(record['mlxDerivedData'])/'SourcePackages')
    for source in workers:
        if hashlib.sha256(source.read_bytes()).hexdigest()!=record['workerOutputs'][source.name]:raise ValueError('Worker differs from completed build: '+source.name)
        # Debug records are stripped from the private copy before its strict
        # path scan. Instrumentation is rejected even in unstripped inputs.
        check_binary(source, check_paths=False)
    check_profiles(mlx.parent)
    for source in workers:
        if not source.is_file():raise SystemExit('Missing source-built worker: '+str(source))
        shutil.copy2(source,out/source.name)
        if hashlib.sha256((out/source.name).read_bytes()).hexdigest()!=record['workerOutputs'][source.name]:raise ValueError('Worker changed during packaging: '+source.name)
        subprocess.run(['xcrun','strip','-S',str(out/source.name)],check=True)
        normalize_rpaths(out/source.name)
        if (b'/' + b'Users/') in (out/source.name).read_bytes():raise SystemExit('Worker contains personal absolute paths; rebuild with prefix mapping: '+source.name)
        subprocess.run(['xcrun','install_name_tool','-add_rpath','@executable_path/SwiftRuntime',str(out/source.name)],check=True)
    runtime=out/'SwiftRuntime';runtime.mkdir()
    subprocess.run(['xcrun','swift-stdlib-tool','--copy','--platform','macosx',*sum((['--scan-executable',str(out/p.name)] for p in workers),[]),'--destination',str(runtime)],check=True)
    for binary in [*(out/p.name for p in workers),*runtime.glob('*.dylib')]:
        check_binary(binary)
        subprocess.run(['codesign','--force','--sign',os.environ.get('VECTA_SIGNING_IDENTITY','-'),str(binary)],check=True)
        subprocess.run(['codesign','--verify','--strict',str(binary)],check=True)
    verify_runtime(out,workers)
    bundles=list(mlx.parent.glob('*.bundle'))
    if not any(list(b.rglob('*.metallib')) for b in bundles):raise SystemExit('MLX Metal resources are missing.')
    for bundle in bundles:shutil.copytree(bundle,out/bundle.name)
    resources={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for bundle in out.glob('*.bundle') for p in sorted(bundle.rglob('*')) if p.is_file()}
    if resources!=record['mlxResources']:raise ValueError('MLX resources differ from completed build')
    shutil.copy2(ROOT/'AI/Resources/models-mlx.json',out/'models.json')
    notices=out/'Licenses';notices.mkdir()
    for base in [Path(record['speechBuild'])/'checkouts',Path(record['mlxDerivedData'])/'SourcePackages/checkouts']:
        if not base.exists():continue
        for dependency in sorted(base.iterdir()):
            if not dependency.is_dir():continue
            # MLX embeds metal-cpp, fmt, mlx-c and nlohmann JSON; swift-crypto
            # embeds BoringSSL. Their own nested licenses are not replaced by
            # the enclosing Swift package's license.
            for source in sorted(dependency.rglob('*')):
                relative=source.relative_to(dependency)
                if any(part in {'.git','.build','.swiftpm'} for part in relative.parts):continue
                if not source.name.upper().startswith(('LICENSE','COPYING','NOTICE','COPYRIGHT')):continue
                if source.suffix.lower() not in {'','.txt','.md','.mit','.apache','.bsd'}:continue
                if source.is_symlink():raise ValueError('Linked dependency notice')
                if source.is_file():shutil.copy2(source,notices/(dependency.name+'-'+str(relative).replace('/','-')))
    codec=Path(os.environ.get('VECTA_CODEC_BUILD_ROOT',str(ROOT/'.build/native-codecs')))/'install/licenses'
    if not codec.exists():raise SystemExit('Codec notices are missing.')
    for source in codec.iterdir():
        if source.is_file():shutil.copy2(source,notices/source.name)
    for source in (ROOT/'Licenses').iterdir():
        if source.is_file():shutil.copy2(source,notices/source.name)
    shutil.copy2(ROOT/'LICENSE',notices/'Vecta-LICENSE')
    check_profiles(out)
    if not any('argmax' in p.name and p.name.endswith('-NOTICES') for p in notices.iterdir()):raise SystemExit('Required Argmax NOTICES missing; do not distribute this package.')
    manifest={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.rglob('*')) if p.is_file()}
    (out/'resources-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')

if __name__=='__main__':main()
