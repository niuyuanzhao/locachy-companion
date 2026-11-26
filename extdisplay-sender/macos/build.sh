#!/bin/sh
# Build the LOCachy Mac extended-display sender.
# The upstream source is fetched by immutable commit and verified before use.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# The signing keychain passphrase is random per user and kept in the login keychain
# under this service name. It is never written into this repository.
SIGN_PASS_SERVICE="org.locachy.extdisplay.signing-keychain"

sign_keychain_pass_get() {
    security find-generic-password -a "${USER:-locachy}" -s "$SIGN_PASS_SERVICE" -w 2>/dev/null || true
}

sign_keychain_pass_set() {
    NEW_PASS=$1
    printf 'add-generic-password -a "%s" -s "%s" -w "%s" -T /usr/bin/security\n' \
        "${USER:-locachy}" "$SIGN_PASS_SERVICE" "$NEW_PASS" | security -i >/dev/null 2>&1
}

sign_keychain_lock() {
    KC_PATH=$1
    security lock-keychain "$KC_PATH" >/dev/null 2>&1 || true
}

sign_outputs() {
    SIGN_PRODUCT=$1
    SIGN_APP=$2
    SIGN_DIR=$3
    SIGN_TMP=$4
    SIGN_HELPER=${5:-}
    mkdir -p -- "$SIGN_DIR" 2>/dev/null || SIGN_DIR="$SIGN_TMP/signing"
    mkdir -p -- "$SIGN_DIR"
    chmod 700 "$SIGN_DIR" 2>/dev/null || true
    EPHEMERAL="${LOCACHY_SIGN_EPHEMERAL:-0}"
    if [ "$EPHEMERAL" = "1" ]; then
        # Test builds get a throwaway keychain under SIGN_TMP. They never read or
        # change the user's signing keychain or the login keychain.
        KEYCHAIN="$SIGN_TMP/ephemeral-signing.keychain-db"
        rm -f -- "$KEYCHAIN"
    else
        KEYCHAIN="$SIGN_DIR/signing.keychain-db"
        if [ ! -f "$KEYCHAIN" ] && [ -n "${USER:-}" ] && [ -f "/Users/$USER/Library/Application Support/LOCachy/signing.keychain-db" ]; then
            cp -- "/Users/$USER/Library/Application Support/LOCachy/signing.keychain-db" "$KEYCHAIN" 2>/dev/null || true
            chmod 600 "$KEYCHAIN" 2>/dev/null || true
        fi
    fi

    KEYCHAIN_READY=0
    if [ ! -f "$KEYCHAIN" ]; then
        if [ "$EPHEMERAL" = "1" ]; then
            PASS=$(openssl rand -hex 32)
        else
            # One passphrase per user, shared by every copy of the keychain: reuse the stored
            # one, and generate and store a new one only when none exists. Never overwrite it.
            PASS=$(sign_keychain_pass_get)
            if [ -z "$PASS" ]; then
                PASS=$(openssl rand -hex 32)
                if ! sign_keychain_pass_set "$PASS"; then
                    printf 'warning: cannot store the signing keychain passphrase in the login keychain; using ad-hoc signature\n' >&2
                    PASS=""
                fi
            fi
        fi
        if [ -n "$PASS" ]; then
            CNF="$SIGN_TMP/codesign-openssl.cnf"
            PASS_FILE="$SIGN_TMP/p12.pass"
            cat >"$CNF" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = LOCachy Extended Display Signing
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
EOF
            (umask 077; printf '%s\n' "$PASS" > "$PASS_FILE")
            openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SIGN_TMP/cs.key" -out "$SIGN_TMP/cs.crt" -days 3650 -config "$CNF" >/dev/null 2>&1
            openssl pkcs12 -export -out "$SIGN_TMP/cs.p12" -inkey "$SIGN_TMP/cs.key" -in "$SIGN_TMP/cs.crt" -passout "file:$PASS_FILE" -legacy >/dev/null 2>&1 || \
                openssl pkcs12 -export -out "$SIGN_TMP/cs.p12" -inkey "$SIGN_TMP/cs.key" -in "$SIGN_TMP/cs.crt" -passout "file:$PASS_FILE" >/dev/null 2>&1
            if {
                printf 'create-keychain -p "%s" "%s"\n' "$PASS" "$KEYCHAIN"
                printf 'unlock-keychain -p "%s" "%s"\n' "$PASS" "$KEYCHAIN"
                printf 'set-keychain-settings -l -u -t 300 "%s"\n' "$KEYCHAIN"
                printf 'import "%s" -k "%s" -P "%s" -T /usr/bin/codesign\n' "$SIGN_TMP/cs.p12" "$KEYCHAIN" "$PASS"
                printf 'set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "%s" "%s"\n' "$PASS" "$KEYCHAIN"
            } | security -i >/dev/null 2>&1; then
                chmod 600 "$KEYCHAIN" 2>/dev/null || true
                KEYCHAIN_READY=1
            else
                printf 'warning: cannot create signing keychain %s; using ad-hoc signature\n' "$KEYCHAIN" >&2
            fi
            rm -f -- "$CNF" "$PASS_FILE" "$SIGN_TMP/cs.key" "$SIGN_TMP/cs.crt" "$SIGN_TMP/cs.p12"
        fi
    else
        PASS=$(sign_keychain_pass_get)
        if [ -n "$PASS" ] && printf 'unlock-keychain -p "%s" "%s"\n' "$PASS" "$KEYCHAIN" | security -i >/dev/null 2>&1; then
            security set-keychain-settings -l -u -t 300 "$KEYCHAIN" >/dev/null 2>&1 || true
            KEYCHAIN_READY=1
        else
            printf 'warning: %s does not open with the passphrase in the login keychain; using ad-hoc signature\n' "$KEYCHAIN" >&2
        fi
    fi

    if [ "$KEYCHAIN_READY" -eq 1 ]; then
        codesign --force --keychain "$KEYCHAIN" --sign "LOCachy Extended Display Signing" --identifier org.locachy.extdisplay.sender "$SIGN_PRODUCT" >/dev/null 2>&1 || \
            codesign --force --sign - --identifier org.locachy.extdisplay.sender "$SIGN_PRODUCT" >/dev/null 2>&1 || true
        cp -- "$SIGN_PRODUCT" "$SIGN_APP/Contents/MacOS/locachy-macos-sender"
        codesign --force --deep --keychain "$KEYCHAIN" --sign "LOCachy Extended Display Signing" --identifier org.locachy.extdisplay.sender "$SIGN_APP" >/dev/null 2>&1 || \
            codesign --force --deep --sign - --identifier org.locachy.extdisplay.sender "$SIGN_APP" >/dev/null 2>&1 || true
        if [ -n "$SIGN_HELPER" ] && [ -f "$SIGN_HELPER" ]; then
            codesign --force --keychain "$KEYCHAIN" --sign "LOCachy Extended Display Signing" --identifier org.locachy.extdisplay.hid-helper "$SIGN_HELPER" >/dev/null 2>&1 || \
                codesign --force --sign - --identifier org.locachy.extdisplay.hid-helper "$SIGN_HELPER" >/dev/null 2>&1 || true
        fi
        sign_keychain_lock "$KEYCHAIN"
        if [ "$EPHEMERAL" = "1" ]; then
            rm -f -- "$KEYCHAIN"
        fi
    else
        codesign --force --sign - --identifier org.locachy.extdisplay.sender "$SIGN_PRODUCT" >/dev/null 2>&1 || true
        cp -- "$SIGN_PRODUCT" "$SIGN_APP/Contents/MacOS/locachy-macos-sender"
        codesign --force --deep --sign - --identifier org.locachy.extdisplay.sender "$SIGN_APP" >/dev/null 2>&1 || true
        if [ -n "$SIGN_HELPER" ] && [ -f "$SIGN_HELPER" ]; then
            codesign --force --sign - --identifier org.locachy.extdisplay.hid-helper "$SIGN_HELPER" >/dev/null 2>&1 || true
        fi
    fi
}

