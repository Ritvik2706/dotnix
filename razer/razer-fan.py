#!/usr/bin/env python3
"""razer-fan.py — the Blade's fans and power mode, without Synapse.

  razer-fan.py status [--json]   mode, fans, temperatures, charger, what is overriding what
  razer-fan.py set <rpm> [min]   fans at least <rpm> (3500-5000), for [min] minutes or until `auto`
  razer-fan.py max [min]         the same at 5000
  razer-fan.py auto              drop the override: back to the curve, or the firmware without it
  razer-fan.py mode              the firmware power mode
  razer-fan.py mode <name>       pin it: silent, balanced, gaming, creator
  razer-fan.py mode auto         follow the charger again
  razer-fan.py curve             the daemon (razer-fan.service)
  razer-fan.py charge            the firmware's battery charge limit
  razer-fan.py charge <n|off>    stop charging at n% (50-80), for a laptop left plugged in

`curve` leaves a cool laptop to the firmware and takes over as it heats up. It
follows the CPU package every 3 s, and the GPU too, since a model or a render can
work the GPU hard with the CPU cool. It also keeps the power mode and the matching
power profile: gaming on the charger, balanced on battery, unless one is pinned
(the island's Super+D has them; a pin lasts until reboot). Silent is for quiet
places: the CPU is capped hard, since the firmware's silent mode alone lets a heavy
load sit at 95 C, and the fans stay with the firmware unless the heat stays serious.
It owns this channel, so everything else goes
through it: `set`, `max` and `mode` leave a note it reads, and act directly only
when it isn't running. An override is a floor, never a ceiling: the curve can
always go faster.

The dGPU must be able to sleep, and two things here wake it for ~20 s. nvidia-smi:
so it is asked only when already awake, and more slowly than that window unless it
is hot (busy), or the asking itself would keep it up. And the firmware's mode
command (0x0d02, which also takes and releases the fans), measured to wake it
within 0.3 s, where reads and the speed command (0x0d01) don't: so that command is
sent only when something has to change, and everything else is checked by reading.

If anything goes wrong the fans go back to the firmware, which has its own
thermal protection: on exit, and when the CPU sensor is lost. A failed command
is retried on the next tick rather than ending the daemon.

Protocol from razer-laptop-control-no-dkms and razer-ctl: 91-byte HID feature
reports on interface 0. Only the fan, power mode and charge-limit commands are
used: this never changes the CPU/GPU boost, and it leaves the keyboard to
razer-fx/OpenRazer (whose daemon would take it over, which is why that project's
daemon isn't used).
"""
import collections, fcntl, glob, json, os, re, signal, subprocess, sys, time

VID_PID = "00001532:0000028A"          # Blade 15 (2022), RZ09-0421
RPM_MIN, RPM_MAX = 3500, 5000          # that model's range in the project's device table
ZONES = (1, 2)
MODES = {0: "balanced", 1: "gaming", 2: "creator", 3: "silent", 4: "custom"}
CHARGER_MODE, BATTERY_MODE, SILENT_MODE = 1, 0, 3
PROFILES = {0: "balanced", 1: "performance", 2: "balanced", 3: "power-saver"}   # powerprofilesctl's

# One rpm per level, and the temperature each sensor reaches it at. Level 0 is the
# firmware's own control. The GPU's top step is under its own 80 C target, where it
# starts giving up clocks: the fans should be flat out before that, not after. The
# CPU's top step is under thermald's cap (system/thermald), for the same reason.
RPMS = (0, 3500, 4000, 4500, 5000)
CPU_AT = (0, 68, 76, 83, 89)
GPU_AT = (0, 60, 67, 72, 77)
# In silent the curve only steps in near the limits, and only for heat that lasts:
# the CPU's speed is capped by then, so this is a safety net, not a curve.
SILENT_CPU_AT = (0, 96, 97, 98, 99)
SILENT_GPU_AT = (0, 84, 86, 88, 90)
SILENT_SPEED = 35                      # percent of the CPU's top speed
DOWN_MARGIN = 6                        # a step down waits for this many degrees below its threshold
DOWN_HOLD = 20                         # and for this many seconds at the level
RELEASE_HOLD = 120                     # longer for the last step: giving the fans back wakes the dGPU
TICK = 3
REASSERT = 30                          # sent again: a resume can reset the firmware
SENSOR_GRACE = 3                       # ticks without the CPU sensor before giving up the fans
WAKE_GAP = 5                           # seconds lost to suspend that count as a wake

