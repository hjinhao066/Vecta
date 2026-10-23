#!/usr/bin/env python3
"""Verify an actual source-built release bundle and exercise matching LAME relink."""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import os
import plistlib
import re
import runpy
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            value.update(block)
    return value.hexdigest()


def require(value, message):
    if not value:
        raise ValueError(message)


def inventory(folder):
    result = {}
    for path in sorted(Path(folder).rglob('*')):
        if path.is_symlink():
            result[path.relative_to(folder).as_posix()] = {'link': os.readlink(path)}
        elif path.is_file():
            result[path.relative_to(folder).as_posix()] = {'sha256': digest(path), 'mode': path.stat().st_mode & 0o777}
    return result


def signing_information(binary):
    display = subprocess.run(['codesign', '-d', '--verbose=4', str(binary)], capture_output=True, text=True, check=True)
    details = display.stdout + display.stderr
    authorities = [line.removeprefix('Authority=') for line in details.splitlines() if line.startswith('Authority=')]
    if 'Signature=adhoc' in details:
        kind = 'ad-hoc'
    elif any(name.startswith('Developer ID Application:') for name in authorities):
        kind = 'developer-id-application'
    elif any(name.startswith(('Apple Development:', 'Mac Developer:')) for name in authorities):
        kind = 'apple-development'
    else:
        kind = 'certificate-signed'
    team = next((line.removeprefix('TeamIdentifier=') for line in details.splitlines() if line.startswith('TeamIdentifier=')), None)
    requirement = subprocess.run(['codesign', '-d', '-r-', str(binary)], capture_output=True, text=True, check=True)
    text = requirement.stdout + requirement.stderr
    designated = next((line.split('=>', 1)[1].strip() for line in text.splitlines() if 'designated =>' in line), None)
    require(designated, 'Missing designated code-signing requirement')
    return {'signature': kind, 'teamIdentifier': None if team == 'not set' else team, 'designatedRequirement': designated}


def verify_manifest(folder, filename):
    values = json.loads((folder/filename).read_text())
    files = {name: value for name, value in values.items() if name != 'toolchain'}
    for name, value in files.items():
        relative = PurePosixPath(name)
        require(not relative.is_absolute() and '..' not in relative.parts, 'Unsafe manifest entry')
        path = folder/name
        require(not path.is_symlink() and path.is_file() and digest(path) == value, 'Manifest mismatch: '+name)
    actual = {p.relative_to(folder).as_posix() for p in folder.rglob('*') if p.is_file()}
    require(actual == set(files) | {filename}, 'Unmanifested package input')
    return len(files)


def check_loads(binary, app):
    archs = set(subprocess.check_output(['xcrun', 'lipo', '-archs', str(binary)], text=True).split())
    # swift-stdlib-tool copies Apple's universal compatibility runtime. Only
    # those packaged dylibs may retain extra slices; our executables stay arm64.
    runtime = binary.parent == app/'Contents/Resources/LocalAI/SwiftRuntime' and binary.suffix == '.dylib'
    require('arm64' in archs if runtime else archs == {'arm64'}, 'Non-arm64 binary: '+binary.name)
    loads = subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True)
    for line in loads.splitlines()[1:]:
        name = line.strip().split(' (')[0]
        if name.startswith(('/usr/lib/', '/System/Library/')):
            continue
        if name.startswith('@rpath/'):
            leaf = name.removeprefix('@rpath/')
            require(any((p/leaf).is_file() for p in (binary.parent/'SwiftRuntime', binary.parent, app/'Contents/Frameworks')), 'Unresolved dynamic dependency: '+name)
        elif name.startswith('@executable_path/'):
            require((binary.parent/name.removeprefix('@executable_path/')).is_file(), 'Unresolved executable dependency')
        else:
            raise ValueError('External/absolute dynamic dependency: '+name)
    commands = subprocess.check_output(['xcrun', 'otool', '-l', str(binary)], text=True)
    for path in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands):
        require(path.startswith(('@executable_path/', '@loader_path/')) or path in {'/usr/lib/swift','@loader_path','@executable_path'}, 'Nonportable runtime search path')