if [ "${1:-}" = "--sign" ]; then
    [ $# -eq 4 ] || [ $# -eq 5 ] || { printf '%s\n' 'usage: build.sh --sign PRODUCT APP SIGN_DIR [HELPER]' >&2; exit 2; }
    TMP_SIGN=$(mktemp -d "${TMPDIR:-/tmp}/locachy-sign.XXXXXX")
    trap 'rm -rf -- "$TMP_SIGN"' EXIT
    rm -rf -- "$4/LOCachy Extended Display.app"
    cp -R -- "$3" "$4/LOCachy Extended Display.app"
    sign_outputs "$2" "$4/LOCachy Extended Display.app" "$4" "$TMP_SIGN" "${5:-}"
    cp -- "$4/LOCachy Extended Display.app/Contents/MacOS/locachy-macos-sender" "$3/Contents/MacOS/locachy-macos-sender" 2>/dev/null || true
    exit 0
fi

OUT=${1:-/tmp/locachy-macos-sender-build}
UPSTREAM_COMMIT=0f44853adc5d44646a9e4d74e4516db460efb8bb
UPSTREAM_SHA256=dba0ece10f0d0d810b63f64269d62dd3eaea52058f7566ea1159fb17be0f1a15
URL="https://codeload.github.com/peetzweg/opendisplay/tar.gz/$UPSTREAM_COMMIT"
ARCHIVE="$OUT/opendisplay-$UPSTREAM_COMMIT.tar.gz"
SOURCE="$OUT/opendisplay-$UPSTREAM_COMMIT"
GENERATED="$OUT/generated"
PRODUCT="$OUT/locachy-macos-sender"
HELPER="$OUT/locachy-hid-helper"
APP="$OUT/LOCachy Extended Display.app"

case "$(uname -s)" in Darwin) ;; *) printf '%s\n' 'The macOS sender must be built on macOS with xcrun.' >&2; exit 2 ;; esac
command -v xcrun >/dev/null || { printf '%s\n' 'xcrun is required.' >&2; exit 2; }
command -v curl >/dev/null || { printf '%s\n' 'curl is required.' >&2; exit 2; }
command -v shasum >/dev/null || { printf '%s\n' 'shasum is required.' >&2; exit 2; }
rm -rf -- "$SOURCE" "$GENERATED"
mkdir -p -- "$OUT" "$GENERATED"
if [ ! -f "$ARCHIVE" ]; then
    curl --fail --location --retry 2 --connect-timeout 15 --max-time 180 "$URL" -o "$ARCHIVE"
