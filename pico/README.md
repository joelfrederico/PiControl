# picontrol (Pico 2 W)

MicroPython library that receives controller input from the PiControl iOS app
over BLE. The Pico advertises the PiControl GATT service; the iPhone connects
and streams input packets, delivered to your code as `ControllerState`
callbacks.

Requires MicroPython ≥ 1.20 firmware for the **Pico 2 W** (aioble is bundled
in official firmware builds with BLE).

## Install into a project

Any of:

- **Copy**: copy the `picontrol/` directory onto the device (or into your
  project) with mpremote / MicroPico:

  ```sh
  mpremote cp -r picontrol :
  ```

- **mip** (once this repo is on GitHub):

  ```sh
  mpremote mip install github:joelfrederico/PiControl/pico
  ```

## Usage

```python
import asyncio
from picontrol import PiControlReceiver, BUTTON_CROSS

def on_state(state):
    if state.pressed(BUTTON_CROSS):
        ...                 # buttons: bitmask helpers
    speed = state.ly        # sticks: -127..127; triggers: state.l2 0..255

async def main():
    receiver = PiControlReceiver(name="PiControl-pico", on_state=on_state)
    await receiver.run()    # advertises, serves, re-advertises on disconnect

asyncio.run(main())
```

Optional `on_connect(device)` / `on_disconnect()` hooks track connection
state. `run()` serves one iPhone connection at a time and only returns if
cancelled — run it as a task alongside your motor/sensor loops:

```python
asyncio.create_task(receiver.run())
```

## Demo

[`examples/main.py`](examples/main.py): onboard LED tracks the cross button,
stick values print to the console.

```sh
mpremote cp -r picontrol : + cp examples/main.py : + run examples/main.py
```

## Notes

- `picontrol/protocol.py` is a verbatim copy of the pi5 version; edit the
  pi5 copy and re-copy it (a test in `pi5/tests` enforces they match).
- The packet format and BLE UUIDs are documented in the top-level README.