def verify(build):
    app = build/'Vecta.app'
    pack = runpy.run_path(str(ROOT/'Tools/package-workers.py'))
    builder = runpy.run_path(str(ROOT/'Tools/build.py'))
    kit = runpy.run_path(str(ROOT/'Tools/make-relink-kit.py'))
    require(json.loads((build/'source-manifest.json').read_text()) == builder['source_snapshot'](), 'Candidate source changed')
    metadata = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    require(metadata['CFBundleIdentifier'] == 'app.vecta.mac' and metadata['CFBundleExecutable'] == 'Vecta', 'Bundle identity mismatch')
    require(metadata['LSMinimumSystemVersion'] == '15.0', 'Full local-AI release requires macOS 15+')
    require(metadata['CFBundleDevelopmentRegion'] == 'en' and set(metadata['CFBundleLocalizations']) == {'en', 'ru'}, 'Localization metadata mismatch')
    identity = json.loads((build/'link-integrity.json').read_text())
    require(not identity['configuration']['development'] and not identity['configuration']['frontendOnly'], 'Development build is not a release')
    kit['matching_link'](build, json.loads((build/'codec-integrity.json').read_text()))
    resources = app/'Contents/Resources'
    workers = resources/'LocalAI'
    require(not any(p.name == 'VectaQwen' for p in app.rglob('*')), 'Legacy executable present')
    require(not (resources/'DEVELOPMENT-ONLY.txt').exists(), 'Development resources present')
    counts = {folder.name: verify_manifest(folder, filename) for folder, filename in [(workers, 'resources-manifest.json'), (build/'relink-kit', 'SHA256.json')]}
    localized = []
    for name in ('Localization', 'en.lproj', 'ru.lproj'):
        before, after = inventory(ROOT/'App/Resources'/name), inventory(resources/name)
        require(before and before == after, 'Localized resources differ: '+name)
        localized.extend(name+'/'+p for p in before)
    for language in ('en', 'ru'):
        subprocess.run(['plutil', '-lint', str(resources/(language+'.lproj/InfoPlist.strings'))], check=True)
    executable = app/'Contents/MacOS/Vecta'
    data = executable.read_bytes()
    for flag in (b'--verify-application-lifecycle', b'--verify-summary-options', b'--verify-reset-policy', b'--verify-library-ownership', b'--verify-performance-state', b'--verify-fast-transfer-availability', b'--verify-fast-transfer-ui', b'--verify-performance-refresh', b'--verify-saved-detail-preparation', b'--verify-language-restart-policy', b'--verify-welcome', b'--verify-speaker-merge', b'--verify-speaker-ui', b'--verify-public-demo', b'--verify-recording-card', b'--verify-playback-keyboard', b'--verify-library-search', b'--verify-model-download-host'):
        require(flag not in data, 'Development harness remains')
    worker_paths = [workers/name for name in ('VectaSpeech', 'VectaMLX')]
    for binary in [executable, *worker_paths, *(workers/'SwiftRuntime').glob('*.dylib')]:
        pack['check_binary'](binary)
        check_loads(binary, app)
        require(binary.suffix == '.dylib' or os.access(binary, os.X_OK), 'Missing executable permission')
        subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
    pack['verify_runtime'](workers, worker_paths); pack['check_profiles'](workers)
    require(any(workers.rglob('*.metallib')), 'MLX Metal resources missing')
    registry = json.loads((workers/'models.json').read_text())
    require({m['id'] for m in registry['models']} == {'whisper', 'speaker', 'tokenizer', 'gigaam', 'qwen4b', 'qwen9b'}, 'Unexpected production model registry')
    require(all(m.get('backend') == 'mlx' for m in registry['models'] if m['id'].startswith('qwen') or m['id'] == 'gigaam'), 'Non-MLX production backend')
    forbidden = {'.gguf', '.safetensors', '.mp3', '.wav', '.m4a', '.sqlite', '.db', '.profraw', '.pem', '.key', '.log'}
    for path in app.rglob('*'):
        require(not path.is_symlink(), 'Unexpected app bundle link')
        require(path.suffix.lower() not in forbidden and path.name not in {'authorization.json', 'backend.env', '.env'}, 'Private asset in app bundle')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], check=True)
    exits = {}
    for worker in worker_paths:
        with tempfile.TemporaryDirectory(prefix='vecta-worker-check-') as temporary:
            result = subprocess.run(['/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)', str(worker)], cwd=temporary, env={'PATH': '/usr/bin:/bin'}, input=b'', stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            require(result.returncode == 1, 'Unexpected missing-input worker exit: '+worker.name)
            require(not list(Path(temporary).rglob('*.profraw')), 'Worker created a profile')
            exits[worker.name] = result.returncode
    relinked = build/('relinked-Vecta-'+uuid.uuid4().hex)
    subprocess.run(['bash', str(build/'relink-kit/relink.sh'), str(build/'relink-kit/codec-libs/libmp3lame.a'), str(relinked)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(relinked)], check=True)
    signing = signing_information(executable)
    summary = {'version': metadata['CFBundleShortVersionString'], 'build': metadata['CFBundleVersion'], 'nondevelopment': True, 'sourceMatches': True, 'linkMatches': True, 'hashCounts': counts, 'localizedResources': localized, 'binaryPrivacyRuntime': 'PASS', 'workerMissingInputExit': exits, 'actualRelink': 'PASS', 'physicalHardware': 'NOT TESTED', 'realModelInference': 'NOT TESTED', 'cleanUserInstallation': 'NOT TESTED', 'developerID': signing['signature'] == 'developer-id-application', 'signing': signing, 'notarized': False, 'installed': False}
    (build/'verification-summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps(summary, sort_keys=True))
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('build', type=Path)
    args = parser.parse_args()
    verify(args.build.resolve())