fi
actual=$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)
[ "$actual" = "$UPSTREAM_SHA256" ] || { printf 'OpenDisplay archive digest mismatch: %s\n' "$actual" >&2; exit 1; }
tar -xzf "$ARCHIVE" -C "$OUT"
# GitHub's archive directory is opendisplay-<commit>.
[ -d "$SOURCE" ] || { printf 'Missing extracted upstream tree: %s\n' "$SOURCE" >&2; exit 1; }
for file in Mac/VirtualDisplay.swift Mac/OriginRestore.swift Mac/VirtualCanvasSizing.swift Mac/CGVirtualDisplayPrivate.h; do
    mkdir -p "$GENERATED/$(dirname "$file")"
    cp "$SOURCE/$file" "$GENERATED/$file"
done
patch --batch --forward --fuzz=0 -d "$GENERATED" -p1 < "$ROOT/patches/session-display.patch"

SDK=$(xcrun --sdk macosx --show-sdk-path)
SWIFTC=$(xcrun --find swiftc)
# Use the host architecture so this command is safe on both Apple silicon and
# Intel build Macs. A release builder can invoke this recipe once per arch and
# lipo the two resulting binaries outside this repository.
TARGET="$(uname -m)-apple-macos13.0"
"$SWIFTC" -swift-version 5 -parse-as-library -target "$TARGET" -sdk "$SDK" -O \
    -import-objc-header "$GENERATED/Mac/CGVirtualDisplayPrivate.h" \
    -framework AppKit -framework ApplicationServices -framework Carbon -framework CoreGraphics -framework CoreImage -framework CoreMedia \
    -framework CoreServices -framework CoreVideo -framework IOKit -framework Metal -framework Network \
    -framework ScreenCaptureKit -framework Security -framework VideoToolbox \
    "$GENERATED/Mac/OriginRestore.swift" \
    "$GENERATED/Mac/VirtualCanvasSizing.swift" \
    "$GENERATED/Mac/VirtualDisplay.swift" \
    "$ROOT/sources/UpstreamLog.swift" \
    "$ROOT/sources/Wire.swift" \
    "$ROOT/sources/DisplayModeDB.swift" \
    "$ROOT/sources/DisplayIdentity.swift" \
    "$ROOT/sources/PairingCode.swift" \
    "$ROOT/sources/PeerStore.swift" \
    "$ROOT/sources/SecureTransport.swift" \
    "$ROOT/sources/HidHelperProtocol.swift" \
    "$ROOT/sources/KeyMap.swift" \
    "$ROOT/sources/VirtualKeyboardClient.swift" \
    "$ROOT/sources/Input.swift" \
    "$ROOT/sources/Capture.swift" \
    "$ROOT/sources/LinkInterfaces.swift" \
    "$ROOT/sources/Discovery.swift" \
    "$ROOT/sources/ConnectionWindow.swift" \
    "$ROOT/sources/SenderMain.swift" \
    -o "$PRODUCT"

