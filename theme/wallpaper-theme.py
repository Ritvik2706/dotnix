#!/usr/bin/env python3
"""wallpaper-theme — the Lumen palette, following the wallpaper.

  wallpaper-theme.py apply [IMAGE]   theme everything for IMAGE (default: what awww shows)
  wallpaper-theme.py show  [IMAGE]   print what IMAGE would get, write nothing
  wallpaper-theme.py save  NAME      keep the current theme as presets/NAME.json, pinned to this wallpaper
  wallpaper-theme.py unpin [IMAGE]   let IMAGE go back to a generated theme

Glass, everywhere: every colour comes from what is behind the surface that
shows it, never from an accent picked for the picture as a whole.
  niri     borders have no colour of their own: the patched niri draws the
           frost of what is really behind each border under it, live
           (border-glass), lifted toward white like a lit glass edge.
  island   presets/dusk.json's roles (the hand-tuned look: lightness, chroma,
           contrast) take their hues from the wallpaper right behind the
           island: its own light from the whole strip and card reach, the two
           sides of its prism from the left and the right of it. Grey behind,
           nearly clear glass; colour behind, that colour.
A pinned wallpaper (pins.json) gets a saved preset exactly instead.

Writes, only when something changed (each consumer reloads on its own):
  lumen/shells/island/theme.plm   the island's palette (lumen hot-reloads it)
  niri/theme.kdl                  glass border light, insert hint, tab indicator
  ~/.cache/lumen/theme.json       the roles, for anything else that wants them
  ~/.cache/lumen/term/{tmux.conf,zsh,nvim.sh}, ghostty/wall-colours
                                  the terminal: accent (the island's lilac), glass
                                  chips/borders, and eldritch's code colours
                                  re-hued toward the wallpaper (term_colours)
"""
import json
import math
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

HERE = Path(__file__).resolve().parent
DOTNIX = HERE.parent
PRESETS = HERE / "presets"
PINS = HERE / "pins.json"
LUMEN_OUT = DOTNIX / "lumen/shells/island/theme.plm"
NIRI_OUT = DOTNIX / "niri/theme.kdl"
STATE = Path.home() / ".cache/lumen/theme.json"
TERM_DIR = Path.home() / ".cache/lumen/term"
GHOSTTY_OUT = DOTNIX / "ghostty/wall-colours"
CACHE = Path.home() / ".cache/lumen/themes"
WALLS = DOTNIX / "wallpapers"


# ── OKLab / OKLCH ────────────────────────────────────────────────
def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def rgb_to_oklab(rgb):
    r, g, b = np.moveaxis(srgb_to_linear(rgb), -1, 0)
    l = np.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    m = np.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    s = np.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return np.stack([
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    ], -1)


def oklab_to_linear(lab):
    L, a, b = lab
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return np.array([
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    ])


def hex_to_lch(h):
    rgb = np.array([int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)])
    L, a, b = rgb_to_oklab(rgb)
    return L, math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360


def lch_to_hex(L, C, h):
    # Out of gamut: keep the lightness and the hue, give up chroma until it fits.
    def at(c):
        return oklab_to_linear((L, c * math.cos(math.radians(h)), c * math.sin(math.radians(h))))

    def fits(c):
        lin = at(c)
        return np.all(lin >= -1e-4) and np.all(lin <= 1 + 1e-4)

    if not fits(C):
        lo, hi = 0.0, C
        for _ in range(24):
            mid = (lo + hi) / 2
            lo, hi = (mid, hi) if fits(mid) else (lo, mid)
        C = lo
    lin = at(C)
    rgb = linear_to_srgb(lin)
    return "#" + "".join(f"{round(float(v) * 255):02x}" for v in rgb)


# ── what is behind each surface ──────────────────────────────────
def lch_of(lab):
    return lab[..., 0], np.hypot(lab[..., 1], lab[..., 2]), np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360


def hue_dist(a, b):
    return abs((a - b + 180) % 360 - 180)


# Logical pixels, as niri lays them out (config.kdl: gaps 8, struts 16/16/-3)
# under the island (island.plm: margin 5, reserve 34; the open card is up to
# ~400 wide).
GEOM = {"gaps": 8, "strut_lr": 16, "strut_top": -3, "island_margin": 5, "island_reserve": 34,
        "pill_w": 260, "pill_h": 29, "card_w": 400, "card_h": 300}


def screen_size():
    try:
        out = json.loads(subprocess.run(["niri", "msg", "-j", "focused-output"], capture_output=True, text=True).stdout)
        lg = out["logical"]
        return lg["width"], lg["height"]
    except Exception:
        return 1600, 900


