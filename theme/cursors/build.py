#!/usr/bin/env python3
"""Build the link pointer from SVG; requires rsvg-convert and Pillow."""
import io
from pathlib import Path
import struct
import subprocess

from PIL import Image

ROOT = Path(__file__).resolve().parent
DEST = ROOT / "Bibata-Modern-Ice-MiddleFinger" / "cursors"
SIZES = (16, 20, 21, 22, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96)
IMAGE_TYPE = 0xFFFD0002


def build():
    DEST.mkdir(parents=True, exist_ok=True)
    chunks = []
    for size in SIZES:
        png = subprocess.check_output([
            "rsvg-convert", "-w", str(size * 4), "-h", str(size * 4),
            str(ROOT / "hand2.svg"),
        ])
        image = Image.open(io.BytesIO(png)).convert("RGBA").resize(
            (size, size), Image.Resampling.LANCZOS
        )
        # Xcursor stores premultiplied ARGB pixels in little-endian order.
        pixels = bytearray()
        for r, g, b, a in struct.iter_unpack("4B", image.tobytes()):
            pixels.extend((b * a // 255, g * a // 255, r * a // 255, a))
        chunks.append(struct.pack(
            "<9I", 36, IMAGE_TYPE, size, 1, size, size,
            round(145 * size / 256), round(17 * size / 256), 40,
        ) + pixels)
    offset = 16 + 12 * len(SIZES)
    output = bytearray(struct.pack("<4I", 0x72756358, 16, 0x10000, len(SIZES)))
    for size, chunk in zip(SIZES, chunks):
        output.extend(struct.pack("<3I", IMAGE_TYPE, size, offset))
        offset += len(chunk)
    (DEST / "hand2").write_bytes(output + b"".join(chunks))
    for name in (
        "pointer", "pointing_hand", "9d800788f1b08800ae810202380a0822",
        "e29285e634086352946a0e7090d73106",
    ):
        target = DEST / name
        if not target.is_symlink():
            target.symlink_to("hand2")
    print(f"Built {len(SIZES)} sizes in {DEST}")


if __name__ == "__main__":
    build()