"$SWIFTC" -swift-version 5 -parse-as-library -target "$TARGET" -sdk "$SDK" -O \
    -framework Foundation -framework Security -framework SystemConfiguration \
    "$ROOT/sources/HidHelperProtocol.swift" \
    "$ROOT/sources/KarabinerWire.swift" \
    "$ROOT/sources/HidHelperMain.swift" \
    -o "$HELPER"

# The app bundle is the normal no-argument entry point. The raw binary remains
# available for the documented manual CLI and for protocol tests.
rm -rf -- "$APP"
mkdir -p -- "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -- "$PRODUCT" "$APP/Contents/MacOS/locachy-macos-sender"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>LOCachy Extended Display</string>
<key>CFBundleExecutable</key><string>locachy-macos-sender</string>
<key>CFBundleIdentifier</key><string>org.locachy.extdisplay.sender</string>
<key>CFBundleName</key><string>LOCachy Extended Display</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.2</string>
<key>CFBundleVersion</key><string>0.5.2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Discover and connect to the LOCachy extended display over a dedicated Thunderbolt or USB4 link.</string>
<key>NSBonjourServices</key><array><string>_locachy-ext._tcp</string></array>
<key>NSScreenCaptureUsageDescription</key><string>Capture the LOCachy virtual display so it can be shown on the LOCachy computer.</string>
<key>NSAccessibilityUsageDescription</key><string>Apply keyboard and pointer input from LOCachy to the virtual display.</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST
SIGN_DIR="${LOCACHY_SIGN_DIR:-${HOME:-$OUT}/Library/Application Support/LOCachy}"
sign_outputs "$PRODUCT" "$APP" "$SIGN_DIR" "$OUT" "$HELPER"

printf 'PASS: built %s\n' "$PRODUCT"
printf 'PASS: built %s\n' "$HELPER"
printf 'PASS: built app bundle %s\n' "$APP"