def screen_lab(path):
    """The wallpaper as it lands on the screen (awww fills and crops), at half
    the logical size, sharp and frosted: the same pixels the island and the
    borders sit on."""
    W, H = screen_size()
    w, h = W // 2, H // 2
    img = Image.open(path)
    img.seek(0)
    img = img.convert("RGB")
    s = max(w / img.width, h / img.height)
    img = img.resize((max(w, round(img.width * s)), max(h, round(img.height * s))), Image.LANCZOS)
    l, t = (img.width - w) // 2, (img.height - h) // 2
    img = img.crop((l, t, l + w, t + h))
    sharp = rgb_to_oklab(np.asarray(img, dtype=np.float64) / 255)
    frost = rgb_to_oklab(np.asarray(img.filter(ImageFilter.GaussianBlur(10)), dtype=np.float64) / 255)
    return sharp, frost, (W, H)


def rim_backdrop(sharp, size):
    """The wallpaper right beside the window borders: a thin band outside the
    tiles' edges (the gaps and struts), and the seam between two half-width
    columns."""
    W, H = size
    g = GEOM
    k = 0.5  # half scale
    x0 = (g["strut_lr"] + g["gaps"]) * k
    x1 = (W - g["strut_lr"] - g["gaps"]) * k
    y0 = (g["island_margin"] + g["island_reserve"] + g["strut_top"] + g["gaps"]) * k
    y1 = (H - g["gaps"]) * k
    hh, ww = sharp.shape[:2]
    pts = []

    def band(xs, ys):
        pts.append(sharp[np.clip(ys.astype(int), 0, hh - 1), np.clip(xs.astype(int), 0, ww - 1)])

    for off in (-3, -2, -1):
        xs = np.arange(int(x0), int(x1))
        band(xs, np.full(len(xs), y0 + off))
        band(xs, np.full(len(xs), y1 - off))
        ys = np.arange(int(y0), int(y1))
        band(np.full(len(ys), x0 + off), ys)
        band(np.full(len(ys), x1 - off), ys)
    for off in (-2, -1, 0, 1, 2):
        ys = np.arange(int(y0), int(y1))
        band(np.full(len(ys), ww / 2 + off), ys)
    return np.concatenate(pts)


def island_backdrop(frost, size):
    """What the island's glass frosts: the strip the resting pill lives on
    (weighted most: it is always there, and only ever over the wallpaper), and
    fainter, the reach of the open card below it. Each pixel comes with where
    it sits across the island, -1 (left) to 1 (right)."""
    W, H = size
    k = 0.5
    g = GEOM
    hh, ww = frost.shape[:2]
    pts, wts, rel = [], [], []
    for w_, h_, weight in ((g["pill_w"], g["pill_h"], 3.0), (g["card_w"], g["card_h"], 1.0)):
        x0, x1 = int((W - w_) / 2 * k), int((W + w_) / 2 * k)
        y0, y1 = int(g["island_margin"] * k), int((g["island_margin"] + h_) * k) + 1
        block = frost[y0:min(y1, hh), x0:min(x1, ww)]
        pts.append(block.reshape(-1, 3))
        wts.append(np.full(block.shape[0] * block.shape[1], weight / (block.shape[0] * block.shape[1])))
        rel.append(np.tile(np.linspace(-1, 1, block.shape[1]), block.shape[0]))
    return np.concatenate(pts), np.concatenate(wts), np.concatenate(rel)


def colour_of(pts, w):
    """The colour some glass shows of what is behind it: the hue its vivid
    parts carry (chroma-weighted, so a grey sky with one pink cloud reads pink)
    and how vivid that is."""
    L, C, _ = lch_of(pts)
    wc = w * C ** 2
    if wc.sum() < 1e-9:
        return {"h": 0.0, "C": 0.0, "Cv": 0.0, "L": float((L * w).sum() / w.sum())}
    h = math.degrees(math.atan2((pts[:, 2] * wc).sum(), (pts[:, 1] * wc).sum())) % 360
    o = np.argsort(C)
    cw = np.cumsum(w[o])
    c80 = float(C[o][np.searchsorted(cw, 0.8 * cw[-1])])
    # Cv: how vivid the vivid parts are (chroma-weighted), for accents; a black
    # field with a red emblem has a grey C but a red Cv.
    cv = float((C * wc).sum() / wc.sum())
    return {"h": h, "C": c80, "Cv": cv, "L": float((L * w).sum() / w.sum())}


