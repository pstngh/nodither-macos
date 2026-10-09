# nodither-macos

A small CLI that stops temporal dithering on external displays on Apple Silicon Macs (SDR).

It does two things, and you need both:

1. **Turns off GPU dithering.** macOS renders into a 10-bit framebuffer, and the display coprocessor (DCP) temporally dithers it down to the link's bit depth. `nodither` sets `enableDither = No` on each external display pipe, the same way [Stillcolor](https://github.com/aiaf/Stillcolor) does.
2. **Sets the link to 8-bit RGB (full range).** On a 10-bit link, monitors whose panel is really 8-bit + FRC fake the extra 2 bits by flickering between neighbouring shades. That is temporal dithering too, done by the monitor. With an 8-bit link it has nothing to dither. This also replaces YCbCr / limited-range links with RGB full range.

The 8-bit link alone just moves the dithering from the monitor to the GPU. Turning GPU dithering off alone leaves the monitor's FRC in place. With both, the Mac rounds to 8 bits and the monitor displays them as-is. Smooth gradients can show slightly more banding; that is the expected trade-off.

## Install

```bash
git clone https://github.com/pstngh/nodither-macos
cd nodither-macos
swift build -c release
.build/release/nodither install
```

`install` copies the binary to `~/.local/bin/nodither` and loads the LaunchAgent `~/Library/LaunchAgents/local.nodither.plist`. It applies the settings right away, at every login, and whenever a monitor is attached. No root needed.

## Usage

| Command | |
|---|---|
| `nodither apply` | Set 8-bit RGB links, then `enableDither = No` |
| `nodither status` | Show `enableDither` and the current link per external display |
| `nodither install` | Install the binary and LaunchAgent |
| `nodither uninstall` | Remove the LaunchAgent and the installed binary |

```
$ nodither status
DELL U4323QE [dispext0]
  enableDither  No
  link          8-bit RGB, full range
DELL G2524H [disp0]
  enableDither  No
  link          8-bit RGB, full range
```

The log is at `~/Library/Logs/nodither.log`.

## How it works

- **Dithering:** `IORegistryEntrySetCFProperty(enableDither = false)` on every `IOMobileFramebufferAP` marked `external` (the parent class of `AppleCLCD2` and `IOMobileFramebufferShim`).
- **Link:** WindowServer's private SkyLight output-mode API. `SLSGetDisplayOutputModeLinkDescriptions` lists the links the current display mode supports, and `SLSConfigureDisplayOutputMode` selects `{BitDepth 8, Range full, EOTF SDR, PixelEncoding RGB}`. WindowServer saves the choice as `LinkDescription` in its display preferences and restores it when the monitor reconnects.
- **Status:** `enableDither` comes from the IORegistry (what `ioreg -lw0 | grep enableDither` shows). The link comes from the DCP itself via `IOAVVideoInterfaceGetLinkData`, so it reports what is actually on the cable.
- **Reapplying with zero overhead:** nothing stays resident. The LaunchAgent uses launchd's `com.apple.iokit.matching` event stream on `DCPAVServiceProxy` (`Location = External`), which the DCP publishes each time a monitor attaches. launchd starts `nodither agent`, which waits for WindowServer to bring the display online, applies, and exits. `RunAtLoad` covers login.

## Notes

- Uses private Apple APIs, so a macOS update can break it.
- Tested on a Mac mini M4 with macOS 26.6 and two Dell monitors (one on HDMI, one on USB-C), including a monitor power cycle. Other chips and macOS versions are untested.
- SDR only. HDR needs a 10-bit link.
- `enableDither` resets on reboot; the LaunchAgent sets it again at login.
- `uninstall` does not switch the link back, because WindowServer keeps the saved setting. Choose a different connection mode (e.g. in BetterDisplay) to change it.

## Credits

The `enableDither` approach comes from [Stillcolor](https://github.com/aiaf/Stillcolor) by Abdullah Arif (MIT).

## License

MIT
