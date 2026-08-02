"""Virtual DualSense output device via Linux uinput.

Consumes ControllerState updates and mirrors them onto a synthetic evdev
device that reports the DualSense vendor/product IDs and axis/button set,
so games and libraries on the Pi detect a real "DualSense Wireless
Controller". Requires the `uinput` extra (`pip install picontrol[uinput]`)
and permission to open /dev/uinput (root, or a udev rule).

Rumble: the device advertises FF_RUMBLE force feedback. When a game
uploads and plays a rumble effect, the `on_rumble(intensity, sharpness)`
callback fires (values ready for PiControlReceiver.set_haptics, which
makes the phone vibrate). The callback runs on an internal reader
thread — marshal to your event loop if needed (see cli.py).

Motion steering: pass `motion_steering="pitch"|"roll"|"yaw"` to replace
the left stick X axis with the phone's tilt, scaled so `motion_range`
radians is full deflection.
"""

import threading

from evdev import AbsInfo, UInput, ecodes as e, ff

from . import protocol
from .protocol import attitude_to_stick, rumble_to_haptics

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
    e.EV_FF: [e.FF_RUMBLE],
}

_MOTION_SOURCES = ("pitch", "roll", "yaw")


def _stick(value):
    # protocol i8 (-127..127, center 0) -> DualSense axis (0..255, center 128)
    return max(0, min(255, value + 128))


class DualSenseSink:
    """Feed ControllerState updates to a virtual DualSense device.

    on_rumble: optional callback(intensity, sharpness), both 0.0-1.0,
        fired from a reader thread whenever a game plays or stops a
        rumble effect on the virtual device.
    motion_steering: None, or one of "pitch"/"roll"/"yaw" — that attitude
        component replaces the left stick X axis.
    motion_range: radians of tilt for full stick deflection.
    """

    def __init__(self, on_rumble=None, motion_steering=None, motion_range=0.785):
        if motion_steering is not None and motion_steering not in _MOTION_SOURCES:
            raise ValueError("motion_steering must be one of %r" % (_MOTION_SOURCES,))
        self.on_rumble = on_rumble
        self.motion_steering = motion_steering
        self.motion_range = motion_range
        self._effects = {}  # effect id -> (strong, weak)
        self._ui = UInput(
            _CAPABILITIES,
            name=DEVICE_NAME,
            vendor=VENDOR_SONY,
            product=PRODUCT_DUALSENSE,
            version=0x0111,
            bustype=e.BUS_BLUETOOTH,
        )
        self._ff_thread = threading.Thread(
            target=self._serve_forcefeedback, name="picontrol-ff", daemon=True)
        self._ff_thread.start()

    def update(self, state):
        for mask, code in _BUTTON_MAP:
            self._ui.write(e.EV_KEY, code, 1 if state.pressed(mask) else 0)
        if self.motion_steering is not None:
            tilt = getattr(state, self.motion_steering)
            lx = attitude_to_stick(tilt, self.motion_range)
        else:
            lx = state.lx
        self._ui.write(e.EV_ABS, e.ABS_X, _stick(lx))
        self._ui.write(e.EV_ABS, e.ABS_Y, _stick(state.ly))
        self._ui.write(e.EV_ABS, e.ABS_RX, _stick(state.rx))
        self._ui.write(e.EV_ABS, e.ABS_RY, _stick(state.ry))
        self._ui.write(e.EV_ABS, e.ABS_Z, state.l2)
        self._ui.write(e.EV_ABS, e.ABS_RZ, state.r2)
        self._ui.write(e.EV_ABS, e.ABS_HAT0X, state.dpad_x)
        self._ui.write(e.EV_ABS, e.ABS_HAT0Y, state.dpad_y)
        self._ui.syn()

    def _serve_forcefeedback(self):
        """Handle FF uploads/plays from games; runs on the reader thread
        until the uinput fd closes."""
        try:
            for event in self._ui.read_loop():
                if event.type == e.EV_UINPUT:
                    if event.code == e.UI_FF_UPLOAD:
                        upload = self._ui.begin_upload(event.value)
                        effect = upload.effect
                        if effect.type == e.FF_RUMBLE:
                            rumble = effect.u.ff_rumble_effect
                            self._effects[effect.id] = (
                                rumble.strong_magnitude, rumble.weak_magnitude)
                        upload.retval = 0
                        self._ui.end_upload(upload)
                    elif event.code == e.UI_FF_ERASE:
                        erase = self._ui.begin_erase(event.value)
                        self._effects.pop(erase.effect_id, None)
                        erase.retval = 0
                        self._ui.end_erase(erase)
                elif event.type == e.EV_FF:
                    # Games play/stop an uploaded effect: value > 0 plays.
                    magnitudes = self._effects.get(event.code)
                    if magnitudes is None or self.on_rumble is None:
                        continue
                    if event.value > 0:
                        intensity, sharpness = rumble_to_haptics(*magnitudes)
                    else:
                        intensity, sharpness = 0.0, 0.5
                    self.on_rumble(intensity, sharpness)
        except OSError:
            pass  # device closed; thread exits

    def close(self):
        self._ui.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
