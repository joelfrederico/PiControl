# PiControl — working notes for collaborators

This file explains how the project fits together and, more importantly, *why*
it is the way it is. Read the top-level [README.md](README.md) first for the
architecture diagram and the packet layout table — that README is the single
source of truth for the wire protocol. This file adds the context you'd
otherwise have to learn the hard way.

## The one architectural fact everything follows from

iOS will not let an app present the phone as a Bluetooth HID device. So the
roles are inverted from what you'd expect: **the Pi/Pico/Mac advertises as
the BLE peripheral, and the iPhone is the central** that connects *to* it and
streams input packets at ~60 Hz using write-without-response. If you find
yourself confused about who connects to whom, come back to this paragraph.

## Components

| Path | What | Language/stack |
|---|---|---|
| `ios/` | The controller app (scan/connect UI + on-screen gamepad + motion) | SwiftUI, CoreBluetooth, CoreMotion |
| `pi5/` | Receiver library for Raspberry Pi OS; optional uinput sink emulates a DualSense | Python, `bless` |
| `pico/` | Receiver library for Pico 2 W | MicroPython, `aioble` |
| `mac/fake_receiver.swift` | Test receiver: advertises like a Pi, shows received input in a window | Swift script, no Xcode project |

## The protocol, and the rules for changing it

The packet is a fixed-size little-endian struct — layout table in the top
README. Three implementations must agree:

1. `ios/PiControl/Protocol.swift` — the production **encoder**
2. `pi5/src/picontrol/protocol.py` — the production **decoder**
3. `pico/picontrol/protocol.py` — a **verbatim copy** of #2

Rules, enforced partly by tests:

- `pico/picontrol/protocol.py` must be byte-identical to the pi5 copy —
  `test_pico_copy_is_identical` fails otherwise. Edit the pi5 one, then
  `cp pi5/src/picontrol/protocol.py pico/picontrol/protocol.py`.
- That file must stay **MicroPython-compatible**: no dataclasses, no typing,
  stdlib `struct`/`math` only.
- Any layout change bumps `PROTOCOL_VERSION` in all implementations
  (including `mac/fake_receiver.swift`), updates the README table, and
  updates `pi5/tests/test_protocol.py`. Receivers hard-reject packets with
  the wrong version — there is deliberately no backward compatibility;
  all ends live in this repo and move together.
- Checklist for a protocol change: README table → pi5 `protocol.py` → copy
  to pico → tests → `Protocol.swift` → `fake_receiver.swift` → run tests +
  build the app. The receiver **config** struct (`<BBB`, served on the
  `…0003` characteristic, read+notify) follows the same checklist and has
  its own version byte; the phone parses it leniently (unparseable →
  defaults: everything on, 60 Hz). The **haptics** struct (`<BBB` on
  `…0004`, read+notify: version, intensity, sharpness) works the same
  way — receiver → phone rumble, lenient decode meaning "off".
- State tracking lives in the protocol library (`InputTracker`: latest
  state, button edges, seq-gap loss counting) — *staleness* detection stays
  in receivers, because MicroPython has no portable wall clock. Don't move
  clock-based logic into `protocol.py`.
Attitude fields (v2): radians × 32767/π as i16, portrait device frame,
fused by CoreMotion (`.xArbitraryZVertical`). Yaw has an arbitrary zero — no
magnetometer — so receivers should use attitude *changes* (e.g. steering),
never absolute heading.

## Building and running

**iOS app** (`ios/`): the `.xcodeproj` and `Info.plist` are *generated* and
gitignored — `project.yml` is the source of truth (XcodeGen). Icon and launch
image PNGs are also generated (from `icon/*.svg`) and gitignored. Fresh
checkout:

```sh
brew install xcodegen librsvg
cd ios && ./icon/generate.sh && xcodegen generate && open PiControl.xcodeproj
```

BLE does not work in the iOS Simulator — you need a real iPhone (personal
team signing is fine, but the install expires after 7 days; just re-run from
Xcode). CLI build check without signing:

