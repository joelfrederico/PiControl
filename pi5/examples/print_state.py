"""Minimal picontrol usage: advertise, print state, demo haptics.

Run on the Pi 5 (or a Mac) with the library installed — no root or
uinput needed:

    python3 examples/print_state.py

Holding the cross button vibrates the phone; the tracker's edge
detection triggers it exactly once per press/release.
"""

import asyncio

from picontrol import BUTTON_CROSS, PiControlReceiver


async def main():
    async with PiControlReceiver() as receiver:
        print("Advertising; connect from the PiControl iOS app...")
        async for state in receiver.states():
            # Edge-triggered haptics: rumble while cross is held.
            if receiver.tracker.just_pressed(BUTTON_CROSS):
                receiver.set_haptics(0.8, sharpness=0.3)
            elif receiver.tracker.just_released(BUTTON_CROSS):
                receiver.set_haptics(0.0)

            marker = "X" if state.pressed(BUTTON_CROSS) else " "
            print(f"[{marker}] L=({state.lx:4d},{state.ly:4d}) "
                  f"R=({state.rx:4d},{state.ry:4d}) "
                  f"L2={state.l2:3d} R2={state.r2:3d} dpad=({state.dpad_x:2d},{state.dpad_y:2d}) "
                  f"att=({state.pitch:+.2f},{state.roll:+.2f},{state.yaw:+.2f}) "
                  f"lost={receiver.tracker.lost}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
