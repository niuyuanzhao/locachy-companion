#!/bin/sh
# Build the sender and run protocol, discovery fixture and loopback TLS checks.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-/tmp/locachy-macos-sender-build}
mkdir -p "$OUT/tests"

LOCACHY_SIGN_DIR="$OUT/signing" LOCACHY_SIGN_EPHEMERAL=1 "$HERE/build.sh" "$OUT"

verify_signed() {
    TARGET=$1
    INFO=$(codesign -dv --verbose=2 "$TARGET" 2>&1)
    if ! printf '%s\n' "$INFO" | grep -Fq "Authority=LOCachy Extended Display Signing"; then
        printf 'FAIL: %s is not signed with LOCachy Extended Display Signing\n%s\n' "$TARGET" "$INFO" >&2
        exit 1
    fi
    if printf '%s\n' "$INFO" | grep -Fq "Signature=adhoc"; then
        printf 'FAIL: %s fell back to ad-hoc signature\n%s\n' "$TARGET" "$INFO" >&2
        exit 1
    fi
    printf 'PASS: %s signed with LOCachy Extended Display Signing\n' "$(basename "$TARGET")"
}

verify_signed "$OUT/LOCachy Extended Display.app"
verify_signed "$OUT/locachy-macos-sender"
verify_signed "$OUT/locachy-hid-helper"

SIGN_TEST="$OUT/tests/sign-sandbox"
rm -rf -- "$SIGN_TEST"
mkdir -p -- "$SIGN_TEST/dir"
cp -- "$OUT/locachy-macos-sender" "$SIGN_TEST/locachy-macos-sender"
cp -- "$OUT/locachy-hid-helper" "$SIGN_TEST/locachy-hid-helper"
cp -R -- "$OUT/LOCachy Extended Display.app" "$SIGN_TEST/LOCachy Extended Display.app"
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$SIGN_TEST" LOCACHY_SIGN_EPHEMERAL=1 \
    sh "$HERE/build.sh" --sign \
    "$SIGN_TEST/locachy-macos-sender" \
    "$SIGN_TEST/LOCachy Extended Display.app" \
    "$SIGN_TEST/dir" \
    "$SIGN_TEST/locachy-hid-helper"
verify_signed "$SIGN_TEST/dir/LOCachy Extended Display.app"
verify_signed "$SIGN_TEST/locachy-macos-sender"
verify_signed "$SIGN_TEST/locachy-hid-helper"
rm -rf -- "$SIGN_TEST"

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
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -framework IOKit -framework Network -framework Security \
    "$HERE/sources/Wire.swift" "$HERE/sources/PairingCode.swift" "$HERE/sources/PeerStore.swift" \
    "$HERE/sources/SecureTransport.swift" "$HERE/sources/LinkInterfaces.swift" "$HERE/sources/Discovery.swift" \
    "$HERE/tests/ConnectionTests.swift" -o "$OUT/tests/connection-tests"
"$OUT/tests/connection-tests"

xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos13.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -import-objc-header "$OUT/generated/Mac/CGVirtualDisplayPrivate.h" \
    -framework CoreGraphics -framework CoreImage -framework CoreVideo -framework Metal -framework MetalPerformanceShaders \
    "$OUT/generated/Mac/OriginRestore.swift" "$OUT/generated/Mac/VirtualCanvasSizing.swift" \
    "$OUT/generated/Mac/VirtualDisplay.swift" "$HERE/sources/UpstreamLog.swift" \
    "$HERE/sources/Wire.swift" "$HERE/sources/DisplayModeDB.swift" "$HERE/sources/DisplayIdentity.swift" \
    "$HERE/sources/FramePipeline.swift" \
    "$HERE/tests/DisplayModeTests.swift" -o "$OUT/tests/display-mode-tests"
"$OUT/tests/display-mode-tests"

"$HERE/tests/tls-loopback.sh" "$OUT"

"$OUT/locachy-macos-sender" --check
"$OUT/locachy-hid-helper" --check
printf '%s\n' 'PASS: all sender checks'
