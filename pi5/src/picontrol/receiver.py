"""BLE peripheral that receives controller input from the PiControl iOS app.

The Pi advertises the PiControl GATT service; the iPhone connects as central
and streams input packets via write-without-response. Each decoded packet is
delivered to the `on_state` callback and to the `states()` async iterator.

The receiver also serves a config characteristic (read+notify) telling the
phone what it wants: motion data, analog data, and packet rate. Change it
mid-connection with `set_config(...)` — the phone applies it live.
"""

import asyncio
import logging

from bless import (
    BlessServer,
    GATTAttributePermissions,
    GATTCharacteristicProperties,
)

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

logger = logging.getLogger(__name__)

DEFAULT_NAME = "PiControl-pi5"


def _use_legacy_advertising():
    """Keep bless's advertisement within legacy (non-extended) advertising.

    bless always exports TxPower, MinInterval and MaxInterval on its
    LEAdvertisement1 object. BlueZ accepts those three only when the
    controller supports *extended* advertising — it gates them on the
    MGMT_ADV_PARAM_* feature flags — so on radios without it (notably the
    Raspberry Pi's onboard chip) RegisterAdvertisement is rejected and the
    receiver never appears. We only ever leave them at bless's defaults, so
    drop them from the exported interface and let BlueZ advertise the
    ordinary legacy way.

    No-op off the BlueZ backend (e.g. macOS/CoreBluetooth).
    """
    try:
        from bless.backends.bluezdbus.dbus.advertisement import (
            BlueZLEAdvertisement,
        )
    except ImportError:
        return
    for name in ("TxPower", "MinInterval", "MaxInterval"):
        if hasattr(BlueZLEAdvertisement, name):
            delattr(BlueZLEAdvertisement, name)
            logger.debug("removed experimental advertising property %s", name)


class PiControlReceiver:
    """Advertise the PiControl service and receive ControllerState updates.

    Usage with a callback:

        receiver = PiControlReceiver(on_state=handle_state)
        await receiver.start()

    or as an async iterator:

        async with PiControlReceiver() as receiver:
            async for state in receiver.states():
                ...

    `receiver.tracker` exposes the latest state plus button edges and packet
    loss (see protocol.InputTracker).
    """

    def __init__(self, name=DEFAULT_NAME, on_state=None,
                 wants_motion=True, wants_analog=True,
                 rate_hz=DEFAULT_RATE_HZ):
        self.name = name
        self.on_state = on_state
        self.tracker = InputTracker()
        self.config = ReceiverConfig(wants_motion=wants_motion,
                                     wants_analog=wants_analog,
                                     rate_hz=rate_hz)
        self.haptics = HapticsCommand()
        self._server = None
        self._queue = asyncio.Queue()

    async def start(self):
        _use_legacy_advertising()
        self._server = BlessServer(name=self.name)
        self._server.write_request_func = self._on_write
        self._server.read_request_func = self._on_read
        await self._server.add_new_service(SERVICE_UUID)
        await self._server.add_new_characteristic(
            SERVICE_UUID,
            INPUT_CHAR_UUID,
            (GATTCharacteristicProperties.write
             | GATTCharacteristicProperties.write_without_response),
            None,
            GATTAttributePermissions.writeable,
        )
        await self._server.add_new_characteristic(
            SERVICE_UUID,
            CONFIG_CHAR_UUID,
            (GATTCharacteristicProperties.read
             | GATTCharacteristicProperties.notify),
            encode_config(self.config),
            GATTAttributePermissions.readable,
        )
        await self._server.add_new_characteristic(
            SERVICE_UUID,
            HAPTICS_CHAR_UUID,
            (GATTCharacteristicProperties.read
             | GATTCharacteristicProperties.notify),
            encode_haptics(self.haptics),
            GATTAttributePermissions.readable,
        )
        await self._server.start()
        logger.info("advertising as %r (service %s, config %r)",
                    self.name, SERVICE_UUID, self.config)

    async def stop(self):
        if self._server is not None:
            await self._server.stop()
            self._server = None

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
        if self._server is not None:
            characteristic = self._server.get_characteristic(CONFIG_CHAR_UUID)
            if characteristic is not None:
                characteristic.value = encode_config(self.config)
                self._server.update_value(SERVICE_UUID, CONFIG_CHAR_UUID)
        logger.info("config changed: %r", self.config)

    def set_haptics(self, intensity, sharpness=None):
        """Drive the phone's vibration: intensity 0.0-1.0 (0 = off),
        optional sharpness 0.0-1.0 (0 = dull rumble, 1 = crisp buzz)."""
        self.haptics.intensity = intensity
        if sharpness is not None:
            self.haptics.sharpness = sharpness
        if self._server is not None:
            characteristic = self._server.get_characteristic(HAPTICS_CHAR_UUID)
            if characteristic is not None:
                characteristic.value = encode_haptics(self.haptics)
                self._server.update_value(SERVICE_UUID, HAPTICS_CHAR_UUID)

    async def __aenter__(self):
        await self.start()
        return self

    async def __aexit__(self, *exc):
        await self.stop()

    async def states(self):
        """Yield ControllerState objects as packets arrive."""
        while True:
            yield await self._queue.get()

    def _on_read(self, characteristic, **kwargs):
        return characteristic.value

    def _on_write(self, characteristic, value, **kwargs):
        try:
            state = self.tracker.feed(value)
        except ProtocolError as exc:
            logger.warning("dropping bad packet: %s", exc)
            return
        if self.on_state is not None:
            self.on_state(state)
        self._queue.put_nowait(state)
