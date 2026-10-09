# nodither-macos

A small CLI that stops temporal dithering on external displays on Apple Silicon Macs (SDR).

It does two things, and you need both:

1. **Turns off GPU dithering.** macOS renders into a 10-bit framebuffer, and the display coprocessor (DCP) temporally dithers it down to the link's bit depth. `nodither` sets `enableDither = No` on each external display pipe, the same way [Stillcolor](https://github.com/aiaf/Stillcolor) does.
2. **Sets the link to 8-bit RGB (full range).** On a 10-bit link, monitors whose panel is really 8-bit + FRC fake the extra 2 bits by flickering between neighbouring shades. That is temporal dithering too, done by the monitor. With an 8-bit link it has nothing to dither. This also replaces YCbCr / limited-range links with RGB full range.

The 8-bit link alone just moves the dithering from the monitor to the GPU. Turning GPU dithering off alone leaves the monitor's FRC in place. With both, the Mac rounds to 8 bits and the monitor displays them as-is. Smooth gradients can show slightly more banding; that is the expected trade-off.

## Install

Prebuilt binary from the [latest release](https://github.com/pstngh/nodither-macos/releases/latest) (arm64, macOS 13 or later):

```bash
curl -L https://github.com/pstngh/nodither-macos/releases/latest/download/nodither-macos-arm64.tar.gz | tar xz
./nodither install
```

The binary is ad-hoc signed, not notarized. Downloads made with `curl` run as-is; if you download the archive in a browser, macOS blocks the binary until you run `xattr -d com.apple.quarantine nodither`.

Or build from source (needs the Xcode Command Line Tools):

```bash
git clone https://github.com/pstngh/nodither-macos
cd nodither-macos
swift build -c release
.build/release/nodither install
```

Either way, `install` copies the binary to `~/.local/bin/nodither` and loads the LaunchAgent `~/Library/LaunchAgents/local.nodither.plist`. It applies the settings right away, at every login, and whenever a monitor is attached. No root needed.

## Usage

| Command | |
|---|---|
| `nodither apply [monitor ...]` | Set 8-bit links (RGB full range when offered), then `enableDither = No` |
| `nodither status` | Show `enableDither` and the current link per external display |
| `nodither install [monitor ...]` | Install the binary and LaunchAgent |
| `nodither uninstall` | Remove the LaunchAgent and binary, and restore the default link and dithering |

Monitors are matched by any part of their name, ignoring case (`nodither install U4323`). Without names, every external display is managed. `uninstall` restores exactly the monitors the installed agent managed.

```
$ nodither status
DELL U4323QE
  enableDither  No
  link          8-bit RGB, full range
DELL G2524H
  enableDither  No
  link          8-bit RGB, full range
```

The log is at `~/Library/Logs/nodither.log`.

## How it works

- **Dithering:** `IORegistryEntrySetCFProperty(enableDither = false)` on every `IOMobileFramebufferAP` marked `external` (the parent class of `AppleCLCD2` and `IOMobileFramebufferShim`).
- **Link:** WindowServer's private SkyLight output-mode API. `SLSGetDisplayOutputModeLinkDescriptions` lists the links the current display mode supports, and `SLSConfigureDisplayOutputMode` selects an 8-bit SDR link: RGB full range when offered, otherwise RGB limited, then YCbCr 4:4:4, then 4:2:2. Any 8-bit link leaves the monitor nothing to dither; encoding and range only affect color accuracy. WindowServer saves the choice as `LinkDescription` in its display preferences and restores it when the monitor reconnects.
- **Status:** `enableDither` comes from the IORegistry (what `ioreg -lw0 | grep enableDither` shows). The link comes from the DCP itself via `IOAVVideoInterfaceGetLinkData`, so it reports what is actually on the cable. Monitors are matched across IOKit, the DCP and CoreGraphics by their EDID product ID and serial.
- **Reapplying with zero overhead:** nothing stays resident. The LaunchAgent uses launchd's `com.apple.iokit.matching` event stream on `DCPAVServiceProxy` (`Location = External`), which the DCP publishes each time a monitor attaches, including after the Mac wakes from sleep. launchd starts `nodither agent`, which waits for WindowServer to bring the display online, applies, and exits. `RunAtLoad` covers login.

## Compared to BetterDisplay

[BetterDisplay](https://github.com/waydabber/BetterDisplay) can also turn off GPU dithering and pick a connection mode. Tested against BetterDisplay 5.1.1 on the same Mac:

- **GPU dithering: same mechanism.** BetterDisplay writes `enableDither` with `IORegistryEntrySetCFProperty`, like Stillcolor and `nodither`. The difference is reapplying: BetterDisplay has to keep running and polls the displays every 2 seconds, while `nodither` only runs at login, monitor attach and wake.
- **Connection mode: same options, different layer.** BetterDisplay lists the same link options WindowServer offers, but programs the display hardware underneath WindowServer. When BetterDisplay switched the U4323QE to 10-bit, the monitor received 10-bit while WindowServer's current output mode and saved preferences still said 8-bit. At the next game-style mode switch, WindowServer put back its own saved link and the BetterDisplay setting was lost. BetterDisplay's "Configuration Protection" exists to switch it back again after such events (not tested here).

`nodither` sets the link in WindowServer itself, so macOS keeps it on its own across monitor power cycles, sleep/wake and mode switches, with nothing running in between.

BetterDisplay does far more: a GUI, any connection mode including ones WindowServer wouldn't choose, HDR, presets, and testing across many Macs. If you run both, leave BetterDisplay's connection-mode protection off so the two don't fight over the link.

## Notes

- Uses private Apple APIs, so a macOS update can break it. If one disappears, that step is skipped and the run exits 1; turning off GPU dithering only needs public IOKit, so it still happens.
- Tested on a Mac mini M4 with macOS 26.6 and two Dell monitors (one on HDMI, one on USB-C), including a monitor power cycle and a system sleep/wake. Other chips and macOS versions are untested.
- SDR only. HDR needs a 10-bit link.
- `enableDither` resets on reboot; the LaunchAgent sets it again at login.
- Display mode changes don't undo it. WindowServer applies the saved 8-bit RGB link to whatever mode is active, so a game that switches resolution or refresh rate keeps it, and GPU dithering stays off across the link retrain (tested 4K60 → 4K30 and 240 → 120 Hz, during the switch and after the game quits).
- Night Shift, color profile switches and gamma changes don't reset the link or `enableDither` (tested).
- `uninstall` switches each managed monitor back to the link WindowServer picks by default and turns GPU dithering back on.

## Credits

The `enableDither` approach comes from [Stillcolor](https://github.com/aiaf/Stillcolor) by Abdullah Arif (MIT).

## License

MIT
