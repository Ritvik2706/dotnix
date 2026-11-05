#!/usr/bin/env python3
"""game-guard.py — looks after the laptop while a game is open.

  game-guard.py          watch (started by niri); needs niri's event stream
  game-guard.py check    the same pre-flight checks, printed

While a game window exists it holds off idle (a controller isn't input to
hypridle, so a game on the TV would blank at 10 min and suspend at 20) and warns
about what would actually hurt. Nothing runs between games: it waits on niri's
events, and only reads the GPU, which nvidia-smi would wake, during a game.
CPU temperature isn't warned about: 100 C spikes are normal here (razer-fan.py).
"""
import fcntl, json, os, re, select, shutil, subprocess, sys, time

GAMES = re.compile(r"^(steam_proton|steam_app_.*|gamescope)$")
TICK = 15                    # seconds between checks, during a game only
AGAIN = 300                  # the same warning at most this often
GPU_HOT = 90                 # its slowdown is 95, shutdown 98
RAM_LOW_GIB = 1.5
DISK_LOW_GIB = 15


def out(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def on_ac():
    return read("/sys/class/power_supply/AC0/online") == "1"


def ram_available_gib():
    m = re.search(r"MemAvailable:\s+(\d+)", read("/proc/meminfo"))
    return int(m.group(1)) / 1048576 if m else 99


def gpu_temp():
    t = out("nvidia-smi", "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits")
    return int(t) if t.isdigit() else 0


def preflight():
    """What's wrong now, as (key, title, advice)."""
    bad = []
    if out("systemctl", "--user", "is-active", "razer-fan") != "active":
        bad.append(("fan", "Fan control is off", "systemctl --user restart razer-fan"))
    if not on_ac():
        bad.append(("ac", "On battery", "Plug in the charger: the GPU is held back and heat doesn't help the battery"))
    if not os.path.exists("/dev/ntsync"):
        bad.append(("ntsync", "ntsync isn't loaded", "Wine falls back to slower sync: sudo modprobe ntsync"))
    if out("systemctl", "is-active", "thermald") == "active":
        bad.append(("thermald", "thermald is running", "It cut the CPU to 9 W here: sudo systemctl disable --now thermald"))
    kernel = read("/sys/module/nvidia/version").replace(".", "-")
    if kernel and "nvidia-" + kernel not in out("flatpak", "list", "--columns=application"):
        bad.append(("driver", "NVIDIA driver mismatch", f"Flatpak has no GL for {kernel}: flatpak update, or games lose the GPU"))
    free = shutil.disk_usage(os.path.expanduser("~")).free / 2**30
    if free < DISK_LOW_GIB:
        bad.append(("disk", "Disk nearly full", f"{free:.0f} GiB left"))
    if ram_available_gib() < 3:
        bad.append(("ram", "Memory is tight", f"{ram_available_gib():.1f} GiB free: close something first"))
    return bad


def during():
    bad = []
    t = gpu_temp()
    if t >= GPU_HOT:
        bad.append(("hot", f"GPU at {t} C", "Check the vents and that the lid is open"))
    if ram_available_gib() < RAM_LOW_GIB:
        bad.append(("ram", "Memory nearly out", "Close the browser or the game may be killed"))
    if out("systemctl", "--user", "is-active", "razer-fan") != "active":
        bad.append(("fan", "Fan control stopped", "systemctl --user restart razer-fan"))
    if not on_ac():
        bad.append(("ac", "On battery", "Plug in the charger"))
    return bad


class Guard:
    def __init__(self):
        self.inhibit = None
        self.said = {}

    def warn(self, items):
        now = time.monotonic()
        for key, title, advice in items:
            if now - self.said.get(key, -AGAIN) >= AGAIN:
                self.said[key] = now
                subprocess.run(["notify-send", "-a", "Game guard", "-u", "critical", title, advice])

    def playing(self):
        return self.inhibit is not None

    def start(self):
        self.inhibit = subprocess.Popen(["systemd-inhibit", "--what=idle", "--who=game-guard",
                                         "--why=A game is open", "--mode=block", "sleep", "infinity"])
        self.said = {}
        self.warn(preflight())

    def stop(self):
        self.inhibit.terminate()
        self.inhibit.wait()
        self.inhibit = None


def game_open():
    try:
        return any(GAMES.match(w.get("app_id") or "") for w in json.loads(out("niri", "msg", "-j", "windows")))
    except ValueError:
        return False


def watch():
    lock = open(os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "game-guard.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return
    guard = Guard()

    def update():
        now = game_open()
        if now and not guard.playing():
            guard.start()
        elif guard.playing() and not now:
            guard.stop()

    while True:
        stream = subprocess.Popen(["niri", "msg", "-j", "event-stream"], stdout=subprocess.PIPE)
        fd = stream.stdout.fileno()
        update()
        last = time.monotonic()
        pending = b""
        while True:
            # Read the pipe itself: a buffered reader hides lines from select.
            ready, _, _ = select.select([fd], [], [], TICK if guard.playing() else None)
            if ready:
                data = os.read(fd, 65536)
                if not data:
                    break                     # niri went away: listen again
                pending += data
                *lines, pending = pending.split(b"\n")
                if any(l.startswith((b'{"WindowOpenedOrChanged"', b'{"WindowClosed"', b'{"WindowsChanged"')) for l in lines):
                    update()
            if guard.playing() and time.monotonic() - last >= TICK:
                last = time.monotonic()
                guard.warn(during())
        time.sleep(2)


def main():
    if sys.argv[1:] == ["check"]:
        bad = preflight()
        for _, title, advice in bad:
            print(f"! {title}: {advice}")
        print("ready" if not bad else f"{len(bad)} to look at")
        sys.exit(1 if bad else 0)
    watch()


if __name__ == "__main__":
    main()
