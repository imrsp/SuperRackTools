"""Regression checks for the ARM64 Flutter cache bootstrap."""

from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

from prepare_arm64 import extract, prepare


def pe(machine):
    data = bytearray(70)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 60, 64)
    data[64:68] = b'PE\0\0'
    struct.pack_into('<H', data, 68, machine)
    return data


class Arm64CacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / 'bin/cache'
        self.cache.mkdir(parents=True)
        (self.cache / 'engine.stamp').write_text('a' * 40)
        self.urls = []
        self.dll_machine = 0xAA64

    def download(self, url, destination):
        self.urls.append(url)
        with zipfile.ZipFile(destination, 'w') as archive:
            if 'cpp-client-wrapper' in url:
                archive.writestr('cpp_client_wrapper/core_implementations.cc', '// wrapper')
            elif url.endswith('/artifacts.zip'):
                archive.writestr('icudtl.dat', 'icu')
            else:
                archive.writestr('flutter_windows.dll', pe(self.dll_machine))
                archive.writestr('flutter_windows.dll.lib', 'library')
                archive.writestr('gen_snapshot.exe', pe(0x8664))

    def test_bootstrap_and_reuse_matching_revision(self):
        prepare(self.root, self.download)
        prepare(self.root, self.download)
        self.assertEqual(len(self.urls), 3)
        self.assertTrue(all('/' + 'a' * 40 + '/' in url for url in self.urls))

    def test_engine_upgrade_refreshes_cache(self):
        prepare(self.root, self.download)
        (self.cache / 'engine.stamp').write_text('b' * 40)
        prepare(self.root, self.download)
        self.assertEqual(len(self.urls), 6)
        self.assertTrue(all('/' + 'b' * 40 + '/' in url for url in self.urls[3:]))

    def test_missing_snapshot_repairs_matching_cache(self):
        prepare(self.root, self.download)
        (self.cache / 'artifacts/engine/windows-arm64-release/gen_snapshot.exe').unlink()
        prepare(self.root, self.download)
        self.assertEqual(len(self.urls), 6)

    def test_wrong_dll_architecture_never_publishes_stamp(self):
        self.dll_machine = 0x8664
        with self.assertRaisesRegex(ValueError, 'DLL must target ARM64'):
            prepare(self.root, self.download)
        self.assertFalse((self.cache / 'artifacts/engine/superrack-arm64-release.stamp').exists())

    def test_failed_refresh_preserves_previous_cache(self):
        prepare(self.root, self.download)
        (self.cache / 'engine.stamp').write_text('b' * 40)
        def fail(url, destination):
            raise OSError('download failed')
        with self.assertRaises(OSError):
            prepare(self.root, fail)
        stamp = self.cache / 'artifacts/engine/superrack-arm64-release.stamp'
        self.assertEqual(stamp.read_text().strip(), 'a' * 40)

    def test_zip_traversal_rejected(self):
        archive = self.root / 'unsafe.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            output.writestr('../outside', 'bad')
        with self.assertRaisesRegex(ValueError, 'Unsafe ZIP path'):
            extract(archive, self.root / 'staging')
        self.assertFalse((self.root / 'outside').exists())


if __name__ == '__main__':
    unittest.main()
