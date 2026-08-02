"""`picontrol-dualsense` entry point: advertise, receive, drive a virtual
DualSense. Use --dry-run to print decoded state instead of creating the
uinput device (works without root and without the [uinput] extra)."""

import argparse
import asyncio
import logging
import math

from .receiver import DEFAULT_NAME, PiControlReceiver


async def _run(args):
    receiver = PiControlReceiver(name=args.name)

    if args.dry_run:
        receiver.on_state = print
        sink_close = lambda: None
    else:
        from .uinput_sink import DualSenseSink
        sink = DualSenseSink(
            motion_steering=args.motion_steering,
            motion_range=math.radians(args.motion_range),
        )
        receiver.on_state = sink.update
        # FF rumble events arrive on the sink's reader thread; bless isn't
        # thread-safe, so marshal set_haptics onto the event loop.
        loop = asyncio.get_running_loop()
        sink.on_rumble = lambda intensity, sharpness: loop.call_soon_threadsafe(
            receiver.set_haptics, intensity, sharpness)
        sink_close = sink.close

    try:
        async with receiver:
            await asyncio.Event().wait()  # run until Ctrl-C
    finally:
        sink_close()


def main():
    parser = argparse.ArgumentParser(
        description="Expose the PiControl iPhone app as a virtual DualSense.")
    parser.add_argument("--name", default=DEFAULT_NAME,
                        help="advertised BLE device name (default: %(default)s)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print controller state instead of creating a uinput device")
    parser.add_argument("--motion-steering", choices=("pitch", "roll", "yaw"),
                        help="replace left stick X with this attitude component")
    parser.add_argument("--motion-range", type=float, default=45.0,
                        help="tilt in degrees for full stick deflection "
                             "(default: %(default)s)")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)
    try:
        asyncio.run(_run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
