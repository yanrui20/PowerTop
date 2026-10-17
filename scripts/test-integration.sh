#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
SDK="$(xcrun --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
"$SWIFTC" -sdk "$SDK" -target arm64-apple-macosx14.0 -parse-as-library \
    "$ROOT/PowerTop/Shared/EnergyHelperProtocol.swift" "$ROOT/PowerTop/Models/EnergyMode.swift" \
    "$ROOT/Helper/EnergyHelper.swift" "$ROOT/scripts/helper-xpc-tests.swift" -o "$TEST_DIR/xpc-tests"
codesign --force --sign - --options runtime "$TEST_DIR/xpc-tests"
"$TEST_DIR/xpc-tests"
SOURCES=()
while IFS= read -r source; do
    [ "$(basename "$source")" = "PowerTopApp.swift" ] || SOURCES+=("$source")
done < <(find "$ROOT/PowerTop" -name '*.swift' -type f)
"$SWIFTC" -sdk "$SDK" -target arm64-apple-macosx14.0 -DPOWER_TOP_TESTING -parse-as-library \
    "${SOURCES[@]}" "$ROOT/scripts/status-layout-tests.swift" -o "$TEST_DIR/layout-tests"
"$TEST_DIR/layout-tests"
