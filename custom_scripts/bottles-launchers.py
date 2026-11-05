#!/usr/bin/env python3
"""bottles-launchers — every program in every Bottles bottle, as a launcher entry.

Bottles (Flatpak) can make desktop entries itself, but only one by one and
through the DynamicLauncher portal, into a folder the lumen launcher does not
read. This keeps ~/.local/share/applications in step with Bottles instead:

  * one `bottles-<bottle>-<program id>.desktop` per program in a bottle's
    Programs list, launching it through bottles-cli (so the bottle's runner,
    DXVK, discrete GPU etc. all apply, exactly as the ▶ button in Bottles);
  * the icon taken out of the program's .exe, as a PNG (lumen reads svg/png);
  * StartupWMClass = the exe's name, which is the class its window has under
    xwayland-satellite, so lumen can tell the game's window is that app;
  * entries for programs or bottles that are gone get removed.

It runs as a user service (system/systemd/bottles-launchers.service) and
sleeps on inotify: it wakes only when a bottle is added/removed or a bottle's
bottle.yml is written, then syncs once after the burst settles. Run it with
--once to sync and exit.
"""

import ctypes
import io
import json
import os
import re
import select
import struct
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
BOTTLES = f"{HOME}/.var/app/com.usebottles.bottles/data/bottles/bottles"
APPS = f"{HOME}/.local/share/applications"
ICONS = f"{HOME}/.local/share/bottles-launchers/icons"
PREFIX = "bottles-"
MARK = "X-Bottles-Launcher=true"
CLI = ["flatpak", "run", "--command=bottles-cli", "com.usebottles.bottles"]
SETTLE = 1.5  # seconds of quiet before syncing after a change


def log(*a):
    print(*a, flush=True)


def slug(s):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", s).strip("_") or "bottle"


def exec_arg(s):
    """One argument of a desktop Exec= line (quoted per the spec)."""
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("`", "\\`").replace("$", "\\$")
    return '"' + s.replace("%", "%%") + '"'


def value(s):
    """A desktop-file string value: no newlines."""
    return " ".join(str(s).split())


# --- the icon inside a Windows .exe --------------------------------------

RT_ICON, RT_GROUP_ICON = 3, 14


def pe_resources(data):
    """{(type, name): [bytes, ...]} for the RT_ICON / RT_GROUP_ICON resources."""
    if data[:2] != b"MZ":
        return {}
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        return {}
    nsec, optsize = struct.unpack_from("<xxHxxxxxxxxxxxxH", data, pe + 4)
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    ddir = opt + (96 if magic == 0x10B else 112)
    rva, _size = struct.unpack_from("<II", data, ddir + 2 * 8)  # resource table
    if not rva:
        return {}
    sections = []
    for i in range(nsec):
        s = opt + optsize + 40 * i
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", data, s + 8)
        sections.append((vaddr, max(vsize, rsize), raddr))

    def off(r):
        for vaddr, size, raddr in sections:
            if vaddr <= r < vaddr + size:
                return r - vaddr + raddr
        raise ValueError("rva outside sections")

    base = off(rva)

    def entries(d):
        named, ids = struct.unpack_from("<HH", data, d + 12)
        for i in range(named + ids):
            name, ptr = struct.unpack_from("<II", data, d + 16 + 8 * i)
            yield name, ptr

    out = {}
    for typ, p1 in entries(base):
        if typ not in (RT_ICON, RT_GROUP_ICON) or not p1 & 0x80000000:
            continue
        for name, p2 in entries(base + (p1 & 0x7FFFFFFF)):
            if not p2 & 0x80000000:
                continue
            for _lang, p3 in entries(base + (p2 & 0x7FFFFFFF)):
                if p3 & 0x80000000:
                    continue
                drva, dsize = struct.unpack_from("<II", data, base + p3)
                o = off(drva)
                out.setdefault((typ, name), []).append(data[o:o + dsize])
    return out


def exe_icon_png(exe, dest):
    """Write the exe's biggest icon to dest as PNG; True if it did."""
    try:
        from PIL import Image
        with open(exe, "rb") as f:
            res = pe_resources(f.read())
        groups = sorted(k for k in res if k[0] == RT_GROUP_ICON)
        if not groups:
            return False
        grp = res[groups[0]][0]
        _, _, count = struct.unpack_from("<HHH", grp, 0)
        best = None
        for i in range(count):
            w, h, colors, _r, planes, bits, size, iid = struct.unpack_from("<BBBBHHIH", grp, 6 + 14 * i)
            img = res.get((RT_ICON, iid), [None])[0]
            if img is None:
                continue
            key = ((w or 256) * (h or 256), bits)
            if best is None or key > best[0]:
                best = (key, (w, h, colors, planes, bits, img))
        if best is None:
            return False
        w, h, colors, planes, bits, img = best[1]
        ico = struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", w, h, colors, 0, planes, bits, len(img), 22) + img
        im = Image.open(io.BytesIO(ico))
        im.load()
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        tmp = dest + ".tmp"
        im.convert("RGBA").save(tmp, "PNG")
        os.replace(tmp, dest)
        return True
    except Exception as e:  # a missing or odd icon never stops the sync
        log(f"icon: {exe}: {e}")
        return False


