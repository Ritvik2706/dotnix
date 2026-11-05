#!/usr/bin/env python3
"""niri-glass.py — write niri/glass.json: the island's glass for niri's own UI.

niri draws the screenshot UI's panel as the island's open card with its
controls on it (patched niri, src/ui/screenshot_ui.rs GlassStyle). The values
come from lumen/shells/island/glass.plm (the `lgs_*` saved values, derived as
glass.plm derives its card and control materials) and the wallpaper theme's
colours in theme.plm, so tuning the Glass page or picking a wallpaper reaches
niri too. Run by glass-save.py and wallpaper-theme.py apply; niri reads the
file each time the screenshot UI opens.

Keep the derivations below in step with glass.plm's `derived` and `controls`
sections.
"""
import json
import os
import re
from pathlib import Path

DOTNIX = Path(__file__).resolve().parent.parent
GLASS = DOTNIX / "lumen/shells/island/glass.plm"
THEME = DOTNIX / "lumen/shells/island/theme.plm"
OUT = DOTNIX / "niri/glass.json"


def lets(path, prefix=""):
    """`let NAME = VALUE` lines: percentages as fractions, numbers, #colours."""
    out = {}
    for m in re.finditer(rf"^\s*let {prefix}(\w+)\s*=\s*([^/\n]+?)\s*(//.*)?$", path.read_text(), re.M):
        raw = m.group(2).strip()
        if raw.startswith("#"):
            out[m.group(1)] = raw
        elif raw.endswith("%"):
            out[m.group(1)] = float(raw[:-1]) / 100
        else:
            try:
                out[m.group(1)] = float(raw)
            except ValueError:
                pass
    return out


def mix(a, b, t):
    pa = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    pb = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x + (y - x) * t):02x}" for x, y in zip(pa, pb))


def main():
    g = lets(GLASS, "lgs_")
    t = lets(THEME)
    read = min(max(g["readability"], 0), 1)
    soften = min(max(g["frost_strength"], 0), 1)
    fill = 0.07  # lgc_fill
    style = {
        # The open card (island.plm's body at dark = 1).
        "frost": 0.9 * read * soften,  # lg_card_frost
        "merge": g["merge"],
        "card_refraction": g["card_refraction"],
        "card_bevel": g["card_bevel"],
        "dispersion": g["dispersion"],
        "specular": g["specular"],
        "glass_tint": g["glass_tint"],
        "rim_tint": g["rim_tint"],
        "card_alpha": g["card_tint"],  # card_alpha
        "card_smoke": 0.04 + 0.10 * read,  # card_smoke
        "card_milk": g["milk"] + 0.02 * read,  # lg_card_milk
        # Its controls: `material control` (layer 2).
        "ctrl_refraction": g["refraction"] * 1.3,  # lgb_refraction
        "ctrl_bevel": 9.0,  # lgb_bevel
        "ctrl_magnify": g["magnify"] * 0.6,  # lgc_magnify
        "ctrl_glass_tint": g["glass_tint"],  # lgb_glass_tint
        "ctrl_fill": fill + 0.08,  # lgb_fill
        "ctrl_lit": 0.55,  # CONTROLS.md: lit by state
        # Colours.
        "dusk": t["dusk"],
        "deep": t["deep"],
        "chip": t["chip"],
        "soft_l": mix(t["pearl"], t["lilac"], 0.42),
        "soft_s": mix(t["pearl"], t["sunset"], 0.38),
        "ink": t["ink_base"],
        "lit_ink": t["pearl_ink"],
    }
    text = json.dumps(style, indent=2) + "\n"
    if OUT.exists() and OUT.read_text() == text:
        return
    tmp = OUT.with_suffix(".json.tmp")
    tmp.write_text(text)
    os.replace(tmp, OUT)


if __name__ == "__main__":
    main()
