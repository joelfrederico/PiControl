"""PiControl BLE input packet protocol.

This file is shared verbatim between pi5/src/picontrol/ and pico/picontrol/,
so it must stay MicroPython-compatible: no dataclasses, no typing, stdlib
struct/math only. The packet layout is documented in the top-level README.md.
"""

import math
import struct

PROTOCOL_VERSION = 2

SERVICE_UUID = "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0001"
INPUT_CHAR_UUID = "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0002"
CONFIG_CHAR_UUID = "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0003"
HAPTICS_CHAR_UUID = "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0004"

PACKET_FORMAT = "<BBHBbbbbBBhhh"
PACKET_SIZE = struct.calcsize(PACKET_FORMAT)  # 17 bytes

# Attitude fields are radians scaled to int16: +/-pi maps to +/-32767.
ATTITUDE_SCALE = 32767 / math.pi

# Button bitmask
BUTTON_CROSS = 1 << 0
BUTTON_CIRCLE = 1 << 1
BUTTON_SQUARE = 1 << 2
BUTTON_TRIANGLE = 1 << 3
BUTTON_L1 = 1 << 4
BUTTON_R1 = 1 << 5
BUTTON_L3 = 1 << 6
BUTTON_R3 = 1 << 7
BUTTON_CREATE = 1 << 8
BUTTON_OPTIONS = 1 << 9
BUTTON_PS = 1 << 10
BUTTON_TOUCHPAD = 1 << 11

# Hat values: 0 = centered, then clockwise from north
HAT_CENTERED = 0
HAT_N = 1
HAT_NE = 2
HAT_E = 3
HAT_SE = 4
HAT_S = 5
HAT_SW = 6
HAT_W = 7
HAT_NW = 8

# hat value -> (x, y) with x: -1 left / 1 right, y: -1 up / 1 down
_HAT_XY = {
    HAT_CENTERED: (0, 0),
    HAT_N: (0, -1),
    HAT_NE: (1, -1),
    HAT_E: (1, 0),
    HAT_SE: (1, 1),
    HAT_S: (0, 1),
    HAT_SW: (-1, 1),
    HAT_W: (-1, 0),
    HAT_NW: (-1, -1),
}


def _attitude_to_wire(radians):
    value = int(round(radians * ATTITUDE_SCALE))
    return max(-32767, min(32767, value))


class ProtocolError(Exception):
    pass


class ControllerState:
    """Decoded state of the iPhone controller at one instant.

    Attitude (pitch/roll/yaw, radians) is the phone's fused gyro+accel
    orientation in the portrait device frame; yaw is relative to an
    arbitrary reference, not a compass heading.
    """

    def __init__(self, buttons=0, hat=HAT_CENTERED, lx=0, ly=0, rx=0, ry=0,
                 l2=0, r2=0, seq=0, pitch=0.0, roll=0.0, yaw=0.0):
        self.buttons = buttons
        self.hat = hat
        self.lx = lx
        self.ly = ly
        self.rx = rx
        self.ry = ry
        self.l2 = l2
        self.r2 = r2
        self.seq = seq
        self.pitch = pitch
        self.roll = roll
        self.yaw = yaw

    def pressed(self, button_mask):
        return bool(self.buttons & button_mask)

    @property
    def dpad_x(self):
        return _HAT_XY[self.hat][0]

    @property
    def dpad_y(self):
        return _HAT_XY[self.hat][1]

    def __eq__(self, other):
        if not isinstance(other, ControllerState):
            return NotImplemented
        return (self.buttons == other.buttons and self.hat == other.hat
                and self.lx == other.lx and self.ly == other.ly
                and self.rx == other.rx and self.ry == other.ry
                and self.l2 == other.l2 and self.r2 == other.r2
                and self.seq == other.seq and self.pitch == other.pitch
                and self.roll == other.roll and self.yaw == other.yaw)

    def __repr__(self):
        return ("ControllerState(buttons=0x%03x, hat=%d, lx=%d, ly=%d, "
                "rx=%d, ry=%d, l2=%d, r2=%d, seq=%d, "
                "pitch=%.3f, roll=%.3f, yaw=%.3f)" % (
                    self.buttons, self.hat, self.lx, self.ly,
                    self.rx, self.ry, self.l2, self.r2, self.seq,
                    self.pitch, self.roll, self.yaw))


def decode(data):
    """Decode one input packet into a ControllerState.

    Raises ProtocolError on wrong size, version, or hat value.
    """
    if len(data) != PACKET_SIZE:
        raise ProtocolError("expected %d bytes, got %d" % (PACKET_SIZE, len(data)))
    (version, seq, buttons, hat, lx, ly, rx, ry, l2, r2,
     pitch_raw, roll_raw, yaw_raw) = struct.unpack(PACKET_FORMAT, data)
    if version != PROTOCOL_VERSION:
        raise ProtocolError("unsupported protocol version %d" % version)
    if hat not in _HAT_XY:
        raise ProtocolError("invalid hat value %d" % hat)
    return ControllerState(buttons=buttons, hat=hat, lx=lx, ly=ly,
                           rx=rx, ry=ry, l2=l2, r2=r2, seq=seq,
                           pitch=pitch_raw / ATTITUDE_SCALE,
                           roll=roll_raw / ATTITUDE_SCALE,
                           yaw=yaw_raw / ATTITUDE_SCALE)


