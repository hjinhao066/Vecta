#!/usr/bin/env python3
"""Validate the reviewed public manifest, then scan approved bytes as a second gate.

No recursive discovery is used to select archive contents. Unknown entries are
reported by name only: diagnostic/user-data contents are never opened. Custom
build/cache/output paths must be passed as --exclude, regardless of their names.
"""
from pathlib import Path, PurePosixPath
import argparse
import json
import os
import re
import stat
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = 'Tools/public-sources.json'
# Exact locations, not suffix/glob exclusions hiding new files in source roots.
IGNORED = {
    '.git', '.build', '.swiftpm', '.vendor', '.claude', '.vscode',
    'build', 'dist', 'work', 'outputs',
    'AI/MLX/.build', 'AI/MLX/.swiftpm',
    'Packages/VectaTransport/.build', 'Packages/VectaTransport/.swiftpm',
    'Tools/__pycache__',
    'docs/CURRENT_PROJECT_STATE.md', 'docs/AGENT_HANDOFF.md', 'docs/VERIFICATION.md',
}
FORBIDDEN = {
    'PublicBackend', 'Config', 'project.yml', 'PinPoint.xcodeproj',
    'NativeTransport/Sources/ResearchProbe.swift', 'Production/Launcher.swift',
}
PATTERNS = [
    re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    re.compile(rb'gh[pousr]_[A-Za-z0-9]{30,}'),
    re.compile(rb'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'),
    re.compile(rb'github_pat_[A-Za-z0-9_]{40,}'),
    re.compile(rb'xox[baprs]-[A-Za-z0-9-]{20,}'),
    re.compile(rb'AKIA[A-Z0-9]{16}'),
    re.compile(rb'sk-(?:proj-)?[A-Za-z0-9_-]{20,}'),
]
# Match actual macOS home paths, not documentation's bare path-prefix notation
# or historical application-relative Vecta/Users/<identity> schema.
PERSONAL_PATH = re.compile(rb'(?<![A-Za-z0-9_.-])' + b'/' + rb'Users/[A-Za-z0-9_.-][A-Za-z0-9_. -]*/')
PRIVATE_SUFFIXES = {
    '.mp3', '.wav', '.m4a', '.ogg', '.opus', '.flac', '.sqlite', '.sqlite3',
    '.db', '.p12', '.pfx', '.gguf', '.safetensors', '.profraw', '.log',
    '.pem', '.key', '.aiff', '.aif', '.caf', '.aac', '.mp4', '.ckpt', '.pt', '.pth', '.onnx', '.keychain', '.keychain-db',
}
TEXT_SUFFIXES = {'.swift', '.py', '.sh', '.json', '.yml', '.md', '.txt',
                 '.hpp', '.h', '.c', '.cpp', '.hex', '.resolved', '.strings'}


def canonical_relative(name):
    if not isinstance(name, str) or not name or '\\' in name:
        raise ValueError('Manifest path must be a nonempty POSIX relative path')
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or str(path) != name or name == '.':
        raise ValueError('Unsafe/noncanonical manifest path: ' + name)
    return name


def load_manifest(root):
    path = root / MANIFEST
    if (path.is_symlink() or any(p.is_symlink() for p in path.parents if p != root and p.is_relative_to(root))
            or not path.is_file()):
        raise ValueError('Missing or linked explicit public manifest')
    manifest = json.loads(path.read_text())
    if set(manifest) != {'version', 'roots', 'files'} or manifest['version'] != 1:
        raise ValueError('Unsupported public manifest schema')
    files, roots = manifest['files'], manifest['roots']
    if not isinstance(files, list) or not isinstance(roots, list):
        raise ValueError('Manifest files/roots must be lists')
    files = [canonical_relative(p) for p in files]
    roots = [canonical_relative(p) for p in roots]
    if len(files) != len(set(files)) or len(roots) != len(set(roots)):
        raise ValueError('Duplicate public manifest entry')
    if not files or MANIFEST not in files or any('/' in p for p in roots):
        raise ValueError('Manifest must approve itself and declare top-level roots')
    actual_roots = {p.split('/')[0] for p in files if '/' in p}
    if actual_roots != set(roots):
        raise ValueError('Approved roots do not match explicit public file paths')
    return sorted(files)


