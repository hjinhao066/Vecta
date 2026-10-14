#!/usr/bin/env python3
"""Verify pinned codec source and a write-once, complete installed-input seal.

A legacy archive-only manifest cannot attest to previously consumed headers.
Never reseal such a cache: preserve it and build into a new, empty cache root.
Hashes detect accidental/tampered inputs, not a hostile signer/toolchain.
"""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import os
import stat
import tarfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = 'archive-integrity.json'  # Retain location, explicitly version schema.
STARTED = '.new-codec-build.json'
COMPLETED = '.codec-sealed.json'
SOURCES = {
    'opus-1.5.2': ('tar.gz', '65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1'),
    'lame-3.100': ('tar.gz', 'ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e'),
    'libogg-1.3.5': ('tar.xz', 'c4d91be36fc8e54deae7575241e03f4211eb102afb3fc0775fbbc1b740016705'),
    'libvorbis-1.3.7': ('tar.xz', 'b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b'),
}
ARCHIVES = ('libopus.a', 'libmp3lame.a', 'libvorbisfile.a', 'libvorbis.a', 'libogg.a')
HEADERS = (
    'opus/opus.h', 'opus/opus_custom.h', 'opus/opus_defines.h',
    'opus/opus_multistream.h', 'opus/opus_projection.h', 'opus/opus_types.h',
    'lame/lame.h', 'ogg/ogg.h', 'ogg/os_types.h', 'ogg/config_types.h',
    'vorbis/codec.h', 'vorbis/vorbisenc.h', 'vorbis/vorbisfile.h',
)
REQUIRED = ({'lib/' + p for p in ARCHIVES} | {'include/' + p for p in HEADERS} |
            {'build-flags.txt', 'licenses/opus-COPYING', 'licenses/lame-COPYING',
             'licenses/libogg-COPYING', 'licenses/libvorbis-COPYING'})
TOOL_INPUTS = ('Packages/VectaTransport/build-native-codecs.sh', 'Tools/verify-codec-cache.py')
FRESH_MESSAGE = 'Preserve this cache and choose a new, empty VECTA_CODEC_BUILD_ROOT; no historical verification/resealing is allowed.'


def unlinked(path):
    """Reject links in the complete path, including directory ancestors."""
    path = Path(os.path.abspath(path))
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ValueError('Linked codec path: ' + str(component))
    return path


def digest(path):
    path = unlinked(path)
    if not path.is_file():
        raise ValueError('Missing regular codec input: ' + str(path))
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def archive_path(root, name):
    suffix, _ = SOURCES[name]
    return Path(root) / 'downloads' / name / (name + '.' + suffix)


def source_path(root, name):
    return Path(root) / 'sources' / name / name


def members(bundle, name):
    seen = set()
    for member in bundle:
        path = PurePosixPath(member.name)
        if (not path.parts or path.parts[0] != name or path.is_absolute() or
                '..' in path.parts or '\\' in member.name or
                str(path) != member.name.rstrip('/') or str(path) in seen):
            raise ValueError('Unexpected/duplicate codec archive path')
        seen.add(str(path))
        if not (member.isdir() or member.isfile()):
            raise ValueError('Codec archive includes a linked/nonregular source entry')
        yield member, path.parts


def verified_archive(archive, name):
    if name not in SOURCES or digest(archive) != SOURCES[name][1]:
        raise ValueError('Codec archive does not match pinned source: ' + name)


def verify_source(archive, source):
    source = unlinked(source)
    verified_archive(archive, source.name)
    count = 0
    with tarfile.open(archive) as bundle:
        for member, parts in members(bundle, source.name):
            target = unlinked(source.joinpath(*parts[1:]))
            if member.isdir():
                if not target.is_dir():
                    raise ValueError('Missing codec source directory: ' + member.name)
                continue
            if not target.is_file():
                raise ValueError('Missing cached codec source: ' + member.name)
            expected = bundle.extractfile(member).read()
            actual = target.read_bytes()
            permitted = [expected]
            if source.name == 'libvorbis-1.3.7' and parts[1:] == ('configure',):
                permitted.append(expected.replace(b'-force_cpusubtype_ALL', b''))
            if actual not in permitted:
                raise ValueError('Cached codec source differs from pinned archive: ' + member.name)
            count += 1
    if not count:
        raise ValueError('Empty codec source archive')
    return count


