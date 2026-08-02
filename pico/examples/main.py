"""PiControl demo for the Pico 2 W.

Advertises as "PiControl-pico"; connect from the PiControl iOS app. The
onboard LED tracks the cross button, stick values print to the console,
and holding the circle button vibrates the phone (edge-triggered via the
receiver's InputTracker).

Upload the picontrol/ directory alongside this file (see pico/README.md),
then run or save as main.py on the device.
"""

import asyncio

from machine import Pin
from picontrol import BUTTON_CIRCLE, BUTTON_CROSS, PiControlReceiver

led = Pin("LED", Pin.OUT)
receiver = None


def on_state(state):
    led.value(1 if state.pressed(BUTTON_CROSS) else 0)
    # Edge-triggered haptics: rumble the phone while circle is held.
    if receiver.tracker.just_pressed(BUTTON_CIRCLE):
        receiver.set_haptics(0.8, sharpness=0.3)
    elif receiver.tracker.just_released(BUTTON_CIRCLE):
        receiver.set_haptics(0.0)
    # Print at most ~4x/sec worth of interest: only when sticks are off-center.
    if state.lx or state.ly or state.rx or state.ry:
        print("L=(%4d,%4d) R=(%4d,%4d) L2=%3d R2=%3d att=(%.2f,%.2f,%.2f)"
              % (state.lx, state.ly, state.rx, state.ry, state.l2, state.r2,
                 state.pitch, state.roll, state.yaw))


def on_connect(device):
    print("connected:", device)


def on_disconnect():
    led.value(0)
    print("disconnected; advertising again")


async def main():
    global receiver
    receiver = PiControlReceiver(
        on_state=on_state,
        on_connect=on_connect,
        on_disconnect=on_disconnect,
    )
    print("Advertising as %r; connect from the PiControl iOS app..." % receiver.name)
    await receiver.run()


asyncio.run(main())
