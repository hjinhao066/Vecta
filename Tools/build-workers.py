#!/usr/bin/env python3
"""Build only local Speech and MLX workers; never download model weights."""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
def run(*args,cwd=ROOT):subprocess.run([str(a) for a in args],cwd=cwd,check=True)
def verify_checkout(checkout, expected):
    """Verify all tracked bytes against the pinned tree; reject even ignored extras.

    Builds are out-of-tree, so no untracked checkout inputs are approved. No fetch,
    reset, clean or checkout is performed: inherited work remains untouched.
    """
    checkout=Path(checkout)
    if not checkout.is_dir():raise ValueError('Missing pinned dependency checkout; provision it explicitly before an offline build.')
    def git(*args):
        return subprocess.check_output(['git','-C',str(checkout),*args])
    if git('rev-parse','HEAD').decode().strip()!=expected:
        raise ValueError('dependency checkout differs from the pinned revision; preserve it.')
    if git('status','--porcelain','--untracked-files=all','--ignored'):
        raise ValueError('dependency has modified/unapproved build inputs; preserve the checkout.')
    result={}
    for entry in git('ls-tree','-rz',expected).split(b'\0'):
        if not entry:continue
        metadata,name=entry.split(b'\t',1)
        mode,kind,oid=metadata.split()
        path=checkout/os.fsdecode(name)
        if kind!=b'blob' or mode not in (b'100644',b'100755',b'120000'):
            raise ValueError('Unsupported submodule dependency build input')
        expected_data=git('cat-file','blob',oid.decode())
        if mode==b'120000':
            if not path.is_symlink():raise ValueError('Missing pinned dependency link')
            target=os.readlink(path)
            if os.fsencode(target)!=expected_data or Path(target).is_absolute() or not path.resolve().is_relative_to(checkout.resolve()) or not path.exists():
                raise ValueError('Unapproved/external dependency link')
            # Immutable upstream links are allowed only within their own
            # authenticated tree; targets are separately verified below.
            result[os.fsdecode(name)]=hashlib.sha256(expected_data).hexdigest()
            continue
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents) or not path.is_file():
            raise ValueError('Missing/linked dependency build input')
        data=path.read_bytes()
        if data!=expected_data:
            raise ValueError('dependency tracked input differs from pinned content: '+os.fsdecode(name))
        if bool(path.stat().st_mode & 0o111)!=(mode==b'100755'):
            raise ValueError('dependency tracked input mode differs from pinned tree')
        result[os.fsdecode(name)]=hashlib.sha256(data).hexdigest()
    return result

def mlx_pins():
    resolved=json.loads((ROOT/'AI/MLX/Package.resolved').read_text())
    return {pin['identity'].casefold():pin['state']['revision'] for pin in resolved['pins']}

def verify_mlx_sources(source_packages):
    source_packages=Path(source_packages)
    checkouts=source_packages/'checkouts'
    expected=mlx_pins()
    if not checkouts.is_dir() or checkouts.is_symlink():
        raise ValueError('Missing fresh MLX source package checkouts.')
    actual={path.name.casefold():path for path in checkouts.iterdir() if path.is_dir() and not path.is_symlink()}
    if set(actual)!=set(expected):
        raise ValueError('MLX source package checkout set differs from Package.resolved.')
    for identity,revision in expected.items():
        checkout=actual[identity]
        def git(*args):
            return subprocess.check_output(['git','-C',str(checkout),*args])
        if git('rev-parse','HEAD').decode().strip()!=revision:
            raise ValueError('MLX source package differs from Package.resolved: '+identity)
        if git('status','--porcelain','--untracked-files=all','--ignored'):
            raise ValueError('MLX source package has modified/unapproved inputs: '+identity)
        for line in git('submodule','status','--recursive').splitlines():
            if not line.startswith(b' '):
                raise ValueError('MLX source package has uninitialized/modified submodule: '+identity)
    return {identity:expected[identity] for identity in sorted(expected)}

def speech_cache_args():
    cache=os.environ.get('VECTA_DEPENDENCY_CACHE')
    return ['--cache-path',str(Path(cache)/'swift'),'--enable-dependency-cache','--manifest-cache','local'] if cache else ['--disable-dependency-cache','--manifest-cache','local']

def mlx_cache_args():
    cache=os.environ.get('VECTA_DEPENDENCY_CACHE')
    return ['-packageCachePath',str(Path(cache)/'xcode')] if cache else ['-disablePackageRepositoryCache']

