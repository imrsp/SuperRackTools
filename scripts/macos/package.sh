#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -x "$ROOT/.tools/flutter/bin/flutter" ]]; then
  FLUTTER="$ROOT/.tools/flutter/bin/flutter"
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER="$(command -v flutter)"
else
  echo 'Flutter SDK not found. Add Flutter to PATH or place the project SDK at .tools/flutter.' >&2
  exit 127
fi
cd "$ROOT"
VERSION=$(sed -n 's/^version: *//p' "$ROOT/pubspec.yaml" | sed 's/+.*//')
OUTPUT_DIR=${1:-"$ROOT/dist"}
APP=""
DEST="$OUTPUT_DIR/SuperRackTools.app"
ZIP="$OUTPUT_DIR/SuperRackTools-$VERSION-macos-universal.zip"
DMG="$OUTPUT_DIR/SuperRackTools-$VERSION-macos-universal.dmg"
SIGN_IDENTITY=${DEVELOPER_ID_APPLICATION:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
if [[ -n "$SIGN_IDENTITY" && -z "$NOTARY_PROFILE" ]] || [[ -z "$SIGN_IDENTITY" && -n "$NOTARY_PROFILE" ]]; then
  echo 'Set both DEVELOPER_ID_APPLICATION and NOTARY_PROFILE for a notarized release.' >&2
  exit 2
fi
mkdir -p "$OUTPUT_DIR"
for output in "$DEST" "$ZIP" "$DMG"; do
  [[ ! -e "$output" ]] || { echo "Destination exists: $output" >&2; exit 1; }
done
mkdir -p "$ROOT/work/tmp"
DMG_ROOT=$(mktemp -d "$ROOT/work/tmp/dmg.XXXXXX")
trap 'rm -rf "$DMG_ROOT"' EXIT
if [[ ! -d "$ROOT/macos/Runner.xcodeproj" ]]; then
  "$FLUTTER" create --platforms=macos --project-name super_rack_tools "$ROOT"
fi
"$FLUTTER" pub get
"$ROOT/scripts/macos/configure.sh"
# Flutter release builds macOS as universal by default. The checks below fail
# the package if the app or any bundled framework is missing either slice.
"$FLUTTER" build macos --release --no-pub
APP=$(find "$ROOT/build/macos/Build/Products/Release" -maxdepth 1 -name 'SuperRackTools.app' -print -quit)
[[ -n "$APP" && -d "$APP" ]] || { echo "Flutter macOS app not found" >&2; exit 1; }
SQLITE_FRAMEWORK="$APP/Contents/Frameworks/sqlite3.framework/sqlite3"
[[ -f "$SQLITE_FRAMEWORK" ]] || {
  echo "Bundled SQLite framework not found: $SQLITE_FRAMEWORK" >&2
  exit 1
}
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName SuperRackTools' "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Set :CFBundleName SuperRackTools' "$APP/Contents/Info.plist" 2>/dev/null || true
while IFS= read -r -d '' binary; do
  file -b "$binary" | grep -q 'Mach-O' || continue
  lipo "$binary" -verify_arch arm64 x86_64 >/dev/null || {
    echo "Missing universal slice: $binary" >&2; exit 1;
  }
done < <(find "$APP/Contents" -type f -print0)
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
if [[ -n "$SIGN_IDENTITY" ]]; then
  NOTARY_ZIP="$DMG_ROOT/notarize.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$NOTARY_ZIP"
fi
# Stage the complete app outside dist, then publish it with a same-volume
# rename so it cannot be opened while its frameworks are still being copied.
cp -R "$APP" "$DMG_ROOT/SuperRackTools.app"
mv "$DMG_ROOT/SuperRackTools.app" "$DEST"
ditto -c -k --sequesterRsrc --keepParent "$DEST" "$ZIP"
cp -R "$DEST" "$DMG_ROOT/SuperRackTools.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -quiet -volname SuperRackTools -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
printf 'built: %s\n' "$DEST"
printf 'archive: %s\n' "$ZIP"
printf 'disk image: %s\n' "$DMG"
