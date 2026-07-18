import filecmp
import pathlib

import pytest

from picontrol import protocol
from picontrol.protocol import ControllerState, ProtocolError, decode, encode

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def test_packet_size():
    assert protocol.PACKET_SIZE == 11
    assert len(encode(ControllerState())) == protocol.PACKET_SIZE


def test_round_trip():
    state = ControllerState(
        buttons=protocol.BUTTON_CROSS | protocol.BUTTON_R1 | protocol.BUTTON_PS,
        hat=protocol.HAT_SW,
        lx=-127, ly=127, rx=42, ry=-42,
        l2=0, r2=255, seq=200,
    )
    assert decode(encode(state)) == state


def test_neutral_state():
    state = decode(encode(ControllerState()))
    assert state.buttons == 0
    assert (state.lx, state.ly, state.rx, state.ry) == (0, 0, 0, 0)
    assert (state.dpad_x, state.dpad_y) == (0, 0)
    assert not state.pressed(protocol.BUTTON_CROSS)


def test_dpad_helpers():
    assert decode(encode(ControllerState(hat=protocol.HAT_NE))).dpad_x == 1
    assert decode(encode(ControllerState(hat=protocol.HAT_NE))).dpad_y == -1
    assert decode(encode(ControllerState(hat=protocol.HAT_S))).dpad_y == 1


def test_bad_size_rejected():
    with pytest.raises(ProtocolError):
        decode(b"\x00" * (protocol.PACKET_SIZE - 1))
    with pytest.raises(ProtocolError):
        decode(b"\x00" * (protocol.PACKET_SIZE + 1))


def test_bad_version_rejected():
    packet = bytearray(encode(ControllerState()))
    packet[0] = 99
    with pytest.raises(ProtocolError):
        decode(bytes(packet))


def test_bad_hat_rejected():
    packet = bytearray(encode(ControllerState()))
    packet[4] = 9
    with pytest.raises(ProtocolError):
        decode(bytes(packet))


def test_pico_copy_is_identical():
    """pico/picontrol/protocol.py must stay a verbatim copy of the pi5 one."""
    pi5 = REPO_ROOT / "pi5" / "src" / "picontrol" / "protocol.py"
    pico = REPO_ROOT / "pico" / "picontrol" / "protocol.py"
    assert filecmp.cmp(pi5, pico, shallow=False), (
        "protocol.py differs between pi5 and pico; copy the pi5 version over")
