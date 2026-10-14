#!/usr/bin/env python3
"""Offline synthetic packaging/integrity regressions; no devices/private inputs.

Run: python3 -I Tools/test-packaging.py
All artifacts are created under new temporary fixture directories. No downloads,
real codec cache modification, installation, signing or publication is performed.
"""
from pathlib import Path
import hashlib
import io
import struct
import zlib
import json
import os
import plistlib
import runpy
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
PUBLIC = runpy.run_path(str(ROOT / 'Tools/check-public-tree.py'), run_name='test_public')
CODECS = runpy.run_path(str(ROOT / 'Tools/verify-codec-cache.py'), run_name='test_codecs')
WORKERS = runpy.run_path(str(ROOT / 'Tools/build-workers.py'), run_name='test_workers')
PACK = runpy.run_path(str(ROOT / 'Tools/package-workers.py'), run_name='test_worker_package')
BUILD = runpy.run_path(str(ROOT / 'Tools/build.py'), run_name='test_builder')
KIT = runpy.run_path(str(ROOT / 'Tools/make-relink-kit.py'), run_name='test_kit')
RELEASE = runpy.run_path(str(ROOT / 'Tools/verify-release.py'), run_name='test_release')
DMG = runpy.run_path(str(ROOT / 'Tools/create-dmg.py'), run_name='test_dmg')


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, str):
        data = data.encode()
    path.write_bytes(data)


def json_write(path, value):
    write(path, json.dumps(value, indent=2) + '\n')


def public_fixture(root):
    files = {
        'LICENSE': 'Synthetic license\n', 'NOTICE': 'Synthetic attribution\n',
        'App/Example.swift': 'import Foundation\n',
        'Tools/app-sources.json': '["App/Example.swift"]\n',
        'Tools/public-sources.json': '',
    }
    files.update({p: '{}\n' if p.endswith('.json') else 'Synthetic provenance\n'
                  for p in KIT['PROVENANCE'] if p not in files})
    for name, data in files.items():
        write(root / name, data)
    manifest = {'version': 1, 'roots': sorted({p.split('/')[0] for p in files if '/' in p}),
                'files': sorted(files)}
    json_write(root / 'Tools/public-sources.json', manifest)
    return sorted(files)


def install_fixture(prefix, api=CODECS):
    for name in api['REQUIRED']:
        write(prefix / name, 'synthetic installed ' + name + '\n')
    # Additional transitive/build metadata must also be sealed and checked.
    write(prefix / 'lib/pkgconfig/opus.pc', 'synthetic pkgconfig\n')
    write(prefix / 'lib/libopus.la', 'synthetic libtool metadata\n')
    json_write(prefix / api['MANIFEST'], api['install_manifest'](prefix))


class FixtureCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='vecta-public-fixture-')
        self.base = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()


