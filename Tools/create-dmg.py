#!/usr/bin/env python3
"""Create and locally verify an ad-hoc release DMG; never install or publish."""
from pathlib import Path, PurePosixPath
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
import plistlib
import re
import runpy
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
# Pure-Python build-time Finder layout tools, MIT. No pip/global installation.
LAYOUT_TOOLS = [
    ('ds_store', 'https://files.pythonhosted.org/packages/47/bf/b1c10362a0d670ee8ae086d92c3ab795fca2a927e4ff25e7cd15224d3863/ds_store-1.3.1-py3-none-any.whl', 'fbacbb0bd5193ab3e66e5a47fff63619f15e374ffbec8ae29744251a6c8f05b5'),
    ('mac_alias', 'https://files.pythonhosted.org/packages/39/a1/4136777ed6a56df83e7c748ad28892f0672cbbcdc3b3d15a57df6ba72443/mac_alias-2.2.2-py3-none-any.whl', '504ab8ac546f35bbd75ad014d6ad977c426660aa721f2cd3acf3dc2f664141bd'),
]


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def layout_tools(work, notices):
    for name, url, expected in LAYOUT_TOOLS:
        download = work/(name+'-download'); download.mkdir()
        extraction = work/(name+'-extracted'); extraction.mkdir()
        wheel = download/'tool.whl'
        with urllib.request.urlopen(url, timeout=60) as source, wheel.open('wb') as output:
            shutil.copyfileobj(source, output)
        if hashlib.sha256(wheel.read_bytes()).hexdigest() != expected:
            raise ValueError('DMG layout tool checksum mismatch')
        with zipfile.ZipFile(wheel) as archive:
            seen = set()
            for info in archive.infolist():
                path = PurePosixPath(info.filename)
                mode = info.external_attr >> 16
                if path.is_absolute() or '..' in path.parts or '\\' in info.filename or info.filename in seen or stat.S_ISLNK(mode) or path.suffix == '.pth':
                    raise ValueError('Unsafe layout wheel entry')
                seen.add(info.filename)
            archive.extractall(extraction)
        for license_path in extraction.rglob('*'):
            if license_path.is_file() and license_path.name.lower().startswith(('license', 'copying')):
                shutil.copy2(license_path, notices/(name+'-'+license_path.name))
        sys.path.insert(0, str(extraction))
    from ds_store import DSStore
    from mac_alias import Alias
    return DSStore, Alias


def mount(image, point, writable=False):
    result = subprocess.check_output(['hdiutil', 'attach', '-plist', '-nobrowse', '-noautoopen', '-readwrite' if writable else '-readonly', '-mountpoint', str(point), str(image)])
    try:
        entities = plistlib.loads(result)['system-entities']
        # macOS reports /private/var for temporary paths opened through /var.
        matches = [e for e in entities if e.get('mount-point') and Path(e['mount-point']).resolve() == point.resolve()]
        if len(matches) != 1 or not matches[0].get('dev-entry'):
            raise ValueError('Cannot identify the attached release image')
        return matches[0]['dev-entry']
    except Exception:
        # Attach succeeded: do not let temporary-directory cleanup traverse a
        # mounted filesystem if its plist cannot be interpreted.
        subprocess.run(['hdiutil', 'detach', str(point)], check=False)
        raise


