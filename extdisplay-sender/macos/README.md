# macOS Extended Display Sender

macOS background sender for the LOCachy `extdisplay` receiver.

## Installation and Service

Install from the `niuyuanzhao/locachy` Homebrew tap. To enable true kernel-level virtual USB keyboard passthrough (hardware modifier holds, system hotkeys, secure input fields), install the `locachy-virtual-hid` Cask (which pulls in the pinned `karabiner-driverkit-virtualhiddevice` DriverKit extension and installs the root `locachy-hid-helper` LaunchDaemon alongside the sender formula):

```sh
brew tap niuyuanzhao/locachy
brew install --cask locachy-virtual-hid
brew services start locachy-macos-sender
```

To install only the user-space sender without DriverKit (using physical 1:1 evdev-to-macOS keycode passthrough over `CGEventPost`):

```sh
brew install niuyuanzhao/locachy/locachy-macos-sender
brew services start locachy-macos-sender
```

On the first run:
- Grant **Screen Recording** and **Accessibility** to `LOCachy Extended Display` in **System Settings → Privacy & Security**.
- When `locachy-virtual-hid` is installed, approve the **Karabiner-DriverKit-VirtualHIDDevice** driver extension in **System Settings → Login Items & Extensions → Driver Extensions** (or **Privacy & Security**). Until approved, keyboard input automatically falls back to physical 1:1 `CGEventPost` without interruption.

When `extdisplay` is opened on one or more LOCachy machines over Thunderbolt/USB4 cables, hubs, docks, or daisy chains, the background service discovers each receiver continuously and connects them simultaneously.

## Multi-Display Sessions and Persistent Pairing

- **Simultaneous receivers**: Discovery stays active while displays are streaming, so plugging in a second or third LOCachy receiver brings up its own independent virtual display, capture stream, and VideoToolbox encoder without interrupting existing displays.
- **Stable per-receiver display identity**: Each virtual display derives a deterministic non-zero `serialNum`, `productID` (`0x4C00–0x4CFF`), and display name (`LOCachy-<host>`, falling back to machine model or short `hostId` when the hostname is unset or `locachy`) from the receiver's `hostId` (or `host`, `model`, and panel size) with in-process collision avoidance. macOS WindowServer remembers each receiver's arrangement, resolution, HiDPI scaling, and color profile independently across reconnects.
- **Once-forever pairing (`peers.json`)**: Receivers advertising `hostid=` and `paired=1` (with or without an ephemeral `code=`) match stored credentials in `~/Library/Application Support/LOCachy/peers.json` (mode `0600` in a `0700` directory, updated atomically). Legacy ephemeral-code receivers continue to connect automatically without storing secrets.
  - Import a pairing token from LOCachy via the GUI **Pair…** button or the CLI. The CLI reads the token from stdin so the long-lived secret never appears in the process list:
    ```sh
    printf '%s\n' 'locachy-pair://v1?host=<hostid>&id=<identity>&code=<CODE>&name=<label>' | locachy-macos-sender --pair-token -
    locachy-macos-sender --list-peers
    locachy-macos-sender --forget-peer <hostid>
    ```
  - If a receiver rejects a stored credential at TLS handshake time, automatic retries stop for that receiver and the window prompts you to re-pair instead of looping.
- **Coordinated multi-session input**: A single process-wide `InputCoordinator` owns the one `VirtualKeyboardClient` connection to `locachy-hid-helper`, merges held HID and fallback keys/modifiers across all active sessions, refcounts mouse buttons and shares cursor position across sessions, and assigns each session a distinct Quartz tablet device ID so cancelling or disconnecting one display never drops keys or drags held on another.

## Display Geometry and Input

The receiver reports its physical panel dimensions (`pixelsWide × pixelsHigh`), sanitized `host` and `model` identifiers, exact hardware-backed video codecs (`hevc444`, `hevc420`, `h264`, or legacy `hevc`), and input capabilities (`touch`, `tablet`) in the authenticated handshake. From those panel dimensions, the sender automatically computes 5 proportional HiDPI scaling steps and synthetic physical geometry for **System Settings → Displays** (**Larger Text ↔ More Space**) across arbitrary mainstream resolutions and aspect ratios (defaulting to `1:1` HiDPI on high-density panels and `1:1` native on standard panels), and persists each machine's choice by `(host, model, pixelsWide × pixelsHigh)` in `~/Library/Application Support/LOCachy/display-modes.json`. Native `1:1` modes stream without rescaling; other scaled modes apply Metal Mitchell bicubic scaling (`B=1/3, C=1/3`) in sRGB, then select the highest codec supported by both sides' hardware (`hevc444 → hevc → hevc420 → h264`) for real-time VideoToolbox hardware encoding.

Keyboard input preserves physical 1:1 evdev scancodes so macOS applies its own active keyboard layout, input method, and modifier semantics natively:
- When the `locachy-hid-helper` LaunchDaemon and `Karabiner-DriverKit-VirtualHIDDevice` DriverKit extension are active, evdev keycodes are translated directly into USB HID Keyboard/Consumer usage reports and injected as a real virtual USB keyboard. `locachy-hid-helper` authenticates the connecting sender via kernel `audit_token`, active console user UID, executable path, and code-signing identifier (`org.locachy.extdisplay.sender`), and immediately sends an all-keys-released reset report if the sender disconnects.
- When the virtual HID driver is absent, not yet approved, or mismatched in protocol version, keyboard input automatically falls back to 1:1 physical evdev-to-`CGKeyCode` posting over `CGEventPost` (falling back to logical `keysym` mapping only for keys without a physical evdev mapping).

Relative mouse and trackpad input from LOCachy roam across all active Mac displays. When the receiver offers `"touch"` and `"tablet"`, multi-touch touchscreen gestures (tap, drag, long-press right-click, two-finger scroll, pinch zoom) and active stylus pen events (proximity, pen/eraser switching, pressure, X/Y tilt, hover, barrel buttons) map directly onto the extended display's bounds. When the cable is unplugged, the virtual display is removed and the service returns to waiting for the next connection.