def icon_for(program_id, exe):
    dest = f"{ICONS}/{program_id}.png"
    try:
        if os.path.getmtime(dest) >= os.path.getmtime(exe):
            return dest
    except OSError:
        pass
    return dest if exe_icon_png(exe, dest) else "applications-games"


# --- the sync -------------------------------------------------------------

def bottles():
    r = subprocess.run(CLI + ["-j", "list", "bottles"], capture_output=True, text=True, timeout=120)
    line = next((l for l in r.stdout.splitlines() if l.startswith("{")), None)
    if r.returncode != 0 or line is None:
        raise RuntimeError(f"bottles-cli failed ({r.returncode}): {r.stderr.strip()[-300:]}")
    return json.loads(line)


def entry(bottle, prog):
    exe = prog.get("path") or ""
    exe_name = os.path.basename(exe.replace("\\", "/"))
    lines = [
        "[Desktop Entry]",
        "Type=Application",
        f"Name={value(prog.get('name') or exe_name)}",
        f"Comment={value(f'{bottle} bottle (Bottles)')}",
        "Exec=" + " ".join(exec_arg(a) for a in CLI + ["run", "-b", bottle, "--program-id", prog["id"]]),
        f"Icon={icon_for(prog['id'], exe) if os.path.isfile(exe) else 'applications-games'}",
        "Categories=Game;",
        "Terminal=false",
    ]
    if exe_name:
        lines.append(f"StartupWMClass={value(exe_name)}")
    lines.append(MARK)
    return "\n".join(lines) + "\n"


def sync():
    want = {}
    for bname, conf in bottles().items():
        for pid, prog in (conf.get("External_Programs") or {}).items():
            if prog.get("removed"):
                continue
            prog = dict(prog, id=prog.get("id") or pid)
            want[f"{PREFIX}{slug(bname)}-{slug(prog['id'])}.desktop"] = entry(bname, prog)

    os.makedirs(APPS, exist_ok=True)
    changed = 0
    for fname, text in want.items():
        path = f"{APPS}/{fname}"
        try:
            with open(path) as f:
                if f.read() == text:
                    continue
        except OSError:
            pass
        tmp = f"{APPS}/.{fname}.tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, path)  # one rename: the launcher never reads half a file
        changed += 1
        log(f"wrote {fname}")
    for fname in os.listdir(APPS):
        if fname.startswith(PREFIX) and fname.endswith(".desktop") and fname not in want:
            path = f"{APPS}/{fname}"
            try:
                with open(path) as f:
                    ours = MARK in f.read()
            except OSError:
                continue
            if ours:  # only ever remove entries this script made
                os.remove(path)
                changed += 1
                log(f"removed {fname}")
    # Icons of programs that are gone.
    keep = {re.search(r"--program-id\" \"([^\"]+)\"", t).group(1) for t in want.values()}
    if os.path.isdir(ICONS):
        for icon in os.listdir(ICONS):
            if icon.endswith(".png") and icon[:-4] not in keep:
                os.remove(f"{ICONS}/{icon}")
    log(f"synced: {len(want)} program(s), {changed} change(s)")


# --- inotify --------------------------------------------------------------

IN_CLOSE_WRITE, IN_MOVED_FROM, IN_MOVED_TO = 0x8, 0x40, 0x80
IN_CREATE, IN_DELETE, IN_DELETE_SELF, IN_ONLYDIR = 0x100, 0x200, 0x400, 0x01000000
IN_CLOEXEC = 0o2000000


class Watch:
    def __init__(self):
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.fd = self.libc.inotify_init1(IN_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        self.top = None
        self.dirs = {}  # wd -> bottle dir

    def add(self, path, mask):
        return self.libc.inotify_add_watch(self.fd, os.fsencode(path), mask | IN_ONLYDIR)

    def rewatch(self):
        """Watch the bottles folder (bottles come and go) and each bottle's own
        folder (its bottle.yml is rewritten). Not recursive: drive_c is huge."""
        os.makedirs(BOTTLES, exist_ok=True)
        self.top = self.add(BOTTLES, IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO)
        for name in os.listdir(BOTTLES):
            d = f"{BOTTLES}/{name}"
            if os.path.isdir(d):
                wd = self.add(d, IN_CLOSE_WRITE | IN_MOVED_TO | IN_DELETE_SELF)
                if wd >= 0:
                    self.dirs[wd] = d

    def relevant(self, buf):
        """True if any event in buf could change the programs list."""
        hit, i = False, 0
        while i + 16 <= len(buf):
            wd, mask, _cookie, length = struct.unpack_from("<iIII", buf, i)
            name = buf[i + 16:i + 16 + length].rstrip(b"\0").decode(errors="replace")
            i += 16 + length
            if wd == self.top or mask & IN_DELETE_SELF or name == "bottle.yml":
                hit = True
        return hit

    def wait(self, timeout=None):
        r, _, _ = select.select([self.fd], [], [], timeout)
        return os.read(self.fd, 65536) if r else None


def main():
    if "--once" in sys.argv:
        sync()
        return
    w = Watch()
    w.rewatch()
    try:
        sync()
    except Exception as e:
        log(f"sync failed: {e}")
    while True:
        buf = w.wait()
        if not buf or not w.relevant(buf):
            continue
        while w.wait(SETTLE):  # let a burst of writes settle
            pass
        w.rewatch()
        try:
            sync()
        except Exception as e:
            log(f"sync failed: {e}")


if __name__ == "__main__":
    main()
