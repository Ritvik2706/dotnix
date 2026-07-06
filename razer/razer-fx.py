#!/usr/bin/env python3
"""Layered software lighting effects for Razer devices via OpenRazer.

Hardware runs only one effect at a time; this renders frames on the CPU and
streams them to the per-key matrix, compositing a stack of layers (bottom ->
top). Each layer returns an (rows, cols, 3) RGB grid plus an (rows, cols)
alpha mask in [0, 1]; upper layers blend over lower ones by their alpha, so
gaps (e.g. between starlight twinkles) let the layer below show through.

All per-frame math is vectorised with numpy to keep CPU/battery cost minimal.

Usage:
    ./razer-fx.py wave                  # rainbow wave only
    ./razer-fx.py wave starlight        # wave with starlight twinkles on top
    ./razer-fx.py static:8000ff breath  # purple base, breathing overlay
    ./razer-fx.py --fps 20 wave starlight

Auto-pauses (blanks keys, ~0 CPU) while the lid is closed; resumes on open.
Stop with Ctrl-C (restores the keyboard to off).
"""
import os
import sys
import time
import signal
import argparse
import numpy as np

from openrazer.client import DeviceManager

LID_STATE = "/proc/acpi/button/lid/LID0/state"
PIDFILE = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "razer-fx.pid")

# Toggled by signals so an idle daemon (hypridle) can pause us when the screen
# blanks: SIGUSR1 = pause (blank keys, ~0 CPU), SIGUSR2 = resume.
_paused = {"on": False}


class _Stop(Exception):
    """Raised on SIGTERM so the main loop can blank the keyboard and exit."""


def _on_term(*_):
    raise _Stop()


def _install_signal_pause():
    signal.signal(signal.SIGUSR1, lambda *_: _paused.__setitem__("on", True))
    signal.signal(signal.SIGUSR2, lambda *_: _paused.__setitem__("on", False))
    signal.signal(signal.SIGTERM, _on_term)


def lid_is_open():
    try:
        with open(LID_STATE) as f:
            return "open" in f.read()
    except OSError:
        return True   # no lid sensor -> never pause


def hsv_to_rgb(h, s, v):
    """Vectorised HSV->RGB. h,s,v are arrays in [0,1]; returns float [...,3] 0-255."""
    h = (h % 1.0) * 6.0
    i = np.floor(h).astype(int)
    f = h - i
    p = v * (1 - s)
    q = v * (1 - s * f)
    t = v * (1 - s * (1 - f))
    i = i % 6
    r = np.choose(i, [v, q, p, p, t, v])
    g = np.choose(i, [t, v, v, q, p, p])
    b = np.choose(i, [p, p, t, v, v, q])
    return np.stack([r, g, b], axis=-1) * 255.0


# ---- Layers -------------------------------------------------------------
# A layer is a callable: layer(t, R, C) -> (rgb[R,C,3] float, alpha[R,C] float)
# where R, C are precomputed row/col index grids.

def make_wave(speed=0.25, spread=0.07, sat=1.0, val=1.0):
    def layer(t, R, C):
        hue = (R + C) * spread - t * speed
        rgb = hsv_to_rgb(hue, np.full_like(hue, sat), np.full_like(hue, val))
        return rgb, np.ones(R.shape)
    return layer


# Vivid, saturated anchors (each has a near-zero channel so it doesn't wash
# out to pastel on the keyboard LEDs). mint green -> purple -> pink.
AURORA_PALETTE = np.array([
    [0x7A, 0x00, 0xFF],   # violet
    [0xFF, 0x00, 0x99],   # hot pink
    [0xFF, 0x33, 0x66],   # watermelon rose
], dtype=float)


def make_aurora(speed=0.16, spread=0.05, val=0.65, hold=0.25, palette=AURORA_PALETTE):
    """Slow wave through an aurora palette (mint green -> purple -> pink),
    looping. `hold` (0..0.5) keeps each color solid for longer and squeezes
    the blend into a shorter, harder transition band."""

    def sample(phase):
        n = len(palette)
        x = (phase % 1.0) * n
        i = np.floor(x).astype(int)
        f = (x - i)
        # harden transitions: hold pure color at the ends, blend in the middle
        f = np.clip((f - hold) / (1 - 2 * hold), 0.0, 1.0)[..., None]
        a = palette[i % n]
        b = palette[(i + 1) % n]
        return a * (1 - f) + b * f

    def layer(t, R, C):
        phase = (R + C) * spread - t * speed
        return sample(phase) * val, np.ones(R.shape)
    return layer


