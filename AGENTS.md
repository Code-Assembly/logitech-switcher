# AGENTS.md

Context for coding agents working on this repo. Read it before changing code.

## Scope

logitech-switcher moves one Logitech **MX Keys S** keyboard and one **MX Master 4**
mouse between up to three **Macs** over **Bluetooth LE**, using Logitech's HID++
2.0 protocol directly. Pressing Scroll Lock moves both devices to the next
paired Easy-Switch slot, cycling 0 → 1 → 2 → 0 and skipping slots that are not
paired on every device.

Supported setup, and nothing else:

- macOS 13+, BLE only. No Bolt or Unifying receivers (they use short `0x10`
  reports on usage page `0xFF00`).
- One MX Keys S (`046D:B378`) and one MX Master 4 (`046D:B042`), both on the
  HID++ vendor collection usage page `0xFF43`, usage `0x0202`, long reports
  (ID `0x11`, 20 bytes).
- Each Mac is on the same Easy-Switch number on both devices. Slot cycling
  relies on this, and `nextSlot` refuses to run when the devices disagree.

Do not add support for other models, other operating systems or Logi Options+
coexistence unless asked. Do not add third-party dependencies: Foundation, IOKit
and Carbon only (Carbon is used by the `keys` diagnostic only).

## Layout

| Path | Role |
|------|------|
| `Sources/LogiCore/HIDPP.swift` | Pure framing: `Request`, `Reply`, `ErrorReply`, `Inbound` decode and correlation |
| `Sources/LogiCore/Discovery.swift` | Device index, feature lookup, ChangeHost `0x1814` and HostsInfo `0x1815` reads → `DeviceReport` |
| `Sources/LogiCore/Switch.swift` | Targets, `nextSlot`, `plan`, the switch state machine (`run`, `move`), `verdict` |
| `Sources/LogiCore/Controls.swift` | Reprog controls `0x1B04`: control list, analytics reporting, trigger arming, `isPress` |
| `Sources/LogiCore/HostName.swift` | Writes this Mac's name into its slot (`0x1815` fn 4) |
| `Sources/LogiCore/Config.swift` | Config file and env overrides (`LOGITECH_*`) |
| `Sources/LogiCore/Exit.swift` | Exit codes; every failure path has its own |
| `Sources/LogiHID/HIDPPDevice.swift` | The only IOKit code: device handle, `Presence`, `KeyWatch` |
| `Sources/logitech-switcher/main.swift` | CLI and `performSwitch` |
| `Sources/logitech-switcher/Agent.swift` | LaunchAgent: links devices on arrival, arms the trigger, runs switches |
| `Sources/logitech-switcher/Experiment.swift` | `keys` and `controls` diagnostics |
| `Sources/spike` | Phase 0 open-permission probe, kept for debugging TCC |
| `scripts/` | `make-signing-cert.sh`, `build.sh` (build, sign, zip), `install.sh`, `uninstall.sh`, `configure.sh` |

Protocol logic, state machines and retries live in `LogiCore` as functions over
values, with I/O injected (`Exchange`, `Clock`, presence closures). Only
`LogiHID` touches IOKit. Keep it that way: it is what makes the logic testable
without hardware.

## Hardware facts (verified on the real devices)

- **Feature indexes differ per device and firmware.** Always resolve them with
  root `getFeature`. On the test devices ChangeHost is index 10 (keyboard) and
  14 (mouse). Never hardcode an index.
- **Device index is `0xFF`** over BLE, found by pinging candidates.
- **ChangeHost is rarely answered.** The link drops first, so success is the
  device vanishing from enumeration. Only an HID++ error reply (about 8ms) means
  failure; the send waits 0.1s for one.
- **Host names** are stored per slot, at most 24 bytes, cut mid-word, and never
  refreshed when a Mac is renamed. Name chunks are `[slot, offset, 14 bytes]`.
- **Easy-Switch keys** (controls `0x00D1`-`0x00D3`) are not divertable and send
  no analytics events, so software can neither block nor observe them.
- **Scroll Lock** (control `0x00EA`) sends no key report on a Mac. With
  analytics reporting on (`0x1B04` fn 3, flags byte `0x03`), it sends
  `11 FF <idx> 20 00 EA 01` on press. The keyboard forgets this setting on every
  reconnect, so the agent re-arms on arrival.
- **First write on a freshly opened handle costs 160-930ms**, even on an awake
  device; later writes take 15-30ms. The agent keeps handles open.

## macOS permission model

- Opening the HID++ collection needs **Input Monitoring** for the *responsible*
  process. From a terminal that is the terminal app; under launchd it is the
  binary itself.
- A grant does not reach a process that is already running. The agent exits
  when `IOHIDCheckAccess` says granted but opens still fail, and launchd
  restarts it.
- The grant is bound to the binary's path and signing certificate. Builds are
  signed with a self-signed identity (`logitech-switcher-dev`) so the grant
  survives rebuilds. Moving the binary needs a new grant.

## Rules

- Never divert, remap or suppress the Easy-Switch keys or the mouse's own
  button: they are the user's fallback.
- Mouse first. The keyboard moves only after the mouse is confirmed gone, so a
  failure never leaves the two on different Macs.
- Never send ChangeHost after the send window (default 20s of wall time since
  the press), and stop if a wall-clock jump shows the Mac slept. A switch must
  never land as a surprise after wake.
- Only write the current host's slot (names). Never write other slots, delete
  hosts or touch pairing.
- Every failure gets a distinct exit code and a one-line reason: what failed,
  the value, what to do.

## Build and test

```bash
swift test            # all logic, no hardware
scripts/build.sh      # release build, signed, plus dist/logitech-switcher.zip
```

Tests replay real recorded traffic from
`Tests/LogiCoreTests/Fixtures/mx-keys-s-master-4.jsonl`. Host names in fixtures
and tests use Futurama names (`Nibbler Book Pro`, `Leela’s MacBook Pro (2`).
Never commit real host names, hostnames, serials, usernames or emails. A new
fixture must be scrubbed the same way, keeping each name's byte length so the
chunk layout stays valid.

Hardware checks can't run in CI or in an agent sandbox without Input
Monitoring. Say what needs a human on the hardware rather than claiming it works.

## Style

- No comments that restate code. A comment states a constraint, a why or a
  hardware fact the code can't show.
- Short names that match existing vocabulary (`link`, `plan`, `push`, `leg`,
  `report`, `slot`).
- Error strings: what failed, the offending value, what to do. No "unable to"
  or "an error occurred".
