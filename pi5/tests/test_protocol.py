import filecmp
import pathlib

import pytest

from picontrol import protocol
from picontrol.protocol import ControllerState, ProtocolError, decode, encode

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def test_packet_size():
    assert protocol.PACKET_SIZE == 17
    assert len(encode(ControllerState())) == protocol.PACKET_SIZE


def test_round_trip():
    state = ControllerState(
        buttons=protocol.BUTTON_CROSS | protocol.BUTTON_R1 | protocol.BUTTON_PS,
        hat=protocol.HAT_SW,
        lx=-127, ly=127, rx=42, ry=-42,
        l2=0, r2=255, seq=200,
    )
    assert decode(encode(state)) == state


def test_attitude_round_trip():
    """Attitude is quantized to int16 on the wire, so compare approximately."""
    state = ControllerState(pitch=0.5, roll=-1.2, yaw=3.0)
    decoded = decode(encode(state))
    resolution = 1 / protocol.ATTITUDE_SCALE
    assert decoded.pitch == pytest.approx(0.5, abs=resolution)
    assert decoded.roll == pytest.approx(-1.2, abs=resolution)
    assert decoded.yaw == pytest.approx(3.0, abs=resolution)


def test_attitude_clamped_at_pi():
    import math
    state = decode(encode(ControllerState(roll=math.pi + 1)))
    assert state.roll == pytest.approx(math.pi, abs=1e-3)


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


def test_tracker_edges():
    tracker = protocol.InputTracker()
    tracker.feed(encode(ControllerState(buttons=protocol.BUTTON_CROSS, seq=1)))
    assert tracker.just_pressed(protocol.BUTTON_CROSS)
    assert not tracker.just_released(protocol.BUTTON_CROSS)
    assert tracker.pressed(protocol.BUTTON_CROSS)

    tracker.feed(encode(ControllerState(buttons=protocol.BUTTON_CROSS, seq=2)))
    assert not tracker.just_pressed(protocol.BUTTON_CROSS)  # held, not an edge

    tracker.feed(encode(ControllerState(seq=3)))
    assert tracker.just_released(protocol.BUTTON_CROSS)
    assert not tracker.pressed(protocol.BUTTON_CROSS)


def test_tracker_seq_loss():
    tracker = protocol.InputTracker()
    tracker.feed(encode(ControllerState(seq=10)))
    assert tracker.lost == 0  # first packet can't imply loss
    tracker.feed(encode(ControllerState(seq=11)))
    tracker.feed(encode(ControllerState(seq=15)))  # 12-14 missing
    assert tracker.lost == 3
    assert tracker.packets == 3


def test_tracker_seq_wraps():
    tracker = protocol.InputTracker()
    tracker.feed(encode(ControllerState(seq=255)))
    tracker.feed(encode(ControllerState(seq=0)))
    assert tracker.lost == 0


def test_tracker_bad_packet_changes_nothing():
    tracker = protocol.InputTracker()
    tracker.feed(encode(ControllerState(buttons=protocol.BUTTON_CROSS, seq=1)))
    with pytest.raises(ProtocolError):
        tracker.feed(b"\x00" * 3)
    assert tracker.pressed(protocol.BUTTON_CROSS)
    assert tracker.packets == 1


def test_config_round_trip():
    config = protocol.ReceiverConfig(wants_motion=False, wants_analog=True,
                                     rate_hz=30)
    assert protocol.decode_config(protocol.encode_config(config)) == config


def test_config_decode_is_lenient():
    defaults = protocol.ReceiverConfig()
    assert protocol.decode_config(None) == defaults
    assert protocol.decode_config(b"") == defaults
    assert protocol.decode_config(b"\x00" * 10) == defaults
    unknown_version = bytes([99, 0, 30])
    assert protocol.decode_config(unknown_version) == defaults


def test_config_rate_clamped():
    config = protocol.ReceiverConfig(rate_hz=500)
    assert protocol.decode_config(protocol.encode_config(config)).rate_hz == 120


def test_haptics_round_trip():
    command = protocol.HapticsCommand(intensity=1.0, sharpness=0.0)
    assert protocol.decode_haptics(protocol.encode_haptics(command)) == command


def test_haptics_quantized_round_trip():
    command = protocol.HapticsCommand(intensity=0.5, sharpness=0.25)
    decoded = protocol.decode_haptics(protocol.encode_haptics(command))
    assert decoded.intensity == pytest.approx(0.5, abs=1 / 255)
    assert decoded.sharpness == pytest.approx(0.25, abs=1 / 255)


def test_haptics_decode_is_lenient():
    off = protocol.HapticsCommand()
    assert protocol.decode_haptics(None) == off
    assert protocol.decode_haptics(b"") == off
    assert protocol.decode_haptics(bytes([99, 255, 255])) == off  # bad version


def test_haptics_clamped():
    command = protocol.HapticsCommand(intensity=7.0, sharpness=-2.0)
    decoded = protocol.decode_haptics(protocol.encode_haptics(command))
    assert decoded.intensity == 1.0
    assert decoded.sharpness == 0.0


def test_pico_copy_is_identical():
    """pico/picontrol/protocol.py must stay a verbatim copy of the pi5 one."""
    pi5 = REPO_ROOT / "pi5" / "src" / "picontrol" / "protocol.py"
    pico = REPO_ROOT / "pico" / "picontrol" / "protocol.py"
    assert filecmp.cmp(pi5, pico, shallow=False), (
        "protocol.py differs between pi5 and pico; copy the pi5 version over")
