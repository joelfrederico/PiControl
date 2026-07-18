"""PiControl demo for the Pico 2 W.

Advertises as "PiControl-pico"; connect from the PiControl iOS app. The
onboard LED tracks the cross button and stick values print to the console.

Upload the picontrol/ directory alongside this file (see pico/README.md),
then run or save as main.py on the device.
"""

import asyncio

from machine import Pin
from picontrol import BUTTON_CROSS, PiControlReceiver

led = Pin("LED", Pin.OUT)


def on_state(state):
    led.value(1 if state.pressed(BUTTON_CROSS) else 0)
    # Print at most ~4x/sec worth of interest: only when sticks are off-center.
    if state.lx or state.ly or state.rx or state.ry:
        print("L=(%4d,%4d) R=(%4d,%4d) L2=%3d R2=%3d"
              % (state.lx, state.ly, state.rx, state.ry, state.l2, state.r2))


def on_connect(device):
    print("connected:", device)


def on_disconnect():
    led.value(0)
    print("disconnected; advertising again")


async def main():
    receiver = PiControlReceiver(
        on_state=on_state,
        on_connect=on_connect,
        on_disconnect=on_disconnect,
    )
    print("Advertising as %r; connect from the PiControl iOS app..." % receiver.name)
    await receiver.run()


asyncio.run(main())
