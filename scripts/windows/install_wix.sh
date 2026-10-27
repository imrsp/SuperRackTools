#!/bin/bash
set -euo pipefail
# WiX 5 supports Files harvesting without WiX 6/7 OSMF terms.
dotnet tool install --tool-path "$RUNNER_TEMP/wix" wix --version 5.0.2 --framework net8.0
echo "$(cygpath -w "$RUNNER_TEMP/wix")" >> "$GITHUB_PATH"
