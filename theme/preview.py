#!/usr/bin/env python3
"""preview.py OUT.png IMAGE… — what each wallpaper's theme looks like on the
screen: the wallpaper as awww fills it, two half-width niri columns (left
focused, right not) with their glass borders (the frost behind them, lit),
and the island's pill over the strip it frosts. One row per wallpaper, plus a 3× close-up of the top-left corner,
where the rim meets the wallpaper."""
import importlib.util
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

spec = importlib.util.spec_from_file_location("wt", Path(__file__).with_name("wallpaper-theme.py"))
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)

W, H = 1600, 900


def rgb(h, a=255):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + ((int(h[6:8], 16),) if len(h) == 8 else (a,))


def fill(path):
    img = Image.open(path)
    img.seek(0)
    img = img.convert("RGB")
    s = max(W / img.width, H / img.height)
    img = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    l, t = (img.width - W) // 2, (img.height - H) // 2
    return img.crop((l, t, l + W, t + H)).convert("RGBA")


def gradient(size, a, b):
    # niri's angle=120: from the top-left toward the bottom-right.
    w, h = size
    xx, yy = np.meshgrid(np.arange(w) / w, np.arange(h) / h)
    t = np.clip(xx * 0.6 + yy * 0.4, 0, 1)[..., None]
    g = np.array(a, dtype=float) * (1 - t) + np.array(b, dtype=float) * t
    return Image.fromarray(g.round().astype(np.uint8), "RGBA")


def glass_ring(frost, light, sat):
    """What border-glass draws under a border: the frost, more vivid
    (saturation as niri's postprocess does it), lifted toward white."""
    f = np.asarray(frost.convert("RGB"), dtype=float) / 255
    luma = f @ np.array([0.2126, 0.7152, 0.0722])
    f = luma[..., None] + (f - luma[..., None]) * sat
    f = f + (1 - f) * light
    return Image.fromarray((np.clip(f, 0, 1) * 255).round().astype(np.uint8), "RGB").convert("RGBA")


def window(base, frost_ring, box, sheen_a, sheen_b, inactive, focused):
    x0, y0, x1, y1 = box
    r = 24
    body = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle(box, r, fill=(7, 10, 14, 230))
    base.alpha_composite(body)
    mask = Image.new("L", base.size, 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((x0 - 2, y0 - 2, x1 + 2, y1 + 2), r + 2, fill=255)
    d.rounded_rectangle(box, r, fill=0)
    ring = frost_ring.copy()
    if focused:
        g = Image.new("RGBA", base.size, (0, 0, 0, 0))
        g.paste(gradient((x1 - x0 + 4, y1 - y0 + 4), sheen_a, sheen_b), (x0 - 2, y0 - 2))
    else:
        g = Image.new("RGBA", base.size, inactive)
    ring.alpha_composite(g)
    base.paste(ring, (0, 0), mask)


def render(path):
    t = wt.theme_for(path)
    r = t["roles"]
    n = t.get("niri") or wt.niri_light(0.3)
    base = fill(path)
    frost_ring = glass_ring(base.filter(ImageFilter.GaussianBlur(12)), n["light"], wt.GLASS_SAT)
    g = wt.GEOM
    y0 = g["island_margin"] + g["island_reserve"] + g["strut_top"] + g["gaps"]
    x0, x1, y1 = g["strut_lr"] + g["gaps"], W - g["strut_lr"] - g["gaps"], H - g["gaps"]
    mid = W // 2
    window(base, frost_ring, (x0, y0, mid - g["gaps"] // 2, y1), rgb(n["from"]), rgb(n["to"]), rgb(n["inactive"]), True)
    window(base, frost_ring, (mid + g["gaps"] // 2, y0, x1, y1), None, None, rgb(n["inactive"]), False)
    # The pill: the strip behind it, frosted, under the dusk glass at glass_alpha.
    pw, ph = g["pill_w"], 29
    px0, py0 = (W - pw) // 2, g["island_margin"]
    strip = base.crop((px0 - 20, py0, px0 + pw + 20, py0 + ph)).filter(ImageFilter.GaussianBlur(10))
    glass = Image.new("RGBA", strip.size, rgb(r["dusk"], round(255 * t.get("glass_alpha", 38) / 100)))
    strip.alpha_composite(glass)
    m = Image.new("L", base.size, 0)
    ImageDraw.Draw(m).rounded_rectangle((px0, py0, px0 + pw, py0 + ph), ph // 2, fill=255)
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    layer.paste(strip, (px0 - 20, py0))
    base.paste(layer, (0, 0), m)
    d = ImageDraw.Draw(base)
    try:
        font = ImageFont.truetype("/usr/share/fonts/TTF/DejaVuSans-Bold.ttf", 13)
    except OSError:
        font = ImageFont.load_default()
    d.ellipse((px0 + 6, py0 + 4, px0 + 27, py0 + 25), fill=rgb(r["lilac"]))
    d.text((px0 + 16.5, py0 + 14.5), "2", fill=rgb(r["pearl_ink"]), font=font, anchor="mm")
    d.text((px0 + pw / 2, py0 + 14.5), "02:22", fill=rgb(r["ink"]), font=font, anchor="mm")
    d.rounded_rectangle((px0 + pw - 40, py0 + 9, px0 + pw - 14, py0 + 20), 3, outline=rgb(r["low_c"]), width=2)
    # The prism and the lilac ink, inside the focused window, as the card shows them.
    for i, k in enumerate(("cool", "lilac", "warm", "sunset")):
        d.rounded_rectangle((x0 + 40 + i * 70, y0 + 40, x0 + 100 + i * 70, y0 + 70), 8, fill=rgb(r[k]))
    d.text((x0 + 40, y0 + 95), f"{Path(path).name} · {t['name']}", fill=rgb(r["ink"]), font=font)
    hues = t.get("hues")
    if hues:
        d.text((x0 + 40, y0 + 115), "behind the island: %.0f°  (left %.0f°, right %.0f°)" % (hues["primary"], hues["left"], hues["right"]),
               fill=rgb(r["low_c"]), font=font)
    corner = base.crop((0, 0, 260, 150)).resize((780, 450), Image.NEAREST)
    row = Image.new("RGBA", (800 + 780 + 10, 450), (0, 0, 0, 255))
    row.paste(base.resize((800, 450), Image.LANCZOS), (0, 0))
    row.paste(corner, (810, 0))
    return row


def main():
    out, paths = sys.argv[1], sys.argv[2:]
    rows = [render(p) for p in paths]
    sheet = Image.new("RGBA", (rows[0].width, sum(r.height + 8 for r in rows)), (0, 0, 0, 255))
    y = 0
    for r in rows:
        sheet.paste(r, (0, y))
        y += r.height + 8
    sheet.convert("RGB").save(out)


if __name__ == "__main__":
    main()
