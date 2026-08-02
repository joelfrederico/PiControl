# PiControl

Use an iPhone as a game controller for a Raspberry Pi 5 or a Raspberry Pi Pico 2 W,
mimicking a DualSense controller.

## Architecture

iOS does not allow apps to present the phone as a Bluetooth HID device, so the phone
cannot literally impersonate a DualSense at the radio level. Instead, the receiver
advertises a custom BLE GATT service and the iPhone connects to it and streams
controller input; the receiver synthesizes controller behavior locally.

```
┌────────────┐  BLE write-without-response   ┌──────────────────────────────┐
│  iPhone    │ ────────────────────────────▶ │ Pi 5: virtual DualSense via  │
│  (central) │        input packets          │   uinput — games see a real  │
│  PiControl │                               │   "DualSense" controller     │
│  app       │            — or —             ├──────────────────────────────┤
│            │ ────────────────────────────▶ │ Pico 2 W: your code receives │
└────────────┘                               │   ControllerState callbacks  │
                                             └──────────────────────────────┘
```

- The **Pi 5 or Pico 2 W advertises** the PiControl GATT service (BLE peripheral).
- The **iPhone is the BLE central**: it scans, the user picks a device, and the app
  streams input packets to the "input" characteristic using write-without-response.
- The iPhone connects to **one receiver at a time**. Receivers resume advertising
  when disconnected.
- `pi5/` and `pico/` are **libraries**, so any other Pi or Pico project can depend
  on them to get an iPhone-controller connection.

## Layout

| Directory | What it is |
|---|---|
| [`ios/`](ios/) | SwiftUI iPhone app: scan/connect UI + on-screen controller |
| [`pi5/`](pi5/) | Python library `picontrol` for Raspberry Pi OS (BlueZ). Optional `uinput` sink creates a virtual DualSense |
| [`pico/`](pico/) | MicroPython library `picontrol` for the Pico 2 W (aioble) |

## BLE service

| Item | Value |
|---|---|
| Service UUID | `b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0001` |
| Input characteristic UUID | `b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0002` (write, write-without-response) |
| Config characteristic UUID | `b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0003` (read, notify; optional) |
| Haptics characteristic UUID | `b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0004` (read, notify; optional) |
| Advertised names | `PiControl-pi5`, `PiControl-pico` (configurable) |

## Receiver config

The receiver tells the phone what it wants via the config characteristic —
struct `<BBB` (3 bytes): config version (currently `1`), flags bitmask
(bit 0 = wants motion, bit 1 = wants analog), requested packet rate in Hz
(1–120). The phone reads it at connect and subscribes to notifications, so
a receiver can change its mind mid-connection (`receiver.set_config(...)`):
the phone retunes its send rate and starts/stops CoreMotion live. The
characteristic is optional and the phone parses it leniently — anything
missing or unparseable means "everything on, 60 Hz". The input packet
layout never changes; fields the receiver didn't ask for are just zeroed:
clearing the motion flag stops CoreMotion and zeroes pitch/roll/yaw,
clearing the analog flag zeroes sticks and triggers (buttons and d-pad are
digital and always sent).

## Haptics

The receiver drives the phone's vibration — console-to-controller rumble,
inverted like everything else here — via the haptics characteristic:
struct `<BBB` (3 bytes): version (currently `1`), intensity 0–255 (0 =
off), sharpness 0–255 (0 = dull rumble, 255 = crisp buzz; the CoreHaptics
analog of the DualSense's low/high-frequency motor split). The phone
subscribes and applies changes immediately (`receiver.set_haptics(0.7)`),
and vibration stops on disconnect. Optional and leniently parsed, like
the config characteristic.

## Input packet

One packet per input update, fixed size, little-endian. Struct format
`<BBHBbbbbBBhhh` (17 bytes). This is the single source of truth; the Swift encoder
(`ios/PiControl/Protocol.swift`) and the Python decoder (`pi5/src/picontrol/protocol.py`,
mirrored verbatim in `pico/picontrol/protocol.py`) implement it.

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | version | protocol version, currently `2` |
| 1 | u8 | seq | sequence number, wraps at 255; detects loss/reordering |
| 2 | u16 | buttons | bitmask, see below |
| 4 | u8 | hat | d-pad: 0 = centered, 1 = N, 2 = NE, 3 = E, … 8 = NW |
| 5 | i8 | lx | left stick X, −127 (left) … 127 (right) |
| 6 | i8 | ly | left stick Y, −127 (up) … 127 (down) |
| 7 | i8 | rx | right stick X |
| 8 | i8 | ry | right stick Y |
| 9 | u8 | l2 | left trigger, 0…255 |
| 10 | u8 | r2 | right trigger, 0…255 |
| 11 | i16 | pitch | attitude, radians × 32767/π (±π maps to ±32767) |
| 13 | i16 | roll | attitude, radians × 32767/π |
| 15 | i16 | yaw | attitude, radians × 32767/π |

Button bits: 0 cross, 1 circle, 2 square, 3 triangle, 4 L1, 5 R1, 6 L3, 7 R3,
8 create, 9 options, 10 PS/home, 11 touchpad-click.

**Attitude** (added in v2) is the phone's fused gyro+accelerometer orientation
from CoreMotion: pitch rotates about the device's short axis, roll about its
long axis, yaw about the screen normal. The phone normalizes the frame to the
current landscape interface orientation, so a physical gesture relative to the
on-screen UI produces the same signs in both landscapes. Yaw is relative to an
arbitrary reference (no magnetometer), so use it for relative motion like
steering, not absolute heading. Decoders expose the values back in radians
(`ATTITUDE_SCALE` in the protocol modules).

## End-to-end test

One receiver at a time:

1. **Pi 5**: `pip install "picontrol[uinput] @ file://$(pwd)/pi5"`, run
   `sudo picontrol-dualsense`, connect from the iOS app, and check
   `evtest /dev/input/event*` — a "DualSense Wireless Controller" device should
   appear and emit events as you touch the on-screen controls. The virtual
   pad advertises FF_RUMBLE: when a game plays a rumble effect, the phone
   vibrates. Add `--motion-steering pitch` (or roll/yaw, with
   `--motion-range` degrees for full deflection) to steer the left stick X
   by tilting the phone.
2. **Pico 2 W**: upload `pico/picontrol/` and `pico/examples/main.py`, connect from
   the app, and watch the onboard LED track the cross button while stick values
   print to the console.
