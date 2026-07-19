"""picontrol: receive controller input from the PiControl iOS app over BLE."""

from .protocol import (
    BUTTON_CIRCLE,
    BUTTON_CREATE,
    BUTTON_CROSS,
    BUTTON_L1,
    BUTTON_L3,
    BUTTON_OPTIONS,
    BUTTON_PS,
    BUTTON_R1,
    BUTTON_R3,
    BUTTON_SQUARE,
    BUTTON_TOUCHPAD,
    BUTTON_TRIANGLE,
    ControllerState,
    InputTracker,
    ProtocolError,
    ReceiverConfig,
)


def __getattr__(name):
    # Lazy so that protocol-only use (e.g. the tests) works without the
    # BLE dependency (bless) installed.
    if name == "PiControlReceiver":
        from .receiver import PiControlReceiver
        return PiControlReceiver
    raise AttributeError("module %r has no attribute %r" % (__name__, name))

__all__ = [
    "ControllerState",
    "InputTracker",
    "PiControlReceiver",
    "ProtocolError",
    "ReceiverConfig",
    "BUTTON_CROSS",
    "BUTTON_CIRCLE",
    "BUTTON_SQUARE",
    "BUTTON_TRIANGLE",
    "BUTTON_L1",
    "BUTTON_R1",
    "BUTTON_L3",
    "BUTTON_R3",
    "BUTTON_CREATE",
    "BUTTON_OPTIONS",
    "BUTTON_PS",
    "BUTTON_TOUCHPAD",
]
