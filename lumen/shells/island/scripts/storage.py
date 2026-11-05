#!/usr/bin/env python3
"""storage.py — the island's Storage page: where the disk went, and what can go.

Prints JSON for island.luau (one object per call):

  scan                 the disk, the categories it is used by, and the clean-ups
  ls PATH              the biggest things in one folder (for drilling down)
  details ID           what a clean-up would remove, said in full (the review)
  clean ID             does it; root ones through pkexec (lumen is the polkit agent)
  trash PATH           moves one thing in your home to the Trash (reversible)
  big                  the biggest files in your home (100 MB and up), newest scan each time

Sizes are disk usage (what deleting frees), measured with gdu: the whole home
in a fraction of a second, so the page rescans every time it opens. What the
scan cannot see —btrfs snapshots, metadata— is the used space left over, shown
as its own category.

Nothing here deletes anything a person did not press for, and every clean-up
only touches what can be made again (caches, logs, old package files) or what
the system already meant to remove (snapshots past snapper's own limits,
packages nothing needs). Old downloads go to the Trash, not away.
"""

import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

HOME = os.path.expanduser("~")
PKG = "/var/cache/pacman/pkg"
SNAP = "/.snapshots"
JOURNAL = "/var/log/journal"
COREDUMP = "/var/lib/systemd/coredump"
TRASH = f"{HOME}/.local/share/Trash"
OLD_DAYS = 90
JOURNAL_KEEP = 200 * 1024**2

# Category colours, by index into the page's palette (pages/storage.plm `hue`).
BLUE, PURPLE, ORANGE, GREEN, PINK, TEAL, YELLOW, INDIGO, BROWN, GREY = range(10)


def out(obj):
    print(json.dumps(obj, separators=(",", ":")))