GPU_NODE = "/sys/bus/pci/devices/0000:01:00.0/power/runtime_status"
GPU_BUSY = 60                          # above this it is working, and won't sleep anyway
GPU_EVERY_BUSY = 9
GPU_EVERY_IDLE = 45                    # must stay over the ~20 s a query keeps it awake
CHARGER_NODE = "/sys/class/power_supply/AC0/online"
SPEED_NODE = "/sys/devices/system/cpu/intel_pstate/max_perf_pct"   # writable through system/power-setup.sh

RUNTIME = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
NOTE = RUNTIME + "/razer-fan.json"     # the overrides, for the daemon
LOCK = RUNTIME + "/razer-fan.lock"     # held while the daemon runs

SIZE = 91                              # report id + 90-byte Razer report
OK, NOT_SUPPORTED = 0x02, 0x05


class BladeError(Exception):
    """The control interface failed; it may work next time."""


class Refused(BladeError):
    """The firmware answered, and the answer was no."""


def say(*a):
    print(*a, flush=True)


def ioc(nr):
    return (3 << 30) | (SIZE << 16) | (ord("H") << 8) | nr   # _IOC(READ|WRITE, 'H', nr, SIZE)


HIDIOCSFEATURE, HIDIOCGFEATURE = ioc(0x06), ioc(0x07)


def packet(cmd_class, cmd_id, args):
    r = bytearray(90)
    r[1] = 0x1F                        # transaction id
    r[5] = len(args)
    r[6], r[7] = cmd_class, cmd_id
    r[8:8 + len(args)] = bytes(args)
    crc = 0
    for b in r[2:88]:
        crc ^= b
    r[88] = crc
    return bytearray(1) + r            # report id 0 in front


def control_node():
    for path in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        with open(path + "/device/uevent") as f:
            if VID_PID not in f.read().upper():
                continue
        if re.search(r":\d+\.0/", os.path.realpath(path + "/device") + "/"):
            return "/dev/" + os.path.basename(path)
    raise BladeError("the Blade's control interface isn't here")