class PublicTreeTests(FixtureCase):
    def setUp(self):
        super().setUp()
        self.root = self.base / 'source'
        self.files = public_fixture(self.root)

    def test_explicit_inventory(self):
        self.assertEqual(PUBLIC['public_files'](self.root), self.files)

    def test_unexpected_opaque_diagnostic_rejected_without_reading(self):
        sentinel = self.root / 'App/opaque-diagnostic.bin'
        write(sentinel, b'\x00unreviewed personal diagnostic\xff')
        original = Path.read_bytes
        def reject_private_read(path):
            if path == sentinel:
                self.fail('Unexpected diagnostic content was opened')
            return original(path)
        with mock.patch.object(Path, 'read_bytes', reject_private_read):
            with self.assertRaisesRegex(ValueError, 'unexpected file'):
                PUBLIC['public_files'](self.root)

    def test_unexpected_root_directory(self):
        write(self.root / 'NovelOutput/opaque-sentinel', b'never export')
        with self.assertRaisesRegex(ValueError, 'unexpected directory'):
            PUBLIC['public_files'](self.root)

    def test_machine_local_directories_ignored(self):
        for directory in ('.claude', '.vscode'):
            write(self.root / directory / 'private-opaque', b'\x00private local\xff')
        self.assertEqual(PUBLIC['public_files'](self.root), self.files)

    def test_resolved_nonstandard_output_excluded(self):
        output = self.root / 'App/UnusuallyNamedOutput'
        write(output / 'sentinel.bin', b'never export')
        self.assertEqual(PUBLIC['public_files'](self.root, excluded=(output / '..' / output.name,)), self.files)

    def test_exclusion_cannot_hide_approved_files_or_root(self):
        for excluded in (self.root, self.root.parent, self.root / 'App'):
            with self.assertRaises(ValueError):
                PUBLIC['public_files'](self.root, excluded=(excluded,))

    def test_missing_file_and_missing_root_fail(self):
        (self.root / 'App/Example.swift').unlink()
        with self.assertRaisesRegex(ValueError, 'missing approved'):
            PUBLIC['public_files'](self.root)
        (self.root / 'App').rmdir()
        with self.assertRaisesRegex(ValueError, 'missing approved'):
            PUBLIC['public_files'](self.root)

    def test_approved_and_unapproved_symlinks_fail(self):
        path = self.root / 'App/Example.swift'
        path.unlink()
        path.symlink_to(self.root / 'LICENSE')
        with self.assertRaisesRegex(ValueError, 'symlinks'):
            PUBLIC['public_files'](self.root)

    def test_unknown_empty_directory_fails(self):
        (self.root / 'App/Diagnostics').mkdir()
        with self.assertRaisesRegex(ValueError, 'unexpected directory'):
            PUBLIC['public_files'](self.root)

    def test_bad_manifest_paths_and_duplicates_fail(self):
        path = self.root / 'Tools/public-sources.json'
        original = json.loads(path.read_text())
        for name in ('../private.txt', '/absolute.txt', 'App//Example.swift', 'App/../LICENSE', 'App/Example.swift'):
            manifest = dict(original, files=original['files'] + [name])
            json_write(path, manifest)
            with self.assertRaises(ValueError):
                PUBLIC['public_files'](self.root)

    def test_lexical_secret_is_second_gate(self):
        secret = 'sk-' + 'z' * 32
        write(self.root / 'App/Example.swift', 'let secret = "' + secret + '"\n')
        with self.assertRaisesRegex(ValueError, 'possible secret') as error:
            PUBLIC['public_files'](self.root)
        self.assertNotIn(secret, str(error.exception))

    def test_personal_home_path_vs_documentation_and_schema(self):
        scan = PUBLIC['source_byte_errors']
        self.assertEqual(scan('docs/Example.md', b'Bare prefix `/Users/` and Vecta/Users/<identity>'), [])
        private_path = b'/' + b'Users/example-owner/private-file'
        self.assertTrue(any('personal absolute' in e for e in scan('docs/Example.md', private_path)))

    def test_linked_manifest_parent_not_read(self):
        tools = self.root / 'Tools'
        saved = self.base / 'linked-tools-target'
        tools.rename(saved)
        tools.symlink_to(saved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'linked explicit public manifest'):
            PUBLIC['public_files'](self.root)

    def test_localized_permission_resources_use_text_security_gate(self):
        scan = PUBLIC['source_byte_errors']
        name = 'App/Resources/en.lproj/InfoPlist.strings'
        self.assertEqual(scan(name, b'"NSLocalNetworkUsageDescription" = "Local transfer.";\n'), [])
        for data, category in ((b'\x00opaque', 'opaque content'),
                               (b'\xff', 'non-text content'),
                               (('sk-' + 'z' * 32).encode(), 'possible secret'),
                               (b'/' + b'Users/example-owner/private-file', 'personal absolute')):
            self.assertTrue(any(category in error for error in scan(name, data)))

    def test_exact_public_screenshot_paths_and_format(self):
        def chunk(kind, payload):
            return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)
        header = chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
        body = chunk(b'IDAT', zlib.compress(b'\x00\x00\x00\x00'))
        end = chunk(b'IEND', b'')
        png = b'\x89PNG\r\n\x1a\n' + header + body + end
        scan = PUBLIC['source_byte_errors']
        for name in PUBLIC['PUBLIC_SCREENSHOTS']:
            self.assertEqual(scan(name, png), [])
            for invalid in (png[:-1], png+b'extra', png[:40]+b'bad'+png[43:], b'not a PNG'):
                self.assertTrue(scan(name, invalid))
            self.assertTrue(scan(name, png[:-12] + chunk(b'tEXt', b'private metadata') + end))
        self.assertTrue(scan('docs/assets/screenshots/unreviewed.png', png))
        self.assertTrue(scan('App/screenshot.png', png))

    def test_exact_sample_pdf_path_and_active_content(self):
        scan = PUBLIC['source_byte_errors']
        name = PUBLIC['PUBLIC_PDF']
        pdf = b'%PDF-1.4\nsynthetic fixture\n%%EOF\n'
        self.assertEqual(scan(name, pdf), [])
        for invalid in (b'not PDF', pdf[:-7], b'%PDF-1.4\n/JavaScript (unsafe)\n%%EOF'):
            self.assertTrue(scan(name, invalid))
        self.assertTrue(scan('docs/assets/unreviewed.pdf', pdf))

    def test_opaque_approved_text_rejected(self):
        write(self.root / 'App/Example.swift', b'\x00opaque')
        with self.assertRaisesRegex(ValueError, 'opaque content'):
            PUBLIC['public_files'](self.root)