def encode(state):
    """Encode a ControllerState into packet bytes (used by tests; the iOS
    app has the production encoder in Protocol.swift)."""
    return struct.pack(PACKET_FORMAT, PROTOCOL_VERSION, state.seq,
                       state.buttons, state.hat, state.lx, state.ly,
                       state.rx, state.ry, state.l2, state.r2,
                       _attitude_to_wire(state.pitch),
                       _attitude_to_wire(state.roll),
                       _attitude_to_wire(state.yaw))


class InputTracker:
    """Stateful wrapper over decode(): tracks latest state, button edges,
    and packet loss from seq gaps.

    Deliberately clock-free (MicroPython timekeeping differs per port);
    staleness detection belongs in receivers, which have an event loop.
    """

    def __init__(self):
        self.state = ControllerState()
        self.pressed_edges = 0
        self.released_edges = 0
        self.packets = 0
        self.lost = 0

    def feed(self, data):
        """Decode one packet, update state/edges/loss, return the state.

        Raises ProtocolError like decode(); a bad packet changes nothing.
        """
        new = decode(data)
        prev = self.state
        self.pressed_edges = new.buttons & ~prev.buttons
        self.released_edges = prev.buttons & ~new.buttons
        if self.packets > 0:
            self.lost += (new.seq - prev.seq - 1) % 256
        self.packets += 1
        self.state = new
        return new

    def pressed(self, button_mask):
        return self.state.pressed(button_mask)

    def just_pressed(self, button_mask):
        return bool(self.pressed_edges & button_mask)

    def just_released(self, button_mask):
        return bool(self.released_edges & button_mask)


# Receiver config: served by the receiver on CONFIG_CHAR_UUID (read+notify)
# so the phone can skip unwanted sensors and match the requested rate. The
# input packet layout never changes; unwanted fields are simply zeroed.

CONFIG_VERSION = 1
CONFIG_FORMAT = "<BBB"
CONFIG_SIZE = struct.calcsize(CONFIG_FORMAT)  # 3 bytes

CONFIG_WANT_MOTION = 1 << 0
CONFIG_WANT_ANALOG = 1 << 1

DEFAULT_RATE_HZ = 60


class ReceiverConfig:
    def __init__(self, wants_motion=True, wants_analog=True,
                 rate_hz=DEFAULT_RATE_HZ):
        self.wants_motion = wants_motion
        self.wants_analog = wants_analog
        self.rate_hz = rate_hz

    def __eq__(self, other):
        if not isinstance(other, ReceiverConfig):
            return NotImplemented
        return (self.wants_motion == other.wants_motion
                and self.wants_analog == other.wants_analog
                and self.rate_hz == other.rate_hz)

    def __repr__(self):
        return ("ReceiverConfig(wants_motion=%r, wants_analog=%r, "
                "rate_hz=%d)" % (self.wants_motion, self.wants_analog,
                                 self.rate_hz))


def encode_config(config):
    flags = 0
    if config.wants_motion:
        flags |= CONFIG_WANT_MOTION
    if config.wants_analog:
        flags |= CONFIG_WANT_ANALOG
    rate = max(1, min(120, config.rate_hz))
    return struct.pack(CONFIG_FORMAT, CONFIG_VERSION, flags, rate)


def decode_config(data):
    """Decode a config value, tolerantly: anything unparseable (wrong size
    or unknown version) yields the defaults, so a phone talking to a
    receiver without the characteristic — or a newer one — keeps working."""
    if data is None or len(data) != CONFIG_SIZE:
        return ReceiverConfig()
    version, flags, rate = struct.unpack(CONFIG_FORMAT, data)
    if version != CONFIG_VERSION:
        return ReceiverConfig()
    return ReceiverConfig(
        wants_motion=bool(flags & CONFIG_WANT_MOTION),
        wants_analog=bool(flags & CONFIG_WANT_ANALOG),
        rate_hz=max(1, min(120, rate)),
    )


# Haptics: served by the receiver on HAPTICS_CHAR_UUID (read+notify) to
# drive the phone's vibration, like a console driving controller rumble.
# Intensity and sharpness are 0.0-1.0 (CoreHaptics' two axes; sharpness
# is the analog of the DualSense's low/high frequency motor split).

HAPTICS_VERSION = 1
HAPTICS_FORMAT = "<BBB"
HAPTICS_SIZE = struct.calcsize(HAPTICS_FORMAT)  # 3 bytes


class HapticsCommand:
    def __init__(self, intensity=0.0, sharpness=0.5):
        self.intensity = intensity
        self.sharpness = sharpness

    def __eq__(self, other):
        if not isinstance(other, HapticsCommand):
            return NotImplemented
        return (self.intensity == other.intensity
                and self.sharpness == other.sharpness)

    def __repr__(self):
        return ("HapticsCommand(intensity=%.3f, sharpness=%.3f)"
                % (self.intensity, self.sharpness))


def _unit_to_wire(value):
    return max(0, min(255, int(round(value * 255))))


def encode_haptics(command):
    return struct.pack(HAPTICS_FORMAT, HAPTICS_VERSION,
                       _unit_to_wire(command.intensity),
                       _unit_to_wire(command.sharpness))


def decode_haptics(data):
    """Decode a haptics value, tolerantly: anything unparseable yields the
    default (vibration off)."""
    if data is None or len(data) != HAPTICS_SIZE:
        return HapticsCommand()
    version, intensity, sharpness = struct.unpack(HAPTICS_FORMAT, data)
    if version != HAPTICS_VERSION:
        return HapticsCommand()
    return HapticsCommand(intensity=intensity / 255, sharpness=sharpness / 255)
