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
| Advertised names | `PiControl-pi5`, `PiControl-pico` (configurable) |

## Input packet

One packet per input update, fixed size, little-endian. Struct format
`<BBHBbbbbBB` (11 bytes). This is the single source of truth; the Swift encoder
(`ios/PiControl/Protocol.swift`) and the Python decoder (`pi5/src/picontrol/protocol.py`,
mirrored verbatim in `pico/picontrol/protocol.py`) implement it.

| Offset | Type | Field | Notes |
|---|---|---|---|
| 0 | u8 | version | protocol version, currently `1` |
| 1 | u8 | seq | sequence number, wraps at 255; detects loss/reordering |
| 2 | u16 | buttons | bitmask, see below |
| 4 | u8 | hat | d-pad: 0 = centered, 1 = N, 2 = NE, 3 = E, … 8 = NW |
| 5 | i8 | lx | left stick X, −127 (left) … 127 (right) |
| 6 | i8 | ly | left stick Y, −127 (up) … 127 (down) |
| 7 | i8 | rx | right stick X |
| 8 | i8 | ry | right stick Y |
| 9 | u8 | l2 | left trigger, 0…255 |
| 10 | u8 | r2 | right trigger, 0…255 |

Button bits: 0 cross, 1 circle, 2 square, 3 triangle, 4 L1, 5 R1, 6 L3, 7 R3,
8 create, 9 options, 10 PS/home, 11 touchpad-click.

## End-to-end test

One receiver at a time:

1. **Pi 5**: `pip install "picontrol[uinput] @ file://$(pwd)/pi5"`, run
   `sudo picontrol-dualsense`, connect from the iOS app, and check
   `evtest /dev/input/event*` — a "DualSense Wireless Controller" device should
   appear and emit events as you touch the on-screen controls.
2. **Pico 2 W**: upload `pico/picontrol/` and `pico/examples/main.py`, connect from
   the app, and watch the onboard LED track the cross button while stick values
   print to the console.
