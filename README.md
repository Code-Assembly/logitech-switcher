# logitech-switcher

Moves a Logitech MX Keys S keyboard and MX Master 4 mouse between up to three
Macs with one key press, over Bluetooth, without Logi Options+.

Press Scroll Lock on the keyboard. The Mac the devices are on sends both of them
to the next paired Mac, cycling through Easy-Switch slots 1, 2, 3, 1, ... and
skipping empty ones. The mouse goes first. The keyboard only follows once the mouse is
confirmed gone, so the two never end up split across machines. If anything goes
wrong, both stay where they are and you get a notification. The keyboard's
Easy-Switch keys and the mouse's button keep working as usual.

## Requirements

- macOS 13 or later, Apple silicon or Intel
- Swift 5.9+ (Xcode or the command line tools) on the Mac that builds
- An MX Keys S and an MX Master 4 paired over Bluetooth to every Mac. Bolt and
  Unifying receivers are not supported.
- Each Mac on the same Easy-Switch number on both devices: if a Mac is
  keyboard channel 2, it must be mouse channel 2 too.

## Build

Builds are signed with a self-signed certificate, so the Input Monitoring grant
survives rebuilds. Create the certificate once:

```bash
scripts/make-signing-cert.sh
```

Then build, sign and package:

```bash
scripts/build.sh
```

This writes `.build/release/logitech-switcher` and `dist/logitech-switcher.zip`,
which holds the binary, `install.sh` and `uninstall.sh`. The zip installs on a
Mac with no toolchain.

## Install

On each Mac, with the keyboard and mouse connected to it:

```bash
scripts/install.sh                # from a checkout
logitech-switcher/install.sh      # from the unzipped package
```

This copies the binary to `~/.local/bin/logitech-switcher` and starts a
LaunchAgent (`local.logitech-switcher.agent`) at login. Allow Input Monitoring
for `logitech-switcher` when macOS asks. Running it again upgrades in place and
keeps the grant.

The agent also writes this Mac's computer name (System Settings > General >
About > Name) into its slot on each device, since devices keep the name from
the time they were paired.

## Configuration

None is needed. With no target, a press moves to the next slot paired on both
devices. To override anything, create `~/.config/logitech-switcher/config.json`:

```json
{
  "target": "1",
  "hosts": {"work": {"mouse": 0, "keyboard": 0}},
  "trigger": "0x00EA",
  "hostName": "Studio",
  "notify": "failures",
  "timeouts": {"reply": 1.0, "confirm": 8.0, "window": 20.0}
}
```

| Key | Meaning |
|-----|---------|
| `target` | Fixed host instead of cycling: a slot number (0-2), a `hosts` alias or a host name |
| `hosts` | Named per-device slot maps |
| `trigger` | Keyboard control that triggers a switch, from `logitech-switcher controls` |
| `hostName` | Name written into this Mac's slot; `""` turns this off |
| `notify` | `all`, `failures` or `off` |
| `timeouts` | Reply wait, confirm budget per device, total send window (seconds) |

## Commands

```
logitech-switcher to [host] [device...]     switch now
logitech-switcher discover [device...]      list host slots and names as JSON
logitech-switcher name [name] [device...]   write this Mac's name to the devices
logitech-switcher controls [device...]      list programmable controls
logitech-switcher keys [--analytics]        watch key, HID++ and connection events
logitech-switcher ping [device]             check the HID++ link
```

Run from a terminal, the terminal app needs Input Monitoring too.

## Logs and exit codes

The agent logs JSON lines to `~/Library/Logs/logitech-switcher.log`. Every
failure has its own exit code and a one-line reason on stderr.

| Code | Meaning |
|------|---------|
| 2 | Usage |
| 10 | Input Monitoring not granted to the responsible process |
| 11 | Open needs root (not seen with these devices) |
| 12, 13 | Device absent or not connected to this Mac |
| 14 | Open failed for another reason |
| 15-17 | Config unreadable, unknown device, bad hex value |
| 40 | Write to the device failed |
| 41 | Device did not answer |
| 42 | Device refused a request (HID++ error) |
| 50 | Host unknown or ambiguous, or no next slot |
| 51 | Target slot not paired |
| 52 | The mouse never left; nothing moved |
| 53 | The Mac slept mid-switch or the send window passed |
| 54 | Stranded: the mouse moved, the keyboard did not |

## Uninstall

```bash
scripts/uninstall.sh          # agent and binary
scripts/uninstall.sh --all    # also config and log
```
