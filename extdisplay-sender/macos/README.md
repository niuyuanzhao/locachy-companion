# macOS Extended Display Sender

macOS background sender for the LOCachy `extdisplay` receiver.

## Installation and Service

Install from the `niuyuanzhao/locachy` Homebrew tap and start the background service:

```sh
brew tap niuyuanzhao/locachy
brew install locachy-macos-sender
brew services start locachy-macos-sender
```

On the first run, grant **Screen Recording** and **Accessibility** to `LOCachy Extended Display` in **System Settings → Privacy & Security**.

When `extdisplay` is opened on LOCachy over a Thunderbolt/USB4 cable, hub, dock, or daisy chain, the background service discovers the receiver over the link and connects automatically.

## Display Geometry and Input

The receiver reports its physical panel dimensions (`pixelsWide × pixelsHigh`), sanitized `host` and `model` identifiers, exact hardware-backed video codecs (`hevc444`, `hevc420`, `h264`, or legacy `hevc`), and input capabilities (`touch`, `tablet`) in the authenticated handshake. From those panel dimensions, the sender automatically computes 5 proportional HiDPI scaling steps and synthetic physical geometry for **System Settings → Displays** (**Larger Text ↔ More Space**) across arbitrary mainstream resolutions and aspect ratios (defaulting to `1:1` HiDPI on high-density panels and `1:1` native on standard panels), and persists each machine's choice by `(host, model, pixelsWide × pixelsHigh)` in `~/Library/Application Support/LOCachy/display-modes.json`. Native `1:1` modes stream without rescaling; other scaled modes apply Metal Mitchell bicubic scaling (`B=1/3, C=1/3`) in sRGB, then select the highest codec supported by both sides' hardware (`hevc444 → hevc → hevc420 → h264`) for real-time VideoToolbox hardware encoding.

Relative mouse and trackpad input from LOCachy roam across all active Mac displays. When the receiver offers `"touch"` and `"tablet"`, multi-touch touchscreen gestures (tap, drag, long-press right-click, two-finger scroll, pinch zoom) and active stylus pen events (proximity, pen/eraser switching, pressure, X/Y tilt, hover, barrel buttons) map directly onto the extended display's bounds. When the cable is unplugged, the virtual display is removed and the service returns to waiting for the next connection.
