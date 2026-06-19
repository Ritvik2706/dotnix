#!/usr/bin/env python3
"""Diagnostic v2: scan ALL readable input devices, find which one emits your
keystrokes. Run it, press keys (A S D space) for 8 seconds, paste output."""
import time, selectors, evdev
from openrazer_daemon.keyboard import EVENT_MAPPING, KEY_MAPPING

code_map = {c: KEY_MAPPING[n] for c, n in EVENT_MAPPING.items() if n in KEY_MAPPING}
sel = selectors.DefaultSelector()
opened = []
for path in evdev.list_devices():
    try:
        d = evdev.InputDevice(path)
    except OSError:
        continue
    caps = d.capabilities()
    if evdev.ecodes.KEY_A in caps.get(evdev.ecodes.EV_KEY, []):  # a real keyboard?
        sel.register(d, selectors.EVENT_READ)
        opened.append(f"{path}  name={d.name!r}")

print("keyboards I can read:")
for o in opened:
    print("  ", o)
print(">>> PRESS SOME KEYS NOW (8 seconds)...")
end, got = time.time() + 8, 0
while time.time() < end:
    for k, _ in sel.select(timeout=0.5):
        for ev in k.fileobj.read():
            if ev.type == evdev.ecodes.EV_KEY and ev.value == 1:
                got += 1
                print(f"  [{k.fileobj.path}] {evdev.ecodes.KEY.get(ev.code)} "
                      f"(code {ev.code}) -> matrix {code_map.get(ev.code)}")
print(f">>> captured {got} keydowns")
