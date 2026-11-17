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

The receiver reports its physical panel dimensions (`pixelsWide × pixelsHigh`) along with its authenticated `host` and `model` identifiers in the session handshake. From those dimensions, the sender computes the `1:1` HiDPI base mode (`pixels ÷ 2` points at `@2x` when divisible into even points, otherwise `@1x`), registers five proportional modes (`2.0×`, `1.75×`, `1.5×`, `1.25×`, `1.0×`) for **System Settings → Displays** (**Larger Text ↔ More Space**), and looks up `(host, model, pixelsWide × pixelsHigh)` in `~/Library/Application Support/LOCachy/display-modes.json` so each machine restores its chosen scaling step across reconnects (defaulting to `1:1` on first sight). Native `1:1` modes stream without rescaling; intermediate HiDPI modes capture at native backing resolution and downscale cleanly via Metal Mitchell bicubic (`B=1/3, C=1/3`) in sRGB before hardware HEVC 4:4:4 encoding (or H.264 fallback).

Keyboard, trackpad, and mouse input from LOCachy are forwarded across all active Mac displays. When the cable is unplugged, the virtual display is removed and the service returns to waiting for the next connection.
