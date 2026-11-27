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

# Verify persistent keychain + signing.pass reuse across upgrades under
# Homebrew's Seatbelt post_install restrictions (Keychains read denied,
# file-write-mode denied, mach-lookup restricted to Homebrew's allowlist).
cert_sha256() {
    TARGET=$1
    CERT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/locachy-cert.XXXXXX")
    (cd "$CERT_DIR" && codesign -d --extract-certificates "$TARGET" >/dev/null 2>&1)
    SHA=$(openssl x509 -inform DER -in "$CERT_DIR/codesign0" -noout -fingerprint -sha256 2>/dev/null || true)
    rm -rf -- "$CERT_DIR"
    printf '%s' "$SHA"
}

SB_TEST=$(mktemp -d /private/tmp/locachy-sb-sign.XXXXXX)
cleanup_sb_test() { rm -rf -- "$SB_TEST"; }
trap cleanup_sb_test EXIT
mkdir -p -- "$SB_TEST/dir" "$SB_TEST/v1" "$SB_TEST/v2"
cat >"$SB_TEST/postinstall.sb" <<EOF
(version 1)
(deny network-outbound (to unix-socket))
(allow file-write* (subpath "$SB_TEST"))
(allow file-write-setugid (subpath "$SB_TEST"))
(allow file-write-mode (subpath "$SB_TEST"))
(allow file-write* (subpath "/private/tmp"))
(allow file-write-setugid (subpath "/private/tmp"))
(allow file-write-mode (subpath "/private/tmp"))
(allow file-write* (subpath "/private/var/tmp"))
(allow file-write-setugid (subpath "/private/var/tmp"))
(allow file-write-mode (subpath "/private/var/tmp"))
(allow file-write* (regex #"^/private/var/folders/[^/]+/[^/]+/[C,T]/"))
(allow file-write-setugid (regex #"^/private/var/folders/[^/]+/[^/]+/[C,T]/"))
(allow file-write-mode (regex #"^/private/var/folders/[^/]+/[^/]+/[C,T]/"))
(deny file-read* (subpath "$HOME/Library/Keychains"))
(deny file-read* (subpath "$HOME/Library/Application Support"))
(allow file-write*
    (literal "/dev/ptmx")
    (literal "/dev/dtracehelper")
    (literal "/dev/null")
    (literal "/dev/random")
    (literal "/dev/zero")
    (regex #"^/dev/fd/[0-9]+$")
    (regex #"^/dev/tty[a-z0-9]*$")
)
(deny file-write*)
(deny file-write-setugid)
(deny file-write-mode)
(deny mach-lookup)
(allow mach-lookup
    (xpc-service-name "com.apple.MTLCompilerService")
    (global-name "com.apple.mobileassetd.v2")
    (global-name "com.apple.sysmond")
    (global-name "com.apple.lsd.mapdb")
    (global-name "com.apple.bsd.dirhelper")
    (global-name "com.apple.system.opendirectoryd.libinfo")
    (global-name "com.apple.system.opendirectoryd.membership")
    (global-name "com.apple.PowerManagement.control")
    (global-name "com.apple.SecurityServer")
    (global-name "com.apple.networkd")
    (global-name "com.apple.ocspd")
    (global-name "com.apple.trustd.agent")
    (global-name "com.apple.SystemConfiguration.DNSConfiguration")
    (global-name "com.apple.SystemConfiguration.configd")
)
(deny lsopen)
(deny appleevent-send)
(allow default)
EOF

# 1. Fresh install inside Homebrew's Seatbelt sandbox: creates signing.keychain-db + signing.pass.
cp -- "$OUT/locachy-macos-sender" "$SB_TEST/v1/locachy-macos-sender"
cp -- "$OUT/locachy-hid-helper" "$SB_TEST/v1/locachy-hid-helper"
cp -R -- "$OUT/LOCachy Extended Display.app" "$SB_TEST/v1/LOCachy Extended Display.app"
codesign --force --sign - "$SB_TEST/v1/locachy-macos-sender" >/dev/null 2>&1
codesign --force --sign - "$SB_TEST/v1/locachy-hid-helper" >/dev/null 2>&1
codesign --force --deep --sign - "$SB_TEST/v1/LOCachy Extended Display.app" >/dev/null 2>&1
sandbox-exec -f "$SB_TEST/postinstall.sb" \
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$SB_TEST/nohome" TMPDIR="$SB_TEST" \
    sh "$HERE/build.sh" --sign \
    "$SB_TEST/v1/locachy-macos-sender" \
    "$SB_TEST/v1/LOCachy Extended Display.app" \
    "$SB_TEST/dir" \
    "$SB_TEST/v1/locachy-hid-helper"
verify_signed "$SB_TEST/dir/LOCachy Extended Display.app"
verify_signed "$SB_TEST/v1/locachy-macos-sender"
verify_signed "$SB_TEST/v1/locachy-hid-helper"
[ "$(stat -f '%Lp' "$SB_TEST/dir/signing.pass")" = "600" ] || { printf 'FAIL: signing.pass mode is not 600\n' >&2; exit 1; }
[ "$(stat -f '%Lp' "$SB_TEST/dir/signing.keychain-db")" = "600" ] || { printf 'FAIL: signing.keychain-db mode is not 600\n' >&2; exit 1; }
CERT1=$(cert_sha256 "$SB_TEST/dir/LOCachy Extended Display.app/Contents/MacOS/locachy-macos-sender")
[ -n "$CERT1" ] || { printf 'FAIL: could not extract signing certificate from v1\n' >&2; exit 1; }

# 2. Upgrade inside Homebrew's Seatbelt sandbox: reuses signing.keychain-db + signing.pass with the same cert.
cp -- "$OUT/locachy-macos-sender" "$SB_TEST/v2/locachy-macos-sender"
cp -- "$OUT/locachy-hid-helper" "$SB_TEST/v2/locachy-hid-helper"
cp -R -- "$OUT/LOCachy Extended Display.app" "$SB_TEST/v2/LOCachy Extended Display.app"
codesign --force --sign - "$SB_TEST/v2/locachy-macos-sender" >/dev/null 2>&1
codesign --force --sign - "$SB_TEST/v2/locachy-hid-helper" >/dev/null 2>&1
codesign --force --deep --sign - "$SB_TEST/v2/LOCachy Extended Display.app" >/dev/null 2>&1
sandbox-exec -f "$SB_TEST/postinstall.sb" \
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$SB_TEST/nohome" TMPDIR="$SB_TEST" \
    sh "$HERE/build.sh" --sign \
    "$SB_TEST/v2/locachy-macos-sender" \
    "$SB_TEST/v2/LOCachy Extended Display.app" \
    "$SB_TEST/dir" \
    "$SB_TEST/v2/locachy-hid-helper"
verify_signed "$SB_TEST/dir/LOCachy Extended Display.app"
verify_signed "$SB_TEST/v2/locachy-macos-sender"
verify_signed "$SB_TEST/v2/locachy-hid-helper"
CERT2=$(cert_sha256 "$SB_TEST/dir/LOCachy Extended Display.app/Contents/MacOS/locachy-macos-sender")
if [ "$CERT1" != "$CERT2" ]; then
    printf 'FAIL: certificate changed across sandboxed re-sign (%s vs %s)\n' "$CERT1" "$CERT2" >&2
    exit 1
fi
printf 'PASS: persistent keychain + signing.pass created and reused identical cert across Seatbelt-sandboxed --sign\n'
rm -rf -- "$SB_TEST"
trap - EXIT

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
