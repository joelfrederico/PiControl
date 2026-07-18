"""BLE peripheral that receives controller input from the PiControl iOS app.

The Pi advertises the PiControl GATT service; the iPhone connects as central
and streams input packets via write-without-response. Each decoded packet is
delivered to the `on_state` callback and to the `states()` async iterator.
"""

import asyncio
import logging

from bless import (
    BlessServer,
    GATTAttributePermissions,
    GATTCharacteristicProperties,
)

from .protocol import INPUT_CHAR_UUID, SERVICE_UUID, ProtocolError, decode

logger = logging.getLogger(__name__)

DEFAULT_NAME = "PiControl-pi5"


class PiControlReceiver:
    """Advertise the PiControl service and receive ControllerState updates.

    Usage with a callback:

        receiver = PiControlReceiver(on_state=handle_state)
        await receiver.start()

    or as an async iterator:

        async with PiControlReceiver() as receiver:
            async for state in receiver.states():
                ...
    """

    def __init__(self, name=DEFAULT_NAME, on_state=None):
        self.name = name
        self.on_state = on_state
        self._server = None
        self._queue = asyncio.Queue()

    async def start(self):
        self._server = BlessServer(name=self.name)
        self._server.write_request_func = self._on_write
        await self._server.add_new_service(SERVICE_UUID)
        await self._server.add_new_characteristic(
            SERVICE_UUID,
            INPUT_CHAR_UUID,
            (GATTCharacteristicProperties.write
             | GATTCharacteristicProperties.write_without_response),
            None,
            GATTAttributePermissions.writeable,
        )
        await self._server.start()
        logger.info("advertising as %r (service %s)", self.name, SERVICE_UUID)

    async def stop(self):
        if self._server is not None:
            await self._server.stop()
            self._server = None

    async def __aenter__(self):
        await self.start()
        return self

    async def __aexit__(self, *exc):
        await self.stop()

    async def states(self):
        """Yield ControllerState objects as packets arrive."""
        while True:
            yield await self._queue.get()

    def _on_write(self, characteristic, value, **kwargs):
        try:
            state = decode(value)
        except ProtocolError as exc:
            logger.warning("dropping bad packet: %s", exc)
            return
        if self.on_state is not None:
            self.on_state(state)
        self._queue.put_nowait(state)