class CodecInstallTests(FixtureCase):
    def setUp(self):
        super().setUp()
        self.root = self.base / 'codec'
        self.prefix = self.root / 'install'
        install_fixture(self.prefix)

    def test_complete_installed_inputs_verify(self):
        expected = CODECS['verify_install'](self.prefix)
        self.assertTrue(CODECS['REQUIRED'] <= expected['files'].keys())
        self.assertIn('lib/pkgconfig/opus.pc', expected['files'])
        self.assertIn('lib/libopus.la', expected['files'])

    def test_consumed_header_tamper_fails_before_shell_reuse_or_download(self):
        write(self.prefix / 'include/opus/opus.h', 'tampered consumed header\n')
        with self.assertRaisesRegex(ValueError, 'include/opus/opus.h'):
            CODECS['verify_install'](self.prefix)
        # A fake curl records any forbidden download attempt. Reuse must fail
        # at install integrity before reaching curl, source or native toolchain.
        bin_dir = self.base / 'fake-bin'
        sentinel = self.base / 'download-was-attempted'
        write(bin_dir / 'curl', '#!/bin/bash\ntouch "$DOWNLOAD_SENTINEL"\nexit 99\n')
        (bin_dir / 'curl').chmod(0o755)
        env = dict(os.environ, VECTA_CODEC_BUILD_ROOT=str(self.root),
                   PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                   DOWNLOAD_SENTINEL=str(sentinel))
        result = subprocess.run(['bash', str(ROOT / 'Packages/VectaTransport/build-native-codecs.sh')],
                                cwd=ROOT, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('include/opus/opus.h', result.stderr)
        self.assertFalse(sentinel.exists())

    def test_archive_metadata_flags_license_changes_fail(self):
        for name in ('lib/libopus.a', 'lib/pkgconfig/opus.pc', 'lib/libopus.la',
                     'build-flags.txt', 'licenses/lame-COPYING'):
            path = self.prefix / name
            before = path.read_bytes()
            write(path, before + b'tampered\n')
            with self.assertRaisesRegex(ValueError, 'changed'):
                CODECS['verify_install'](self.prefix)
            write(path, before)

    def test_added_and_removed_headers_fail(self):
        extra = self.prefix / 'include/opus/unsealed.h'
        write(extra, 'unsealed\n')
        with self.assertRaisesRegex(ValueError, 'unsealed.h'):
            CODECS['verify_install'](self.prefix)
        extra.unlink()
        (self.prefix / 'include/lame/lame.h').unlink()
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            CODECS['verify_install'](self.prefix)

    def test_linked_header_directory_and_manifest_fail(self):
        for relative in ('include/opus/opus.h', 'include/opus', CODECS['MANIFEST']):
            path = self.prefix / relative
            backup = self.base / ('backup-' + path.name)
            path.rename(backup)
            path.symlink_to(backup, target_is_directory=backup.is_dir())
            with self.assertRaisesRegex(ValueError, 'Linked'):
                CODECS['verify_install'](self.prefix)
            path.unlink()
            backup.rename(path)

    def test_legacy_manifest_not_resealed_and_root_preserved(self):
        path = self.prefix / CODECS['MANIFEST']
        json_write(path, {n: hashlib.sha256((self.prefix / 'lib' / n).read_bytes()).hexdigest()
                          for n in CODECS['ARCHIVES']})
        before = path.read_bytes()
        with self.assertRaisesRegex(ValueError, 'historical headers'):
            CODECS['verify_install'](self.prefix)
        with self.assertRaisesRegex(ValueError, 'Refusing to overwrite'):
            CODECS['seal_install'](self.prefix, self.root)
        with self.assertRaisesRegex(ValueError, 'not a fresh build'):
            CODECS['prepare'](self.root)
        self.assertEqual(path.read_bytes(), before)

    def test_missing_manifest_does_not_adopt_partial_install(self):
        (self.prefix / CODECS['MANIFEST']).unlink()
        with self.assertRaisesRegex(ValueError, 'no complete'):
            CODECS['verify_install'](self.prefix)
        with self.assertRaisesRegex(ValueError, 'not a fresh build'):
            CODECS['prepare'](self.root)


class RelinkKitTests(FixtureCase):
    def setUp(self):
        super().setUp()
        self.root = self.base / 'source'
        self.files = public_fixture(self.root)
        self.build = self.root / 'SurprisingArtifactName'
        self.out = self.root / 'AnotherNovelKitName'
        self.codec = self.root / 'UnconventionallyNamedCodecCache'
        # Kit has its own verifier namespace. Replace ONLY expected digests for
        # test-generated tar archives; production pins/scripts remain unchanged.
        self.api = KIT['CODECS']
        self.api['prepare'](self.codec)
        self.globals = self.api['verify_source'].__globals__
        self.original_sources = self.globals['SOURCES']
        fake_sources = {}
        for name, (suffix, _) in self.original_sources.items():
            contents = {'COPYING': b'synthetic codec license\n', 'configure': b'configure -force_cpusubtype_ALL\n'}
            source_dir, installed_dir = {
                'opus-1.5.2': ('include', 'opus'), 'lame-3.100': ('include', 'lame'),
                'libogg-1.3.5': ('include/ogg', 'ogg'), 'libvorbis-1.3.7': ('include/vorbis', 'vorbis'),
            }[name]
            for header in self.api['HEADERS']:
                if header.startswith(installed_dir + '/') and header != 'ogg/config_types.h':
                    contents[source_dir + '/' + Path(header).name] = ('synthetic header ' + header + '\n').encode()
            archive = self.api['archive_path'](self.codec, name)
            archive.parent.mkdir(parents=True)
            mode = 'w:gz' if suffix == 'tar.gz' else 'w:xz'
            with tarfile.open(archive, mode) as bundle:
                for relative, data in contents.items():
                    info = tarfile.TarInfo(name + '/' + relative)
                    info.size = len(data)
                    bundle.addfile(info, io.BytesIO(data))
                    write(self.api['source_path'](self.codec, name) / relative, data)
            fake_sources[name] = (suffix, hashlib.sha256(archive.read_bytes()).hexdigest())
        self.globals['SOURCES'] = fake_sources
        self.api['SOURCES'] = fake_sources
        install_fixture(self.codec / 'install', self.api)
        for header in self.api['HEADERS']:
            write(self.codec / 'install/include' / header, 'synthetic header ' + header + '\n')
        # Acquire a first seal through the actual source-verified install path.
        (self.codec / 'install' / self.api['MANIFEST']).unlink()
        self.api['seal_install'](self.codec / 'install', self.codec)
        json_write(self.build / 'codec-integrity.json', self.api['verify_install'](self.codec / 'install'))
        json_write(self.build / 'source-manifest.json', {p: hashlib.sha256((self.root / p).read_bytes()).hexdigest()
                                                      for p in self.files})
        for name in KIT['MODULES']:
            write(self.build / 'modules' / name, 'synthetic matching object ' + name + '\n')
        write(self.build/'Vecta.app/Contents/MacOS/Vecta','synthetic completed executable')
        write(self.build/'Vecta.app/Contents/Info.plist','synthetic configuration')
        with mock.patch.object(subprocess,'check_output',return_value='synthetic toolchain'):
            BUILD['capture_link_identity'](self.build,self.codec/'install',
                BUILD['link_inputs'](self.build,self.codec/'install'),
                ['xcrun','swiftc','-target','arm64-apple-macosx13.0'],{'development':False})
        write(self.build / 'DO-NOT-EXPORT.opaque', b'sentinel build diagnostic')
        write(self.codec / 'DO-NOT-EXPORT.log', b'sentinel codec diagnostic')

    def tearDown(self):
        self.globals['SOURCES'] = self.original_sources
        self.api['SOURCES'] = self.original_sources
        super().tearDown()

    def build_kit(self):
        return KIT['build_kit'](self.root, self.build, self.out, self.codec, toolchain='synthetic toolchain')

    def test_kit_never_archives_resolved_outputs_or_itself(self):
        self.build_kit()
        with tarfile.open(self.out / 'Vecta-source.tar.gz') as archive:
            self.assertEqual(sorted(archive.getnames()), ['Vecta/' + p for p in self.files])
            for member in archive:
                data = archive.extractfile(member).read()
                self.assertNotIn(b'sentinel build diagnostic', data)
                self.assertNotIn(b'sentinel codec diagnostic', data)
        # All codecs' corresponding sources, notices and relink materials exist.
        for name, (suffix, _) in self.api['SOURCES'].items():
            self.assertTrue((self.out / (name + '.' + suffix)).is_file())
        self.assertTrue((self.out / 'codec-licenses/lame-COPYING').is_file())
        self.assertTrue((self.out / 'codec-headers/opus/opus.h').is_file())
        manifest = json.loads((self.out / 'SHA256.json').read_text())
        self.assertIn('modules/Vecta.o', manifest)
        self.assertIn('codec-integrity.json', manifest)
        self.assertNotIn('DO-NOT-EXPORT.opaque', manifest)

    def test_each_replaced_module_rejected_before_export(self):
        for name in KIT['MODULES']:
            path=self.build/'modules'/name
            original=path.read_bytes()
            write(path,'replacement object')
            with self.assertRaisesRegex(ValueError,'matching linker input'):
                self.build_kit()
            self.assertFalse(self.out.exists())
            write(path,original)

    def test_replaced_executable_or_configuration_rejected(self):
        for name in ['Vecta.app/Contents/MacOS/Vecta','Vecta.app/Contents/Info.plist']:
            path=self.build/name;original=path.read_bytes()
            write(path,'replacement')
            with self.assertRaisesRegex(ValueError,'Executable/configuration differs'):
                self.build_kit()
            self.assertFalse(self.out.exists())
            write(path,original)

    def test_missing_link_identity_cannot_reseal_existing_build(self):
        (self.build/'link-integrity.json').unlink()
        with self.assertRaisesRegex(ValueError,'Missing/nonregular'):
            self.build_kit()
        self.assertFalse(self.out.exists())

    def test_exported_module_mutation_during_archive_rejected(self):
        original=KIT['archive_sources']
        def mutate(*args,**kwargs):
            original(*args,**kwargs)
            write(self.out/'modules/Vecta.o',b'replaced exported object')
        with mock.patch.dict(KIT['build_kit'].__globals__,archive_sources=mutate):
            with self.assertRaisesRegex(ValueError,'Exported relink input changed'):
                self.build_kit()
        self.assertFalse((self.out/'SHA256.json').exists())

    def test_module_mutation_during_copy_rejected(self):
        original=KIT['build_kit'].__globals__['checked_copy']
        def mutate(source,destination,expected=None):
            if source.name=='Vecta.o':write(source,'changed during packaging')
            return original(source,destination,expected)
        with mock.patch.dict(KIT['build_kit'].__globals__,checked_copy=mutate):
            with self.assertRaisesRegex(ValueError,'Relink input changed'):
                self.build_kit()
        self.assertFalse((self.out/'SHA256.json').exists())

    def test_module_mutation_during_link_rejected(self):
        before=BUILD['link_inputs'](self.build,self.codec/'install')
        write(self.build/'modules/Vecta.o','changed while linking')
        with self.assertRaisesRegex(ValueError,'Linker inputs changed'):
            BUILD['capture_link_identity'](self.build,self.codec/'install',before,[],{})

    def test_unexcluded_opaque_sentinel_aborts_before_archive(self):
        write(self.root / 'App/DO-NOT-EXPORT.opaque', b'private unexpected diagnostic')
        with self.assertRaisesRegex(ValueError, 'unexpected file'):
            self.build_kit()
        self.assertFalse(self.out.exists())

    def test_selected_codec_identity_must_match_build(self):
        manifest = json.loads((self.build / 'codec-integrity.json').read_text())
        manifest['files']['include/opus/opus.h'] = '0' * 64
        json_write(self.build / 'codec-integrity.json', manifest)
        with self.assertRaisesRegex(ValueError, 'matching compiled-input'):
            self.build_kit()
        self.assertFalse(self.out.exists())

    def test_incomplete_source_manifest_fails(self):
        path = self.build / 'source-manifest.json'
        manifest = json.loads(path.read_text())
        del manifest['App/Example.swift']
        json_write(path, manifest)
        with self.assertRaisesRegex(ValueError, 'lacks approved inputs'):
            self.build_kit()

    def test_changed_source_or_codec_header_fails_before_archive(self):
        write(self.root / 'App/Example.swift', 'import Foundation\n// Changed\n')
        with self.assertRaisesRegex(ValueError, 'Source differs'):
            self.build_kit()
        write(self.root / 'App/Example.swift', 'import Foundation\n')
        write(self.codec / 'install/include/opus/opus.h', 'tampered header\n')
        with self.assertRaisesRegex(ValueError, 'include/opus/opus.h'):
            self.build_kit()
        self.assertFalse(self.out.exists())

    def test_linked_module_rejected(self):
        path = self.build / 'modules/Vecta.o'
        path.unlink()
        path.symlink_to(self.root / 'LICENSE')
        with self.assertRaisesRegex(ValueError, 'Linked'):
            self.build_kit()

    def test_binary_parser_delimiter_is_not_private_key_material(self):
        marker = b'-----BEGIN ' + b'PRIVATE KEY-----'
        source = self.build / 'modules/parser.o'
        target = self.base / 'checked-parser.o'
        write(source, marker + bytes([0]) + b'public parser code')
        KIT['checked_copy'](source, target)
        self.assertEqual(target.read_bytes(), source.read_bytes())

    def test_binary_private_key_payload_and_token_are_rejected(self):
        marker = b'-----BEGIN ' + b'PRIVATE KEY-----'
        for index, data in enumerate([marker + b'\n' + b'A' * 64, marker,
                                      b'sk-' + b'x' * 32,
                                      b'/' + b'Users/private-owner/file']):
            source = self.build / 'modules' / ('private-' + str(index) + '.o')
            target = self.base / ('rejected-' + str(index) + '.o')
            write(source, data)
            with self.assertRaisesRegex(ValueError, 'possible private content'):
                KIT['checked_copy'](source, target)
            self.assertFalse(target.exists())

    def test_existing_output_preserved(self):
        write(self.out / 'preserve.txt', b'existing artifact')
        with self.assertRaisesRegex(ValueError, 'existing artifacts'):
            self.build_kit()
        self.assertEqual((self.out / 'preserve.txt').read_bytes(), b'existing artifact')

    def test_deleted_manifest_cannot_reseal_historical_cache(self):
        (self.codec / 'install' / self.api['MANIFEST']).unlink()
        with self.assertRaisesRegex(ValueError, 'already completed'):
            self.api['seal_install'](self.codec / 'install', self.codec)
        self.assertFalse((self.codec / 'install' / self.api['MANIFEST']).exists())

    def test_archive_scans_actual_bytes_after_initial_gate(self):
        # A non-executable provenance document may not be in a build snapshot.
        # Recheck actual bytes being archived, not just the earlier lexical pass.
        write(self.root / 'docs/PROVENANCE.md', b'\x00new opaque private content')
        with self.assertRaisesRegex(ValueError, 'opaque content'):
            KIT['archive_sources'](self.root, self.files, self.base / 'failed-source.tar.gz', {})

    def test_source_archive_pin_and_ancestor_links_rejected(self):
        archive = self.api['archive_path'](self.codec, 'lame-3.100')
        original = archive.read_bytes()
        write(archive, original + b'tampered')
        with self.assertRaisesRegex(ValueError, 'pinned source'):
            self.api['verify_source'](archive, self.api['source_path'](self.codec, 'lame-3.100'))
        write(archive, original)
        source = self.api['source_path'](self.codec, 'lame-3.100')
        linked = source / 'include'
        saved = source / 'saved-include'
        linked.rename(saved)
        linked.symlink_to(saved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Linked'):
            self.api['verify_source'](archive, source)

    def test_archive_path_and_entry_types_rejected(self):
        for member_name, type_flag in [('lame-3.100/../escape', tarfile.REGTYPE),
                                       ('lame-3.100/link', tarfile.SYMTYPE)]:
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode='w') as bundle:
                info = tarfile.TarInfo(member_name)
                info.type = type_flag
                bundle.addfile(info)
            buffer.seek(0)
            with tarfile.open(fileobj=buffer) as bundle:
                with self.assertRaises(ValueError):
                    list(self.api['members'](bundle, 'lame-3.100'))


class WorkerBuildTests(FixtureCase):
    def setUp(self):
        super().setUp()
        self.checkout=self.base/'checkout';self.checkout.mkdir()
        def git(*args):return subprocess.check_output(['git','-C',str(self.checkout),*args],stderr=subprocess.DEVNULL)
        self.git=git
        git('init');git('config','user.email','fixture@example.invalid');git('config','user.name','Offline Fixture')
        write(self.checkout/'Package.swift','synthetic build input')
        write(self.checkout/'.gitignore','ignored-output\n')
        git('add','.');git('commit','-m','fixture')
        self.pin=git('rev-parse','HEAD').decode().strip()

    def verify(self):return WORKERS['verify_checkout'](self.checkout,self.pin)

    def test_worker_build_uses_fresh_derived_data_and_disables_coverage(self):
        root=self.base/'build-source'
        globals_=WORKERS['main'].__globals__
        commands=[]
        resolved=[]
        def invoke(*command,**kwargs):
            commands.append(command)
            if command[0]=='xcodebuild' and command[-1]=='build':
                derived=Path(command[command.index('-derivedDataPath')+1])
                speech=next(c[c.index('--scratch-path')+1] for c in reversed(commands) if c[0]=='swift')
                for worker in [Path(speech)/'release/VectaSpeech',derived/'Build/Products/Release/VectaMLX']:
                    write(worker,b'completed synthetic worker')
                write(derived/'Build/Products/Release/mlx.bundle/default.metallib',b'metal')
        def resolve(source_packages):
            resolved.append(Path(source_packages))
            return {}
        json_write(root/'Package.resolved',{'pins':[]})
        with mock.patch.dict(globals_,ROOT=root,run=invoke,verify_checkout=lambda p,r:{},
                             resolve_mlx_sources=resolve,verify_mlx_sources=lambda p:{}):
            WORKERS['main']();WORKERS['main']()
        xcode=[c for c in commands if c[0]=='xcodebuild' and c[-1]=='build']
        resolutions=[c for c in commands if c[0]=='xcodebuild' and c[1]=='-resolvePackageDependencies']
        self.assertEqual(len(xcode),2)
        self.assertEqual(len(resolutions),0)
        self.assertEqual(len(resolved),2)
        self.assertNotEqual(resolved[0],resolved[1])
        self.assertTrue(all(path.name=='SourcePackages' for path in resolved))
        speech=[c[c.index('--scratch-path')+1] for c in commands if c[0]=='swift']
        self.assertEqual(len(speech),2)
        self.assertNotEqual(speech[0],speech[1])
        self.assertFalse(any('cmake' in str(c[0]).lower() for c in commands))
        self.assertNotEqual(xcode[0][xcode[0].index('-derivedDataPath')+1],xcode[1][xcode[1].index('-derivedDataPath')+1])
        for command,resolved_source in zip(xcode,resolved):
            self.assertIn('-clonedSourcePackagesDirPath',command)
            self.assertEqual(Path(command[command.index('-clonedSourcePackagesDirPath')+1]),resolved_source)
            self.assertIn('ENABLE_CODE_COVERAGE=NO',command)
            self.assertIn('OTHER_LDFLAGS=$(inherited) -Xlinker -headerpad_max_install_names',command)
            self.assertIn('CLANG_ENABLE_CODE_COVERAGE=NO',command)
            self.assertIn('SWIFT_ENABLE_CODE_COVERAGE=NO',command)
            self.assertNotIn('-enableCodeCoverage',command)
        record=json.loads((root/'.build/worker-build.json').read_text())
        self.assertEqual(set(record['workerOutputs']),{'VectaSpeech','VectaMLX'})
        self.assertIn('mlx.bundle/default.metallib',record['mlxResources'])

    def test_clean_pinned_content_is_stable(self):
        self.assertEqual(self.verify(),self.verify())
        self.assertIn('Package.swift',self.verify())

    def test_wrong_head_rejected_without_checkout_mutation(self):
        with self.assertRaisesRegex(ValueError,'pinned revision'):
            WORKERS['verify_checkout'](self.checkout,'0'*40)
        self.assertEqual(self.git('rev-parse','HEAD').decode().strip(),self.pin)

    def test_tracked_dirty_staged_and_assume_unchanged_rejected(self):
        write(self.checkout/'Package.swift','altered content')
        with self.assertRaisesRegex(ValueError,'modified/unapproved'):self.verify()
        self.git('add','Package.swift')
        with self.assertRaisesRegex(ValueError,'modified/unapproved'):self.verify()
        self.git('reset','--','Package.swift')
        self.git('update-index','--assume-unchanged','Package.swift')
        with self.assertRaisesRegex(ValueError,'pinned content'):self.verify()
        self.assertEqual((self.checkout/'Package.swift').read_text(),'altered content')

    def test_untracked_and_ignored_inputs_rejected(self):
        for name in ['unapproved.c','ignored-output']:
            write(self.checkout/name,'unapproved')
            with self.assertRaisesRegex(ValueError,'modified/unapproved'):self.verify()
            self.assertTrue((self.checkout/name).exists())
            (self.checkout/name).unlink()

    def test_symlinked_tracked_input_rejected(self):
        path=self.checkout/'Package.swift';path.unlink();path.symlink_to(self.checkout/'.gitignore')
        with self.assertRaises(ValueError):self.verify()

    def test_pinned_internal_symlink_is_authenticated_but_escape_is_rejected(self):
        link=self.checkout/'upstream-link'
        link.symlink_to('Package.swift')
        self.git('add','upstream-link');self.git('commit','-m','pinned internal link')
        pin=self.git('rev-parse','HEAD').decode().strip()
        self.assertIn('upstream-link',WORKERS['verify_checkout'](self.checkout,pin))
        link.unlink();link.symlink_to('../external-input')
        write(self.base/'external-input','external')
        self.git('add','upstream-link');self.git('commit','-m','pinned external link')
        pin=self.git('rev-parse','HEAD').decode().strip()
        with self.assertRaisesRegex(ValueError,'external'):WORKERS['verify_checkout'](self.checkout,pin)

    def test_during_build_content_change_is_detected(self):
        before=self.verify()
        write(self.checkout/'Package.swift','changed during compile')
        with self.assertRaises(ValueError):self.verify()
        self.assertIsInstance(before,dict)


class WorkerPackagingTests(FixtureCase):
    def test_packaging_scans_all_workers_signs_and_hashes_runtime(self):
        root=self.base/'source';derived=root/'AI/MLX/.build/fresh-release'
        products=derived/'Build/Products/Release'
        workers=[root/'.build/speech-release/release/VectaSpeech',products/'VectaMLX']
        for worker in workers:write(worker,b'synthetic executable')
        write(products/'mlx.bundle/default.metallib',b'metal')
        write(derived/'SourcePackages/checkouts/mlx-swift/Source/Cmlx/json/LICENSE.MIT','embedded JSON MIT')
        write(root/'AI/Resources/models-mlx.json','{}')
        write(root/'.build/speech-release/checkouts/argmax/NOTICES','synthetic Argmax notice')
        write(root/'.build/native-codecs/install/licenses/codec.txt','synthetic codec notice')
        write(root/'Licenses/third-party.txt','synthetic license')
        write(root/'LICENSE','synthetic application license')
        record={'mlxDerivedData':str(derived),'speechBuild':str(root/'.build/speech-release'),'speechInputs':{},
                'workerOutputs':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in workers},
                'mlxResources':{'mlx.bundle/default.metallib':hashlib.sha256(b'metal').hexdigest()}}
        json_write(root/'.build/worker-build.json',record)
        out=self.base/'package'
        calls=[]
        def invoke(command,**kwargs):
            calls.append(command)
            if 'swift-stdlib-tool' in command:
                runtime=Path(command[command.index('--destination')+1])
                write(runtime/'libswiftCompatibilitySpan.dylib',b'synthetic compatibility runtime')
        def inspect(command,**kwargs):
            if '-L' in command:return '@rpath/libswiftCompatibilitySpan.dylib (compatibility version 1.0.0)'
            return 'sectname __text\n size 0x10\n'
        globals_=PACK['main'].__globals__
        with mock.patch.dict(globals_,ROOT=root), \
             mock.patch.object(sys,'argv',['package-workers.py',str(out)]), \
             mock.patch.object(runpy,'run_path',return_value={'verify_checkout':lambda p,r:{},'verify_mlx_sources':lambda p:{}}), \
             mock.patch.object(subprocess,'run',side_effect=invoke), \
             mock.patch.object(subprocess,'check_output',side_effect=inspect), \
             mock.patch.dict(os.environ,{'VECTA_CODEC_BUILD_ROOT':str(root/'.build/native-codecs'),'VECTA_SIGNING_IDENTITY':'-'}):
            PACK['main']()
        copy=next(c for c in calls if 'swift-stdlib-tool' in c)
        self.assertEqual(copy.count('--scan-executable'),2)
        for worker in workers:self.assertIn(str(out/worker.name),copy)
        for worker in workers:
            self.assertTrue(any('install_name_tool' in c and '@executable_path/SwiftRuntime' in c and str(out/worker.name) in c for c in calls))
        runtime=out/'SwiftRuntime/libswiftCompatibilitySpan.dylib'
        self.assertTrue(any(c[:3]==['codesign','--force','--sign'] and str(runtime) in c for c in calls))
        self.assertTrue(any(c[:3]==['codesign','--verify','--strict'] and str(runtime) in c for c in calls))
        manifest=json.loads((out/'resources-manifest.json').read_text())
        self.assertEqual(manifest['SwiftRuntime/libswiftCompatibilitySpan.dylib'],hashlib.sha256(runtime.read_bytes()).hexdigest())
        self.assertIn('Licenses/argmax-NOTICES',manifest)
        self.assertIn('Licenses/mlx-swift-Source-Cmlx-json-LICENSE.MIT',manifest)
        self.assertFalse((out/'VectaQwen').exists())

    def test_developer_toolchain_rpaths_removed_without_system_or_relative_changes(self):
        commands='cmd LC_RPATH\n cmdsize 48\n path /Applications/Xcode.app/Toolchain/lib (offset 12)\ncmd LC_RPATH\n cmdsize 32\n path /usr/lib/swift (offset 12)\ncmd LC_RPATH\n cmdsize 32\n path @loader_path (offset 12)\n'
        with mock.patch.object(subprocess,'check_output',return_value=commands), mock.patch.object(subprocess,'run') as invoke:
            PACK['normalize_rpaths'](self.base/'VectaSpeech')
        invoke.assert_called_once_with(['xcrun','install_name_tool','-delete_rpath','/Applications/Xcode.app/Toolchain/lib',str(self.base/'VectaSpeech')],check=True)

    def test_nonempty_coverage_and_profile_sections_fail_closed(self):
        binary=self.base/'worker';write(binary,b'clean binary')
        for section in ['__llvm_covmap','__llvm_covfun','__llvm_prf_data','__llvm_prf_cnts','__llvm_prf_names']:
            with mock.patch.object(subprocess,'check_output',return_value='sectname '+section+'\n size 0x10\n'):
                with self.assertRaisesRegex(ValueError,'Nonempty LLVM'):PACK['check_binary'](binary)
        with mock.patch.object(subprocess,'check_output',return_value='sectname __llvm_prf_bits\n size 0x0\n'):
            PACK['check_binary'](binary)
        write(binary,b'default.profraw')
        with mock.patch.object(subprocess,'check_output',return_value=''):
            with self.assertRaisesRegex(ValueError,'profile runtime'):PACK['check_binary'](binary)

    def test_nonempty_profile_resource_rejected(self):
        path=self.base/'nested/default.profraw';write(path,b'')
        PACK['check_profiles'](self.base)
        write(path,b'profile')
        with self.assertRaisesRegex(ValueError,'Nonempty LLVM profile'):PACK['check_profiles'](self.base)

    def test_compatibility_span_must_be_loader_visible(self):
        out=self.base;worker=Path('VectaMLX')
        loads='@rpath/libswiftCompatibilitySpan.dylib (compatibility version 1.0.0)'
        with mock.patch.object(subprocess,'check_output',return_value=loads):
            with self.assertRaisesRegex(ValueError,'Missing loader-visible'):PACK['verify_runtime'](out,[worker])
            write(out/'SwiftRuntime/libswiftCompatibilitySpan.dylib',b'synthetic runtime')
            PACK['verify_runtime'](out,[worker])

    def test_release_executables_require_only_arm64(self):
        app=self.base/'Vecta.app'
        for binary in [app/'Contents/MacOS/Vecta', app/'Contents/Resources/LocalAI/VectaSpeech', app/'Contents/Resources/LocalAI/VectaMLX']:
            with mock.patch.object(subprocess,'check_output',side_effect=['arm64\n', '', '']):
                RELEASE['check_loads'](binary,app)
            for archs in ['x86_64 arm64', 'arm64 arm64e', 'x86_64', '']:
                with self.subTest(binary=binary.name,archs=archs), mock.patch.object(subprocess,'check_output',return_value=archs):
                    with self.assertRaisesRegex(ValueError,'Non-arm64'):
                        RELEASE['check_loads'](binary,app)

    def test_release_sdk_runtime_requires_arm64_slice(self):
        app=self.base/'Vecta.app'
        binary=app/'Contents/Resources/LocalAI/SwiftRuntime/libswiftCompatibilitySpan.dylib'
        for archs in ['arm64', 'x86_64 arm64 arm64e']:
            with mock.patch.object(subprocess,'check_output',side_effect=[archs, '', '']):
                RELEASE['check_loads'](binary,app)
        for archs in ['x86_64', 'arm64e', '']:
            with self.subTest(archs=archs), mock.patch.object(subprocess,'check_output',return_value=archs):
                with self.assertRaisesRegex(ValueError,'Non-arm64'):
                    RELEASE['check_loads'](binary,app)
        for other in [app/'Contents/Frameworks'/binary.name, binary.parent/'unexpected-executable']:
            with mock.patch.object(subprocess,'check_output',return_value='x86_64 arm64 arm64e'):
                with self.assertRaisesRegex(ValueError,'Non-arm64'):
                    RELEASE['check_loads'](other,app)

    def test_no_legacy_build_dependency_or_registry_entry(self):
        for name in ['build-workers.py','package-workers.py']:
            text=(ROOT/'Tools'/name).read_text()
            self.assertNotIn('llama.cpp',text)
            self.assertNotIn('VectaQwen',text)
            self.assertNotIn('cmake',text.casefold())
        for name in ['models.json','models-mlx.json']:
            models=json.loads((ROOT/'AI/Resources'/name).read_text())['models']
            self.assertEqual({m['id'] for m in models},{'whisper','speaker','tokenizer','qwen4b','qwen9b'})
            self.assertTrue(all(m.get('backend')=='mlx' for m in models if m['id'].startswith('qwen')))