@contextmanager
def temporary_work():
    work = Path(tempfile.mkdtemp(prefix='vecta-dmg-'))
    try:
        yield work
    finally:
        if os.path.ismount(work/'mounted'):
            print('Release packaging workspace retained: image is still mounted.', file=sys.stderr)
        else:
            shutil.rmtree(work)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path); parser.add_argument('output', type=Path)
    args = parser.parse_args()
    build, out = args.build.resolve(), args.output.absolute()
    if out.exists() or out.is_symlink():
        raise SystemExit('Use a new artifact directory; existing files are preserved.')
    verifier = runpy.run_path(str(ROOT/'Tools/verify-release.py'), run_name='dmg_verifier')
    # The release verifier binds source/link/codec/resources before packaging.
    verification = verifier['verify'](build)
    signing = verification['signing']
    app = build/'Vecta.app'
    before = verifier['inventory'](app)
    metadata = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    version = metadata['CFBundleShortVersionString']
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', version):
        raise ValueError('Unsafe release version')
    out.mkdir(parents=True)
    dmg = out/('Vecta-'+version+'-macOS-arm64.dmg')
    notices = out/'Licenses'; notices.mkdir()
    shutil.copytree(app/'Contents/Resources/LocalAI/Licenses', notices/'Components')
    for name in ('LICENSE', 'NOTICE'):
        shutil.copy2(ROOT/name, notices/name)
    with temporary_work() as work:
        DSStore, Alias = layout_tools(work, notices)
        stage = work/'stage'; stage.mkdir()
        shutil.copytree(app, stage/'Vecta.app')
        (stage/'Applications').symlink_to('/Applications', target_is_directory=True)
        background = stage/'.background'; background.mkdir()
        run('xcrun', 'swift', ROOT/'Tools/DMGBackground.swift', background/'background.png')
        shutil.copy2(ROOT/'docs/INSTALL.md', stage/'Install.txt')
        run('codesign', '--verify', '--deep', '--strict', stage/'Vecta.app')
        rw = work/'layout.dmg'
        run('hdiutil', 'create', '-fs', 'HFS+', '-format', 'UDRW', '-volname', 'Vecta', '-srcfolder', stage, rw)
        point = work/'mounted'; point.mkdir()
        device = mount(rw, point, writable=True)
        try:
            with DSStore.open(str(point/'.DS_Store'), 'w+') as store:
                store['.']['bwsp'] = {'ShowStatusBar': False, 'ShowToolbar': False, 'ShowSidebar': False, 'ShowTabView': False, 'WindowBounds': '{{120, 120}, {640, 400}}'}
                store['.']['icvp'] = {'backgroundType': 2, 'backgroundImageAlias': Alias.for_file(str(point/'.background/background.png')).to_bytes(), 'iconSize': 96.0, 'gridSpacing': 100.0, 'textSize': 13.0, 'labelOnBottom': True, 'showItemInfo': False, 'showIconPreview': True, 'arrangeBy': 'none', 'viewOptionsVersion': 1}
                store['.']['vstl'] = ('type', b'icnv')
                store['Vecta.app']['Iloc'] = (175, 195)
                store['Applications']['Iloc'] = (465, 195)
                store['Install.txt']['Iloc'] = (320, 460)
            run('sync')
        finally:
            run('hdiutil', 'detach', device)
        run('hdiutil', 'convert', rw, '-format', 'UDZO', '-imagekey', 'zlib-level=9', '-o', dmg)
        run('hdiutil', 'verify', dmg)
        device = mount(dmg, point)
        try:
            if os.readlink(point/'Applications') != '/Applications':
                raise ValueError('Applications shortcut mismatch')
            if verifier['inventory'](point/'Vecta.app') != before:
                raise ValueError('DMG application identities changed')
            run('codesign', '--verify', '--deep', '--strict', point/'Vecta.app')
            # Simulate Finder copy into a new Applications directory, not the
            # real installed app. This never replaces /Applications/Vecta.app.
            copy = work/'Applications'; copy.mkdir()
            shutil.copytree(point/'Vecta.app', copy/'Vecta.app')
            if verifier['inventory'](copy/'Vecta.app') != before:
                raise ValueError('Copy changed application identities')
            run('codesign', '--verify', '--deep', '--strict', copy/'Vecta.app')
            with DSStore.open(str(point/'.DS_Store'), 'r') as store:
                if store['Vecta.app']['Iloc'] != (175, 195) or store['Applications']['Iloc'] != (465, 195):
                    raise ValueError('Installer window layout mismatch')
            if not (point/'.background/background.png').is_file():
                raise ValueError('Installer artwork missing')
        finally:
            run('hdiutil', 'detach', device)
    if verifier['inventory'](app) != before:
        raise ValueError('Original candidate changed during DMG creation')
    kit = out/('Vecta-'+version+'-LAME-relink-kit.tar.gz')
    with tarfile.open(kit, 'w:gz') as archive:
        archive.add(build/'relink-kit', arcname='Vecta-relink-kit')
    shutil.copy2(build/'relink-kit/Vecta-source.tar.gz', out/('Vecta-'+version+'-source.tar.gz'))
    licenses = out/('Vecta-'+version+'-licenses.tar.gz')
    with tarfile.open(licenses, 'w:gz') as archive:
        archive.add(notices, arcname='Licenses')
    signature_label = {'ad-hoc': 'ad-hoc', 'apple-development': 'Apple Development', 'developer-id-application': 'Developer ID Application', 'certificate-signed': 'certificate' }[signing['signature']]
    signing_notice = f"The app is {signature_label} signed, " + ('NOT notarized.' if verification['developerID'] else 'NOT Developer ID signed or notarized.')
    notes = f"""# Vecta {version} — build {metadata['CFBundleVersion']} developer preview

Native macOS, Apple Silicon, macOS15+. Local WhisperKit/SpeakerKit and MLX Qwen4B/9B. Models are installed separately by explicit user action. Modern recorder first provisioning requires authorized PLAUD Partner credentials; cached reconnect is local.

{signing_notice} See INSTALL.md for Apple-supported installation and the release readiness report for verification limits. Hardware coverage is limited to the documented tested setup. Keep a backup before first launch/migration.

Assets: DMG, SHA256SUMS, matching source, component licenses and LAME source/object/relink kit. Do not distribute the DMG without its matching kit. Nothing was published by this build.
"""
    (out/'RELEASE_NOTES.md').write_text(notes)
    values = {p.name: verifier['digest'](p) for p in sorted(out.iterdir()) if p.is_file()}
    (out/'SHA256SUMS').write_text(''.join(value+'  '+name+'\n' for name, value in values.items()))
    summary = {'dmg': dmg.name, 'bytes': dmg.stat().st_size, 'sha256': verifier['digest'](dmg), 'hdiutilVerify': 'PASS', 'mountAndDetach': 'PASS', 'finderLayoutData': 'PASS', 'mountedBundleIdentity': 'PASS', 'temporaryApplicationsCopy': 'PASS', 'actualApplicationsInstall': 'NOT TESTED', 'cleanUserGatekeeper': 'NOT TESTED', 'signature': signing['signature'], 'signing': signing, 'developerID': verification['developerID'], 'notarized': False, 'published': False}
    (out/'artifact-verification.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps(summary, sort_keys=True))


if __name__ == '__main__':
    main()