class Blade:
    def __init__(self):
        self.fd = None

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def send(self, cmd_id, args, cmd_class=0x0D):
        """One command and its checked reply. The keyboard's lighting shares this
        interface, so a reply meant for something else is simply tried again. The
        node is opened here, and dropped on error: a resume can replace it."""
        try:
            if self.fd is None:
                self.fd = os.open(control_node(), os.O_RDWR)
            for _ in range(5):
                req = packet(cmd_class, cmd_id, args)
                fcntl.ioctl(self.fd, HIDIOCSFEATURE, bytes(req))
                time.sleep(0.003)
                buf = bytearray(SIZE)
                fcntl.ioctl(self.fd, HIDIOCGFEATURE, buf)
                r = buf[1:]
                if (r[6], r[7], r[1]) == (cmd_class, cmd_id, 0x1F):
                    if r[0] == OK:
                        return r[8:]
                    if r[0] == NOT_SUPPORTED:
                        raise Refused(f"the firmware doesn't support 0x{cmd_class:02x}{cmd_id:02x}")
                time.sleep(0.01)
        except OSError as e:
            self.close()
            raise BladeError(f"control interface: {e}") from e
        raise BladeError(f"no good reply to 0x{cmd_class:02x}{cmd_id:02x}")

    def mode(self, zone):
        a = self.send(0x82, [0, zone, 0, 0])
        return a[2], a[3]              # power mode, 1 if the fan is held by hand

    def power(self):
        """The power mode, or None while the zones disagree."""
        modes = {self.mode(z)[0] for z in ZONES}
        return modes.pop() if len(modes) == 1 else None

    def set_mode(self, power):
        for z in ZONES:
            self.send(0x02, [0, z, power, self.mode(z)[1]])
        if self.power() != power:
            raise Refused(f"the firmware didn't take {MODES.get(power, power)}")

    def rpm(self, zone):
        return self.send(0x81, [0, zone, 0])[2] * 100

    def hold(self, rpm):
        rpm = max(RPM_MIN, min(RPM_MAX, rpm))
        for z in ZONES:
            power, held = self.mode(z)
            if not held:
                self.send(0x02, [0, z, power, 1])
            self.send(0x01, [0, z, rpm // 100])
        return rpm

    def auto(self):
        for z in ZONES:
            power, held = self.mode(z)
            if held:
                self.send(0x02, [0, z, power, 0])

    def charge(self):
        v = self.send(0x92, [0], 0x07)[0]
        return bool(v & 0x80), v & 0x7F

    def set_charge(self, on, limit):
        self.send(0x12, [(0x80 if on else 0) | limit], 0x07)
        return self.charge()


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def cpu_temp():
    for hwmon in glob.glob("/sys/class/hwmon/hwmon*"):
        if read(hwmon + "/name") == "coretemp":
            value = read(hwmon + "/temp1_input")   # temp1 is "Package id 0"
            return int(value) / 1000 if value else None
    return None


def gpu_awake():
    return read(GPU_NODE) == "active"


def gpu_temp():
    """Only ever called with the GPU awake: see the top of this file."""
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=3).stdout
        return int(out.strip())
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def on_charger():
    """True, False, or None if it can't be told."""
    value = read(CHARGER_NODE)
    return value == "1" if value in ("0", "1") else None


def set_profile(mode):
    try:
        subprocess.run(["powerprofilesctl", "set", PROFILES[mode]], capture_output=True, timeout=5, check=True)
    except (KeyError, OSError, subprocess.SubprocessError) as e:
        say(f"power profile: {e}")


def set_speed(percent):
    try:
        with open(SPEED_NODE, "w") as f:
            f.write(str(percent))
    except OSError as e:
        say(f"CPU speed cap: {e} (system/power-setup.sh gives access)")


def load_note():
    """The overrides still in force; a broken note counts as none."""
    try:
        with open(NOTE) as f:
            note = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(note, dict):
        return {}
    if note.get("until") and time.time() >= note["until"]:
        note.pop("floor", None)
        note.pop("until", None)
    return note


def save_note(note):
    with open(NOTE + ".new", "w") as f:
        json.dump(note, f)
    os.replace(NOTE + ".new", NOTE)


def level_for(readings, current, since):
    """Up at once; down one step at a time, after a margin and a wait, so the
    fans don't hunt as the package spikes (it swings 10 degrees in seconds).
    `readings` is (thresholds, temperature) per sensor: the hottest one leads,
    and all of them have to have cooled for a step down."""
    want = max(max(i for i, t in enumerate(at) if temp >= t) for at, temp in readings)
    if want > current:
        return want
    cooled = all(temp < at[current] - DOWN_MARGIN for at, temp in readings)
    if want < current and cooled and since >= (RELEASE_HOLD if current == 1 else DOWN_HOLD):
        return current - 1
    return current


class Governor:
    """What the daemon does each tick, apart from the clock and the signals."""

    def __init__(self, blade):
        self.blade = blade
        self.level, self.changed = 0, 0.0
        self.recent = collections.deque(maxlen=3)
        self.lost = 0                  # ticks without the CPU sensor
        self.silent = False
        self.gpu, self.gpu_at = None, float("-inf")
        self.refused = set()           # modes the firmware said no to; asking again won't help
        self.forget()

    def forget(self):
        """Assume nothing about the firmware: everything is sent again."""
        self.rpm, self.sent = None, 0.0
        self.wanted, self.checked = None, float("-inf")

    def read_gpu(self, now):
        if not gpu_awake():
            self.gpu = None
            return
        busy = self.gpu is not None and self.gpu >= GPU_BUSY
        if now - self.gpu_at >= (GPU_EVERY_BUSY if busy else GPU_EVERY_IDLE):
            self.gpu, self.gpu_at = gpu_temp(), now

    def next_level(self, now):
        cpu = cpu_temp()
        if cpu is None:
            self.lost += 1
            if self.lost == SENSOR_GRACE:
                say("CPU sensor lost: fans to the firmware")
            return 0 if self.lost >= SENSOR_GRACE else self.level
        if self.lost >= SENSOR_GRACE:
            say("CPU sensor back")
        self.lost = 0
        self.recent.append(cpu)
        cpu = min(self.recent) if self.silent else max(self.recent)
        readings = [(SILENT_CPU_AT if self.silent else CPU_AT, cpu)]
        self.read_gpu(now)
        if self.gpu is not None:
            readings.append((SILENT_GPU_AT if self.silent else GPU_AT, self.gpu))
        return level_for(readings, self.level, now - self.changed)

    def fans(self, now, floor):
        level = self.next_level(now)
        if level != self.level:
            self.level, self.changed = level, now
        rpm = max(RPMS[self.level], floor)
        if rpm != self.rpm or (rpm and now - self.sent >= REASSERT):
            self.blade.hold(rpm) if rpm else self.blade.auto()
            if rpm != self.rpm:
                gpu = "" if self.gpu is None else f", GPU {self.gpu} C"
                cpu = f"{self.recent[-1]:.0f} C" if self.recent else "no sensor"
                say(f"{cpu}{gpu}: {rpm or 'firmware auto'}")
            self.rpm, self.sent = rpm, now

    def power(self, now, pinned):
        charger = on_charger()
        wanted = pinned if pinned is not None else (
            None if charger is None else CHARGER_MODE if charger else BATTERY_MODE)
        if wanted is None or wanted in self.refused:
            return
        if wanted == self.wanted and now - self.checked < REASSERT:
            return
        if self.blade.power() != wanted:
            try:
                self.blade.set_mode(wanted)
                say(f"power mode: {MODES[wanted]}")
            except Refused as e:
                self.refused.add(wanted)
                say(f"power mode: {e}")
                return
        # Only on a change, so the island's own profile switch still works in between.
        if wanted != self.wanted:
            set_profile(wanted)
            set_speed(SILENT_SPEED if wanted == SILENT_MODE else 100)
        if wanted == SILENT_MODE and not self.silent:
            self.level = 0             # quiet now, not a step at a time
            self.recent.clear()        # and a spike from before doesn't count
        self.silent = wanted == SILENT_MODE
        self.wanted, self.checked = wanted, now

    def tick(self, now):
        note = load_note()
        self.power(now, {v: k for k, v in MODES.items()}.get(note.get("mode")))
        self.fans(now, note.get("floor", 0))


def daemon_running():
    try:
        fd = os.open(LOCK, os.O_RDWR | os.O_CREAT, 0o600)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def curve():
    lock = os.open(LOCK, os.O_RDWR | os.O_CREAT, 0o600)
    for attempt in range(5):           # daemon_running() takes it for a moment too
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if attempt == 4:
                sys.exit("razer-fan: already running")
            time.sleep(0.2)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    blade = Blade()
    governor = Governor(blade)
    failing = False
    clocks = time.monotonic(), time.clock_gettime(time.CLOCK_BOOTTIME)
    try:
        while True:
            now, boot = time.monotonic(), time.clock_gettime(time.CLOCK_BOOTTIME)
            # The monotonic clock stops in suspend and this one doesn't.
            if (boot - clocks[1]) - (now - clocks[0]) > WAKE_GAP:
                say("woke: sending everything again")
                blade.close()
                governor.forget()
            clocks = now, boot
            try:
                governor.tick(now)
                if failing:
                    say("control interface back")
                failing = False
            except BladeError as e:
                if not failing:
                    say(f"{e}: trying again")
                failing = True
                blade.close()
                governor.forget()
            time.sleep(TICK)
    finally:
        try:
            blade.auto()
            blade.set_mode(BATTERY_MODE)
            set_profile(BATTERY_MODE)
            set_speed(100)
        except BladeError as e:
            say(f"leaving: {e}")


def status(as_json):
    blade = Blade()
    power, charger = blade.power(), on_charger()
    limited, limit = blade.charge()
    awake = gpu_awake()
    note = load_note()
    info = {
        "mode": MODES.get(power, power), "mode_pinned": note.get("mode"),
        "fans": [{"zone": z, "rpm": blade.rpm(z), "held": bool(blade.mode(z)[1])} for z in ZONES],
        "floor": note.get("floor", 0), "floor_until": note.get("until"),
        "cpu": cpu_temp(), "gpu": gpu_temp() if awake else None, "gpu_awake": awake,
        "charger": charger, "charge_limit": limit if limited else None,
        "daemon": daemon_running(),
    }
    if as_json:
        return say(json.dumps(info))
    pin = " (pinned)" if info["mode_pinned"] else ""
    say(f"mode     {info['mode']}{pin}")
    for fan in info["fans"]:
        say(f"fan {fan['zone']}    {fan['rpm']} rpm, {'held' if fan['held'] else 'firmware auto'}")
    if info["floor"]:
        left = f", {(info['floor_until'] - time.time()) / 60:.0f} min left" if info["floor_until"] else ""
        say(f"floor    {info['floor']} rpm{left}")
    say(f"cpu      {info['cpu']:.0f} C" if info["cpu"] is not None else "cpu      no sensor")
    say(f"gpu      {info['gpu']} C" if info["gpu"] is not None else f"gpu      {'awake' if awake else 'asleep'}")
    say(f"power    {'unknown' if charger is None else 'charger' if charger else 'battery'}"
        f", {'limit %d%%' % limit if limited else 'no charge limit'}")
    say(f"daemon   {'running' if info['daemon'] else 'NOT running'}")


def set_floor(rpm, minutes):
    if not RPM_MIN <= rpm <= RPM_MAX:
        sys.exit(f"razer-fan: {rpm} is outside {RPM_MIN}-{RPM_MAX}")
    if minutes is not None and minutes <= 0:
        sys.exit("razer-fan: minutes must be above 0")
    note = load_note()
    note["floor"] = rpm
    note.pop("until", None)
    if minutes is not None:
        note["until"] = time.time() + minutes * 60
    save_note(note)
    if not daemon_running():
        Blade().hold(rpm)
        say("the daemon isn't running: held until `auto`, with no time limit and no curve")


def clear_floor():
    note = load_note()
    note.pop("floor", None)
    note.pop("until", None)
    save_note(note)
    if not daemon_running():
        Blade().auto()


def set_mode(name):
    note = load_note()
    if name == "auto":
        note.pop("mode", None)
        save_note(note)
        if not daemon_running() and on_charger() is not None:
            mode = CHARGER_MODE if on_charger() else BATTERY_MODE
            Blade().set_mode(mode)
            set_profile(mode)
            set_speed(100)
        return
    note["mode"] = name
    save_note(note)
    if not daemon_running():
        mode = {v: k for k, v in MODES.items()}[name]
        Blade().set_mode(mode)
        set_profile(mode)
        set_speed(SILENT_SPEED if mode == SILENT_MODE else 100)


def number(text, kind=int):
    try:
        return kind(text)
    except ValueError:
        sys.exit(f"razer-fan: {text!r} isn't a number\n\n{__doc__}")


def main():
    args = sys.argv[1:] or ["status"]
    cmd, rest = args[0], args[1:]
    if cmd == "status" and rest in ([], ["--json"]):
        status(bool(rest))
    elif cmd == "curve" and not rest:
        curve()
    elif cmd == "auto" and not rest:
        clear_floor()
    elif cmd == "max" and len(rest) <= 1:
        set_floor(RPM_MAX, number(rest[0], float) if rest else None)
    elif cmd == "set" and len(rest) in (1, 2):
        set_floor(number(rest[0]), number(rest[1], float) if len(rest) == 2 else None)
    elif cmd == "mode" and not rest:
        power = Blade().power()
        say(MODES.get(power, power))
    elif cmd == "mode" and len(rest) == 1 and rest[0] in ("auto", *(n for n in MODES.values() if n != "custom")):
        set_mode(rest[0])
    elif cmd == "charge" and not rest:
        limited, limit = Blade().charge()
        say(f"limit {limit}%" if limited else "no limit")
    elif cmd == "charge" and rest == ["off"]:
        Blade().set_charge(False, 80)
    elif cmd == "charge" and len(rest) == 1:
        Blade().set_charge(True, max(50, min(80, number(rest[0]))))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    try:
        main()
    except BladeError as e:
        sys.exit(f"razer-fan: {e}")