```sh
xcodebuild -project PiControl.xcodeproj -scheme PiControl \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

If `xcodebuild` complains about CommandLineTools, either
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` or prefix
with `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

**Mac fake receiver**: `mac/fake-receiver` — a wrapper that compiles
`fake_receiver.swift` to a cached binary and runs it; opens a window, no
project, no signing. (Plain `swift fake_receiver.swift` script mode fails
with "Symbols not found: ___isPlatformVersionAtLeast" — the JIT lacks the
availability-check builtin that SwiftUI controls like Toggle/Picker emit.
Always compile; don't interpret.) This is the fastest way to verify the whole pipeline:
it advertises `PiControl-mac`, and everything the phone sends is visualized
live (sticks, buttons, triggers, d-pad, attitude dials, packet rate).
Closing the window quits it. macOS will ask for Bluetooth permission on
behalf of the *terminal* app that launched it.

**pi5 library**: works on macOS too (`bless` has a CoreBluetooth backend),
which is handy for testing the Python side without hardware:

```sh
cd pi5 && python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/python -m pytest        # protocol tests
.venv/bin/python -u examples/print_state.py   # advertise + print states
```

## Hard-won lessons — do not relearn these

- **Buttons must use raw UIKit touches, not SwiftUI gestures.** iOS's
  "system gesture gate" delays *recognizer-based* input (all SwiftUI
  gestures) for touches starting near the physical bottom edge of the phone
  (the USB side — which is under one hand in landscape) while it rules out a
  system swipe; the Xcode console shows "System gesture gate timed out".
  `defersSystemGestures` does **not** prevent it, and iOS rejects the
  `delaysTouchesBegan` workaround at runtime as unsupported. Raw
  `touchesBegan`/`touchesEnded` are not gated — that's what `RawPressHandler`
  in `ContentView.swift` is for. If you "clean it up" back to SwiftUI
  gestures, edge buttons will lag up to a second. The thumbsticks still use
  `DragGesture` because held-and-dragged touches never exhibited the problem.
- **The launch screen is a static image by OS design** — nothing animates
  until the app process runs. That's why `SplashView` mirrors the launch
  image exactly (same asset) and adds the spinner. iOS also caches launch
  screens aggressively: if a launch-screen change doesn't show up, delete
  the app from the phone or reboot it.
- **`ControllerState.pitch/roll/yaw` are deliberately not `@Published`.**
  They change at 60 Hz; publishing them would re-render SwiftUI constantly
  for values no view displays. The BLE send loop reads them directly.
- **Packets are full-state, not deltas.** Every packet carries the entire
  controller state, so dropped write-without-response packets are harmless.
  Keep this property: it's what makes the link robust with zero retry logic.
- **The constant-rate send loop must stay dumb — do not "optimize" it.**
  Idle suppression and send-on-change were both considered and rejected
  (2026-07). The steady full-state stream does four jobs at once: input
  delivery, dead-man signal (silence must always mean "controller gone —
  stop the motors", never "idle"), drop self-healing (a lost "all zeros"
  release packet is corrected ~16 ms later; with idle silence it never
  would be, freezing the receiver at a stale non-idle state), and a
  predictable rate contract. Send-on-change alone buys single-digit ms —
  writes wait for the next BLE connection event (~15–30 ms, iOS-negotiated)
  regardless — while needing a burst limiter against 120 Hz stick-drag
  events. The tuning lever already exists: receivers request a different
  rate_hz (1–120) via the config characteristic.
- The `seq` byte increments only on packets actually sent, so consecutive
  seq values at the receiver do NOT prove no 60 Hz ticks were skipped —
  watch the receiver's pkt/s display instead.
- **Never publish per-packet state to a UI.** Attitude noise makes every
  60 Hz packet unique; when the fake receiver published each one, SwiftUI
  re-rendered per packet on the same main queue CoreBluetooth delivers on,
  and the backlog surfaced as *input lag on everything*. The receiver now
  ingests packets into a plain var and refreshes the display from a 30 Hz
  timer. Keep that decoupling in any future receiver UI.

## Testing a change end-to-end

1. `mac/fake-receiver` on the Mac.
2. Run the app on a real iPhone (⌘R), connect to `PiControl-mac`.
3. Mash every control; watch the window. Quick taps must register
   instantly — if a button needs *holding* to register, you've reintroduced
   the gesture-gate bug (see above).
4. `cd pi5 && .venv/bin/python -m pytest` for the protocol.

Note: `uinput_sink.py` (virtual DualSense, FF rumble) is Linux-only —
`evdev` doesn't install on macOS, so it can only be syntax-checked here
(`python -m py_compile`). Its FF read-loop and effect handling must be
verified on an actual Pi with `evtest`/`fftest` or a game.

## House style

- Generated artifacts (xcodeproj, Info.plist, icon PNGs) are never
  committed; their sources (`project.yml`, SVGs) are.
- The mac receiver stays a single runnable script — resist turning it into
  an Xcode project.
- Comments explain *constraints* (why raw touches, why not @Published), not
  what the next line does.
