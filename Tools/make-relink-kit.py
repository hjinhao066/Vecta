#!/usr/bin/env python3
"""Create an explicit-source/object/codec kit for an already completed build.

CLI: make-relink-kit.py BUILD NEW_KIT_DIRECTORY [--root SOURCE_ROOT].
Requires BUILD/source-manifest.json and BUILD/codec-integrity.json, captured by
the builder before consuming the corresponding source and codec inputs.
"""
from pathlib import Path
import argparse
import hashlib
import io
import json
import os
import runpy
import shutil
import stat
import subprocess
import sys
import tarfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
PUBLIC = runpy.run_path(str(ROOT / 'Tools/check-public-tree.py'), run_name='vecta_public_tree')
CODECS = runpy.run_path(str(ROOT / 'Tools/verify-codec-cache.py'), run_name='vecta_codec_cache')
MODULES = ('Vecta.o', 'libNotePinTransport.a', 'libNotePinAudio.a', 'libCNativeAudio.a')
PROVENANCE = {'LICENSE', 'NOTICE', 'docs/PROVENANCE.md', 'docs/import-ledger.json',
              'docs/path-renames.json', 'docs/type-renames.json', 'docs/DEPENDENCIES.md'}
RELINK = '''#!/bin/bash
set -euo pipefail
kit="$(cd "$(dirname "$0")" && pwd)"
lame="${1:?Provide the rebuilt libmp3lame.a path}"
output="${2:?Provide a new output executable path}"
if [[ -e "$output" || -L "$output" ]]; then echo "Output exists; preserve it." >&2; exit 2; fi
xcrun swiftc -target arm64-apple-macosx13.0 -L "$kit/modules" -lsqlite3 -framework NaturalLanguage "$kit/modules/libNotePinTransport.a" "$kit/modules/libNotePinAudio.a" "$kit/modules/libCNativeAudio.a" "$kit/codec-libs/libopus.a" "$lame" "$kit/codec-libs/libvorbisfile.a" "$kit/codec-libs/libvorbis.a" "$kit/codec-libs/libogg.a" "$kit/modules/Vecta.o" -o "$output"
codesign --force --sign - "$output"
'''
README = '''Vecta LAME source/relink kit

You may modify and relink the LGPL-covered library, including reverse engineering
for debugging those modifications as required by the applicable LGPL terms.
This permission applies regardless of other application license statements.
Retained-source origin and notices are in Vecta-source.tar.gz (LICENSE, NOTICE,
docs/PROVENANCE.md and the import/rename ledgers). No clean-room claim is made.

Requires an Apple Silicon Mac and the matching Xcode/Swift toolchain recorded in
SHA256.json. Application objects and all non-system codec/transport archives,
installed codec headers/licenses, and pinned codec corresponding-source archives
are supplied. Standard Apple frameworks come from Xcode/macOS, not this kit.
Inference workers are separate; their pinned build manifests/scripts and retained
notices remain in the source tree and matching app bundle.

Unpack Vecta-source.tar.gz and use Packages/VectaTransport/build-native-codecs.sh
with its Tools/verify-codec-cache.py and a NEW VECTA_CODEC_BUILD_ROOT. The codec
builder downloads pinned sources if needed; downloads are not necessary to modify
and relink LAME using the included lame-3.100.tar.gz. Legacy archive-only caches
cannot prove historical header integrity and are intentionally not upgraded.

For a modified LAME, unpack lame-3.100.tar.gz into a new empty directory. Configure
out-of-tree in a separate empty build directory (absolute source path below):
  bash /absolute/source/lame-3.100/configure --prefix=/new/modified-lame-install \\
    --disable-shared --enable-static --disable-frontend --disable-decoder
  make -j 4
  make install
Use matching architecture, macOS deployment target 13.0 and toolchain. The normal
cache checker rejects altered source; do not try to reseal an old production cache.
Then run:
  bash relink.sh /new/modified-lame-install/lib/libmp3lame.a /new/path/Vecta

Use a copy of the matching Vecta.app. Replace Contents/MacOS/Vecta with your
relinked executable and ad-hoc sign that copy. Preserve the original app and user
data. Developer ID/notarization signatures no longer describe a modified bundle.
Modified builds are your locally signed development copies.

SHA256.json is a content inventory, not a cryptographic release attestation.
codec-integrity.json records the matching compiled-input cache identity.
link-integrity.json binds exact module/archive bytes to the completed executable,
configuration, linker command and toolchain. These are content identities, not
a signed attestation of an untrusted builder.
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def regular(path):
    path = CODECS['unlinked'](path)
    if not path.is_file() or not stat.S_ISREG(path.stat().st_mode):
        raise ValueError('Missing/nonregular relink input: ' + str(path))
    return path


def snapshot_sources(root, build, files):
    manifest = regular(build / 'source-manifest.json')
    snapshot = json.loads(manifest.read_text())
    if not isinstance(snapshot, dict):
        raise ValueError('Invalid build source manifest')
    approved = set(files)
    # Same minimum closure as build.py; a builder may snapshot more reviewed
    # documentation/provenance, but never omit executable/source-build inputs.
    required = {p for p in files if p.split('/')[0] in
                {'App', 'Domain', 'Storage', 'AI', 'Packages', 'Tools', 'Tests'} or
                p in {'Package.swift', 'Package.resolved'}}
    if not required <= snapshot.keys() or not snapshot.keys() <= approved:
        raise ValueError('Build manifest lacks approved inputs or includes unapproved paths; rebuild from the reviewed source tree')
    for name, expected in snapshot.items():
        PUBLIC['canonical_relative'](name)
        if not isinstance(expected, str) or len(expected) != 64 or sha(regular(root / name).read_bytes()) != expected:
            raise ValueError('Source differs from matching executable: ' + name)
    return snapshot


def archive_sources(root, files, destination, snapshot):
    """Archive only reviewed paths and the exact bytes checked against the build."""
    with tarfile.open(destination, 'w:gz') as archive:
        for name in files:
            path = regular(root / name)
            data = path.read_bytes()
            errors = PUBLIC['source_byte_errors'](name, data)
            if errors:
                raise ValueError('\n'.join(errors))
            if name in snapshot and sha(data) != snapshot[name]:
                raise ValueError('Source changed during kit creation: ' + name)
            info = tarfile.TarInfo('Vecta/' + name)
            info.size = len(data)
            info.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
            info.mtime = 0
            archive.addfile(info, io.BytesIO(data))


def checked_copy(source, destination, expected=None):
    source = regular(source)
    data = source.read_bytes()
    if expected is not None and sha(data) != expected:
        raise ValueError('Relink input changed during kit creation: ' + source.name)
    patterns = PUBLIC['PATTERNS']
    # RSA import code contains standalone, NUL-terminated PEM delimiter literals.
    # They are not key material. Any non-standalone marker still fails closed;
    # source archives retain the stricter scan, and token/path rules are unchanged.
    private_key = any(data[match.end():match.end() + 1] != b'\x00' for match in patterns[0].finditer(data))
    if (b'/' + b'Users/') in data or private_key or any(p.search(data) for p in patterns[1:]):
        raise ValueError('Relink input contains possible private content (redacted): ' + source.name)
    with destination.open('xb') as output:
        output.write(data)
    destination.chmod(0o644)


def matching_link(build,identity):
    value=json.loads(regular(build/'link-integrity.json').read_text())
    expected={'modules/'+name for name in MODULES}|{'codec-libs/'+name for name in CODECS['ARCHIVES']}
    if value.get('version')!=1 or set(value.get('inputs',{}))!=expected:
        raise ValueError('Incomplete matching linker input identity; rebuild')
    files={'Vecta.app/Contents/MacOS/Vecta','Vecta.app/Contents/Info.plist','source-manifest.json','codec-integrity.json'}
    if set(value.get('files',{}))!=files or not value.get('command') or not value.get('configuration') or not value.get('toolchain'):
        raise ValueError('Missing executable/configuration/link identity; rebuild')
    for name,expected_hash in value['files'].items():
        if sha(regular(build/name).read_bytes())!=expected_hash:
            raise ValueError('Executable/configuration differs from matching link: '+name)
    for name in MODULES:
        if sha(regular(build/'modules'/name).read_bytes())!=value['inputs']['modules/'+name]:
            raise ValueError('Module differs from matching linker input: '+name)
    for name in CODECS['ARCHIVES']:
        if identity['files']['lib/'+name]!=value['inputs']['codec-libs/'+name]:
            raise ValueError('Codec differs from matching linker input: '+name)
    return value

def build_kit(root, build, out, codec, toolchain=None):
    # Reject links before resolving, including custom output/cache ancestors.
    root = Path(root).resolve()
    build, out, codec = (CODECS['unlinked'](p).resolve() for p in (build, out, codec))
    if out.exists():
        raise ValueError('Choose a new kit directory; existing artifacts are preserved')
    files = PUBLIC['public_files'](root, excluded=(build, out, out / 'Vecta-source.tar.gz', codec))
    if not PROVENANCE <= set(files):
        raise ValueError('Public allowlist omits required retained-source provenance/notices')
    snapshot = snapshot_sources(root, build, files)
    CODECS['verify_cache'](codec)
    identity = CODECS['verify_install'](codec / 'install')
    recorded = json.loads(regular(build / 'codec-integrity.json').read_text())
    if recorded != identity:
        raise ValueError('Selected codec cache differs from the matching compiled-input manifest; rebuild')
    link=matching_link(build,identity)
    out.mkdir(parents=True)
    modules, libs = out / 'modules', out / 'codec-libs'
    modules.mkdir()
    libs.mkdir()
    for name in MODULES:
        checked_copy(build / 'modules' / name, modules / name,link['inputs']['modules/'+name])
    for name in CODECS['ARCHIVES']:
        checked_copy(codec / 'install/lib' / name, libs / name, identity['files']['lib/' + name])
    # Corresponding source for EVERY supplied codec, not just LAME.
    for name, (suffix, expected) in CODECS['SOURCES'].items():
        checked_copy(CODECS['archive_path'](codec, name), out / (name + '.' + suffix), expected)
    for directory in ('include', 'licenses'):
        for name, expected in identity['files'].items():
            if not name.startswith(directory + '/'):
                continue
            destination = out / ('codec-headers' if directory == 'include' else 'codec-licenses') / Path(name).relative_to(directory)
            destination.parent.mkdir(parents=True, exist_ok=True)
            checked_copy(codec / 'install' / name, destination, expected)
    checked_copy(build / 'link-integrity.json', out / 'link-integrity.json')
    checked_copy(build / 'codec-integrity.json', out / 'codec-integrity.json',link['files']['codec-integrity.json'])
    checked_copy(build / 'source-manifest.json', out / 'source-manifest.json',link['files']['source-manifest.json'])
    archive_sources(root, files, out / 'Vecta-source.tar.gz', snapshot)
    (out / 'relink.sh').write_text(RELINK)
    (out / 'relink.sh').chmod(0o755)
    (out / 'README.txt').write_text(README)
    # Final read-only gates detect changes during packaging. Leave failed partial
    # outputs for diagnosis; never present them as verified releasable kits.
    if PUBLIC['public_files'](root, excluded=(build, out, codec)) != files:
        raise ValueError('Public source inventory changed during packaging')
    snapshot_sources(root, build, files)
    if CODECS['verify_install'](codec / 'install') != identity:
        raise ValueError('Codec cache changed during packaging')
    if matching_link(build,identity)!=link:raise ValueError('Link identity changed during kit creation')
    if json.loads((out/'link-integrity.json').read_text())!=link:raise ValueError('Copied link identity changed during kit creation')
    expected_exports = dict(link['inputs'])
    expected_exports.update({name + '.' + suffix: expected for name, (suffix, expected) in CODECS['SOURCES'].items()})
    for name, expected in identity['files'].items():
        for directory, destination in [('include', 'codec-headers'), ('licenses', 'codec-licenses')]:
            if name.startswith(directory + '/'):
                expected_exports[destination + '/' + str(Path(name).relative_to(directory))] = expected
    for name in ['codec-integrity.json', 'source-manifest.json']:
        expected_exports[name] = link['files'][name]
    for name, expected in expected_exports.items():
        if sha(regular(out / name).read_bytes()) != expected:
            raise ValueError('Exported relink input changed during kit creation: ' + name)
    manifest = {p.relative_to(out).as_posix(): sha(regular(p).read_bytes()) for p in sorted(out.rglob('*')) if p.is_file()}
    if any(manifest[name] != expected for name, expected in expected_exports.items()):
        raise ValueError('Exported relink inputs changed during final inventory')
    if toolchain is None:toolchain=link['toolchain']
    if toolchain!=link['toolchain']:raise ValueError('Kit toolchain differs from matching executable identity')
    manifest['toolchain'] = toolchain
    (out / 'SHA256.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    codec = Path(os.environ.get('VECTA_CODEC_BUILD_ROOT', str(args.root / '.build/native-codecs')))
    try:
        print(build_kit(args.root, args.build, args.output, codec))
    except (ValueError, OSError, tarfile.TarError) as error:
        raise SystemExit(str(error))


if __name__ == '__main__':
    main()