def analyse(path):
    sharp, frost, size = screen_lab(path)
    pts, w, rel = island_backdrop(frost, size)
    pill = pts[w == w.max()]
    ring = rim_backdrop(sharp, size)
    _, C, _ = lch_of(pts)
    return {
        # The island's own light, and the two sides of its prism: the left
        # and the right of what is behind it.
        "primary": colour_of(pts, w),
        "left": colour_of(pts[rel < 0], w[rel < 0]),
        "right": colour_of(pts[rel >= 0], w[rel >= 0]),
        "mean_C": float((C * w).sum() / w.sum()),
        "pill_L": round(float(pill[:, 0].mean()), 3),
        "ring_L": round(float(np.median(ring[:, 0])), 3),
    }


def dominant_of(pts):
    """Like colour_of, but the hue of the strongest colour present rather than
    the average of all of them: blue sky over yellow grass averages to a
    green that isn't there. Peak of a chroma²-weighted hue histogram (10°
    bins, smoothed), refined by the pixels within 25° of it; Cv is how vivid
    those are, C how tinted the patch is overall."""
    L, C, h = lch_of(pts)
    wc = C ** 2
    o = np.argsort(C)
    c80 = float(C[o][min(int(0.8 * len(C)), len(C) - 1)])
    base = {"C": c80, "L": float(L.mean())}
    if wc.sum() < 1e-9:
        return {"h": 0.0, "Cv": 0.0, **base}
    hist = np.bincount((h // 10).astype(int) % 36, weights=wc, minlength=36)
    hist = hist + 0.5 * (np.roll(hist, 1) + np.roll(hist, -1))
    peak = (np.argmax(hist) + 0.5) * 10
    near = np.abs((h - peak + 180) % 360 - 180) < 25
    wn = wc * near
    hh = math.degrees(math.atan2((pts[:, 2] * wn).sum(), (pts[:, 1] * wn).sum())) % 360
    return {"h": hh, "Cv": float((C * wn).sum() / wn.sum()), **base}


def term_backdrop(path):
    """What the terminal's glass frosts, by where each of its accents sits: a
    full-width column under the island (where niri opens ghostty). The prompt
    (path chip, ❯) lives along the left, the git branch just right of it, the
    tmux bar along the bottom; the code palette sees the whole of it."""
    _, frost, (W, H) = screen_lab(path)
    g = GEOM
    k = 0.5
    hh, ww = frost.shape[:2]
    x0, x1 = (g["strut_lr"] + g["gaps"]) * k, (W - g["strut_lr"] - g["gaps"]) * k
    y0 = (g["island_margin"] + g["island_reserve"] + g["strut_top"] + g["gaps"]) * k
    y1 = (H - g["gaps"]) * k
    tw, th = x1 - x0, y1 - y0

    def region(fx0, fx1, fy0, fy1):
        a = frost[int(y0 + th * fy0):max(int(y0 + th * fy1), int(y0 + th * fy0) + 1),
                  int(x0 + tw * fx0):max(int(x0 + tw * fx1), int(x0 + tw * fx0) + 1)].reshape(-1, 3)
        return dominant_of(a)

    bar = 40 / (th / k)   # the tmux bar: its bottom 40 logical px
    whole = frost.reshape(-1, 3)
    return {"screen": dominant_of(whole),
            "area": region(0, 1, 0, 1),
            "prompt": region(0, 0.32, 0, 1 - bar),
            "branch": region(0.32, 0.5, 0, 1 - bar),
            "bar": region(0, 0.4, 1 - bar, 1),
            "bar_right": region(0.6, 1, 1 - bar, 1)}


# ── a theme ───────────────────────────────────────────────────────
def load_preset(name):
    return json.loads((PRESETS / f"{name}.json").read_text())


def hue_delta(a, b):
    return (a - b + 180) % 360 - 180


def gain(c, ref, hue):
    """As vivid as what is behind: grey behind, nearly clear glass; colour
    behind, its colour. Yellow needs its chroma or it reads olive."""
    k = min(max(c / ref, 0.15), 1.15)
    if 85 <= hue <= 120 and c > 0.06:
        return max(k, 1.0) * 1.2
    return k


def role_hue(dusk_h, anchor, h):
    """Dusk's roles sit a little off the wallpaper's own hue (its lilac is
    ~19° purpler than idk.png's violet): that taste carries over to hues near
    dusk's and fades out away from them, so a red never drifts to orange."""
    fade = max(0.0, 1 - hue_dist(h, anchor) / 60)
    return h + hue_delta(dusk_h, anchor) * fade


def is_red(h):
    return h < 36 or h > 345


def is_yellow(h):
    return 85 <= h <= 120


def accent_lightness(L, h):
    """Dusk's pastel lightness suits violet, blue, green, peach. A red that
    light is salmon, no longer red: it sits lower. A yellow that dark cannot
    be yellow at all (only mustard): it sits higher."""
    if is_red(h):
        return min(L, 0.72)
    if is_yellow(h):
        return max(L, 0.88)
    return L


# Where each of dusk's roles takes its colour from, behind the island.
ROLE_SOURCE = {"cool": "left", "lilac": "primary", "warm": "right", "sunset": "right"}


def generate(path):
    base = load_preset("dusk")
    ref = base["hues"]
    got = analyse(path)
    out = {"name": "generated", "source": str(path), "roles": {}}
    src_of = {k: got[k] for k in ("primary", "left", "right")}
    # Cool greys read as glass; warm or green ones as brown or dirty: keep those greyer.
    p = got["primary"]
    kn = min(got["mean_C"] / 0.05, 1.0) * (1.0 if 180 <= p["h"] <= 330 else 0.45)
    for role, (hexc, fam) in base["roles"].items():
        if role == "rim":
            continue
        L, C, h = hex_to_lch(hexc)
        if fam == "neutral":
            hh = role_hue(h, ref["primary"], p["h"]) % 360
            out["roles"][role] = lch_to_hex(L, C * kn, hh)
            continue
        src = src_of[ROLE_SOURCE.get(role, "primary")]
        anchor = ref["secondary"] if fam == "secondary" else ref["primary"]
        hh = role_hue(h, anchor, src["h"]) % 360
        out["roles"][role] = lch_to_hex(accent_lightness(L, hh), C * gain(src["C"], 0.12, hh), hh)
    out["hues"] = {k: round(v["h"], 1) for k, v in src_of.items()}
    out["niri"] = niri_light(got["ring_L"])
    # A bright strip behind the pill: more glass, so the white ink still reads.
    out["term"] = term_backdrop(path)
    out["glass_alpha"] = round(38 + 20 * min(max((got["pill_L"] - 0.62) / 0.25, 0), 1))
    return out


def a8(alpha):
    return f"{round(alpha * 255):02X}"


def niri_light(ring_L):
    """niri's borders have no colour of their own: each is the frost of what
    is behind it (border-glass), lit like a glass edge, inside a dark hairline
    at its silhouette, with a white sheen over the focused one. The brighter
    what is behind, the less it can be lit (it would wash out to white) and
    the more the dark hairline has to carry it."""
    t = min(max((ring_L - 0.45) / 0.4, 0.0), 1.0)
    return {"light": round(0.38 - 0.16 * t, 2), "shade": round(0.4 + 0.3 * t, 2),
            # Focus is the glass being lit, not a painted highlight: the sheen is
            # faint and nearly even, so no corner reads as frosted.
            "from": "#FFFFFF" + a8(0.16), "to": "#FFFFFF" + a8(0.06), "inactive": "#FFFFFF" + a8(0.03)}


def pins():
    try:
        return json.loads(PINS.read_text())
    except FileNotFoundError:
        return {}


def theme_for(path):
    name = pins().get(Path(path).name)
    if name:
        t = load_preset(name)
        return {"name": name, "source": str(path),
                "roles": {r: v[0] for r, v in t["roles"].items()},
                **{k: t[k] for k in ("niri", "glass_alpha") if k in t},
                "term": term_backdrop(path)}
    return cached(path)


def cached(path):
    """A generated theme is worked out once per picture (it takes a few
    seconds): kept by name, size and mtime, and by this script's own mtime,
    so changing the rules recomputes everything."""
    st = Path(path).stat()
    me = Path(__file__).stat().st_mtime_ns + (PRESETS / "dusk.json").stat().st_mtime_ns
    key = f"{Path(path).name}-{st.st_size}-{st.st_mtime_ns}-{me}"
    f = CACHE / (key + ".json")
    try:
        return json.loads(f.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    t = generate(path)
    CACHE.mkdir(parents=True, exist_ok=True)
    for old in CACHE.glob(Path(path).name + "-*.json"):
        old.unlink()
    write_if_changed(f, json.dumps(t, indent=1) + "\n")
    return t


# ── writing it out ────────────────────────────────────────────────
def write_if_changed(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        if path.read_text() == text:
            return False
    except FileNotFoundError:
        pass
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)
    return True


def lumen_text(t):
    r = t["roles"]
    order = ["ink", "cool", "warm", "lilac", "sunset", "dusk", "deep", "rim_grey",
             "idle_c", "low_c", "chip", "chip_hi", "pearl", "pearl_ink",
             "shade", "stack1_t", "stack1_b", "stack2_t", "stack2_b", "well_t", "well_b"]
    lines = [f"    let {k:<9} = {r[k]}" for k in order]
    lines.append(f"    let glass_alpha = {t.get('glass_alpha', 38)}%")
    return ("// Written by theme/wallpaper-theme.py for " + Path(t["source"]).name +
            f" (theme: {t['name']}): the island's colours, from what is behind it. Don't edit.\n"
            "part Theme {\n" + "\n".join(lines) + "\n}\n")


GLASS_KEYS = ("border-glass", "border-light", "border-shade", "border-inactive")


def glass_niri():
    """Which glass-border settings the niri on this session's socket knows
    (the patched one, possibly an older build of it still running after a
    newer was installed): each is tried on that very process's binary, since
    an unknown one would make niri reject the whole config."""
    try:
        socks = sorted(Path(os.environ["XDG_RUNTIME_DIR"]).glob("niri.wayland-*.sock"),
                       key=lambda p: p.stat().st_mtime, reverse=True)
        exe = f"/proc/{socks[0].name.split('.')[-2]}/exe"
    except (OSError, KeyError, IndexError):
        return set()
    known = set()
    CACHE.mkdir(parents=True, exist_ok=True)
    probe = CACHE / "glass-probe.kdl"
    for key in GLASS_KEYS:
        probe.write_text(f"blur {{ {key} 0.5; }}\n")
        if subprocess.run([exe, "validate", "-c", str(probe)], capture_output=True).returncode == 0:
            known.add(key)
    return known


GLASS_SAT = 1.8  # border-glass: how vivid the frost under a border is


def niri_text(t):
    head = (f"// Written by theme/wallpaper-theme.py for {Path(t['source']).name} (theme: {t['name']}).\n"
            "// Included by config.kdl.\n")
    known = glass_niri()
    if "border-glass" not in known:
        # A niri without glass borders: nothing shows what is behind, so the
        # island's own light (from what is behind it) stands in until a restart.
        c = t["roles"]["lilac"].upper()
        return (head + "layout {\n"
                f"    border {{ active-gradient from=\"{c}\" to=\"#FFFFFFCC\" angle=120; inactive-color \"#FFFFFF1F\"; }}\n"
                f"    insert-hint {{ color \"{c}40\"; }}\n"
                f"    tab-indicator {{ active-color \"{c}\"; }}\n"
                "}\n")
    n = t.get("niri") or niri_light(0.3)
    blur = [f"border-glass {GLASS_SAT}"]
    if "border-light" in known:
        blur.append(f"border-light {n['light']}")
    if "border-shade" in known:
        blur.append(f"border-shade {n['shade']}")
    if "border-inactive" in known:
        blur.append(f"border-inactive {n.get('inactive_k', 0.25)}")
    return (head +
            "// Borders have no colour of their own: each is the frost of what is really\n"
            "// behind it (border-glass), lit like a glass edge (border-light) inside a dark\n"
            "// hairline at its silhouette (border-shade), faint sheen on the focused one;\n"
            "// unfocused windows' glass is quieter and in shade (border-inactive).\n"
            f"blur {{ {'; '.join(blur)}; }}\n"
            "layout {\n"
            f"    border {{ active-gradient from=\"{n['from']}\" to=\"{n['to']}\" angle=120; inactive-color \"{n['inactive']}\"; }}\n"
            "    insert-hint { color \"#FFFFFF33\"; }\n"
            "    tab-indicator { active-color \"#FFFFFFB3\"; inactive-color \"#FFFFFF33\"; }\n"
            "}\n")


# The terminal's glass, at its own (eldritch navy) lightness and chroma.
TERM_BASE = {"chip": "#3a4357", "quiet": "#2a3244", "rule": "#3a4152",
             "border": "#232a38", "border_hi": "#8b93a7"}


RED_HUE = 18          # eldritch's red: a failed ❯ and errors own it
ACCENT_RED_GAP = 40   # accents keep this far from it


def term_hue(local, screen):
    """The hue and vividness an accent takes from what is right behind it. A
    near-grey patch (black sky, grey wall) borrows the wallpaper's vivid hue
    instead, a little quieter, so an accent is never just grey."""
    wl = min(local["Cv"] / 0.06, 1.0)
    d = hue_delta(local["h"], screen["h"])
    h = (screen["h"] + d * wl) % 360
    return h, max(local["Cv"] * wl, 0.7 * screen["Cv"])


def term_accent(h, cv, away_from=None):
    """An accent at dusk's lilac lightness and chroma (pastel, readable on the
    dark glass), as vivid as what is behind it, never near error red, and
    (for a second accent) at least 35° from the first."""
    L, C, _ = hex_to_lch(load_preset("dusk")["roles"]["lilac"][0])
    if away_from is not None and hue_dist(h, away_from) < 35:
        h = away_from + math.copysign(45, hue_delta(h, away_from) or 1)
    d = hue_delta(h, RED_HUE)
    if abs(d) < ACCENT_RED_GAP:
        h = RED_HUE + math.copysign(ACCENT_RED_GAP, d or 1)
    h %= 360
    return lch_to_hex(accent_lightness(L, h), C * min(max(cv / 0.1, 0.45), 1.15), h), h


def term_palette(t):
    """Each of the terminal's accents and glass chips from the wallpaper right
    behind where it is drawn (term_backdrop): ❯, the folder icon and the
    cursor from behind the prompt, the branch from just right of it, tmux's
    marks and chips from behind the bar. Chips are neutrals: tinted with that
    hue, as strongly as it is vivid, so grey behind stays grey."""
    b = t.get("term")
    if not b:   # an old cached theme: the island's colours
        r = t["roles"]
        return {"accent": r["lilac"], "accent2": r["cool"], "bar_accent": r["lilac"],
                **{n: base for n, base in TERM_BASE.items()}, "chip_bar": TERM_BASE["chip"],
                "quiet_bar": TERM_BASE["quiet"]}
    scr = b["screen"]
    hp, cp = term_hue(b["prompt"], scr)
    hb, cb = term_hue(b["branch"], scr)
    hbar, cbar = term_hue(b["bar"], scr)
    out = {}
    out["accent"], h1 = term_accent(hp, cp)
    out["accent2"], _ = term_accent(hb, cb, away_from=h1)
    out["bar_accent"], _ = term_accent(hbar, cbar)

    def tint(base, h, cv):
        L, C, _ = hex_to_lch(base)
        return lch_to_hex(L, C * min(max(cv / 0.08, 0.15), 1.3), h)

    for name, base in TERM_BASE.items():
        out[name] = tint(base, hp, cp)          # prompt chip, selection, borders
    out["chip_bar"] = tint(TERM_BASE["chip"], hbar, cbar)
    out["quiet_bar"] = tint(TERM_BASE["quiet"], hbar, cbar)
    return out


# The terminal's code colours: eldritch (ghostty + nvim), re-hued toward the
# wallpaper but never at the cost of reading code. Lightness and chroma stay
# eldritch's; only hue moves. Cool colours (blue, purple, pink, cyan) lean far
# toward the wallpaper's own hue (together); red/green/yellow/orange only a little, so an
# error is still red and an addition still green. Neutrals (background, greys,
# text) take the island's neutral tint. A grey wallpaper moves nothing.
# name: (eldritch hex, group)
TERM_COLOURS = {
    "bg": ("#070a0e", "n"), "fg": ("#ebfafa", "n"),
    "0": ("#070a0e", "n"), "8": ("#646477", "n"), "7": ("#b7bfce", "n"), "15": ("#ebfafa", "n"),
    "1": ("#f16c75", "w"), "2": ("#37f499", "w"), "3": ("#f7c67f", "w"),
    "4": ("#7081d0", "c"), "5": ("#fca6ff", "c"), "6": ("#04d1f9", "c"),
    # nvim (nvim/lua/config/active-colorscheme.sh names)
    "linkarzu_color01": ("#fca6ff", "c"), "linkarzu_color02": ("#37f499", "w"),
    "linkarzu_color03": ("#04d1f9", "c"), "linkarzu_color04": ("#987afb", "c"),
    "linkarzu_color05": ("#9ad900", "w"), "linkarzu_color06": ("#05ff23", "w"),
    "linkarzu_color08": ("#e58f2a", "w"), "linkarzu_color11": ("#f16c75", "w"),
    "linkarzu_color12": ("#f1fc79", "w"), "linkarzu_color16": ("#e9b3fd", "c"),
    "linkarzu_color24": ("#f94dff", "c"), "linkarzu_color15": ("#013e4a", "c"),
    "linkarzu_color18": ("#2d244b", "c"), "linkarzu_color19": ("#10492d", "w"),
    "linkarzu_color20": ("#013e4a", "c"), "linkarzu_color21": ("#4b314c", "c"),
    "linkarzu_color22": ("#1e2b00", "w"), "linkarzu_color23": ("#2d1c08", "w"),
    "linkarzu_color09": ("#b7bfce", "n"), "linkarzu_color14": ("#ffffff", "n"),
    "linkarzu_color10": ("#0D1116", "n"), "linkarzu_color17": ("#141b22", "n"),
    "linkarzu_color07": ("#141b22", "n"), "linkarzu_color25": ("#232e3b", "n"),
    "linkarzu_color13": ("#232e3b", "n"), "linkarzu_color26": ("#0D1116", "n"),
}
# Cool colours move as one group: blue (eza's folders, nvim's functions) sits
# on the wallpaper's own hue, pink and cyan TERM_SPREAD° either side of it
# (eldritch's order). Red/yellow/green only lean, each on its own: (share of
# the gap, cap °). The group stays TERM_MIN_SEP° clear of them, so the six
# ANSI hues never blur together; a wallpaper whose hue is warm leaves the
# group at the nearest edge of that free arc.
TERM_SPREAD = 40
TERM_WARM_LEAN = (0.3, 15)
TERM_MIN_SEP = 28
# A little less neon than eldritch, closer to the island's pastels.
TERM_CHROMA = 0.85


def term_tint(t):
    """The code palette's tint (hue, strength) and the hue its cool group
    centres on: from the whole area behind the terminal (its vivid parts,
    falling back on the wallpaper's), the island's colours for an old theme."""
    b = t.get("term")
    if not b:
        r = t["roles"]
        _, c_ref, _ = hex_to_lch(load_preset("dusk")["roles"]["stack1_t"][0])
        _, c, h_n = hex_to_lch(r["stack1_t"])
        _, _, h_a = hex_to_lch(r["lilac"])
        return h_n, min(max(c / c_ref, 0.15), 1.3), h_a
    h, cv = term_hue(b["area"], b["screen"])
    # neutrals: as tinted as the area mostly is (C), the hue of its vivid parts
    k = min(max(b["area"]["C"] / 0.05, 0.15), 1.3)
    return h, k, h


def term_colours(t):
    h_n, k, h_a = term_tint(t)
    b = t.get("term")
    # a grey wallpaper's hue means nothing: don't follow it
    wk = min(term_hue(b["area"], b["screen"])[1] / 0.08, 1.0) if b else min(k, 1.0)

    def lean(h):
        frac, cap = TERM_WARM_LEAN
        d = hue_delta(h_a, h)
        return (h + math.copysign(min(abs(d) * frac, cap), d) * wk) % 360

    hue = {n: hex_to_lch(b)[2] for n, (b, _) in TERM_COLOURS.items()}
    green, red = lean(hue["2"]), lean(hue["1"])
    # The free arc for blue: from just past green to just short of red.
    lo = (green + TERM_MIN_SEP + TERM_SPREAD) % 360
    width = (red - TERM_MIN_SEP - TERM_SPREAD - lo) % 360
    off = (h_a - lo) % 360
    if off > width:   # outside the arc: the nearer edge
        off = width if off - width < 360 - off else 0
    blue = (lo + off) % 360
    blue = (hue["4"] + hue_delta(blue, hue["4"]) * wk) % 360
    turn = hue_delta(blue, hue["4"])
    # Each cool colour keeps its side of blue, TERM_SPREAD away (eldritch's are
    # ~53° apart); darker cool tints (nvim's heading backgrounds) follow theirs.
    side = {}
    for n, (base, group) in TERM_COLOURS.items():
        if group == "c":
            d = hue_delta(hue[n], hue["4"])
            side[n] = 0 if abs(d) < 20 else math.copysign(TERM_SPREAD, d)
    out = {}
    for n, (base, group) in TERM_COLOURS.items():
        L, C, h = hex_to_lch(base)
        if group == "n":
            out[n] = lch_to_hex(L, max(C, 0.012) * k, h_n)
        elif group == "c":
            target = (blue + side[n]) % 360
            hh = (h + hue_delta(target, h) * wk) % 360 if wk else h
            out[n] = lch_to_hex(L, C * TERM_CHROMA, hh)
        else:
            out[n] = lch_to_hex(L, C * TERM_CHROMA, lean(h))
    return out


def term_texts(t):
    p = term_palette(t)
    head = f"Written by theme/wallpaper-theme.py for {Path(t['source']).name} (theme: {t['name']}). Don't edit."
    tmux = (f"# {head}\n"
            f"set -g @t_accent '{p['bar_accent']}'\n"
            f"set -g @t_chip '{p['chip_bar']}'\n"
            f"set -g @t_quiet '{p['quiet_bar']}'\n"
            f"set -g @t_rule '{p['rule']}'\n"
            f"set -g message-style 'fg=brightwhite,bg={p['quiet_bar']}'\n"
            f"set -g message-command-style 'fg=brightwhite,bg={p['quiet_bar']}'\n"
            f"set -g mode-style 'fg=brightwhite,bg={p['chip']}'\n"
            f"set -g window-status-bell-style 'fg={p['bar_accent']}'\n"
            f"set -g pane-border-style 'fg={p['border']},bg=default'\n"
            f"set -g pane-active-border-style 'fg={p['border_hi']},bg=default'\n"
            f"set -g popup-border-style 'fg={p['rule']},bg=default'\n"
            f"setenv -g FLOAX_BORDER_COLOR '{p['rule']}'\n")
    zsh = (f"# {head}\n"
           f"_p_accent='{p['accent']}'\n"
           f"_p_accent2='{p['accent2']}'\n"
           f"_p_quiet='{p['quiet']}'\n")
    c = term_colours(t)
    bright = {"9": "1", "10": "2", "11": "3", "12": "4", "13": "5", "14": "6"}
    ghostty = (f"# {head}\n"
               f"background = {c['bg']}\n"
               f"foreground = {c['fg']}\n"
               + "".join(f"palette = {i}={c[str(i)]}\n" for i in (0, 1, 2, 3, 4, 5, 6, 7, 8))
               + "".join(f"palette = {b}={c[n]}\n" for b, n in bright.items())
               + f"palette = 15={c['15']}\n"
               f"cursor-color = {p['accent']}\n"
               f"selection-background = {p['chip']}\n")
    nvim = (f"# {head}\n# Overrides nvim/lua/config/active-colorscheme.sh (see config/colors.lua).\n"
            + "".join(f"{n}={v}\n" for n, v in c.items() if n.startswith("linkarzu_"))
            # nvim's cursor is the same accent as ghostty's
            + f"linkarzu_color24={p['accent']}\n")
    return tmux, zsh, ghostty, nvim


def apply_term(t):
    """Each terminal piece picks the new colours up live: tmux re-sources its
    file, ghostty reloads its config (its palette: everything drawn in ANSI
    colours, eza, git, zsh's highlighting, follows), zsh re-reads its file at
    the next prompt, nvim watches its file."""
    tmux, zsh, ghostty, nvim = term_texts(t)
    changed = []
    if write_if_changed(TERM_DIR / "nvim.sh", nvim):
        changed.append("nvim")   # running nvims watch the file
    if write_if_changed(TERM_DIR / "tmux.conf", tmux):
        changed.append("tmux")
        subprocess.run(["tmux", "source-file", str(TERM_DIR / "tmux.conf")], capture_output=True)
    if write_if_changed(TERM_DIR / "zsh", zsh):
        changed.append("zsh")
    if write_if_changed(GHOSTTY_OUT, ghostty):
        changed.append("ghostty")
        subprocess.run(["pkill", "-USR2", "-x", "ghostty"], capture_output=True)
    return changed


def current_wallpaper():
    out = subprocess.run(["awww", "query"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "image: " in line:
            return line.split("image: ", 1)[1].strip()
    sys.exit("awww shows no image")


def apply(path):
    t = theme_for(path)
    changed = []
    if write_if_changed(LUMEN_OUT, lumen_text(t)):
        changed.append("lumen")
    if write_if_changed(NIRI_OUT, niri_text(t)):
        changed.append("niri")
        subprocess.run(["niri", "msg", "action", "load-config-file"], capture_output=True)
    changed += apply_term(t)
    write_if_changed(STATE, json.dumps(t, indent=2) + "\n")
    print(f"{Path(path).name}: {t['name']}" + (f" → {', '.join(changed)}" if changed else " (unchanged)"))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "apply"
    arg = sys.argv[2] if len(sys.argv) > 2 else None
    if cmd == "apply":
        apply(arg or current_wallpaper())
    elif cmd == "warm":
        # Every wallpaper's theme, ahead of time (the island runs it when its
        # wallpaper panel opens), so a pick recolours at once.
        for w in sorted(WALLS.iterdir()):
            if w.suffix.lower() in (".png", ".jpg", ".jpeg", ".webp", ".gif") and w.name not in pins():
                cached(str(w))
    elif cmd == "show":
        path = arg or current_wallpaper()
        print(json.dumps({"analysis": analyse(path), **theme_for(path)}, indent=2))
    elif cmd == "save":
        if not arg:
            sys.exit("save NAME")
        path = current_wallpaper()
        t = theme_for(path)
        fam = load_preset("dusk")["roles"]
        preset = {"name": arg, "about": f"Kept from {Path(path).name}.",
                  "roles": {r: [v, fam[r][1]] for r, v in t["roles"].items()},
                  **{k: t[k] for k in ("niri", "glass_alpha") if k in t}}
        (PRESETS / f"{arg}.json").write_text(json.dumps(preset, indent=2) + "\n")
        p = pins()
        p[Path(path).name] = arg
        PINS.write_text(json.dumps(p, indent=2) + "\n")
        print(f"saved {arg}, pinned to {Path(path).name}")
    elif cmd == "unpin":
        name = Path(arg or current_wallpaper()).name
        p = pins()
        p.pop(name, None)
        PINS.write_text(json.dumps(p, indent=2) + "\n")
        apply(arg or current_wallpaper())
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
