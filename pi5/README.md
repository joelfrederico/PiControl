# picontrol (Raspberry Pi 5)

Python library that receives controller input from the PiControl iOS app over
BLE. The Pi advertises the PiControl GATT service; the iPhone connects and
streams input packets. Optionally exposes the input as a **virtual DualSense**
so games and libraries on the Pi see a real controller.

Requires Raspberry Pi OS (or any Linux with BlueZ) and Python ≥ 3.11.

## Install

As a dependency of another project (path or git URL):

```sh
pip install "picontrol @ file:///home/pi/PiControl/pi5"          # library only
pip install "picontrol[uinput] @ file:///home/pi/PiControl/pi5"  # + virtual DualSense
```

For development in this repo:

```sh
cd pi5
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[uinput,dev]"
```

## Library usage

```python
import asyncio
from picontrol import PiControlReceiver, BUTTON_CROSS

async def main():
    async with PiControlReceiver(name="PiControl-pi5") as receiver:
        async for state in receiver.states():
            if state.pressed(BUTTON_CROSS):
                ...            # buttons: bitmask helpers
            speed = state.ly   # sticks: -127..127; triggers: state.l2 0..255

asyncio.run(main())
```

A callback style is also supported: `PiControlReceiver(on_state=fn)` invokes
`fn(state)` per packet. See [`examples/print_state.py`](examples/print_state.py).

## Virtual DualSense

```sh
picontrol-dualsense            # needs access to /dev/uinput (see below)
picontrol-dualsense --dry-run  # just print decoded state; no root needed
```

Connect from the iOS app, then verify with `evtest`: a "DualSense Wireless
Controller" (vendor 054c, product 0ce6) input device should appear and emit
events.

`/dev/uinput` access: either run with `sudo`, or add a udev rule:

```sh
echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' | sudo tee /etc/udev/rules.d/99-uinput.rules
sudo usermod -aG input $USER   # then re-login
```

## Tests

Protocol tests are pure Python and run anywhere (including a Mac):

```sh
python3 -m pytest
```

## Notes

- BlueZ must be running (`sudo systemctl status bluetooth`); no pairing is
  required — the service uses unauthenticated writes on a custom UUID.
- `picontrol/protocol.py` is shared verbatim with the Pico library; edit the
  pi5 copy and re-copy it (a test enforces they match).
