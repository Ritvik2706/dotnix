#!/usr/bin/env python3
"""
Hold suspend until the lock screen has actually drawn.

WHY THIS EXISTS

A hyprlock that starts at the instant of suspend never draws a frame, and
resume-lock.sh has to swap it out on wake — the old-lock / black / new-lock
sequence on every lid open. Closing the lid now locks at once (Hyprland's lid
bind → sleep-lock.sh lid), but measured: logind suspends ~270ms after the lid
shuts, and hypridle's inhibit_sleep=3 lets go the moment the compositor says
"locked" — which is before hyprlock has drawn anything. (Read from hypridle's
source: mode 3 releases in onLocked(); mode 1 releases right after spawning
before_sleep_cmd without waiting for it.) So nothing was holding the system
up for the one thing that mattered.

This takes a logind "delay" inhibitor of its own, and on PrepareForSleep
releases it only once the lock is mature: session locked, the current
hyprlock born on a lit panel, and alive >= MATURE_MS. logind waits for every
delay inhibitor (capped by InhibitDelayMaxSec, 5s here), so a lid close now
costs ~0.7s more before sleep and the lock is whole when you open it.

It also writes the VERDICT that resume-lock.sh keys on: the PID of a lock
that was mature at suspend, which is safe to keep across the wake. No
verdict, the old swap runs — so if this guard is dead or the lock never
matured, the behaviour simply falls back to what it was.
"""
import os
import subprocess
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

MATURE_MS = 700        # birth → drawn, with margin (immediate_render ≈ 200ms)
MAX_WAIT_S = 3.5       # never hold suspend longer than this (logind cap is 5s)

RUN = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
BIRTH_FILE = os.path.join(RUN, "hyprlock-birth")
VERDICT_FILE = os.path.join(RUN, "hyprlock-verdict")

LOGIN1 = ("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager")

bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
inhibit_fd = None


def log(msg):
    print(msg, flush=True)


def sh(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=2).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def take_inhibitor():
    global inhibit_fd
    if inhibit_fd is not None:
        return
    try:
        res, fds = bus.call_with_unix_fd_list_sync(
            *LOGIN1, "Inhibit",
            GLib.Variant("(ssss)", ("sleep", "lock-sleep-guard",
                                    "Let the lock screen draw before sleeping", "delay")),
            GLib.VariantType("(h)"), Gio.DBusCallFlags.NONE, -1, None, None)
        inhibit_fd = fds.get(res.unpack()[0])   # a dup we own
    except GLib.Error as e:
        log(f"could not take sleep inhibitor: {e.message}")


def release_inhibitor():
    global inhibit_fd
    if inhibit_fd is not None:
        os.close(inhibit_fd)
        inhibit_fd = None


def locked():
    return sh("hyprctl", "locked") == "true"


def lock_pid():
    return sh("systemctl", "--user", "show", "-p", "MainPID", "--value", "hyprlock.service")


def mature_pid():
    """PID of the current lock if it is mature, else None."""
    if not locked():
        return None
    pid = lock_pid()
    try:
        bpid, lit, bms = open(BIRTH_FILE).read().split()
    except (OSError, ValueError):
        return None
    if bpid != pid or pid in ("", "0") or lit != "lit":
        return None
    return pid if time.time() * 1000 - int(bms) >= MATURE_MS else None


def before_sleep():
    t0 = time.monotonic()
    try:
        os.unlink(VERDICT_FILE)
    except FileNotFoundError:
        pass
    # Lid close has normally locked already. Anything else (menu, idle,
    # `systemctl suspend`) is covered here; start is a no-op if it is up.
    if lock_pid() in ("", "0"):
        sh("systemctl", "--user", "start", "--no-block", "hyprlock.service")

    pid = None
    while time.monotonic() - t0 < MAX_WAIT_S:
        pid = mature_pid()
        if pid:
            break
        time.sleep(0.05)

    held = int((time.monotonic() - t0) * 1000)
    if pid:
        with open(VERDICT_FILE + ".tmp", "w") as f:
            f.write(pid + "\n")
        os.replace(VERDICT_FILE + ".tmp", VERDICT_FILE)
        log(f"lock {pid} drawn — sleeping (held {held}ms)")
    else:
        log(f"lock not mature after {held}ms — sleeping anyway; wake will swap it")
    release_inhibitor()


def on_signal(_conn, _sender, _path, _iface, _signal, params):
    (going_down,) = params.unpack()
    if going_down:
        before_sleep()
    else:
        take_inhibitor()   # back up; hold again for the next sleep


def main():
    bus.signal_subscribe(LOGIN1[0], LOGIN1[2], "PrepareForSleep", LOGIN1[1],
                         None, Gio.DBusSignalFlags.NONE, on_signal)
    take_inhibitor()
    log("holding sleep until the lock screen has drawn")
    GLib.MainLoop().run()


if __name__ == "__main__":
    sys.exit(main())
