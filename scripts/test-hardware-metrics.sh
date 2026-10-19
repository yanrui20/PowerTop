#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
if [ -d "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" ]; then
    SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    SWIFTC="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
else
    SDK="$(xcrun --show-sdk-path)"
    SWIFTC="$(xcrun --find swiftc)"
fi
SOURCES=()
while IFS= read -r source; do
    [ "$(basename "$source")" = "PowerTopApp.swift" ] || SOURCES+=("$source")
done < <(find "$ROOT/PowerTop" -name '*.swift' -type f)
"$SWIFTC" -sdk "$SDK" -target arm64-apple-macosx14.0 -parse-as-library \
    "${SOURCES[@]}" "$ROOT/scripts/hardware-metrics-tests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$@"
