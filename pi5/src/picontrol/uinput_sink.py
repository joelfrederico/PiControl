"""Virtual DualSense output device via Linux uinput.

Consumes ControllerState updates and mirrors them onto a synthetic evdev
device that reports the DualSense vendor/product IDs and axis/button set,
so games and libraries on the Pi detect a real "DualSense Wireless
Controller". Requires the `uinput` extra (`pip install picontrol[uinput]`)
and permission to open /dev/uinput (root, or a udev rule).
"""

from evdev import AbsInfo, UInput
from evdev import ecodes as e

from . import protocol

DEVICE_NAME = "DualSense Wireless Controller"
VENDOR_SONY = 0x054C
PRODUCT_DUALSENSE = 0x0CE6

_BUTTON_MAP = [
    (protocol.BUTTON_CROSS, e.BTN_SOUTH),
    (protocol.BUTTON_CIRCLE, e.BTN_EAST),
    (protocol.BUTTON_SQUARE, e.BTN_WEST),
    (protocol.BUTTON_TRIANGLE, e.BTN_NORTH),
    (protocol.BUTTON_L1, e.BTN_TL),
    (protocol.BUTTON_R1, e.BTN_TR),
    (protocol.BUTTON_L3, e.BTN_THUMBL),
    (protocol.BUTTON_R3, e.BTN_THUMBR),
    (protocol.BUTTON_CREATE, e.BTN_SELECT),
    (protocol.BUTTON_OPTIONS, e.BTN_START),
    (protocol.BUTTON_PS, e.BTN_MODE),
]

_STICK_ABSINFO = AbsInfo(value=128, min=0, max=255, fuzz=0, flat=15, resolution=0)
_TRIGGER_ABSINFO = AbsInfo(value=0, min=0, max=255, fuzz=0, flat=0, resolution=0)
_HAT_ABSINFO = AbsInfo(value=0, min=-1, max=1, fuzz=0, flat=0, resolution=0)

_CAPABILITIES = {
    e.EV_KEY: [code for _, code in _BUTTON_MAP],
    e.EV_ABS: [
        (e.ABS_X, _STICK_ABSINFO),
        (e.ABS_Y, _STICK_ABSINFO),
        (e.ABS_RX, _STICK_ABSINFO),
        (e.ABS_RY, _STICK_ABSINFO),
        (e.ABS_Z, _TRIGGER_ABSINFO),
        (e.ABS_RZ, _TRIGGER_ABSINFO),
        (e.ABS_HAT0X, _HAT_ABSINFO),
        (e.ABS_HAT0Y, _HAT_ABSINFO),
    ],
}


def _stick(value):
    # protocol i8 (-127..127, center 0) -> DualSense axis (0..255, center 128)
    return max(0, min(255, value + 128))


class DualSenseSink:
    """Feed ControllerState updates to a virtual DualSense device."""

    def __init__(self):
        self._ui = UInput(
            _CAPABILITIES,
            name=DEVICE_NAME,
            vendor=VENDOR_SONY,
            product=PRODUCT_DUALSENSE,
            version=0x0111,
            bustype=e.BUS_BLUETOOTH,
        )

    def update(self, state):
        for mask, code in _BUTTON_MAP:
            self._ui.write(e.EV_KEY, code, 1 if state.pressed(mask) else 0)
        self._ui.write(e.EV_ABS, e.ABS_X, _stick(state.lx))
        self._ui.write(e.EV_ABS, e.ABS_Y, _stick(state.ly))
        self._ui.write(e.EV_ABS, e.ABS_RX, _stick(state.rx))
        self._ui.write(e.EV_ABS, e.ABS_RY, _stick(state.ry))
        self._ui.write(e.EV_ABS, e.ABS_Z, state.l2)
        self._ui.write(e.EV_ABS, e.ABS_RZ, state.r2)
        self._ui.write(e.EV_ABS, e.ABS_HAT0X, state.dpad_x)
        self._ui.write(e.EV_ABS, e.ABS_HAT0Y, state.dpad_y)
        self._ui.syn()

    def close(self):
        self._ui.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