def source_byte_errors(name, data):
    """Defense-in-depth scan shared with the packager's actual archived bytes."""
    path = PurePosixPath(name)
    suffix = path.suffix.lower()
    errors = []
    if suffix in PRIVATE_SUFFIXES or path.name in {'backend.env', 'authorization.json', '.env'}:
        errors.append(name + ': private/generated asset')
    if any(pattern.search(data) for pattern in PATTERNS):
        errors.append(name + ': possible secret (content redacted)')
    if suffix in TEXT_SUFFIXES or path.name in {'LICENSE', 'NOTICE', '.gitignore'}:
        try:
            data.decode('utf-8')
        except UnicodeDecodeError:
            errors.append(name + ': non-text content in approved text file')
        if b'\x00' in data:
            errors.append(name + ': opaque content in approved text file')
        if PERSONAL_PATH.search(data):
            errors.append(name + ': personal absolute path')
    elif name == 'App/Resources/Vecta.icns':
        if not data.startswith(b'icns') or len(data) < 8 or int.from_bytes(data[4:8], 'big') != len(data):
            errors.append(name + ': unexpected icon resource format')
    else:
        errors.append(name + ': unreviewed resource type')
    if suffix == '.swift' and b'import UIKit' in data:
        errors.append(name + ': iOS product source')
    return errors


def public_files(root=ROOT, excluded=()):
    """Return validated relative paths; raise ValueError on any failed gate.

    This API may be loaded with runpy.run_path(..., run_name='vecta_public_tree').
    Callers MUST pass their resolved custom build/kit/codec output locations.
    """
    root = Path(root).resolve()
    excluded = tuple(Path(p).resolve() for p in excluded)
    if any(root == p or root.is_relative_to(p) for p in excluded):
        raise ValueError('An output exclusion cannot contain the source root')
    files = load_manifest(root)
    approved = set(files)
    directories = {str(parent) for f in files for parent in PurePosixPath(f).parents
                   if str(parent) != '.'}
    errors = []
    found = set()

    def ignored(path, relative):
        return relative in IGNORED or any(
            path.resolve() == p or path.resolve().is_relative_to(p) for p in excluded)

    for name in files:
        path = root / name
        if any(str(parent) in IGNORED for parent in PurePosixPath(name).parents) or ignored(path, name):
            errors.append(name + ': approved source overlaps an excluded output')
    for name in FORBIDDEN:
        if (root / name).exists() or (root / name).is_symlink():
            errors.append(name + ': retired product path')

    def walk(directory):
        with os.scandir(directory) as entries:
            for entry in sorted(entries, key=lambda e: e.name):
                path = Path(entry.path)
                relative = path.relative_to(root).as_posix()
                if ignored(path, relative):
                    continue
                mode = entry.stat(follow_symlinks=False).st_mode
                if stat.S_ISLNK(mode):
                    errors.append(relative + ': symlinks are not allowed in public source')
                elif stat.S_ISDIR(mode):
                    if relative not in directories:
                        errors.append(relative + ': unexpected directory (not reviewed)')
                    else:
                        walk(path)
                elif not stat.S_ISREG(mode):
                    errors.append(relative + ': nonregular source entry')
                elif relative not in approved:
                    errors.append(relative + ': unexpected file (not reviewed)')
                else:
                    found.add(relative)

    walk(root)
    errors.extend(name + ': missing approved source/resource' for name in sorted(approved - found))
    if errors:
        raise ValueError('\n'.join(errors))
    # Only approved, regular files are opened; lexical checks are NOT an allowlist.
    for name in files:
        errors.extend(source_byte_errors(name, (root / name).read_bytes()))
    closure = json.loads((root / 'Tools/app-sources.json').read_text())
    if not isinstance(closure, list) or any(not isinstance(p, str) or p not in approved for p in closure):
        errors.append('Product closure includes an unapproved source')
    if any(old in str(closure) for old in ['BetaConfiguration', 'BetaSession.swift', 'PinpointAPIClient', 'PublicBackend']):
        errors.append('Product closure includes retired implementation')
    if errors:
        raise ValueError('\n'.join(errors))
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT, help='Source root (synthetic checks/export validation)')
    parser.add_argument('--exclude', type=Path, action='append', default=[], help='Resolved build/kit/cache output; repeatable')
    args = parser.parse_args()
    excluded = args.exclude[:]
    if os.environ.get('VECTA_CODEC_BUILD_ROOT'):
        excluded.append(Path(os.environ['VECTA_CODEC_BUILD_ROOT']))
    try:
        files = public_files(args.root, excluded)
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
    print(f'PASS: {len(files)} explicitly approved public source/resource files inspected. '
          'Lexical scan is not a complete privacy guarantee.')


if __name__ == '__main__':
    main()
