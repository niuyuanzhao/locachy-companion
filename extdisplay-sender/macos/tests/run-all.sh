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
    "$HERE/sources/Wire.swift" "$HERE/sources/PairingCode.swift" \
    "$HERE/sources/HidHelperProtocol.swift" "$HERE/sources/KeyMap.swift" \
    "$HERE/sources/VirtualKeyboardClient.swift" "$HERE/sources/Input.swift" \
    "$HERE/tests/ProtocolTests.swift" -o "$OUT/tests/protocol-tests"
"$OUT/tests/protocol-tests"

rm -f "$OUT/tests/hid-tests"
xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos13.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -framework Foundation \
    "$HERE/sources/HidHelperProtocol.swift" "$HERE/sources/KarabinerWire.swift" \
    "$HERE/sources/VirtualKeyboardClient.swift" "$HERE/tests/HidTests.swift" \
    -o "$OUT/tests/hid-tests"
"$OUT/tests/hid-tests"

xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos13.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -framework IOKit -framework Network \
    "$HERE/sources/Wire.swift" "$HERE/sources/PairingCode.swift" "$HERE/sources/PeerStore.swift" \
    "$HERE/sources/LinkInterfaces.swift" "$HERE/sources/Discovery.swift" \
    "$HERE/tests/ConnectionTests.swift" -o "$OUT/tests/connection-tests"
"$OUT/tests/connection-tests"

xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos13.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -import-objc-header "$OUT/generated/Mac/CGVirtualDisplayPrivate.h" \
    -framework CoreGraphics -framework CoreImage -framework CoreVideo \
    "$OUT/generated/Mac/OriginRestore.swift" "$OUT/generated/Mac/VirtualCanvasSizing.swift" \
    "$OUT/generated/Mac/VirtualDisplay.swift" "$HERE/sources/UpstreamLog.swift" \
    "$HERE/sources/Wire.swift" "$HERE/sources/DisplayModeDB.swift" "$HERE/sources/DisplayIdentity.swift" \
    "$HERE/tests/DisplayModeTests.swift" -o "$OUT/tests/display-mode-tests"
"$OUT/tests/display-mode-tests"

"$HERE/tests/tls-loopback.sh" "$OUT"

"$OUT/locachy-macos-sender" --check
"$OUT/locachy-hid-helper" --check
printf '%s\n' 'PASS: all sender checks'
