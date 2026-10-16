#!/usr/bin/env python3
"""One local release entrypoint. No install, model download, upload or publication."""
from pathlib import Path
import argparse
import json
import os
import platform
import runpy
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(*args, cwd=ROOT, env=None):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)


def doctor(model_free=False):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('A native Apple Silicon Mac is required; do not build under Rosetta.')
    major = int(platform.mac_ver()[0].split('.')[0])
    if major < 15:
        raise SystemExit('Full local AI requires macOS 15 or later.')
    for tool in ('python3', 'git', 'xcrun', 'xcodebuild', 'swift', 'make', 'curl', 'codesign', 'hdiutil'):
        if not shutil.which(tool):
            raise SystemExit('Missing build tool: ' + tool + '. See docs/BUILD.md.')
    version = subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True)
    import re
    match = re.search(r'Swift version (\d+)\.(\d+)', version)
    minimum = (6, 2) if model_free else (6, 3)
    if not match or tuple(map(int, match.groups())) < minimum:
        raise SystemExit('Select Swift 6.2+ for model-free checks or full Xcode 26.4+ (Swift 6.3+) for MLX Metal builds.')
    if shutil.disk_usage(ROOT).free < 4*1024**3:
        raise SystemExit('At least4 GB free build space is required. Preserve existing outputs/user data; choose a volume with more space.')
    run('xcodebuild', '-version')
    print(version.strip())
    print('PASS build prerequisites. Network fetches pinned dependency sources, never model weights.')


def check(heavy=False):
    run('python3', '-I', ROOT/'Tools/check-public-tree.py')
    run('python3', '-I', ROOT/'Tools/test-packaging.py')
    run('python3', '-I', ROOT/'Tools/check-workflows.py')
    for script in ('Tools/test-core.sh', 'Tests/run-speaker-identity-checks.sh',
                   'Tests/run-native-runtime-checks.sh', 'Tests/run-localization-checks.sh',
                   'Tests/run-prompt-language-checks.sh', 'Tests/run-local-ai-event-cache-checks.sh',
                   'Tests/run-fast-transcription-checks.sh', 'Tests/run-application-settings-checks.sh',
                   'Tests/run-legacy-model-checks.sh', 'Tests/run-mac-recording-checks.sh', 'Tests/run-model-download-checks.sh'):
        run('bash', ROOT/script)
    if heavy:
        fixture = ROOT/'.build'/('native-app-checks-'+uuid.uuid4().hex)
        run('python3', '-I', ROOT/'Tools/build.py', fixture, '--frontend-only', '--development')
        run('python3', '-I', ROOT/'Tools/check-native-app.py', fixture/'Vecta.app')
        record = json.loads((ROOT/'.build/worker-build.json').read_text())
        run('bash', ROOT/'Tests/run-speech-model-configuration-checks.sh', Path(record['speechBuild'])/'release')
        run('swift', 'test', '--package-path', ROOT/'Packages/VectaTransport', '--jobs', '3')
        derived = Path(record['mlxDerivedData'])
        test_derived = Path(tempfile.mkdtemp(prefix='tests-',dir=ROOT/'AI/MLX/.build'))
        run('xcodebuild', '-scheme', 'VectaMLX', '-configuration', 'Release',
            '-destination', 'platform=macOS', '-derivedDataPath', test_derived,
            '-clonedSourcePackagesDirPath', derived/'SourcePackages',
            '-skipMacroValidation', '-skipPackageUpdates', '-disableAutomaticPackageResolution',
            '-onlyUsePackageVersionsFromResolvedFile', 'ENABLE_TESTABILITY=YES', 'ENABLE_CODE_COVERAGE=NO', 'test', cwd=ROOT/'AI/MLX')
    print('PASS requested automated checks. Physical hardware, real model inference and clean-user UI are separate.')


def export_source(destination):
    gate = runpy.run_path(str(ROOT/'Tools/check-public-tree.py'), run_name='release_public')
    files = gate['public_files'](ROOT, excluded=[destination])
    destination.mkdir(parents=True, exist_ok=False)
    for name in files:
        target = destination/name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT/name, target)
    run('python3', '-I', destination/'Tools/check-public-tree.py', cwd=destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    prerequisites = sub.add_parser('doctor')
    prerequisites.add_argument('--model-free', action='store_true', help='Check the Swift 6.2 source-test toolchain without MLX build requirements')
    tests = sub.add_parser('check'); tests.add_argument('--heavy', action='store_true')
    source = sub.add_parser('export'); source.add_argument('output', type=Path)
    for name in ('build', 'clean'):
        build = sub.add_parser(name)
        build.add_argument('output', type=Path)
        build.add_argument('--version', default='0.1.0')
        build.add_argument('--build', default='65')
    args = parser.parse_args()
    if args.action == 'doctor':
        doctor(args.model_free); return
    if args.action == 'check':
        check(args.heavy); return
    out = args.output.absolute()
    if out.exists() or out.is_symlink():
        raise SystemExit('Use a new output path; existing artifacts are preserved.')
    if args.action == 'export':
        export_source(out); return
    doctor()
    out.mkdir(parents=True)
    if args.action == 'clean':
        source = export_source(out/'source')
        # No inherited SwiftPM, codec, worker or module cache. Keep HOME/Keychain
        # unchanged: neither the builder nor tests read an owner profile.
        env = os.environ.copy()
        for key in list(env):
            if key.startswith('VECTA_') or key in ('SWIFT_MODULECACHE_PATH', 'CLANG_MODULE_CACHE_PATH'):
                del env[key]
        env['VECTA_CODEC_BUILD_ROOT'] = str(source/'.build/native-codecs')
        env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(source/'.build/module-cache')
        env['CLANG_MODULE_CACHE_PATH'] = str(source/'.build/clang-cache')
        env['SWIFTPM_TESTS_MODULECACHE'] = str(source/'.build/test-module-cache')
        run('python3', '-I', source/'Tools/release.py', 'build', out/'release',
            '--version', args.version, '--build', args.build, cwd=source, env=env)
        print('PASS isolated public-source build:', out/'release')
        return
    check()
    run('python3', '-I', ROOT/'Tools/build.py', out/'build', '--version', args.version, '--build', args.build)
    check(heavy=True)
    run('python3', '-I', ROOT/'Tools/verify-release.py', out/'build')
    run('python3', '-I', ROOT/'Tools/create-dmg.py', out/'build', out/'artifacts')
    print('Local release artifacts:', out/'artifacts')
    print('Nothing installed, uploaded or published.')


if __name__ == '__main__':
    main()
