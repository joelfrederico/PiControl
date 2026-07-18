"""PiControl BLE input packet protocol.

This file is shared verbatim between pi5/src/picontrol/ and pico/picontrol/,
so it must stay MicroPython-compatible: no dataclasses, no typing, stdlib
struct only. The packet layout is documented in the top-level README.md.
"""

import struct

PROTOCOL_VERSION = 1

SERVICE_UUID = "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0001"
INPUT_CHAR_UUID = "b7f9a1e0-9c3d-4b6a-8a5e-1f2d3c4b0002"

PACKET_FORMAT = "<BBHBbbbbBB"
PACKET_SIZE = struct.calcsize(PACKET_FORMAT)  # 11 bytes

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


class ProtocolError(Exception):
    pass


class ControllerState:
    """Decoded state of the iPhone controller at one instant."""

    def __init__(self, buttons=0, hat=HAT_CENTERED, lx=0, ly=0, rx=0, ry=0,
                 l2=0, r2=0, seq=0):
        self.buttons = buttons
        self.hat = hat
        self.lx = lx
        self.ly = ly
        self.rx = rx
        self.ry = ry
        self.l2 = l2
        self.r2 = r2
        self.seq = seq

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
                and self.seq == other.seq)

    def __repr__(self):
        return ("ControllerState(buttons=0x%03x, hat=%d, lx=%d, ly=%d, "
                "rx=%d, ry=%d, l2=%d, r2=%d, seq=%d)" % (
                    self.buttons, self.hat, self.lx, self.ly,
                    self.rx, self.ry, self.l2, self.r2, self.seq))


def decode(data):
    """Decode one input packet into a ControllerState.

    Raises ProtocolError on wrong size, version, or hat value.
    """
    if len(data) != PACKET_SIZE:
        raise ProtocolError("expected %d bytes, got %d" % (PACKET_SIZE, len(data)))
    version, seq, buttons, hat, lx, ly, rx, ry, l2, r2 = struct.unpack(
        PACKET_FORMAT, data)
    if version != PROTOCOL_VERSION:
        raise ProtocolError("unsupported protocol version %d" % version)
    if hat not in _HAT_XY:
        raise ProtocolError("invalid hat value %d" % hat)
    return ControllerState(buttons=buttons, hat=hat, lx=lx, ly=ly,
                           rx=rx, ry=ry, l2=l2, r2=r2, seq=seq)


def encode(state):
    """Encode a ControllerState into packet bytes (used by tests; the iOS
    app has the production encoder in Protocol.swift)."""
    return struct.pack(PACKET_FORMAT, PROTOCOL_VERSION, state.seq,
                       state.buttons, state.hat, state.lx, state.ly,
                       state.rx, state.ry, state.l2, state.r2)
