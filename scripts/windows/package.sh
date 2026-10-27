#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
VERSION=$(sed -n 's/^version: *//p' "$ROOT/pubspec.yaml" | sed 's/+.*//')
ARCH=${1:?usage: scripts/windows/package.sh x64|arm64}
case "$ARCH" in x64) EXPECTED=0x8664 ;; arm64) EXPECTED=0xAA64 ;; *) echo 'architecture must be x64 or arm64' >&2; exit 2 ;; esac
case "$ARCH" in
  x64)
    UPGRADE_CODE='{A6B3DB8A-8F9E-4C62-A931-F6A279C3D1E4}'
    SHORTCUT_GUID='{56B91F60-B3A1-4D66-AC18-AD1594DD14B3}'
    ;;
  arm64)
    UPGRADE_CODE='{C8144072-397E-42F6-92F8-9113A771C91B}'
    SHORTCUT_GUID='{F1AE9E90-FF67-49F7-94D5-2A7677667E06}'
    ;;
esac
if [[ ! -d "$ROOT/windows/runner" ]]; then
  flutter create --platforms=windows --project-name super_rack_tools "$ROOT"
fi
flutter pub get
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ROOT/scripts/windows/configure.ps1"
if [[ "$ARCH" == x64 ]]; then
  # Flutter selects the Windows architecture from the Flutter SDK host ABI.
  flutter build windows --release --no-pub
else
  # The stable Windows Flutter SDK is x64-only. Generate the Flutter CMake
  # configuration with Flutter, then use Visual Studio's ARM64 cross-toolchain.
  flutter build windows --release --config-only --no-pub
  python3 "$ROOT/scripts/windows/prepare_arm64.py"
  cmake -S "$ROOT/windows" -B "$ROOT/build/windows/arm64" \
    -G 'Visual Studio 17 2022' -A ARM64 \
    -DFLUTTER_TARGET_PLATFORM=windows-arm64
  cmake --build "$ROOT/build/windows/arm64" --config Release --target INSTALL
fi
BINARY=$(python3 "$ROOT/scripts/windows/bundle.py" find \
  "$ROOT/build/windows/$ARCH/runner/Release" "$EXPECTED")
RELEASE_DIR=$(dirname "$BINARY")
DEST="$ROOT/dist/SuperRackTools-$VERSION-windows-$ARCH"
ZIP_DEST="$ROOT/dist/SuperRackTools-$VERSION-windows-$ARCH.zip"
MSI_DEST="$ROOT/dist/SuperRackTools-$VERSION-windows-$ARCH.msi"
for output in "$DEST" "$MSI_DEST" "$ZIP_DEST"; do
  [[ ! -e "$output" ]] || { echo "Destination exists: $output" >&2; exit 1; }
done
mkdir -p "$ROOT/dist"
STAGING=$(mktemp -d "$ROOT/dist/.windows-$ARCH.XXXXXX")
cleanup() { python3 -c 'import pathlib,shutil,sys; shutil.rmtree(pathlib.Path(sys.argv[1]),ignore_errors=True)' "$STAGING"; }
trap cleanup EXIT
BUNDLE="$STAGING/SuperRackTools-$VERSION-windows-$ARCH"
mkdir -p "$BUNDLE"
cp -R "$RELEASE_DIR/"* "$BUNDLE/"
python3 "$ROOT/scripts/windows/bundle.py" stage \
  "$BUNDLE" "$STAGING" "$VERSION" "$ARCH" "$EXPECTED"
wix build "$ROOT/scripts/windows/installer.wxs" \
  -arch "$ARCH" \
  -d "Version=$VERSION" \
  -d "UpgradeCode=$UPGRADE_CODE" \
  -d "ShortcutGuid=$SHORTCUT_GUID" \
  -d "BundleDir=$(cygpath -w "$BUNDLE")" \
  -o "$STAGING/SuperRackTools-$VERSION-windows-$ARCH.msi"
mv "$BUNDLE" "$DEST"
mv "$STAGING/SuperRackTools-$VERSION-windows-$ARCH.msi" "$MSI_DEST"
mv "$STAGING/SuperRackTools-$VERSION-windows-$ARCH.zip" "$ZIP_DEST"
printf 'runtime package: %s\n' "$DEST"
printf 'installer: %s\n' "$MSI_DEST"
printf 'archive: %s\n' "$ZIP_DEST"
