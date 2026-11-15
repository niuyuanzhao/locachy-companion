#!/bin/sh
# Build the sender and run protocol, discovery fixture and loopback TLS checks.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-/tmp/locachy-macos-sender-build}
mkdir -p "$OUT/tests"

"$HERE/build.sh" "$OUT"

rm -f "$OUT/tests/protocol-tests"
xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos13.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -framework AppKit -framework Carbon \
    "$HERE/sources/Wire.swift" "$HERE/sources/PairingCode.swift" "$HERE/sources/Input.swift" \
    "$HERE/tests/ProtocolTests.swift" -o "$OUT/tests/protocol-tests"
"$OUT/tests/protocol-tests"

xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos13.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -framework IOKit -framework Network \
    "$HERE/sources/Wire.swift" "$HERE/sources/PairingCode.swift" "$HERE/sources/LinkInterfaces.swift" "$HERE/sources/Discovery.swift" \
    "$HERE/tests/ConnectionTests.swift" -o "$OUT/tests/connection-tests"
"$OUT/tests/connection-tests"

"$HERE/tests/tls-loopback.sh" "$OUT"

"$OUT/locachy-macos-sender" --check
printf '%s\n' 'PASS: all sender checks'
