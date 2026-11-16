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

The receiver reports its physical panel dimensions (`pixelsWide × pixelsHigh`) in the session handshake. From those dimensions, the sender creates a single exact 1:1 virtual display (`points = pixels ÷ 2` at `@2x` HiDPI when divisible into even points for high-density panels, otherwise `pixels` at `@1x`) with no saved mode presets or fractional downscaling, and streams at the panel's physical resolution using hardware HEVC 4:4:4 (or H.264 fallback).

Keyboard, trackpad, and mouse input from LOCachy are forwarded across all active Mac displays. When the cable is unplugged, the virtual display is removed and the service returns to waiting for the next connection.