def extract_source(archive, destination, name):
    destination = unlinked(destination)
    verified_archive(archive, name)
    if not destination.is_dir() or any(destination.iterdir()):
        raise ValueError('Extraction requires its own new, empty directory')
    # Validate the whole archive before writing. Do not execute anything here.
    with tarfile.open(archive) as bundle:
        entries = list(members(bundle, name))
        for member, parts in entries:
            target = unlinked(destination.joinpath(*parts))
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open('xb') as output, bundle.extractfile(member) as input_file:
                    for chunk in iter(lambda: input_file.read(1024 * 1024), b''):
                        output.write(chunk)
                target.chmod(member.mode & 0o777)


def installed_files(prefix):
    prefix = unlinked(prefix)
    if not prefix.is_dir():
        raise ValueError('Missing installed codec cache. ' + FRESH_MESSAGE)
    values = {}
    for directory, dirs, files in os.walk(prefix, followlinks=False):
        for name in dirs + files:
            path = unlinked(Path(directory) / name)
            mode = path.stat().st_mode
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise ValueError('Nonregular installed codec input: ' + str(path))
        for name in files:
            path = Path(directory) / name
            relative = path.relative_to(prefix).as_posix()
            if relative != MANIFEST:
                values[relative] = digest(path)
    missing = REQUIRED - values.keys()
    if missing:
        raise ValueError('Incomplete installed codec inputs: ' + ', '.join(sorted(missing)) + '. ' + FRESH_MESSAGE)
    return dict(sorted(values.items()))


def build_inputs():
    return {p: digest(ROOT / p) for p in TOOL_INPUTS}


def install_manifest(prefix):
    return {'version': 2, 'files': installed_files(prefix), 'build_inputs': build_inputs(),
            'sources': {name: spec[1] for name, spec in SOURCES.items()}}


def verify_install(prefix):
    prefix = unlinked(prefix)
    manifest = unlinked(prefix / MANIFEST)
    if not manifest.is_file():
        raise ValueError('Codec cache has no complete installed-input integrity manifest. ' + FRESH_MESSAGE)
    expected = json.loads(manifest.read_text())
    if (not isinstance(expected, dict) or set(expected) != {'version', 'files', 'build_inputs', 'sources'} or
            expected.get('version') != 2):
        raise ValueError('Legacy/incomplete codec integrity manifest cannot verify historical headers. ' + FRESH_MESSAGE)
    if (not isinstance(expected['files'], dict) or
            any(not isinstance(p, str) or not isinstance(h, str) or len(h) != 64
                for p, h in expected['files'].items())):
        raise ValueError('Invalid installed codec file integrity map. ' + FRESH_MESSAGE)
    actual = install_manifest(prefix)
    if actual != expected:
        changed = set(actual['files']) ^ set(expected.get('files', {}))
        changed.update(p for p, h in actual['files'].items() if expected.get('files', {}).get(p) != h)
        detail = ', '.join(sorted(changed)) or 'source/build input identity'
        raise ValueError('Cached codec installed input changed: ' + detail + '. ' + FRESH_MESSAGE)
    return expected


def verify_cache(root):
    root = unlinked(root)
    verify_install(root / 'install')  # Fail before source access or any downloads.
    completed = unlinked(root / COMPLETED)
    if (not completed.is_file() or json.loads(completed.read_text()) !=
            {'version': 1, 'manifest_sha256': digest(root / 'install' / MANIFEST)}):
        raise ValueError('Missing/changed first-build completion evidence. ' + FRESH_MESSAGE)
    for name in SOURCES:
        verify_source(archive_path(root, name), source_path(root, name))


