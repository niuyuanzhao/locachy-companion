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

## Display Modes and Input

The receiver reports its physical panel dimensions (`pixelsWide × pixelsHigh`) in the session handshake. From those dimensions, the sender creates a virtual display and derives five proportional scaled modes (`2.0×`, `1.75×`, `1.5×`, `1.25×`, `1.0×` of the panel size) for **System Settings → Displays**, while streaming at the panel's physical resolution using hardware HEVC 4:4:4 (or H.264 fallback). The selected mode is saved across sessions.

Keyboard, trackpad, and mouse input from LOCachy are forwarded across all active Mac displays. When the cable is unplugged, the virtual display is removed and the service returns to waiting for the next connection.