def make_bands(palette=AURORA_PALETTE):
    """Static diagnostic: show each palette color as a side-by-side vertical
    band, left -> right, so you can see which colors render distinctly."""
    def layer(t, R, C):
        cols = R.shape[1]
        idx = np.clip((C / cols * len(palette)).astype(int), 0, len(palette) - 1)
        return palette[idx], np.ones(R.shape)
    return layer


def make_static(hexcol):
    col = np.array([int(hexcol[i:i+2], 16) for i in (0, 2, 4)], dtype=float)
    def layer(t, R, C):
        rgb = np.broadcast_to(col, R.shape + (3,)).astype(float)
        return rgb, np.ones(R.shape)
    return layer


def make_breath(period=4.0, sat=1.0):
    def layer(t, R, C):
        v = (np.sin(t * 2 * np.pi / period) + 1) / 2
        hue = np.full(R.shape, t * 0.03)
        rgb = hsv_to_rgb(hue, np.full(R.shape, sat), np.full(R.shape, v))
        return rgb, np.ones(R.shape)
    return layer


def make_starlight(rate=5.0, life=2.8, color=None):
    """Random keys flash and fade; transparent (alpha 0) elsewhere."""
    born = np.full((6, 16), -1e9)          # birth time per key (resized on first call)
    rgb = np.zeros((6, 16, 3))
    state = {"last": None, "init": False}

    def layer(t, R, C):
        nonlocal born, rgb
        if not state["init"]:
            born = np.full(R.shape, -1e9)
            rgb = np.zeros(R.shape + (3,))
            state["last"] = t
            state["init"] = True
        dt = t - state["last"]; state["last"] = t
        n = int(rate * dt) + (1 if np.random.random() < (rate * dt) % 1 else 0)
        rows, cols = R.shape
        for _ in range(n):
            r, c = np.random.randint(rows), np.random.randint(cols)
            born[r, c] = t
            if color:
                rgb[r, c] = [int(color[i:i+2], 16) for i in (0, 2, 4)]
            else:
                hue = np.random.random()
                rgb[r, c] = hsv_to_rgb(np.array(hue), np.array(0.2), np.array(1.0))
        # normalized 0..1 age over the twinkle's lifetime
        age = np.clip((t - born) / life, 0.0, 1.0)
        # smooth ease-in then ease-out: a gentle bell instead of an instant
        # pop. sin(pi*age) rises and falls softly so twinkles breathe rather
        # than flicker, which reads as far less distracting.
        alpha = np.sin(np.pi * age) ** 1.5
        alpha[age >= 1.0] = 0.0
        return rgb * alpha[..., None], alpha
    return layer


def _reactive_keycode_map():
    """evdev keycode -> (row, col) for this keyboard, reused from OpenRazer."""
    from openrazer_daemon.keyboard import EVENT_MAPPING, KEY_MAPPING
    return {code: KEY_MAPPING[name]
            for code, name in EVENT_MAPPING.items() if name in KEY_MAPPING}


def make_reactive(color="44FF00", life=3.0):
    """Keys light up when pressed and fade out over `life` seconds. Reads
    physical key events via evdev and maps them with OpenRazer's key map.
    Default colour is Razer green. Transparent where no recent press."""
    import threading
    import glob
    try:
        import evdev
    except ImportError:
        sys.exit("reactive needs python-evdev: sudo pacman -S python-evdev")

    rgb_on = np.array([int(color[i:i+2], 16) for i in (0, 2, 4)], dtype=float)
    code_map = _reactive_keycode_map()
    born = {"arr": None}                 # set lazily once we know matrix size

    # keyd remaps the bottom-row modifiers (see /etc/keyd/default.conf) and
    # re-emits the *target* code, so the event we read no longer matches the
    # physical key pressed. We map each emitted code straight to the physical
    # key's matrix cell. We can't use OpenRazer's code_map for these: its
    # bottom-row labels don't account for the Fn key between Ctrl and Win, so
    # everything from Win rightward is shifted one column. These cells are the
    # *physical* LED positions (Ctrl,Fn,Super,Alt = cols 1,2,3,4 on row 5).
    # Cells below are verified physical LED positions (probed one-by-one):
    #   physical Ctrl  (keyd emits Alt)   -> Ctrl LED   (5,1)
    #   physical Win   (keyd emits Ctrl)  -> Super LED  (5,3)
    #   physical Alt   (keyd emits Meta)  -> Alt LED    (5,5)
    e = evdev.ecodes
    CELL_OVERRIDE = {
        e.KEY_LEFTALT:  (5, 1),   # physical Ctrl
        e.KEY_LEFTCTRL: (5, 3),   # physical Win/Super
        e.KEY_LEFTMETA: (5, 5),   # physical Alt
    }

    # Find the device that actually emits keystrokes. A remapper like keyd
    # grabs the physical keyboard and re-emits via a virtual device, so prefer
    # that; otherwise fall back to any readable keyboard (incl. the Razer node).
    kbds, virt = [], []
    for path in evdev.list_devices():
        try:
            d = evdev.InputDevice(path)
        except OSError:
            continue                     # no permission (need 'input' group)
        if evdev.ecodes.KEY_A in d.capabilities().get(evdev.ecodes.EV_KEY, []):
            (virt if "keyd" in d.name.lower() else kbds).append(path)
    paths = virt or kbds
    if not paths:
        sys.exit("no readable keyboard found — is your user in the 'input' group?")

    def reader(path):
        try:
            dev = evdev.InputDevice(path)
        except OSError:
            return                       # missing perms or unplugged
        for ev in dev.read_loop():       # blocks; runs in a daemon thread
            if ev.type == evdev.ecodes.EV_KEY and ev.value == 1:  # key down
                rc = CELL_OVERRIDE.get(ev.code) or code_map.get(ev.code)
                if rc and born["arr"] is not None:
                    r, c = rc
                    if r < born["arr"].shape[0] and c < born["arr"].shape[1]:
                        born["arr"][r, c] = time.time()

    for p in paths:
        threading.Thread(target=reader, args=(p,), daemon=True).start()

    def layer(t, R, C):
        if born["arr"] is None:
            born["arr"] = np.full(R.shape, -1e9)
        alpha = np.clip(1.0 - (time.time() - born["arr"]) / life, 0.0, 1.0)
        return rgb_on * alpha[..., None], alpha
    return layer


