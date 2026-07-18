"""BLE peripheral for the Pico 2 W that receives PiControl iPhone input.

The Pico advertises the PiControl GATT service; the iPhone connects as
central and streams input packets via write-without-response. Requires
MicroPython >= 1.20 firmware for the Pico 2 W (aioble is bundled).
"""

import aioble
import asyncio
import bluetooth

from .protocol import INPUT_CHAR_UUID, SERVICE_UUID, ProtocolError, decode

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
    """

    def __init__(self, name=DEFAULT_NAME, on_state=None,
                 on_connect=None, on_disconnect=None):
        self.name = name
        self.on_state = on_state
        self.on_connect = on_connect
        self.on_disconnect = on_disconnect

        service = aioble.Service(bluetooth.UUID(SERVICE_UUID))
        self._char = aioble.Characteristic(
            service,
            bluetooth.UUID(INPUT_CHAR_UUID),
            write=True,
            write_no_response=True,
            capture=True,
        )
        aioble.register_services(service)

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
                state = decode(data)
            except ProtocolError:
                continue
            if self.on_state is not None:
                self.on_state(state)
