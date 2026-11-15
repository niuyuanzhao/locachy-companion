# macOS extended-display sender

A LOCachy sender for macOS. Managed as a background LaunchAgent service (`brew services start locachy-macos-sender`) or run with no arguments, it watches available Thunderbolt/USB4 IP links, discovers the receiver over the cable, and connects automatically without a Dock icon or manual pairing prompt. It adds one virtual display to the current login session, captures that display with ScreenCaptureKit at the receiver's native panel resolution, encodes hardware HEVC Main 4:4:4 (or H.264 fallback) with VideoToolbox, and sends it to the LOCachy receiver over the link. LOCachy keyboard and touchpad input is applied across the Mac's displays.

A Thunderbolt/USB4 host link may be direct or may pass through a compatible Hub, Dock, monitor, or daisy chain. The sender uses the effective Thunderbolt IP interface (including macOS Thunderbolt Bridge).

## Upstream source and license

The virtual-display code comes from `peetzweg/opendisplay` commit `0f44853adc5d44646a9e4d74e4516db460efb8bb` (release 1.30.2), locked by archive SHA-256 in `upstream.json`. `build.sh` uses four upstream files (`VirtualDisplay.swift`, `OriginRestore.swift`, `VirtualCanvasSizing.swift`, `CGVirtualDisplayPrivate.h`) and applies `patches/session-display.patch`.

Upstream is released under the GNU GPL version 3 (its `LICENSE` is pinned by hash in `upstream.json`). The sender's own files are GPL-3.0-or-later; a built sender combines both under the GPL version 3.

`CGVirtualDisplay` is a private CoreGraphics API. `--check` reports whether the classes exist.

## Build and checks

Requires Xcode Command Line Tools, `curl`, and `shasum`. The tests also need `python3` with its `ssl` module built against OpenSSL 1.1.1 or newer.

```sh
extdisplay-sender/macos/build.sh /tmp/locachy-macos-build          # CLI + app bundle
extdisplay-sender/macos/tests/run-all.sh /tmp/locachy-macos-build  # build + all checks
```

## Running

Start the unattended background service with Homebrew:

```sh
brew services start locachy-macos-sender
```

The service watches verified Thunderbolt IP links, including the macOS Thunderbolt Bridge used by hubs and daisy chains, discovers the receiver, and connects automatically when `extdisplay` is opened on LOCachy. Five scaled HiDPI resolutions (`1080×720`, `1440×960`, `1728×1152`, `1920×1280`, `2160×1440`) can be selected in System Settings → Displays and are remembered across sessions while streaming at the receiver's full physical resolution.

For diagnostics or scripts, the manual CLI form remains available:

```sh
locachy-macos-sender --interface <verified-Thunderbolt-IP-interface> --address <fe80::...%interface> --port 27183
```

macOS 14 or later is needed. The connection window shows Screen Recording and Accessibility readiness and buttons to open the relevant System Settings panes.

## Session profile (frozen)

**Transport.** The receiver listens; the sender dials. Only a numeric link-local address on a verified Thunderbolt IP interface is accepted. Automatic discovery is interface-scoped Bonjour/DNS-SD for `_locachy-ext._tcp.local.`, limited to IPv6 link-local addresses and port 27183. The TXT record carries `pv=3`, `extended=1`, `pair=psk128`, and the per-session `code` on the isolated Thunderbolt link. The receiver removes its advertisement when pairing ends.

The sender classifies hardware via IOKit Thunderbolt IP driver ancestry and queries bridge membership using `/sbin/ifconfig IFACE`, accepting a bridge whose members are Thunderbolt IP ports.

**TLS.**
- TLS 1.2 only, with suite `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8).
- PSK identity `locachy-extdisplay-v1`; ALPN `locachy-extdisplay-v1` is required.
- Session tickets, resumption, certificates, and renegotiation are disabled.
- The sender checks the negotiated version, suite, and ALPN when the handshake completes.

**Per-session key.** The LOCachy broker generates 16 random bytes per connection and encodes them as RFC 4648 base32 (26 characters).

## Protocol

- `hello` arrives first: `pv` 3, `locachy` 1, `extendedOnly` true, the panel physical dimensions, H.264 among `videoCaps`, and all five input capabilities.
- The sender replies `welcome` once, then `streamConfig` (H.264, size, rate up to 60).
- Video is Annex-B access units with 4-byte start codes; every IDR carries SPS/PPS.
- Receiver `ping` gets `pong` with the same `t`. `closing` ends the session.

Input:
- `key` uses the receiver's logical keysym, resolved against the Mac's current keyboard layout. Super maps to Command, Alt/AltGr to Option, Ctrl to Control.
- `button` covers 272/273/274; `pointer` is a normalized position.
- `scroll` takes deltas in stream pixels with natural sign (`phase` 0..4, `source` 0..4).
- `cancel` (`scope` `all`) releases held keys and buttons and ends any open scroll gesture.

## Lifecycle

A session owns one virtual display. When the cable disconnects or the session ends, the sender releases held keys and buttons, stops capture, removes the virtual display, and returns to watching for the next connection.

Reference listener (`tests/tls-listener.py`):

```sh
python3 -I tests/tls-listener.py PORT <32 hex digits> locachy-extdisplay-v1 locachy-extdisplay-v1 PSK-AES128-GCM-SHA256 1.2 LOG
```
