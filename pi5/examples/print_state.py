"""Minimal picontrol usage: advertise and print controller state.

Run on the Pi 5 with the library installed (no root or uinput needed):

    python3 examples/print_state.py
"""

import asyncio

from picontrol import BUTTON_CROSS, PiControlReceiver


async def main():
    async with PiControlReceiver() as receiver:
        print("Advertising; connect from the PiControl iOS app...")
        async for state in receiver.states():
            marker = "X" if state.pressed(BUTTON_CROSS) else " "
            print(f"[{marker}] L=({state.lx:4d},{state.ly:4d}) "
                  f"R=({state.rx:4d},{state.ry:4d}) "
                  f"L2={state.l2:3d} R2={state.r2:3d} dpad=({state.dpad_x:2d},{state.dpad_y:2d})")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
