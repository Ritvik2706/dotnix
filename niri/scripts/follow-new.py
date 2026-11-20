#!/usr/bin/env python3
"""
follow-new.py — when an app's window opens, go to it.

apps.kdl sends apps to their home workspace (Steam to media, Zen to browser,
...), and niri opens them there without leaving the workspace you're on. This
watches niri's event stream and, once a new tiled window has really opened,
focuses it, which also switches to its workspace.

Left alone:
  - floating windows: dialogs, pickers, Steam's toasts and friends list, and
    fixed-size splash/updater windows, which niri floats by itself.
  - windows that close again within SETTLE seconds (other short-lived
    splashes), so you only jump once the real window is up.
  - anything in the first GRACE seconds after login, so the apps restored by
    startup.sh don't pull you around.
  - NO_FOLLOW app ids: side windows meant to open beside you, unfocused
    (the Claude side pane, claude/pane-toggle.sh).

Started by niri (conf/startup.kdl).
"""
import json
import subprocess
import threading
import time

SETTLE = 0.6  # seconds a window must stay open before we jump to it
GRACE = 20.0  # seconds after login with no jumping
NO_FOLLOW = {"dev.dotnix.claude-pane"}

START = time.monotonic()
lock = threading.Lock()
windows = {}  # id -> latest window info


def focus_if_still_there(wid):
    with lock:
        w = windows.get(wid)
    if not w or w.get("is_floating") or w.get("is_focused"):
        return
    subprocess.run(
        ["niri", "msg", "action", "focus-window", "--id", str(wid)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def run():
    proc = subprocess.Popen(
        ["niri", "msg", "-j", "event-stream"], stdout=subprocess.PIPE, text=True
    )
    for line in proc.stdout:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if "WindowsChanged" in ev:
            # Sent first on connect: the windows already open, not new ones.
            with lock:
                windows.clear()
                for w in ev["WindowsChanged"]["windows"]:
                    windows[w["id"]] = w
        elif "WindowOpenedOrChanged" in ev:
            w = ev["WindowOpenedOrChanged"]["window"]
            wid = w["id"]
            with lock:
                new = wid not in windows
                windows[wid] = w
            if new and (w.get("is_floating") or w.get("app_id") in NO_FOLLOW
                        or time.monotonic() - START <= GRACE):
                continue
            if new:
                threading.Timer(SETTLE, focus_if_still_there, (wid,)).start()
        elif "WindowClosed" in ev:
            with lock:
                windows.pop(ev["WindowClosed"]["id"], None)
    proc.wait()


while True:
    run()
    # niri restarting or the stream dropping: reconnect.
    time.sleep(2)