class DMGMountTests(FixtureCase):
    def test_mount_accepts_canonical_alias(self):
        point=self.base/'mounted';point.mkdir()
        alias=self.base/'alias';alias.symlink_to(point,target_is_directory=True)
        result=plistlib.dumps({'system-entities':[{'dev-entry':'/dev/synthetic','mount-point':str(point.resolve())}]})
        with mock.patch.object(subprocess,'check_output',return_value=result), mock.patch.object(subprocess,'run') as detach:
            self.assertEqual(DMG['mount'](self.base/'image.dmg',alias,True),'/dev/synthetic')
            detach.assert_not_called()

    def test_mount_lookup_failure_detaches_owned_mountpoint(self):
        point=self.base/'mounted'
        for result in [b'not a plist',plistlib.dumps({'system-entities':[]}),plistlib.dumps({'system-entities':[{'mount-point':str(point)}]})]:
            with mock.patch.object(subprocess,'check_output',return_value=result), mock.patch.object(subprocess,'run') as detach:
                with self.assertRaises((ValueError,plistlib.InvalidFileException)):
                    DMG['mount'](self.base/'image.dmg',point)
                detach.assert_called_once_with(['hdiutil','detach',str(point)],check=False)

    def test_cleanup_never_traverses_still_mounted_workspace(self):
        work=self.base/'work';work.mkdir();write(work/'mounted/retained','fixture')
        with mock.patch.object(tempfile,'mkdtemp',return_value=str(work)), mock.patch.object(os.path,'ismount',return_value=True), mock.patch.object(shutil,'rmtree') as cleanup:
            with DMG['temporary_work']() as actual:self.assertEqual(actual,work)
            cleanup.assert_not_called()
        self.assertTrue((work/'mounted/retained').exists())
        with mock.patch.object(tempfile,'mkdtemp',return_value=str(work)), mock.patch.object(os.path,'ismount',return_value=False), mock.patch.object(shutil,'rmtree') as cleanup:
            with DMG['temporary_work']():pass
            cleanup.assert_called_once_with(work)


if __name__ == '__main__':
    unittest.main(verbosity=2)
