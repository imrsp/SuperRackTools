#!/usr/bin/env python3
"""Locate a matching Windows executable or stage and validate its runtime ZIP."""

import argparse
import pathlib
import struct
import zipfile


def find_binary(args):
    root, expected = pathlib.Path(args[0]), int(args[1], 16)
    for candidate in root.rglob('SuperRackTools.exe'):
        data = candidate.read_bytes()
        if len(data) < 0x40 or data[:2] != b'MZ':
            continue
        pe = struct.unpack_from('<I', data, 0x3c)[0]
        if pe + 6 <= len(data) and data[pe:pe+4] == b'PE\0\0':
            if struct.unpack_from('<H', data, pe+4)[0] == expected:
                print(candidate)
                break
    else:
        raise SystemExit(f'No SuperRackTools.exe with PE architecture 0x{expected:04x} found in {root}')


def stage_bundle(args):
    folder, staging = pathlib.Path(args[0]), pathlib.Path(args[1])
    version, arch, expected = args[2], args[3], int(args[4], 16)
    for required in (folder / 'flutter_windows.dll', folder / 'data' / 'icudtl.dat', folder / 'data' / 'flutter_assets'):
        if not required.exists(): raise SystemExit(f'Missing runtime dependency: {required.relative_to(folder)}')
    exe = next((p for p in folder.rglob('*.exe') if p.is_file() and p.name.lower() == 'superracktools.exe'), None)
    if exe is None: raise SystemExit('SuperRackTools.exe not found in staged build')
    data = exe.read_bytes()
    if data[:2] != b'MZ': raise SystemExit('Invalid PE executable')
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if pe + 6 > len(data): raise SystemExit('Truncated PE header')
    if data[pe:pe+4] != b'PE\0\0': raise SystemExit('Invalid PE signature')
    machine = struct.unpack_from('<H', data, pe+4)[0]
    if machine != expected: raise SystemExit(f'Wrong PE architecture: 0x{machine:04x}, expected 0x{expected:04x}')
    renamed = folder / 'SuperRackTools.exe'
    if exe != renamed:
        exe.rename(renamed)
    archive = staging / f'SuperRackTools-{version}-windows-{arch}.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
        for path in folder.rglob('*'):
            if path.is_file(): z.write(path, path.relative_to(folder.parent))
    with zipfile.ZipFile(archive) as z:
        bad = z.testzip()
        if bad is not None: raise SystemExit(f'Corrupt ZIP member: {bad}')
    print(f'PE machine verified: 0x{machine:04x}')
    print(f'archive: {archive}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    find = commands.add_parser("find", help="Print the executable matching a PE machine type")
    find.add_argument("release_dir")
    find.add_argument("machine")
    stage = commands.add_parser("stage", help="Validate a copied runtime and create its ZIP")
    for name in ("bundle_dir", "staging_dir", "version", "arch", "machine"):
        stage.add_argument(name)
    args = parser.parse_args()
    if args.command == "find":
        find_binary([args.release_dir, args.machine])
    else:
        stage_bundle([args.bundle_dir, args.staging_dir, args.version, args.arch, args.machine])


if __name__ == "__main__":
    main()
