#!/usr/bin/env python3
"""glass-save.py KEY=VALUE … — write the Glass page's values into glass.plm.

Called by island.luau when Save is pressed on Control Center → Glass. Each
KEY is a saved value's name without the `lgs_` prefix; VALUE is a number as
the scene holds it (a fraction for percentages). Only the matching
`let lgs_KEY = …` lines change; their comments and everything else stay.
The file is replaced atomically, so lumen never reloads a half-written one.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

GLASS = Path(__file__).resolve().parent.parent / "glass.plm"
# Saved as percentages (the scene holds 0..1); the rest are pixels.
PERCENT = {"readability", "frost_strength", "dispersion", "specular", "read_frost",
           "read_alpha", "tint", "card_tint", "prism", "card_rim", "magnify", "milk", "glass_tint", "rim_tint"}


def fmt(key, value):
    if key in PERCENT:
        return f"{round(value * 100)}%"
    return f"{round(value, 2):g}"


def main():
    values = {}
    for arg in sys.argv[1:]:
        key, _, raw = arg.partition("=")
        try:
            values[key] = float(raw)
        except ValueError:
            sys.exit(f"bad value: {arg}")
    text = GLASS.read_text()
    for key, value in values.items():
        pattern = re.compile(rf"^(\s*let lgs_{re.escape(key)}\s*=\s*)([^/\n]*?)(\s*(//.*)?)$", re.M)
        text, n = pattern.subn(lambda m: m.group(1) + fmt(key, value) + m.group(3), text, count=1)
        if n == 0:
            print(f"glass-save: no `let lgs_{key}` in {GLASS}", file=sys.stderr)
    tmp = GLASS.with_suffix(".plm.tmp")
    tmp.write_text(text)
    os.replace(tmp, GLASS)
    # niri's own glass (the screenshot UI) follows the saved values.
    subprocess.run([sys.executable, str(GLASS.parents[3] / "theme/niri-glass.py")], capture_output=True)


if __name__ == "__main__":
    main()
