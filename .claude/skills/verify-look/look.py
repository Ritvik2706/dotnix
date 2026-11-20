#!/usr/bin/env python3
"""look.py — screenshots of every monitor, cropped, and pixel diffs between two.

  look.py shot LABEL [--crop REGION] [--delay S]
      grim each niri output (full output: grim -g regions omit lumen's
      surface) to $XDG_RUNTIME_DIR/look/LABEL-<output>.png, plus a crop
      LABEL-<output>-<region>.png to read. Prints the files.
  look.py diff A B [--crop REGION]
      per output: max channel difference, share of pixels off by more than
      1/255, and a heat map A-vs-B-<output>.png (bright = different).
      "identical" means max diff <= 1 (the glass perf rule).

REGION: island (top centre strip), bottom (bottom strip: tmux/status),
full, or x,y,w,h in output pixels, or x,y,w,h% in percent.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops

DIR = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "look"
REGIONS = {  # fractions of the output: x, y, w, h
    "island": (0.22, 0.0, 0.56, 0.24),
    "bottom": (0.0, 0.80, 1.0, 0.20),
    "full": (0.0, 0.0, 1.0, 1.0),
}


def outputs():
    data = json.loads(subprocess.run(["niri", "msg", "-j", "outputs"], capture_output=True,
                                     text=True, check=True).stdout)
    return [name for name, o in data.items() if o.get("current_mode") is not None]


def box(region, w, h):
    if region in REGIONS:
        fx, fy, fw, fh = REGIONS[region]
        return int(fx * w), int(fy * h), int((fx + fw) * w), int((fy + fh) * h)
    pct = region.endswith("%")
    x, y, bw, bh = (float(v) for v in region.rstrip("%").split(","))
    if pct:
        x, y, bw, bh = x * w / 100, y * h / 100, bw * w / 100, bh * h / 100
    return int(x), int(y), int(x + bw), int(y + bh)


def arg(flag, default):
    if flag in sys.argv:
        i = sys.argv.index(flag)
        return sys.argv[i + 1]
    return default


def shot(label, region, delay):
    DIR.mkdir(parents=True, exist_ok=True)
    if delay:
        time.sleep(delay)
    for out in outputs():
        full = DIR / f"{label}-{out}.png"
        subprocess.run(["grim", "-o", out, str(full)], check=True)
        print(full)
        if region != "full":
            im = Image.open(full)
            crop = DIR / f"{label}-{out}-{region.replace(',', '_').replace('%', 'pct')}.png"
            im.crop(box(region, *im.size)).save(crop)
            print(crop)


def diff(a, b, region):
    for out in outputs():
        fa, fb = DIR / f"{a}-{out}.png", DIR / f"{b}-{out}.png"
        if not (fa.exists() and fb.exists()):
            print(f"{out}: missing {fa.name if not fa.exists() else fb.name}")
            continue
        ia, ib = Image.open(fa).convert("RGB"), Image.open(fb).convert("RGB")
        if ia.size != ib.size:
            print(f"{out}: sizes differ {ia.size} vs {ib.size}")
            continue
        bx = box(region, *ia.size)
        ia, ib = ia.crop(bx), ib.crop(bx)
        d = ImageChops.difference(ia, ib)
        per = np.asarray(d).max(axis=2)
        mx = int(per.max())
        off = float((per > 1).mean())
        heat = d.point(lambda v: min(255, v * 16)).convert("L")
        hp = DIR / f"{a}-vs-{b}-{out}.png"
        heat.save(hp)
        bb = d.point(lambda v: 255 if v > 1 else 0).convert("L").getbbox()
        verdict = "identical (max diff <= 1/255)" if mx <= 1 else f"DIFFERENT, changed area {bb}"
        print(f"{out}: max diff {mx}/255, {off:.2%} of pixels off by >1 → {verdict}\n  heat map: {hp}")


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("shot", "diff"):
        sys.exit(__doc__)
    region = arg("--crop", "island" if sys.argv[1] == "shot" else "full")
    if sys.argv[1] == "shot":
        shot(sys.argv[2], region, float(arg("--delay", "0")))
    else:
        if len(sys.argv) < 4:
            sys.exit(__doc__)
        diff(sys.argv[2], sys.argv[3], region)


if __name__ == "__main__":
    main()
