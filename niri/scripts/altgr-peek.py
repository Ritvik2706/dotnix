#!/usr/bin/env python3
"""
altgr-peek.py — hold AltGr to peek at the lumen island's card, let go to close.

Hyprland binds the key's release (hypr/lua/keybinds/basics.lua); niri only
binds presses. So under niri this listens to the key itself: keyd turns AltGr
into Super_R (/etc/keyd: rightalt = rightmeta) and sends it out of its
"keyd virtual keyboard", which this reads, without grabbing it, so the key
still reaches niri and apps as before. Press -> `emit peek 1`, release ->
`emit peek 0`, auto-repeat ignored.

Needs read access to /dev/input (the `input` group). Started by niri
(config.kdl); Hyprland has its own binds, so not there.
"""
import os
import signal
import subprocess
import time

import evdev
from evdev import ecodes

DEVICE = "keyd virtual keyboard"
KEY = ecodes.KEY_RIGHTMETA
LUMEN = os.path.expanduser("~/.local/bin/lumen")

# Fire and forget: the children reap themselves.
signal.signal(signal.SIGCHLD, signal.SIG_IGN)


def peek(on):
    subprocess.Popen(
        [LUMEN, "--say", "island", f"emit peek {1 if on else 0}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def find():
    for path in evdev.list_devices():
        dev = evdev.InputDevice(path)
        if dev.name == DEVICE:
            return dev
        dev.close()
    return None


while True:
    dev = find()
    if dev is None:
        # keyd not up yet (or restarting): look again shortly.
        time.sleep(2)
        continue
    held = False
    try:
        for ev in dev.read_loop():
            if ev.type != ecodes.EV_KEY or ev.code != KEY or ev.value == 2:
                continue
            if bool(ev.value) != held:
                held = bool(ev.value)
                peek(held)
    except OSError:
        # The device went away (keyd restarted): never leave the card open.
        if held:
            peek(False)
        time.sleep(1)
