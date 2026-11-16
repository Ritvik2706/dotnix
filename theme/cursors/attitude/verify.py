#!/usr/bin/env python3
"""Check the built pack through the actual Xcursor loader and verify rollback."""
import ctypes as c
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent
os.environ['XCURSOR_PATH'] = f'{ROOT.parent}:/usr/share/icons'
THEME = 'Bibata-Modern-Ice-Attitude'


class Image(c.Structure):
    _fields_ = [(n,c.c_uint) for n in ('version','size','width','height','xhot','yhot','delay')] + [('pixels',c.POINTER(c.c_uint))]


class Images(c.Structure):
    _fields_ = [('nimage',c.c_int),('images',c.POINTER(c.POINTER(Image))),('name',c.c_char_p)]


lib = c.CDLL('libXcursor.so.1')
lib.XcursorLibraryLoadImages.argtypes = [c.c_char_p,c.c_char_p,c.c_int]
lib.XcursorLibraryLoadImages.restype = c.POINTER(Images)
lib.XcursorImagesDestroy.argtypes = [c.POINTER(Images)]


def load(name, size, theme=THEME):
    ptr = lib.XcursorLibraryLoadImages(name.encode(),theme.encode(),size)
    assert ptr, (name,size,'failed to load')
    result = []
    for n in range(ptr.contents.nimage):
        im = ptr.contents.images[n].contents
        assert 0 <= im.xhot < im.width and 0 <= im.yhot < im.height
        pixels = c.string_at(im.pixels,im.width*im.height*4)
        result.append((im.width,im.height,im.xhot,im.yhot,im.delay,pixels))
    lib.XcursorImagesDestroy(ptr)
    return result


manifest = json.loads((ROOT/'manifest.json').read_text())
aliases = json.loads((ROOT/'aliases.json').read_text())
for name,spec in manifest.items():
    for size in spec['sizes']:
        frames = load(name,size)
        assert len(frames)==spec['frames'], (name,size,'frame count')
        for frame in frames:
            assert frame[:2]==(size,size)
            assert frame[2:4]==tuple(round(h*size/256) for h in spec['hotspot'])
            assert frame[4]==spec['delay']
        if len(frames)>1:
            assert len({f[5] for f in frames})>=3, (name,'animation does not move')
        for alias in aliases.get(name,[]):
            assert load(alias,size)==frames, (name,alias,size)
for name in ('zoom-in','zoom-out','copy','pencil'):
    assert load(name,21)==load(name,21,'Bibata-Modern-Ice'), (name,'inheritance')
assert load('hand2',21)[0][5]==load('hand2',21,'Bibata-Modern-Ice-MiddleFinger')[0][5]
for path,digest in json.loads((ROOT/'previous-pack.sha256.json').read_text()).items():
    assert hashlib.sha256((ROOT.parent/path).read_bytes()).hexdigest()==digest, ('previous pack changed',path)
print(f'PASS: {len(manifest)} roles at all 15 sizes, aliases, animation frames/timing, hotspots, inheritance, preserved link artwork and byte-identical previous pack.')