def seal_install(prefix, root):
    prefix, root = unlinked(prefix), unlinked(root)
    if (prefix / MANIFEST).exists() or (prefix / MANIFEST).is_symlink():
        raise ValueError('Refusing to overwrite/reseal codec integrity manifest. ' + FRESH_MESSAGE)
    if prefix != root / 'install':
        raise ValueError('Seal must refer to the new build root installation')
    if (root / COMPLETED).exists() or (root / COMPLETED).is_symlink():
        raise ValueError('This cache already completed its first build; no reseal is allowed. ' + FRESH_MESSAGE)
    started = unlinked(root / STARTED)
    if (not started.is_file() or json.loads(started.read_text()) !=
            {'version': 1, 'build_inputs': build_inputs()}):
        raise ValueError('Seal requires a new empty root prepared by this builder. ' + FRESH_MESSAGE)
    # Only a complete new source-verified installation can acquire a first seal.
    for name in SOURCES:
        verify_source(archive_path(root, name), source_path(root, name))
    # Public non-generated headers must be exact copies of verified source.
    for name, source_dir, installed_dir in [
        ('opus-1.5.2', 'include', 'opus'), ('lame-3.100', 'include', 'lame'),
        ('libogg-1.3.5', 'include/ogg', 'ogg'), ('libvorbis-1.3.7', 'include/vorbis', 'vorbis'),
    ]:
        for header in HEADERS:
            if not header.startswith(installed_dir + '/') or header == 'ogg/config_types.h':
                continue  # config_types.h is configure-generated, sealed with other outputs.
            source = source_path(root, name) / source_dir / Path(header).name
            if digest(source) != digest(prefix / 'include' / header):
                raise ValueError('Installed header differs from verified corresponding source: ' + header)
    content = json.dumps(install_manifest(prefix), indent=2) + '\n'
    with (prefix / MANIFEST).open('x') as output:
        output.write(content)
    # Keep a separate write-once completion record: deleting the install manifest
    # must not allow a historical cache to masquerade as a new first build.
    with (root / COMPLETED).open('x') as output:
        json.dump({'version': 1, 'manifest_sha256': digest(prefix / MANIFEST)}, output)
        output.write('\n')


def prepare(root):
    root = unlinked(root)
    if root.exists() and (not root.is_dir() or any(root.iterdir())):
        raise ValueError('An unsealed/legacy/partial codec root is not a fresh build. ' + FRESH_MESSAGE)
    root.mkdir(parents=True, exist_ok=True)
    with (root / STARTED).open('x') as output:
        json.dump({'version': 1, 'build_inputs': build_inputs()}, output)
        output.write('\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    for mode in ('install', 'cache', 'prepare'):
        sub.add_parser(mode).add_argument('path', type=Path)
    source = sub.add_parser('source')
    source.add_argument('archive', type=Path)
    source.add_argument('source', type=Path)
    extract = sub.add_parser('extract')
    extract.add_argument('archive', type=Path)
    extract.add_argument('destination', type=Path)
    extract.add_argument('name', choices=SOURCES)
    seal = sub.add_parser('seal')
    seal.add_argument('prefix', type=Path)
    seal.add_argument('--built-from', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.mode == 'source':
            print('Verified pinned codec source files:', args.source.name, verify_source(args.archive, args.source))
        elif args.mode == 'extract':
            extract_source(args.archive, args.destination, args.name)
        elif args.mode == 'install':
            verify_install(args.path)
            print('Verified installed codec archives, headers, metadata, licenses and build inputs')
        elif args.mode == 'cache':
            verify_cache(args.path)
            print('Verified complete codec source/install cache')
        elif args.mode == 'prepare':
            prepare(args.path)
        else:
            seal_install(args.prefix, args.built_from)
            print('Sealed new source-verified codec installation')
    except (ValueError, OSError, tarfile.TarError) as error:
        raise SystemExit(str(error))


if __name__ == '__main__':
    main()
