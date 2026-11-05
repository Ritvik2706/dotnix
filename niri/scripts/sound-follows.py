#!/usr/bin/env python3
"""sound-follows.py — the sound goes where you are.

Focus on the laptop: its speakers. Focus on the TV: the TV. A fullscreen window
on the TV (a game, a film) keeps the sound there while you work on the laptop.

It follows focus rather than the HDMI port because a TV that's switched off or
unpowered, with the cable still in, keeps reporting itself as connected: waiting
for it to go left the sound on a dead screen.

It only acts when the place changes, so choosing an output by hand sticks until
then, and it leaves anything else alone (Bluetooth headphones). Waits on niri's
and PipeWire's events: no polling.
"""
import fcntl, json, os, select, subprocess, time

TV_OUTPUT = "HDMI-A-1"
CARD = "alsa_card.pci-0000_01_00.1"
TV = "alsa_output.pci-0000_01_00.1.hdmi-stereo"
LAPTOP = "alsa_output.pci-0000_00_1f.3.analog-stereo"
SETTLE = 0.8                 # a burst of events, or the pointer crossing: judge where it lands
NIRI_EVENTS = (b'{"WorkspaceActivated"', b'{"WindowFocusChanged"', b'{"WindowOpenedOrChanged"',
               b'{"WindowClosed"', b'{"WindowLayoutsChanged"')


def run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def niri(what):
    try:
        return json.loads(run("niri", "msg", "-j", what))
    except ValueError:
        return None


def tv_port_up():
    try:
        cards = json.loads(run("pactl", "-f", "json", "list", "cards"))
    except ValueError:
        return False
    for card in cards:
        if card["name"] == CARD:
            return any(k.startswith("hdmi-output") and p.get("availability") == "available"
                       for k, p in card["ports"].items())
    return False


def fullscreen_on_tv(outputs, spaces):
    tv = outputs[TV_OUTPUT].get("logical") or {}
    shown = [s["id"] for s in spaces if s["output"] == TV_OUTPUT and s["is_active"]]
    for w in niri("windows") or []:
        size = (w.get("layout") or {}).get("window_size") or [0, 0]
        if w.get("workspace_id") in shown and size[0] >= tv.get("width", 1 << 30) and size[1] >= tv.get("height", 1 << 30):
            return True
    return False


def where():
    """The sink the sound belongs on now, or None if niri can't say."""
    outputs, spaces = niri("outputs"), niri("workspaces")
    if outputs is None or spaces is None:
        return None
    if TV_OUTPUT not in outputs or not tv_port_up():
        return LAPTOP
    focused = next((s["output"] for s in spaces if s["is_focused"]), None)
    return TV if focused == TV_OUTPUT or fullscreen_on_tv(outputs, spaces) else LAPTOP


def send_to(sink):
    if sink == TV and TV not in run("pactl", "list", "short", "sinks"):
        run("pactl", "set-card-profile", CARD, "output:hdmi-stereo")
        time.sleep(0.6)
    run("pactl", "set-default-sink", sink)
    for line in run("pactl", "list", "short", "sink-inputs").splitlines():
        run("pactl", "move-sink-input", line.split()[0], sink)


def main():
    lock = open(os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "sound-follows.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return
    place = None

    def apply():
        nonlocal place
        want = where()
        if want is None or want == place:
            return
        place = want
        if run("pactl", "get-default-sink") in (TV, LAPTOP):
            send_to(want)

    while True:
        procs = [subprocess.Popen(c, stdout=subprocess.PIPE) for c in
                 (["niri", "msg", "-j", "event-stream"], ["pactl", "subscribe"])]
        fds = [p.stdout.fileno() for p in procs]
        apply()
        due, alive = None, True
        while alive:
            wait = None if due is None else max(0, due - time.monotonic())
            ready, _, _ = select.select(fds, [], [], wait)
            for fd in ready:
                data = os.read(fd, 65536)
                if not data:
                    alive = False
                elif b"on card" in data or any(e in data for e in NIRI_EVENTS):
                    due = time.monotonic() + SETTLE
            if due is not None and time.monotonic() >= due:
                due = None
                apply()
        for p in procs:
            p.kill()
            p.wait()
        time.sleep(2)            # niri or PipeWire restarted: listen again


if __name__ == "__main__":
    main()