def resolve_mlx_sources(source_packages):
    source_packages=Path(source_packages)
    run('xcodebuild','-resolvePackageDependencies','-scheme','VectaMLX',
        '-clonedSourcePackagesDirPath',source_packages,'-skipMacroValidation','-skipPackageUpdates',*mlx_cache_args(),
        '-disableAutomaticPackageResolution','-onlyUsePackageVersionsFromResolvedFile',cwd=ROOT/'AI/MLX')
    mlx=source_packages/'checkouts'/'mlx-swift'
    expected=mlx_pins().get('mlx-swift')
    if expected is None or not mlx.is_dir():
        raise ValueError('Missing pinned mlx-swift checkout.')
    if subprocess.check_output(['git','-C',str(mlx),'rev-parse','HEAD']).decode().strip()!=expected:
        raise ValueError('mlx-swift checkout differs from Package.resolved.')
    run('git','-C',mlx,'submodule','update','--init','--recursive')
    return verify_mlx_sources(source_packages)

def main():
    (ROOT/'.build').mkdir(parents=True,exist_ok=True)
    speech=Path(tempfile.mkdtemp(prefix='speech-release-',dir=ROOT/'.build'))
    run('swift','build','--scratch-path',speech,*speech_cache_args(),'--force-resolved-versions',
        '-c','release','--product','VectaSpeech','--jobs','4','-Xswiftc','-module-cache-path','-Xswiftc',speech/'ModuleCache','-Xlinker','-headerpad_max_install_names',
        '-Xswiftc','-file-prefix-map','-Xswiftc',f'{ROOT}=Vecta',
        '-Xswiftc','-debug-prefix-map','-Xswiftc',f'{ROOT}=Vecta',
        '-Xcc',f'-ffile-prefix-map={ROOT}=Vecta','-Xcc',f'-fdebug-prefix-map={ROOT}=Vecta')
    speech_pins=json.loads((ROOT/'Package.resolved').read_text())['pins']
    speech_inputs={pin['identity']:verify_checkout(speech/'checkouts'/pin['identity'],pin['state']['revision']) for pin in speech_pins}
    remap=f'-ffile-prefix-map={ROOT}=Vecta -fdebug-prefix-map={ROOT}=Vecta'
    # The macro dependency is part of the reviewed revision-pinned MLX tree.
    # Scope trust to this build invocation; do not change global Xcode settings.
    (ROOT/'AI/MLX/.build').mkdir(parents=True,exist_ok=True)
    derived=Path(tempfile.mkdtemp(prefix='release-',dir=ROOT/'AI/MLX/.build'))
    source_packages=derived/'SourcePackages'
    resolve_mlx_sources(source_packages)
    run('xcodebuild','-scheme','VectaMLX','-configuration','Release','-destination','platform=macOS','-derivedDataPath',derived,'-clonedSourcePackagesDirPath',source_packages,'-skipMacroValidation','-skipPackageUpdates',*mlx_cache_args(),'-disableAutomaticPackageResolution','-onlyUsePackageVersionsFromResolvedFile','ENABLE_CODE_COVERAGE=NO','CLANG_ENABLE_CODE_COVERAGE=NO','GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO','GCC_GENERATE_TEST_COVERAGE_FILES=NO','SWIFT_ENABLE_CODE_COVERAGE=NO','OTHER_LDFLAGS=$(inherited) -Xlinker -headerpad_max_install_names',f'OTHER_SWIFT_FLAGS=$(inherited) -file-prefix-map {ROOT}=Vecta -debug-prefix-map {ROOT}=Vecta',f'OTHER_CFLAGS=$(inherited) {remap}',f'OTHER_CPLUSPLUSFLAGS=$(inherited) {remap}','build',cwd=ROOT/'AI/MLX')
    verify_mlx_sources(source_packages)
    products=derived/'Build/Products/Release'
    workers=[speech/'release/VectaSpeech',products/'VectaMLX']
    outputs={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in workers}
    resources={str(p.relative_to(products)):hashlib.sha256(p.read_bytes()).hexdigest() for bundle in products.glob('*.bundle') for p in sorted(bundle.rglob('*')) if p.is_file()}
    (ROOT/'.build/worker-build.json').write_text(json.dumps({'mlxDerivedData':str(derived),'speechBuild':str(speech),'speechInputs':speech_inputs,'workerOutputs':outputs,'mlxResources':resources},indent=2)+'\n')
    print('All local workers built from source; model weights were not downloaded.')
if __name__=='__main__':main()
