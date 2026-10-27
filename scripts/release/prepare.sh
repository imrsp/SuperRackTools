#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
full_version=$(sed -n 's/^version: *//p' pubspec.yaml)
version=${full_version%%+*}
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid pubspec version: $version" >&2
  exit 1
fi
mode=update
if [[ "$EVENT_NAME" == 'workflow_dispatch' ]]; then
  if [[ "$REPUBLISH" != 'true' ]]; then
    mode=skip
  fi
else
  previous_full_version=''
  if [[ "$BEFORE_SHA" != "0000000000000000000000000000000000000000" ]]; then
    previous_full_version=$(git show "$BEFORE_SHA:pubspec.yaml" 2>/dev/null | sed -n 's/^version: *//p' || true)
  fi
  previous_version=${previous_full_version%%+*}
  if [[ "$version" != "$previous_version" ]]; then
    mode=create
  fi
fi
echo "version=$version" >> "$GITHUB_OUTPUT"
if [[ "$mode" == 'skip' ]]; then
  echo 'mode=skip' >> "$GITHUB_OUTPUT"
  echo "Manual release update was not requested; skipping release publication."
  exit 0
fi
tag="v$version"
if git show-ref --verify --quiet "refs/tags/$tag"; then
  mode=update
fi
python3 scripts/release/extract_notes.py \
  --tag "$tag" \
  --changelog CHANGELOG.md \
  --pubspec pubspec.yaml \
  --output "$RUNNER_TEMP/release-notes.md"
echo "mode=$mode" >> "$GITHUB_OUTPUT"
echo "Release mode: $mode ($version); release notes validated."
