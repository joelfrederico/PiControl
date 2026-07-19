"""BLE peripheral for the Pico 2 W that receives PiControl iPhone input.

The Pico advertises the PiControl GATT service; the iPhone connects as
central and streams input packets via write-without-response. Requires
MicroPython >= 1.20 firmware for the Pico 2 W (aioble is bundled).

The receiver also serves a config characteristic (read+notify) telling the
phone what it wants: motion data, analog data, and packet rate. Change it
mid-connection with `set_config(...)` — the phone applies it live.
"""

import aioble
import asyncio
import bluetooth

from .protocol import (
    CONFIG_CHAR_UUID,
    DEFAULT_RATE_HZ,
    HAPTICS_CHAR_UUID,
    INPUT_CHAR_UUID,
    SERVICE_UUID,
    HapticsCommand,
    InputTracker,
    ProtocolError,
    ReceiverConfig,
    encode_config,
    encode_haptics,
)

DEFAULT_NAME = "PiControl-pico"
_ADV_INTERVAL_US = 250_000


class PiControlReceiver:
    """Advertise the PiControl service and receive ControllerState updates.

        receiver = PiControlReceiver(on_state=handle_state)
        await receiver.run()

    `on_state(state)` is called for every packet while connected. `run()`
    advertises, serves one connection at a time, and re-advertises on
    disconnect; it only returns if cancelled. Optional hooks `on_connect(
    device)` and `on_disconnect()` track connection state.

    `receiver.tracker` exposes the latest state plus button edges and
    packet loss (see protocol.InputTracker).
    """

    def __init__(self, name=DEFAULT_NAME, on_state=None,
                 on_connect=None, on_disconnect=None,
                 wants_motion=True, wants_analog=True,
                 rate_hz=DEFAULT_RATE_HZ):
        self.name = name
        self.on_state = on_state
        self.on_connect = on_connect
        self.on_disconnect = on_disconnect
        self.tracker = InputTracker()
        self.config = ReceiverConfig(wants_motion=wants_motion,
                                     wants_analog=wants_analog,
                                     rate_hz=rate_hz)

        service = aioble.Service(bluetooth.UUID(SERVICE_UUID))
        self._char = aioble.Characteristic(
            service,
            bluetooth.UUID(INPUT_CHAR_UUID),
            write=True,
            write_no_response=True,
            capture=True,
        )
        self._config_char = aioble.Characteristic(
            service,
            bluetooth.UUID(CONFIG_CHAR_UUID),
            read=True,
            notify=True,
        )
        self._haptics_char = aioble.Characteristic(
            service,
            bluetooth.UUID(HAPTICS_CHAR_UUID),
            read=True,
            notify=True,
        )
        aioble.register_services(service)
        self._config_char.write(encode_config(self.config))
        self.haptics = HapticsCommand()
        self._haptics_char.write(encode_haptics(self.haptics))

    def set_config(self, wants_motion=None, wants_analog=None, rate_hz=None):
        """Update the served config and notify a connected phone.

        Only the given fields change; the rest keep their current values.
        """
        if wants_motion is not None:
            self.config.wants_motion = wants_motion
        if wants_analog is not None:
            self.config.wants_analog = wants_analog
        if rate_hz is not None:
            self.config.rate_hz = rate_hz
        self._config_char.write(encode_config(self.config), send_update=True)

    def set_haptics(self, intensity, sharpness=None):
        """Drive the phone's vibration: intensity 0.0-1.0 (0 = off),
        optional sharpness 0.0-1.0 (0 = dull rumble, 1 = crisp buzz)."""
        self.haptics.intensity = intensity
        if sharpness is not None:
            self.haptics.sharpness = sharpness
        self._haptics_char.write(encode_haptics(self.haptics), send_update=True)

    async def run(self):
        while True:
            connection = await aioble.advertise(
                _ADV_INTERVAL_US,
                name=self.name,
                services=[bluetooth.UUID(SERVICE_UUID)],
            )
            if self.on_connect is not None:
                self.on_connect(connection.device)
            try:
                await self._serve(connection)
            finally:
                if self.on_disconnect is not None:
                    self.on_disconnect()

    async def _serve(self, connection):
        while connection.is_connected():
            try:
                # Timeout so a disconnect can't leave us blocked forever.
                _, data = await self._char.written(timeout_ms=1000)
            except asyncio.TimeoutError:
                continue
            try:
                state = self.tracker.feed(data)
            except ProtocolError:
                continue
            if self.on_state is not None:
                self.on_state(state)
