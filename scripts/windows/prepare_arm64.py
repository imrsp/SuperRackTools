#!/usr/bin/env python3
"""Cache official ARM64 Release engine artifacts for an x64 Flutter host."""

import argparse
import os
from pathlib import Path
import re
import shutil
import struct
import tempfile
import urllib.request
import zipfile


def pe_machine(path):
    data = path.read_bytes()
    if len(data) < 64 or data[:2] != b'MZ':
        raise ValueError(f'Invalid PE file: {path}')
    offset = struct.unpack_from('<I', data, 60)[0]
    if offset + 6 > len(data) or data[offset:offset + 4] != b'PE\0\0':
        raise ValueError(f'Invalid PE header: {path}')
    return struct.unpack_from('<H', data, offset + 4)[0]


def validate(engine):
    release = engine / 'windows-arm64-release'
    for filename in ('flutter_windows.dll', 'flutter_windows.dll.lib', 'gen_snapshot.exe'):
        if not (release / filename).is_file():
            raise ValueError(f'Missing ARM64 Release artifact: {filename}')
    if pe_machine(release / 'flutter_windows.dll') != 0xAA64:
        raise ValueError('Flutter engine DLL must target ARM64')
    if pe_machine(release / 'gen_snapshot.exe') != 0x8664:
        raise ValueError('gen_snapshot must run on the x64 build host')
    for filename in ('icudtl.dat', 'cpp_client_wrapper/core_implementations.cc'):
        if not (engine / 'windows-arm64' / filename).is_file():
            raise ValueError(f'Missing ARM64 common artifact: {filename}')


def download_file(url, destination):
    print(f'Downloading {url}', flush=True)
    with urllib.request.urlopen(url, timeout=120) as response:
        with destination.open('wb') as output:
            shutil.copyfileobj(response, output)


def extract(archive, destination):
    with zipfile.ZipFile(archive) as source:
        for member in source.infolist():
            target = (destination / member.filename).resolve()
            if not target.is_relative_to(destination.resolve()):
                raise ValueError(f'Unsafe ZIP path: {member.filename}')
        source.extractall(destination)


def prepare(flutter_root, download=download_file):
    cache = flutter_root / 'bin/cache'
    revision = (cache / 'engine.stamp').read_text().strip()
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError(f'Invalid Flutter engine revision: {revision!r}')
    engine = cache / 'artifacts/engine'
    stamp = engine / 'superrack-arm64-release.stamp'
    if stamp.exists() and stamp.read_text().strip() == revision:
        try:
            validate(engine)
            print(f'ARM64 engine cache verified: {revision}')
            return
        except (ValueError, OSError):
            pass
    base = os.environ.get('FLUTTER_STORAGE_BASE_URL', 'https://storage.googleapis.com').rstrip('/')
    realm_file = cache / 'engine.realm'
    realm = realm_file.read_text().strip() if realm_file.exists() else ''
    if realm:
        base += '/' + realm
    base += f'/flutter_infra_release/flutter/{revision}'
    archives = (
        ('windows-arm64/artifacts.zip', 'windows-arm64'),
        ('windows-arm64/flutter-cpp-client-wrapper.zip', 'windows-arm64'),
        ('windows-arm64-release/windows-arm64-flutter.zip', 'windows-arm64-release'),
    )
    engine.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='superrack-arm64-', dir=cache) as temporary:
        staging = Path(temporary)
        for index, (remote, target) in enumerate(archives):
            archive = staging / f'{index}.zip'
            download(f'{base}/{remote}', archive)
            extract(archive, staging / target)
        validate(staging)
        # Only publish verified artifacts. The private stamp changes last, so a
        # failed download or interrupted copy is retried on the next invocation.
        stamp.unlink(missing_ok=True)
        for target in ('windows-arm64', 'windows-arm64-release'):
            destination = engine / target
            if destination.exists():
                shutil.rmtree(destination)
            (staging / target).replace(destination)
        stamp.write_text(revision + '\n')
    print(f'ARM64 DLL and x64 gen_snapshot verified for engine {revision}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter-root', type=Path)
    args = parser.parse_args()
    executable = shutil.which('flutter')
    root = args.flutter_root or (
        Path(executable).resolve().parent.parent if executable else None
    )
    if root is None:
        parser.error('Flutter is not on PATH; provide --flutter-root')
    prepare(root)


if __name__ == '__main__':
    main()
