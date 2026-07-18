"""`picontrol-dualsense` entry point: advertise, receive, drive a virtual
DualSense. Use --dry-run to print decoded state instead of creating the
uinput device (works without root and without the [uinput] extra)."""

import argparse
import asyncio
import logging

from .receiver import DEFAULT_NAME, PiControlReceiver


async def _run(args):
    if args.dry_run:
        sink_update = print
        sink_close = lambda: None
    else:
        from .uinput_sink import DualSenseSink
        sink = DualSenseSink()
        sink_update = sink.update
        sink_close = sink.close

    try:
        async with PiControlReceiver(name=args.name, on_state=sink_update):
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
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)
    try:
        asyncio.run(_run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