LAYER_FACTORIES = {
    "wave": lambda a: make_wave(),
    "aurora": lambda a: make_aurora(),
    "bands": lambda a: make_bands(),
    "breath": lambda a: make_breath(),
    "reactive": lambda a: make_reactive(color=a or "44FF00"),
    "starlight": lambda a: make_starlight(color=a or None),
    "static": lambda a: make_static(a or "ffffff"),
}


def build_layer(spec):
    name, _, arg = spec.partition(":")
    if name not in LAYER_FACTORIES:
        sys.exit(f"unknown layer '{name}'. choices: {', '.join(LAYER_FACTORIES)}")
    return LAYER_FACTORIES[name](arg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("layers", nargs="+", help="layers bottom->top, e.g. wave starlight")
    ap.add_argument("--fps", type=float, default=15.0)
    args = ap.parse_args()

    dm = DeviceManager(); dm.sync_effects = False
    dev = next((d for d in dm.devices if d.has("lighting_led_matrix")), None)
    if dev is None:
        sys.exit("no device with a controllable matrix found")
    rows, cols = dev.fx.advanced.rows, dev.fx.advanced.cols
    R, C = np.meshgrid(np.arange(rows), np.arange(cols), indexing="ij")
    R, C = R.astype(float), C.astype(float)
    layers = [build_layer(s) for s in args.layers]
    mtx = dev.fx.advanced.matrix
    _install_signal_pause()
    with open(PIDFILE, "w") as f:           # so hypridle can signal us by PID
        f.write(str(os.getpid()))
    print(f"{dev.name}: {rows}x{cols}, layers={args.layers}, {args.fps:g} fps. "
          f"pid {os.getpid()} -> {PIDFILE}. Ctrl-C to stop.")

    frame = 1.0 / args.fps
    t0 = time.time()
    blanked = False
    try:
        while True:
            # Pause (blank, ~0 CPU) while the lid is shut or an idle daemon
            # has signalled SIGUSR1 (e.g. screen blanked). Resume on open/SIGUSR2.
            if not lid_is_open() or _paused["on"]:
                if not blanked:
                    mtx.reset(); dev.fx.advanced.draw(); blanked = True
                # Poll often so effects snap back quickly on lid-open/resume;
                # this only re-reads a tiny /proc file, so CPU cost is trivial.
                time.sleep(0.1)
                continue
            blanked = False
            t = time.time() - t0
            out = np.zeros((rows, cols, 3))
            for layer in layers:
                rgb, alpha = layer(t, R, C)
                a = alpha[..., None]
                out = out * (1 - a) + rgb * a
            out = np.clip(out, 0, 255).astype(int)
            for r in range(rows):
                for c in range(cols):
                    mtx.set(r, c, tuple(out[r, c]))
            dev.fx.advanced.draw()
            time.sleep(frame)
    except (KeyboardInterrupt, _Stop):
        mtx.reset(); dev.fx.advanced.draw(); dev.fx.static(0, 0, 0)
        print("\nstopped.")
    finally:
        try:
            os.remove(PIDFILE)
        except OSError:
            pass


if __name__ == "__main__":
    main()