def human(n, approx=False):
    n = max(0, int(n))
    pre = "≈ " if approx else ""
    for unit, size in (("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3)):
        if n >= size:
            v = n / size
            s = f"{v:.1f}".removesuffix(".0") if v < 100 else f"{v:.0f}"
            return f"{pre}{s} {unit}"
    return f"{pre}{n} B"


def home(p):
    return "~" + p[len(HOME):] if p == HOME or p.startswith(HOME + "/") else p


SIZES = {}   # every path any gdu call has measured: one scan answers many questions
DIRS = set()
LISTED = {}


def gdu(path):
    """{child path: bytes} for one folder (files and folders), biggest first.
    gdu's lines: a flag (`.` some of it unreadable, `@` a symlink or special file),
    the size, and the name, with a `/` in front if it is a folder. Symlinks are
    left out: deleting one frees nothing and drilling into one leaves the disk."""
    path = os.path.abspath(path)
    if path in LISTED:
        return LISTED[path]
    kids = {}
    if os.path.isdir(path):
        try:
            r = subprocess.run(["gdu", "-n", "-p", "-x", "--no-prefix", path], capture_output=True, text=True, timeout=120)
            lines = r.stdout.splitlines()
        except (OSError, subprocess.TimeoutExpired):
            lines = []
        for line in lines:
            m = re.match(r"^(.)\s*(\d+) (/?)(.*)$", line)
            if not m or m.group(1) == "@":
                continue
            p = os.path.join(path, m.group(4))
            kids[p] = SIZES[p] = int(m.group(2))
            if m.group(3):
                DIRS.add(p)
    LISTED[path] = kids
    SIZES[path] = sum(kids.values())
    return kids


def size_of(path):
    path = os.path.abspath(path)
    if path in SIZES:
        return SIZES[path]
    if os.path.islink(path):
        return 0
    if os.path.isfile(path):
        try:
            return os.lstat(path).st_blocks * 512
        except OSError:
            return 0
    gdu(path)
    return SIZES[path]


def disk():
    s = os.statvfs("/")
    total = s.f_blocks * s.f_frsize
    free = s.f_bavail * s.f_frsize
    return total, total - s.f_bfree * s.f_frsize, free


def is_dir(p):
    if p in DIRS:
        return True
    try:
        return stat.S_ISDIR(os.lstat(p).st_mode)
    except OSError:
        return False


# --- where it went -------------------------------------------------------

def categories():
    """[(id, name, sub, hue, [(path, bytes)…])], each member a real path to drill into."""
    root = gdu("/")
    var = {p: b for p, b in root.items() if p == "/var"}
    system = [(p, b) for p, b in root.items() if p != "/var"]
    logs = list(var.items()) + [("/var/log", sum(gdu("/var/log").values()))]
    pkg = [(PKG, sum(gdu(PKG).values()))]

    h = gdu(HOME)
    share = gdu(f"{HOME}/.local/share")
    local = gdu(f"{HOME}/.local")
    varapp = gdu(f"{HOME}/.var/app")
    taken = set()

    def take(*paths):
        got = []
        for p in paths:
            for src in (h, share, local, varapp):
                if p in src and p not in taken:
                    got.append((p, src[p]))
                    taken.add(p)
                    break
        return got

    games = take(f"{HOME}/Games", f"{HOME}/.local/share/Steam", f"{HOME}/.local/share/lutris",
                 f"{HOME}/.local/share/heroic", f"{HOME}/.var/app/com.usebottles.bottles",
                 f"{HOME}/.var/app/com.valvesoftware.Steam", f"{HOME}/.config/heroic")
    trash = take(TRASH)
    caches = take(f"{HOME}/.cache")
    downloads = take(f"{HOME}/Downloads")
    code = take(f"{HOME}/github", f"{HOME}/.cargo", f"{HOME}/.rustup", f"{HOME}/.npm", f"{HOME}/go",
                f"{HOME}/.pub-cache", f"{HOME}/.local/share/pnpm", f"{HOME}/.gradle", f"{HOME}/.m2",
                f"{HOME}/.bun", f"{HOME}/.nvm", f"{HOME}/.cache/go-build")
    # .local and .var stand for what is left in them once the ones above are taken.
    taken.update({f"{HOME}/.local", f"{HOME}/.var", f"{HOME}/.local/share", f"{HOME}/.var/app"})
    files, apps = [], []
    for p, b in h.items():
        if p in taken:
            continue
        (apps if os.path.basename(p).startswith(".") else files).append((p, b))
    for src in (share, local, varapp):
        for p, b in src.items():
            if p not in taken:
                apps.append((p, b))
                taken.add(p)

    cats = [
        ("files", "Your files", "Documents, pictures, projects", BLUE, files),
        ("games", "Games", "Steam, Bottles, ~/Games", PURPLE, games),
        ("code", "Code & toolchains", "Repos, cargo, npm, go", GREEN, code),
        ("apps", "App data", "Settings and data apps keep", TEAL, apps),
        ("caches", "Caches", "~/.cache — apps rebuild these", ORANGE, caches),
        ("trash", "Trash", "Deleted, not emptied", PINK, trash),
        ("downloads", "Downloads", "~/Downloads", YELLOW, downloads),
        ("pkg", "Package cache", "Old pacman downloads", INDIGO, pkg),
        ("system", "System", "Installed programs (/usr, /opt)", BROWN, system),
        ("logs", "Logs & system data", "/var", GREY, logs),
    ]
    return [(i, n, s, c, sorted(m, key=lambda x: -x[1])) for i, n, s, c, m in cats]


# --- what can go ---------------------------------------------------------

def pkg_removable():
    """Cached package files past the newest two of each installed package, and every
    file of packages no longer installed (paccache -rk2 + -ruk0, without needing it)."""
    try:
        names = os.listdir(PKG)
    except OSError:
        return [], 0
    r = subprocess.run(["pacman", "-Qq"], capture_output=True, text=True)
    installed = set(r.stdout.split())
    groups = {}
    drop = []
    for f in names:
        p = f"{PKG}/{f}"
        if f.startswith("download-") and is_dir(p):  # a download pacman never finished
            drop.append(p)
            continue
        m = re.match(r"^(.+)-([^-]+)-([^-]+)-([^-]+)\.pkg\.tar(\.[a-z0-9]+)?$", f)
        if m:
            try:
                groups.setdefault(m.group(1), []).append((os.lstat(p).st_mtime, p))
            except OSError:
                pass
    for name, files in groups.items():
        files.sort(reverse=True)
        keep = 2 if name in installed else 0
        for _, p in files[keep:]:
            drop.append(p)
            if os.path.exists(p + ".sig"):
                drop.append(p + ".sig")
    total = sum(size_of(p) for p in drop)
    return drop, total


def orphans():
    r = subprocess.run(["pacman", "-Qdtq"], capture_output=True, text=True)
    names = [n for n in r.stdout.split() if re.fullmatch(r"[A-Za-z0-9@._+-]+", n)]
    sizes = {}
    if names:
        q = subprocess.run(["pacman", "-Qi", *names], capture_output=True, text=True, env={**os.environ, "LC_ALL": "C"})
        cur = None
        for line in q.stdout.splitlines():
            if line.startswith("Name"):
                cur = line.split(":", 1)[1].strip()
            elif line.startswith("Installed Size") and cur:
                v, unit = line.split(":", 1)[1].split()
                mult = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3}.get(unit, 1)
                sizes[cur] = int(float(v) * mult)
    return names, sizes


def snapshots():
    try:
        nums = sorted(int(d) for d in os.listdir(SNAP) if d.isdigit())
    except OSError:
        nums = []
    r = subprocess.run(["systemctl", "is-enabled", "snapper-cleanup.timer"], capture_output=True, text=True)
    timer = r.stdout.strip() == "enabled"
    limits = {}
    try:
        with open("/etc/snapper/configs/root") as f:
            for line in f:
                m = re.match(r'^(NUMBER_LIMIT|TIMELINE_LIMIT_\w+)="?([^"\n]*)"?', line)
                if m:
                    limits[m.group(1)] = m.group(2)
    except OSError:
        pass
    keep = 0
    for k, v in limits.items():
        try:
            keep += int(v.split("-")[-1])
        except ValueError:
            pass
    return nums, timer, keep


def dev_caches():
    paths = [f"{HOME}/.cache/go-build", f"{HOME}/.npm/_cacache", f"{HOME}/.cargo/registry/cache",
             f"{HOME}/.cache/pip", f"{HOME}/.cache/yarn", f"{HOME}/.cache/electron", f"{HOME}/.cache/node-gyp",
             f"{HOME}/.cache/typescript", f"{HOME}/.cache/ms-playwright", f"{HOME}/.bun/install/cache"]
    return [(p, size_of(p)) for p in paths if os.path.isdir(p)]


def old_downloads():
    d = f"{HOME}/Downloads"
    cut = time.time() - OLD_DAYS * 86400
    items = []
    try:
        for e in os.scandir(d):
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            newest = max(st.st_mtime, st.st_atime if e.is_file(follow_symlinks=False) else 0)
            if e.is_dir(follow_symlinks=False):
                # A folder is old only if nothing in it was touched since.
                for root, _dirs, fs in os.walk(e.path):
                    for f in fs[:200]:
                        try:
                            newest = max(newest, os.lstat(os.path.join(root, f)).st_mtime)
                        except OSError:
                            pass
                    if newest >= cut:
                        break
            if newest < cut:
                items.append((e.path, size_of(e.path), newest))
    except OSError:
        pass
    return sorted(items, key=lambda x: -x[1])


def cleanups(hidden):
    """[{id, name, sub, bytes, approx, root, kind}] — only the ones with something in them."""
    items = []
    t = size_of(TRASH)
    items.append(dict(id="trash", name="Empty the Trash", sub="Files you already deleted", bytes=t, root=False))
    drop, pb = pkg_removable()
    items.append(dict(id="pkg", name="Old package files", sub=f"{len(drop)} files · keeps the newest 2 of each", bytes=pb, root=True))
    paru = [p for p in (f"{HOME}/.cache/paru/clone", f"{HOME}/.cache/yay") if os.path.isdir(p)]
    items.append(dict(id="aur", name="AUR build files", sub="paru's sources and builds", bytes=sum(size_of(p) for p in paru), root=False))
    nums, timer, keep = snapshots()
    extra = max(0, len(nums) - keep)
    snap_sub = f"{len(nums)} snapshots" + ("" if timer else " · cleanup was never on")
    items.append(dict(id="snap", name="Old snapshots", sub=snap_sub, bytes=hidden if extra else 0, approx=True, root=True, count=extra))
    names, sizes = orphans()
    items.append(dict(id="orphans", name="Unused packages", sub=f"{len(names)} installed as a dependency of nothing", bytes=sum(sizes.values()), root=True))
    j = size_of(JOURNAL)
    items.append(dict(id="journal", name="System logs", sub="journald · keeps the last 200 MB", bytes=max(0, j - JOURNAL_KEEP), root=True))
    c = size_of(COREDUMP)
    items.append(dict(id="cores", name="Crash dumps", sub="systemd-coredump", bytes=c, root=True))
    dc = dev_caches()
    items.append(dict(id="dev", name="Developer caches", sub="go, npm, cargo, pip… downloaded again", bytes=sum(b for _, b in dc), root=False))
    th = size_of(f"{HOME}/.cache/thumbnails")
    items.append(dict(id="thumbs", name="Thumbnails", sub="Remade when folders are opened", bytes=th, root=False))
    od = old_downloads()
    items.append(dict(id="olddl", name="Old downloads", sub=f"Untouched {OLD_DAYS}+ days · go to the Trash", bytes=sum(b for _, b, _ in od), root=False))
    for it in items:
        it.setdefault("approx", False)
        it["size"] = human(it["bytes"], it["approx"])
    return [it for it in items if it["bytes"] > 0 or it.get("count")]


def scan():
    total, used, free = disk()
    cats = categories()
    seen = sum(b for *_, m in cats for _, b in m)
    hidden = max(0, used - seen)
    rows = []
    for cid, name, sub, hue, members in cats:
        b = sum(x for _, x in members)
        if b <= 0:
            continue
        rows.append(dict(id=cid, name=name, sub=sub, hue=hue, bytes=b, size=human(b),
                         members=[dict(name=os.path.basename(p) or p, path=p, bytes=x, size=human(x), dir=is_dir(p), trash=can_trash(p)) for p, x in members[:60]]))
    rows.sort(key=lambda r: -r["bytes"])
    if hidden > 1e9:
        rows.append(dict(id="hidden", name="Snapshots & other", sub="What a scan can't see (needs root)", hue=10, bytes=hidden, size=human(hidden), members=[]))
    clean = cleanups(hidden)
    out(dict(total=total, used=used, free=free, total_h=human(total), used_h=human(used), free_h=human(free),
             cats=rows, clean=clean, can_free=human(sum(c["bytes"] for c in clean if not c.get("approx"))),
             at=int(time.time())))


def ls(path):
    path = os.path.abspath(path)
    kids = gdu(path)
    items = [dict(name=os.path.basename(p), path=p, bytes=b, size=human(b), dir=is_dir(p), trash=can_trash(p)) for p, b in list(kids.items())[:80]]
    out(dict(path=path, shown=home(path), bytes=sum(kids.values()), size=human(sum(kids.values())), items=items))


def ago(t):
    d = max(0, time.time() - t)
    for unit, secs in (("year", 31536000), ("month", 2592000), ("week", 604800), ("day", 86400)):
        if d >= secs:
            n = int(d // secs)
            return f"{n} {unit}{'s' if n > 1 else ''} ago"
    return "today"


def big():
    """Files of 100 MB and more anywhere in your home (not the Trash: that is a clean-up
    of its own), biggest first. find does it in a fraction of a second."""
    r = subprocess.run(["find", HOME, "-xdev", "-type", "f", "-size", "+100M", "-not", "-path", f"{TRASH}/*",
                        "-printf", r"%b\t%T@\t%p\n"], capture_output=True, text=True, timeout=120)
    files = []
    for line in r.stdout.splitlines():
        try:
            blocks, mtime, path = line.split("\t", 2)
            files.append((int(blocks) * 512, float(mtime), path))
        except ValueError:
            continue
    files.sort(key=lambda x: -x[0])
    items = [dict(name=os.path.basename(p), path=p, dir_path=os.path.dirname(p), bytes=b, size=human(b),
                  sub=f"{home(os.path.dirname(p))} · {ago(t)}", trash=can_trash(p)) for b, t, p in files[:80]]
    out(dict(items=items, total=human(sum(b for b, _, _ in files)), count=len(files)))


# --- the review ------------------------------------------------------------

def details(cid):
    lines, title, about, button = [], "", "", "Clean up"
    if cid == "trash":
        title, about = "Empty the Trash", "Removes everything in the Trash for good. This can't be undone."
        kids = gdu(f"{TRASH}/files")
        lines = [f"{human(b):>9}   {os.path.basename(p)}" for p, b in list(kids.items())[:40]]
        button = "Empty Trash"
    elif cid == "pkg":
        drop, b = pkg_removable()
        title = "Old package files"
        about = ("Pacman keeps every version it ever downloaded. This keeps the newest two of each "
                 "installed package (enough to roll back once) and removes the rest, plus files of "
                 "packages you no longer have. Asks for your password.")
        lines = [f"{human(size_of(p)):>9}   {os.path.basename(p)}" for p in sorted(drop, key=lambda p: -size_of(p))[:40] if not p.endswith(".sig")]
        if len(drop) > 40:
            lines.append(f"            … and {len(drop) - 40} more")
    elif cid == "aur":
        title, about = "AUR build files", "paru keeps the source and build of every AUR package after installing it. They're fetched again on the next update."
        for p in (f"{HOME}/.cache/paru/clone", f"{HOME}/.cache/yay"):
            lines += [f"{human(b):>9}   {os.path.basename(q)}" for q, b in list(gdu(p).items())[:40]]
    elif cid == "snap":
        nums, timer, keep = snapshots()
        title = "Old snapshots"
        about = (f"Snapper is set to keep about {keep} snapshots of / (your numbered and timeline limits), "
                 + ("" if timer else "but its cleanup timer was never turned on, so none were ever removed. ")
                 + "This runs snapper's own cleanup to bring them back to those limits"
                 + ("" if timer else ", and turns the cleanup timer on so it stays that way")
                 + ". Asks for your password. btrfs frees the space over a few minutes.")
        if nums:
            lines = [f"{len(nums)} snapshots, #{nums[0]} – #{nums[-1]}",
                     f"about {max(0, len(nums) - keep)} past the limits",
                     "the size is a guess: only root can measure snapshots"]
        button = "Clean up snapshots"
    elif cid == "orphans":
        names, sizes = orphans()
        title = "Unused packages"
        about = ("Packages installed only as a dependency of something you've since removed. "
                 "Check the list: if you use one directly, keep it (pacman -D --asexplicit NAME). Asks for your password.")
        lines = [f"{human(sizes.get(n, 0)):>9}   {n}" for n in sorted(names, key=lambda n: -sizes.get(n, 0))]
        button = "Remove packages"
    elif cid == "journal":
        title, about = "System logs", "systemd's journal. Keeps the newest 200 MB and removes older logs. Asks for your password."
        lines = [f"{human(size_of(JOURNAL)):>9}   {JOURNAL}"]
    elif cid == "cores":
        title, about = "Crash dumps", "Memory dumps systemd saved when programs crashed. Only useful for debugging those crashes. Asks for your password."
        try:
            fs = sorted(os.scandir(COREDUMP), key=lambda e: -e.stat().st_size)
            lines = [f"{human(e.stat().st_blocks * 512):>9}   {e.name.split('.')[1] if e.name.count('.') > 1 else e.name}" for e in fs[:40]]
        except OSError:
            pass
    elif cid == "dev":
        title, about = "Developer caches", "Packages and build output toolchains keep to go faster. They download or rebuild again when needed."
        lines = [f"{human(b):>9}   {home(p)}" for p, b in sorted(dev_caches(), key=lambda x: -x[1])]
    elif cid == "thumbs":
        title, about = "Thumbnails", "Small previews file managers made. They're made again as you browse."
        lines = [f"{human(size_of(f'{HOME}/.cache/thumbnails')):>9}   ~/.cache/thumbnails"]
    elif cid == "olddl":
        title = "Old downloads"
        about = (f"Things in Downloads nobody has touched for {OLD_DAYS} days. They go to the Trash, so you can "
                 "still get them back; empty the Trash to free the space.")
        lines = [f"{human(b):>9}   {os.path.basename(p)}   ({time.strftime('%b %Y', time.localtime(t))})" for p, b, t in old_downloads()[:40]]
        button = "Move to Trash"
    out(dict(id=cid, title=title, about=about, text="\n".join(lines) or "Nothing to show.", button=button))


# --- doing it ----------------------------------------------------------------

def rm_tree_contents(d):
    if not os.path.isdir(d):
        return
    for e in os.scandir(d):
        try:
            if e.is_dir(follow_symlinks=False):
                shutil.rmtree(e.path, ignore_errors=True)
            else:
                os.unlink(e.path)
        except OSError:
            pass


def as_root(script, *args):
    """One password prompt for the whole job: pkexec on a fixed shell script."""
    r = subprocess.run(["pkexec", "/bin/sh", "-c", script, "sh", *args], capture_output=True, text=True)
    if r.returncode in (126, 127):
        raise PermissionError("Cancelled" if r.returncode == 126 else "No password prompt available")
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip().splitlines()[-1] if (r.stderr or r.stdout).strip() else f"exit {r.returncode}")


def clean(cid):
    before = disk()[2]
    msg = None
    if cid == "trash":
        rm_tree_contents(f"{TRASH}/files")
        rm_tree_contents(f"{TRASH}/info")
        rm_tree_contents(f"{TRASH}/expunged")
    elif cid == "aur":
        rm_tree_contents(f"{HOME}/.cache/paru/clone")
        rm_tree_contents(f"{HOME}/.cache/yay")
    elif cid == "dev":
        for p, _ in dev_caches():
            rm_tree_contents(p)
    elif cid == "thumbs":
        rm_tree_contents(f"{HOME}/.cache/thumbnails")
    elif cid == "olddl":
        items = old_downloads()
        for p, _, _ in items:
            subprocess.run(["gio", "trash", p], capture_output=True)
        msg = f"Moved {len(items)} to the Trash"
    elif cid == "pkg":
        drop, _ = pkg_removable()
        drop = [p for p in drop if os.path.dirname(p) == PKG]
        if drop:
            with tempfile.NamedTemporaryFile("w", delete=False, prefix="storage-pkg-", suffix=".list") as f:
                f.write("\0".join(drop))
                lst = f.name
            os.chmod(lst, 0o644)
            try:
                as_root('cd /var/cache/pacman/pkg && xargs -0 rm -rf -- < "$1"', lst)
            finally:
                os.unlink(lst)
    elif cid == "snap":
        as_root("snapper -c root cleanup number; snapper -c root cleanup timeline; "
                "systemctl enable --now snapper-cleanup.timer")
        msg = "Snapshots cleaned up · btrfs is freeing the space"
    elif cid == "orphans":
        names, _ = orphans()
        if names:
            as_root('pacman -Rns --noconfirm -- "$@"', *names)
    elif cid == "journal":
        as_root("journalctl --vacuum-size=200M")
    elif cid == "cores":
        as_root("rm -f /var/lib/systemd/coredump/*")
    else:
        raise ValueError(f"unknown clean-up {cid}")
    freed = max(0, disk()[2] - before)
    out(dict(ok=True, id=cid, freed=freed, msg=msg or (f"Freed {human(freed)}" if freed else "Done")))


PROTECTED = {HOME, f"{HOME}/.config", f"{HOME}/.local", f"{HOME}/.local/share", f"{HOME}/.cache", f"{HOME}/.ssh",
             f"{HOME}/.gnupg", f"{HOME}/github", f"{HOME}/github/config", f"{HOME}/github/config/dotnix",
             f"{HOME}/.var", f"{HOME}/.var/app", TRASH}


def can_trash(p):
    p = os.path.abspath(p)
    return p.startswith(HOME + "/") and p not in PROTECTED and not p.startswith(TRASH + "/")


def trash(p):
    p = os.path.abspath(p)
    if not can_trash(p) or not os.path.lexists(p):
        raise ValueError("Can't move that to the Trash")
    b = size_of(p)
    r = subprocess.run(["gio", "trash", p], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "gio trash failed")
    out(dict(ok=True, freed=0, msg=f"Moved {os.path.basename(p)} ({human(b)}) to the Trash"))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd, arg = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
    try:
        if cmd == "scan":
            scan()
        elif cmd == "ls":
            ls(arg)
        elif cmd == "details":
            details(arg)
        elif cmd == "clean":
            clean(arg)
        elif cmd == "trash":
            trash(arg)
        elif cmd == "big":
            big()
        else:
            raise ValueError(f"unknown command {cmd}")
    except Exception as e:
        out(dict(ok=False, msg=str(e) or type(e).__name__))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
