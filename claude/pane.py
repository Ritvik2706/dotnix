#!/usr/bin/env python3
"""claude/pane.py — a live window beside Claude Code: watch it code.

Opened as column 2 of the terminal workspace by claude/pane-toggle.sh
(Mod+Shift+D). Fed by claude/hooks/activity.py, which logs every tool call to
$XDG_RUNTIME_DIR/claude-pane/<session>.jsonl and pings this pane's socket.

Two views (Tab switches):
  Live     the file Claude is working on, like an editor beside you that
           reads as a diff: it opens what Claude reads (a highlight sweeps
           the lines read) and replays each edit — the old text is selected
           in red and lifts into red "removed" rows, the new code types in on
           green. The latest edit per file stays shown that way; older ones
           leave gutter marks. A terminal card shows commands and output.
  Changes  the diff log: every file changed this session with +/- counts,
           recent activity and the full diff (word-level highlights).

Several Claudes: each session keeps its own state. The pane shows the Claude
in the tmux pane you're focused on (a tmux hook reports focus changes; see
tmux/tmux.conf), else the one that acted last. Only the shown session
animates and holds highlighted text; the others just keep their latest
state, and a session's log is only read in full when you look at it.

Cost: no timers when nothing is happening (it sleeps in select() until a
ping, key or resize). Frames run at 30 fps only while something moves.

Look: dotnix glass. Chips and rounded caps like the tmux bar, colours from
the wallpaper theme (ghostty/wall-colours + the tmux theme cache), code
highlighted by `bat --theme ansi` (follows the palette).

Keys: Tab view · f / Esc follow again (after scrolling) · j/k, wheel scroll
· ^d/^u · g/G · n/p file (Changes) · a activity (Changes) · click a tab or
file · q quit
"""
import bisect
import difflib
import json
import math
import os
import re
import select
import signal
import socket
import subprocess
import sys
import termios
import time
import tty
import unicodedata
from collections import OrderedDict, deque

HERE = os.path.dirname(os.path.realpath(__file__))
DOTNIX = os.path.dirname(HERE)
RUN = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "claude-pane")
WALL = [os.path.join(DOTNIX, "ghostty/wall-colours"), os.path.join(DOTNIX, "ghostty/ghostty-theme")]
TMUX_THEME = os.path.expanduser("~/.cache/lumen/term/tmux.conf")
EDIT_TOOLS = ("Edit", "MultiEdit", "Write", "NotebookEdit")
BINARY_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico", ".pdf", ".svgz",
              ".zip", ".gz", ".xz", ".mp4", ".mkv", ".webm", ".mp3", ".ogg", ".wav", ".ttf",
              ".otf", ".woff", ".woff2", ".so", ".o", ".pyc", ".ipynb")

FPS = 30
TYPE_BUDGET = 2.2     # s: an edit types out in about this long at most
FADE = 1.6            # s: freshly typed text glows this long
GHOST_MAX = 6         # removed rows shown per change (then "n more")
MAX_SESSIONS = 6      # sessions kept in memory (others re-read when shown)
MAX_TABS = 6
SESSION_MAX_AGE = 24 * 3600

# Nerd Font glyphs (private use): code points only, never raw glyphs here.
G = chr
CAP_L, CAP_R = G(0xE0B6), G(0xE0B4)
ICON_CLAUDE, ICON_BRANCH, ICON_DOTS = G(0xF069), G(0xE725), G(0xF141)
FILE_ICONS = {
    "rs": 0xE7A8, "py": 0xE606, "md": 0xE609, "sh": 0xE795, "zsh": 0xE795, "bash": 0xE795,
    "json": 0xE60B, "lua": 0xE620, "luau": 0xE620, "js": 0xE74E, "ts": 0xE628,
    "css": 0xE749, "html": 0xE736, "c": 0xE61E, "h": 0xE61E, "cpp": 0xE61D, "go": 0xE626,
    "nix": 0xF313, "glsl": 0xF1FC, "frag": 0xF1FC, "vert": 0xF1FC, "kdl": 0xF013,
    "toml": 0xF013, "yaml": 0xF013, "yml": 0xF013, "conf": 0xF013, "plm": 0xF1FC,
}
FILE_DEFAULT = 0xF15B
ACT = {  # tool -> (icon, colour role, verb)
    "Read": (0xF06E, "blue", "reading"), "Edit": (0xF040, "yellow", "editing"),
    "MultiEdit": (0xF040, "yellow", "editing"), "NotebookEdit": (0xF040, "yellow", "editing"),
    "Write": (0xF0F6, "green", "writing"), "Bash": (0xF120, "magenta", "running"),
    "Grep": (0xF002, "cyan", "searching"), "Glob": (0xF002, "cyan", "finding"),
    "WebFetch": (0xF0AC, "cyan", "fetching"), "WebSearch": (0xF0AC, "cyan", "searching the web"),
    "Agent": (0xF0E7, "magenta", "delegating"), "Task": (0xF0E7, "magenta", "delegating"),
    "Skill": (0xF0D0, "magenta", "using skill"),
}


def file_icon(path):
    name = os.path.basename(path or "")
    return G(FILE_ICONS.get(name.rsplit(".", 1)[-1].lower() if "." in name else "", FILE_DEFAULT))


# ── colours ─────────────────────────────────────────────────────────────────
def hex2rgb(h):
    h = h.strip().lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


class Theme:
    def __init__(self):
        self.stamp = None
        self.reload()

    def reload(self):
        stamp = []
        for p in WALL + [TMUX_THEME]:
            try:
                stamp.append(os.path.getmtime(p))
            except OSError:
                stamp.append(0)
        if stamp == self.stamp:
            return
        self.stamp = stamp
        pal = dict(enumerate(
            ["070a0e", "f16c75", "37f499", "f7c67f", "7081d0", "fca6ff", "04d1f9", "b7bfce",
             "646477", "f16c75", "37f499", "f7c67f", "7081d0", "fca6ff", "04d1f9", "ebfafa"]))
        bg, fg, cur = "070a0e", "ebfafa", "f94dff"
        for path in reversed(WALL):  # wall-colours wins
            try:
                text = open(path).read()
            except OSError:
                continue
            for m in re.finditer(r"^palette\s*=\s*(\d+)=#?([0-9a-fA-F]{6})", text, re.M):
                pal[int(m[1])] = m[2]
            for key, val in re.findall(
                    r"^(background|foreground|cursor-color)\s*=\s*#?([0-9a-fA-F]{6})", text, re.M):
                if key == "background": bg = val
                elif key == "foreground": fg = val
                else: cur = val
        tm = {}
        try:
            tm = dict(re.findall(r"@t_(\w+) '#([0-9a-fA-F]{6})'", open(TMUX_THEME).read()))
        except OSError:
            pass
        self.pal = {k: hex2rgb(v) for k, v in pal.items()}
        self.bg, self.fg = hex2rgb(bg), hex2rgb(fg)
        self.accent = hex2rgb(tm.get("accent", cur))
        self.chip = hex2rgb(tm.get("chip", "3a4357"))
        self.quiet = hex2rgb(tm.get("quiet", "2a3244"))
        self.rule = hex2rgb(tm.get("rule", "364157"))
        P = self.pal
        self.dim, self.muted = P[8], mix(P[8], self.fg, 0.35)
        self.green, self.red, self.yellow = P[2], P[1], P[3]
        self.magenta, self.cyan, self.blue = P[5], P[6], P[4]
        self.add_bg, self.add_hi = mix(self.bg, self.green, 0.13), mix(self.bg, self.green, 0.32)
        self.del_bg, self.del_hi = mix(self.bg, self.red, 0.13), mix(self.bg, self.red, 0.34)
        self.curline = mix(self.bg, self.chip, 0.45)
        self.cur_add = mix(self.add_bg, self.chip, 0.35)
        _hl_cache.clear()


T = None  # the Theme


# ── text cells & segments ──────────────────────────────────────────────────
def cw(ch):
    o = ord(ch)
    if o < 32:
        return 0
    if o < 0x300:
        return 1
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in "WF" else 1


def width(s):
    return sum(cw(c) for c in s)


def sgr(fg=None, bg=None, b=False, i=False):
    codes = ["0"]
    if b: codes.append("1")
    if i: codes.append("3")
    if fg: codes.append("38;2;%d;%d;%d" % fg)
    if bg: codes.append("48;2;%d;%d;%d" % bg)
    return "\x1b[" + ";".join(codes) + "m"


class Line:
    """A row of styled segments; render() fits it to exactly w cells and only
    emits a colour change where the style actually changes."""
    __slots__ = ("segs", "fill")

    def __init__(self, fill=None):
        self.segs, self.fill = [], fill

    def add(self, text, fg=None, bg=None, b=False, i=False):
        # bg None = the row's fill, False = explicitly none (caps in a row)
        if text:
            self.segs.append((text, fg, self.fill if bg is None else (bg or None), b, i))
        return self

    def width(self):
        return sum(width(s[0]) for s in self.segs)

    def render(self, w, right=None):
        segs = self.segs
        if right is not None:
            gap = w - self.width() - right.width()
            if gap >= 1:
                segs = segs + [(" " * gap, None, self.fill, False, False)] + right.segs
        out, used, last = [], 0, None
        for text, fg, bg, b, i in segs:
            if used >= w:
                break
            tw = width(text)
            if tw > w - used:
                cut, acc = [], 0
                for c in text:
                    if acc + cw(c) > w - used - 1:
                        break
                    cut.append(c); acc += cw(c)
                text, tw = "".join(cut) + "…", acc + 1
            style = (fg, bg, b, i)
            if style != last:
                out.append(sgr(fg, bg, b, i)); last = style
            out.append(text)
            used += tw
        if used < w:
            out.append(sgr(None, self.fill) + " " * (w - used))
        return "".join(out) + "\x1b[0m"


def chip(line, text, bg, fg, b=False):
    line.add(CAP_L, bg, False)
    line.add(text, fg, bg, b)
    line.add(CAP_R, bg, False)
    return line


def trunc_left(s, w):
    if width(s) <= w:
        return s
    while s and width(s) > w - 1:
        s = s[1:]
    return "…" + s


# ── syntax highlighting via bat (ANSI theme: follows the palette) ──────────
SGR_RE = re.compile(r"\x1b\[([0-9;]*)m")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
NOISE_RE = re.compile(r"^(Shell cwd was reset to |\(eval\):\d+: )")   # Claude Code's own notes


def plain(md):
    """Claude's words without markdown marks"""
    md = re.sub(r"\*\*(.+?)\*\*|__(.+?)__", lambda m: m[1] or m[2], md)
    md = re.sub(r"`([^`]*)`", r"\1", md)
    md = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", md)
    return " ".join(md.replace("#", "").split())
_hl_cache = OrderedDict()   # small LRU of highlighted texts
HL_KEEP = 4
_CELLS = {}                 # one shared tuple per (char, style)
NL = ("\n", None, False, False)


def xterm256(n):
    if n < 16:
        return T.pal[n]
    if n >= 232:
        v = 8 + (n - 232) * 10
        return (v, v, v)
    n -= 16
    lv = [0, 95, 135, 175, 215, 255]
    return (lv[n // 36], lv[(n // 6) % 6], lv[n % 6])


def cell(c, fg, b, i):
    k = (c, fg, b, i)
    v = _CELLS.get(k)
    if v is None:
        if len(_CELLS) > 50_000:
            _CELLS.clear()
        v = _CELLS[k] = k
    return v


def highlight(lines, path):
    """-> one list per line of (char, fg, bold, italic); plain if bat can't."""
    key = (path, hash("\n".join(lines)), len(lines))
    if key in _hl_cache:
        _hl_cache.move_to_end(key)
        return _hl_cache[key]
    res = None
    if lines and sum(map(len, lines)) < 400_000:
        try:
            r = subprocess.run(["bat", "--theme=ansi", "--color=always", "--style=plain",
                                "--paging=never", "--file-name", os.path.basename(path)],
                               input="\n".join(lines) + "\n", capture_output=True, text=True,
                               timeout=5)
            out = r.stdout.split("\n")
            if r.returncode == 0 and len(out) >= len(lines):
                res = []
                fg, bold, ital = None, False, False
                for raw, want in zip(out, lines):
                    cells, pos = [], 0
                    for m in SGR_RE.finditer(raw):
                        cells.extend(cell(c, fg, bold, ital) for c in raw[pos:m.start()])
                        pos = m.end()
                        nums = [int(x) if x else 0 for x in m[1].split(";")]
                        k = 0
                        while k < len(nums):
                            n = nums[k]
                            if n == 0: fg, bold, ital = None, False, False
                            elif n == 1: bold = True
                            elif n == 3: ital = True
                            elif n == 22: bold = False
                            elif n == 23: ital = False
                            elif n == 39: fg = None
                            elif 30 <= n <= 37: fg = T.pal[n - 30]
                            elif 90 <= n <= 97: fg = T.pal[n - 90 + 8]
                            elif n == 38 and k + 2 < len(nums) and nums[k + 1] == 5:
                                fg = xterm256(nums[k + 2]); k += 2
                            elif n == 38 and k + 4 < len(nums) and nums[k + 1] == 2:
                                fg = tuple(nums[k + 2:k + 5]); k += 4
                            k += 1
                    cells.extend(cell(c, fg, bold, ital) for c in raw[pos:])
                    if len(cells) != len(want):  # bat changed the text: plain line
                        cells = [cell(c, None, False, False) for c in want]
                    res.append(cells)
        except (OSError, subprocess.TimeoutExpired):
            res = None
    if res is None:
        res = [[cell(c, None, False, False) for c in l] for l in lines]
    _hl_cache[key] = res
    while len(_hl_cache) > HL_KEEP:
        _hl_cache.popitem(last=False)
    return res


def flat_cells(text, path):
    """whole text -> flat cell list (index == text index, '\n' cells kept)"""
    out = []
    for k, cells in enumerate(highlight(text.split("\n"), path)):
        if k:
            out.append(NL)
        out.extend(cells)
    return out


def newlines(text):
    out, i = [], text.find("\n")
    while i >= 0:
        out.append(i)
        i = text.find("\n", i + 1)
    return out


def line_start(nl, line, n):
    if line <= 0:
        return 0
    return nl[line - 1] + 1 if line - 1 < len(nl) else n


def line_end(nl, line, n):
    return nl[line] if line < len(nl) else n


# ── git / diffs (Changes view) ─────────────────────────────────────────────
def git(args, cwd):
    try:
        r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=5)
        return r.returncode, r.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


_roots = {}


def repo_root(d):
    if d not in _roots:
        code, out = git(["rev-parse", "--show-toplevel"], d) if os.path.isdir(d) else (1, "")
        _roots[d] = out.strip() if code == 0 else None
    return _roots[d]


def parse_unified(text):
    rows, adds, dels, o, n = [], 0, 0, 0, 0
    for line in text.splitlines():
        if line.startswith("@@"):
            try:
                a, b = line.split(" ")[1:3]
                o = int(a[1:].split(",")[0])
                n = int(b[1:].split(",")[0])
            except (ValueError, IndexError):
                pass
            rows.append(("hunk", None, None, line.split("@@", 2)[-1].strip()))
        elif line.startswith(("diff ", "index ", "--- ", "+++ ", "new file", "deleted file",
                              "similarity", "rename ", "old mode", "new mode")):
            continue
        elif line.startswith("+"):
            rows.append(("add", None, n, line[1:])); n += 1; adds += 1
        elif line.startswith("-"):
            rows.append(("del", o, None, line[1:])); o += 1; dels += 1
        elif line.startswith("\\"):
            continue
        elif line.startswith("Binary files"):
            rows.append(("hunk", None, None, "binary file"))
        else:
            rows.append(("ctx", o, n, line[1:])); o += 1; n += 1
    return rows, adds, dels


def intraline(rows):
    marks, i = {}, 0
    while i < len(rows):
        if rows[i][0] != "del":
            i += 1
            continue
        j = i
        while j < len(rows) and rows[j][0] == "del":
            j += 1
        k = j
        while k < len(rows) and rows[k][0] == "add":
            k += 1
        if j - i == k - j:
            for d, a in zip(range(i, j), range(j, k)):
                sm = difflib.SequenceMatcher(None, rows[d][3], rows[a][3], autojunk=False)
                if sm.ratio() < 0.45:
                    continue
                md, ma = set(), set()
                for op, a1, a2, b1, b2 in sm.get_opcodes():
                    if op != "equal":
                        md.update(range(a1, a2)); ma.update(range(b1, b2))
                marks[d], marks[a] = md, ma
        i = k
    return marks


# ── replaying edits ────────────────────────────────────────────────────────
def apply_edits(text, edits, reverse=False):
    """forward (old->new) or reverse (new->old) apply; None if it doesn't fit"""
    seq = list(reversed(edits)) if reverse else edits
    for e in seq:
        a, b = (e["new"], e["old"]) if reverse else (e["old"], e["new"])
        if a not in text:
            return None
        text = text.replace(a, b) if e.get("all") else text.replace(a, b, 1)
    return text


def compute_regions(pre, post):
    """changed regions, top to bottom: (pre_s, pre_e, post_s, post_e), each
    trimmed to the characters that really change (12 -> 16 is one char)"""
    pl, ql = pre.splitlines(keepends=True), post.splitlines(keepends=True)
    po, qo = [0], [0]
    for l in pl: po.append(po[-1] + len(l))
    for l in ql: qo.append(qo[-1] + len(l))
    sm = difflib.SequenceMatcher(None, pl, ql, autojunk=False)
    regs = []
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "equal":
            continue
        ps, pe, qs, qe = po[i1], po[i2], qo[j1], qo[j2]
        a, b = pre[ps:pe], post[qs:qe]
        n = min(len(a), len(b))
        p = 0
        while p < n and a[p] == b[p]:
            p += 1
        s = 0
        while s < n - p and a[-1 - s] == b[-1 - s]:
            s += 1
        if pe - s > ps + p or qe - s > qs + p:
            regs.append((ps + p, pe - s, qs + p, qe - s))
    return regs, sm.get_opcodes()


class FileView:
    """one open file in the Live view"""
    def __init__(self, path, text):
        self.path = path
        self.set_text(text)
        self.signs = {}       # line -> "add" | "mod" | "del" (gutter, whole session)
        self.ghosts = {}      # line -> removed rows shown above it (latest edit)
        self.recent = set()   # lines of the latest edit (green rows)
        self.cursor = None    # char index of the last edit's end
        self.fresh = []       # (start, end, t) recently typed ranges
        self.scan = None      # (first line, last line, t0) read sweep

    def set_text(self, text):
        self.text = text
        self.nl = newlines(text)
        self._cells = None

    def cells(self):
        if self._cells is None:
            self._cells = flat_cells(self.text, self.path)
        return self._cells

    def drop_cells(self):
        self._cells = None

    def nlines(self):
        return len(self.nl) + 1

    def clear_diff(self):
        self.ghosts, self.recent, self.fresh = {}, set(), []

    def update_signs(self, opcodes):
        new = {}
        for op, i1, i2, j1, j2 in opcodes:
            if op == "equal":
                for i in range(i1, i2):
                    if i in self.signs:
                        new[j1 + i - i1] = self.signs[i]
            elif op == "insert":
                for j in range(j1, j2): new[j] = "add"
            elif op == "replace":
                for j in range(j1, j2): new[j] = "mod"
            elif op == "delete":
                new.setdefault(j1, "del")
        self.signs = new


class EditAnim:
    """replays one edit: move to the spot, select what goes (red), lift it
    into removed rows, type the new text in; regions play top to bottom"""

    def __init__(self, view, pre, post, now, hurry=1.0):
        self.view, self.pre, self.post = view, pre, post
        self.regs, self.ops = compute_regions(pre, post)
        self.pre_c, self.post_c = flat_cells(pre, view.path), flat_cells(post, view.path)
        self.pre_nl, self.post_nl = newlines(pre), newlines(post)
        # per region: (anchor line in post, removed rows, post lines it fills)
        self.info = []
        for ps, pe, qs, qe in self.regs:
            rows = []
            if pe > ps:
                l0 = bisect.bisect_left(self.pre_nl, ps)
                l1 = bisect.bisect_left(self.pre_nl, pe - 1)
                s0 = line_start(self.pre_nl, l0, len(pre))
                e1 = line_end(self.pre_nl, l1, len(pre))
                cells = self.pre_c[s0:e1]
                marks = [("del" if ps <= s0 + i < pe else None) for i in range(len(cells))]
                rows = split_lines(cells, marks, 0, None)[0]
            a = bisect.bisect_left(self.post_nl, qs)
            b = bisect.bisect_left(self.post_nl, max(qs, qe - 1)) if qe > qs else a - 1
            self.info.append((a, rows, set(range(a, b + 1))))
        ins = sum(r[3] - r[2] for r in self.regs)
        n = len(self.regs)
        self.t_move = (0.14 if n < 6 else 0.04) / hurry
        self.t_sel = (0.28 if n < 6 else 0.08) / hurry
        budget = TYPE_BUDGET / hurry
        self.cps = max(90.0 * hurry, ins / max(0.25, budget - n * (self.t_move + self.t_sel)))
        self.ri, self.phase, self.t, self.k, self.d = 0, "move", now, 0, 0
        self.fresh = []
        view.clear_diff()
        view.scan = None

    def done(self):
        return self.ri >= len(self.regs)

    def step(self, now):
        while not self.done():
            ps, pe, qs, qe = self.regs[self.ri]
            el = now - self.t
            if self.phase == "move":
                if el < self.t_move: return
                self.phase = "select" if pe > ps else "type"
            elif self.phase == "select":
                if el < self.t_sel: return
                self.phase = "type"   # the selection lifts into removed rows
            elif self.phase == "type":
                il = qe - qs
                self.k = min(il, int(el * self.cps))
                if self.k < il: return
                self.fresh.append((qs, qe, now))
                self.ri += 1
                self.phase, self.k = "move", 0
            self.t = now

    def finish(self, now):
        v = self.view
        v.set_text(self.post)
        v._cells = self.post_c
        v.update_signs(self.ops)
        v.fresh = self.fresh + [(r[2], r[3], now) for r in self.regs[self.ri:]]
        v.ghosts, v.recent = {}, set()
        for anchor, rows, lines in self.info:
            if rows:
                v.ghosts.setdefault(anchor, []).extend(rows)
            v.recent |= lines
        if self.regs:
            v.cursor = self.regs[-1][3]

    def window(self, back, fwd):
        """the lines around the edit point -> (rows, first line, cursor,
        removed rows by line, green lines)"""
        ps, pe, qs, qe = self.regs[self.ri]
        la = bisect.bisect_left(self.post_nl, qs)
        wl = max(0, la - back)
        sa = 0 if wl == 0 else self.post_nl[wl - 1] + 1
        a = self.post_c[sa:qs]
        if self.phase == "type":
            m, mk = self.post_c[qs:qs + self.k], "typing"
        else:
            m, mk = self.pre_c[ps:pe], ("sel" if self.phase == "select" else None)
        cur = len(a) + (len(m) if self.phase == "type" else 0)
        lb = bisect.bisect_left(self.pre_nl, pe)
        eb = line_end(self.pre_nl, lb + fwd, len(self.pre_c))
        b = self.pre_c[pe:eb]
        marks = [None] * len(a) + [mk] * len(m) + [None] * len(b)
        for fs, fe, t in self.fresh:  # earlier regions of this edit, still glowing
            for i in range(max(fs, sa), min(fe, qs)):
                marks[i - sa] = ("fresh", t)
        rows, first, cur_lc = split_lines(a + m + b, marks, wl, cur)
        ghosts, recent = {}, set()
        for k in range(self.ri):
            anchor, g, lines = self.info[k]
            if g:
                ghosts.setdefault(anchor, []).extend(g)
            recent |= lines
        anchor, g, _ = self.info[self.ri]
        if self.phase == "type":
            if g:
                ghosts.setdefault(anchor, []).extend(g)
            typed_lines = m and sum(1 for c in m if c[0] == "\n")
            recent |= set(range(la, la + (typed_lines or 0) + (1 if self.k else 0)))
        return rows, first, cur_lc, ghosts, recent


def split_lines(cells, marks, first, cur):
    lines, line, cur_lc = [], [], None
    for i, (c, m) in enumerate(zip(cells, marks)):
        if i == cur:
            cur_lc = (first + len(lines), len(line))
        if c[0] == "\n":
            lines.append(line); line = []
        else:
            line.append((c, m))
    if cur is not None and cur >= len(cells):
        cur_lc = (first + len(lines), len(line))
    lines.append(line)
    return lines, first, cur_lc


class Timed:
    """an action that just takes a moment (read sweep, command, note)"""

    def __init__(self, dur, now):
        self.end, self.now = now + dur, now

    def step(self, now):
        self.now = now

    def done(self):
        return self.now >= self.end


def read_text(p):
    try:
        with open(p, errors="replace") as f:
            return f.read(2_000_000)
    except OSError:
        return None


class Session:
    """one Claude Code session: its log, Changes data and Live state"""

    def __init__(self, sid, log):
        self.sid, self.log = sid, log
        self.offset, self.ino = 0, None
        self.events = deque(maxlen=200)
        self.files = {}          # Changes: path -> {"t", "recs"}
        self.diffs = {}          # path -> (rows, adds, dels)
        self.dirty = set()       # paths whose diff needs recomputing
        self.ran = False         # a shell command ran since diffs were computed
        self.start_t = None
        self.home, self.branch, self.tmux, self.label = None, "", None, ""
        self.sel, self.follow_sel, self.scroll, self.pending_row = None, True, 0, None
        # Live
        self.model = {}          # path -> text after every edit seen
        self.views = OrderedDict()   # path -> FileView (tabs, most recent last)
        self.active = None
        self.queue = deque()
        self.anim = None
        self.status = None       # (tool, text, t)
        self.why = None          # (Claude's words for this step, t)
        self.term = None         # {"cmd", "out", "t"}
        self.top = self.target = 0.0
        self.manual = self.jump = False

    # log ---------------------------------------------------------------------
    def read_new(self, animate):
        try:
            st = os.stat(self.log)
        except OSError:
            return False
        if self.ino is not None and (st.st_ino != self.ino or st.st_size < self.offset):
            self.offset = 0      # rotated: start over
        self.ino = st.st_ino
        if st.st_size == self.offset:
            return False
        with open(self.log) as f:
            f.seek(self.offset)
            chunk = f.read()
            self.offset = f.tell()
        new = []
        for line in chunk.splitlines():
            try:
                new.append(json.loads(line))
            except ValueError:
                pass
        for e in new:
            self.take(e)
        if len(new) > 8 or not animate:   # catching up: no replay
            keep = self.queue[-1] if (animate and self.queue) else None
            self.settle_all()
            if keep is not None:
                self.queue.append(keep)
        return bool(new)

    def take(self, e):
        # the activity history keeps only what it shows (not file contents)
        self.events.append({k: v for k, v in e.items()
                            if k not in ("orig", "content", "edits", "out")})
        if self.home is None:
            self.home = e.get("cwd") or os.getcwd()
            root = repo_root(self.home)
            if root:
                self.branch = git(["branch", "--show-current"], root)[1].strip()
        if self.start_t is None:
            self.start_t = e["t"]
        if e.get("tmux"):
            self.tmux = e["tmux"]
        tool, p = e["tool"], e.get("path")
        if tool in EDIT_TOOLS and p:
            ent = self.files.setdefault(p, {"t": 0, "recs": []})
            ent["t"] = e["t"]
            ent["recs"].append({k: v for k, v in e.items() if k != "orig"})
            self.dirty.add(p)
            if self.follow_sel:
                self.sel, self.pending_row = p, "latest"
        elif tool == "Bash":
            self.ran = True
        self.queue.append(self.action(e))

    def action(self, e):
        """an event -> a Live action, tracking each file's text"""
        tool, p = e["tool"], e.get("path")
        if tool in ("Edit", "MultiEdit") and p:
            pre = e.get("orig")
            if pre is None:
                pre = self.model.get(p)
            if pre is None:  # first sight: undo this edit on what's on disk
                disk = read_text(p)
                pre = apply_edits(disk, e.get("edits", []), reverse=True) if disk is not None else None
            post = apply_edits(pre, e.get("edits", [])) if pre is not None else None
            if post is None:
                post = read_text(p) or ""
                pre = pre if pre is not None else post
            self.model[p] = post
            return ("edit", e, p, pre.expandtabs(4), post.expandtabs(4))
        if tool == "Write" and p:
            pre = e.get("orig")
            if pre is None:
                pre = self.model.get(p, "")
            post = e.get("content")
            if post is None:
                post = read_text(p) or ""
            self.model[p] = post
            return ("edit", e, p, pre.expandtabs(4), post.expandtabs(4))
        if tool == "Read" and p and not p.lower().endswith(BINARY_EXT):
            return ("read", e, p)
        if tool == "Bash":
            return ("bash", e)
        return ("note", e)

    # Live --------------------------------------------------------------------
    def view_for(self, path, text=None):
        v = self.views.get(path)
        if v is None:
            if text is None:
                text = (self.model.get(path) or read_text(path) or "").expandtabs(4)
            v = FileView(path, text)
            self.views[path] = v
        self.views.move_to_end(path)
        while len(self.views) > MAX_TABS:
            self.views.popitem(last=False)
        for k, fv in self.views.items():  # highlighted cells for the shown file only
            if k != path:
                fv.drop_cells()
        return v

    def describe(self, e):
        tool = e["tool"]
        verb = ACT.get(tool, (0, "", tool.lower()))[2]
        if e.get("path"):
            return f"{verb} {os.path.basename(e['path'])}"
        what = " ".join(str(e.get("what", "")).split())
        return f"{verb} {what}" if what else verb

    def start(self, act, now, hurry):
        kind, e = act[0], act[1]
        self.status = (e["tool"], self.describe(e), now)
        if e.get("why") and (not self.why or plain(e["why"]) != self.why[0]):
            self.why = (plain(e["why"]), now)
        if kind == "edit":
            _, _, p, pre, post = act
            v = self.view_for(p, pre)
            if v.text != pre:     # out of step: start from the edit's own "before"
                v.set_text(pre); v.signs = {}
            self.active, self.manual = p, False
            a = EditAnim(v, pre, post, now, hurry)
            if a.done():
                a.finish(now)
                return Timed(0.2, now)
            return a
        if kind == "read":
            p = act[2]
            disk = read_text(p)
            v = self.view_for(p)
            if disk is not None and p not in self.model and v.text != disk.expandtabs(4):
                v.set_text(disk.expandtabs(4))
            self.active, self.manual = p, False
            off = max(0, (e.get("offset") or 1) - 1)
            n = e.get("limit") or v.nlines()
            v.scan = (off, min(v.nlines(), off + n) - 1, now)
            v.cursor = None
            self.jump = True
            return Timed(0.7 / hurry, now)
        if kind == "bash":
            self.term = {"cmd": e.get("cmd") or e.get("what", ""), "out": e.get("out", ""),
                         "t": now, "desc": e.get("what", "")}
            return Timed(0.5 / hurry, now)
        return Timed(0.25 / hurry, now)

    def tick(self, now):
        """advance the Live state; True while something is moving"""
        for _ in range(50):
            if self.anim is None and self.queue:
                hurry = 1.0 + 0.8 * min(len(self.queue) - 1, 6)
                self.anim = self.start(self.queue.popleft(), now, hurry)
            if self.anim is None:
                return False
            self.anim.step(now)
            if not self.anim.done():
                return True
            if isinstance(self.anim, EditAnim):
                self.anim.finish(now)
            self.anim = None
        return True

    def settle_all(self):
        """apply everything queued at once (catching up, or off screen)"""
        now = time.monotonic()
        if isinstance(self.anim, EditAnim):
            self.anim.finish(now)
        self.anim = None
        last = None
        while self.queue:
            act = self.queue.popleft()
            kind, e = act[0], act[1]
            last = e
            if kind == "edit":
                _, _, p, pre, post = act
                v = self.views.get(p)
                if v is not None:
                    if v.text == pre:
                        v.update_signs(compute_regions(pre, post)[1])
                    v.set_text(post)
                    v.clear_diff()
                    v.scan = None
                else:
                    self.view_for(p, post)
                self.active = p
            elif kind == "read":
                if act[2] not in self.views:
                    self.view_for(act[2])
                self.active = act[2]
            elif kind == "bash":
                self.term = {"cmd": e.get("cmd") or e.get("what", ""), "out": e.get("out", ""),
                             "t": now - 10, "desc": e.get("what", "")}
            if e.get("why"):
                self.why = (plain(e["why"]), now - 10)
        if last is not None:
            self.status = (last["tool"], self.describe(last), now - 10)

    # Changes ---------------------------------------------------------------------
    def refresh_diffs(self):
        if self.ran:
            cwd = self.events[-1]["cwd"] if self.events else self.home
            self.dirty |= self.scan_git(cwd) | set(self.files)
            self.ran = False
        for p in self.dirty:
            if p not in self.files:
                continue
            self.diffs[p] = self.diff_for(p)
            if self.diffs[p][0][:1] == [("hunk", None, None, "binary file")] \
                    and not self.files[p]["recs"]:
                del self.files[p], self.diffs[p]
        self.dirty = set()
        if self.sel is None and self.files:
            self.sel = self.ordered()[0]

    def scan_git(self, cwd):
        root = repo_root(cwd) if cwd else None
        if not root:
            return set()
        _, out = git(["status", "--porcelain=v1", "-z"], root)
        found = set()
        for item in out.split("\0"):
            if len(item) < 4:
                continue
            p = os.path.join(root, item[3:])
            if "__pycache__" in p or p.endswith((".pyc", ".o")):
                continue
            try:
                if os.path.isfile(p) and os.path.getmtime(p) >= (self.start_t or 0) - 1:
                    ent = self.files.setdefault(p, {"t": 0, "recs": []})
                    ent["t"] = max(ent["t"], os.path.getmtime(p))
                    found.add(p)
            except OSError:
                pass
        return found

    def diff_for(self, p):
        root = repo_root(os.path.dirname(p))
        if root:
            code, out = git(["diff", "--no-color", "--no-ext-diff", "-U3", "HEAD", "--", p], root)
            if code == 0 and out:
                return parse_unified(out)
            tracked, _ = git(["ls-files", "--error-unmatch", "--", p], root)
            if tracked != 0 and os.path.exists(p):
                _, out = git(["diff", "--no-index", "--no-color", "-U3", "/dev/null", p], root)
                return parse_unified(out)
            if code == 0:
                return [("hunk", None, None, "no uncommitted changes")], 0, 0
        rows, adds, dels = [], 0, 0
        cur = read_text(p) or ""
        for rec in self.files.get(p, {}).get("recs", []):
            if rec["tool"] == "Write":
                text = "".join(f"+{l}\n" for l in rec.get("content", "").splitlines())
                r, a, d = parse_unified(f"@@ -0,0 +1 @@ new file\n{text}")
            else:
                r, a, d = [], 0, 0
                for e in rec.get("edits", []):
                    base = cur[:cur.find(e["new"])].count("\n") + 1 if e["new"] in cur else 1
                    u = "\n".join(difflib.unified_diff(e["old"].splitlines(),
                                                       e["new"].splitlines(), lineterm="", n=2))
                    rr, aa, dd = parse_unified(u)
                    rr = [(k, o and o + base - 1, n and n + base - 1, t) for k, o, n, t in rr]
                    r += rr; a += aa; d += dd
            rows += r; adds += a; dels += d
        return rows, adds, dels

    def ordered(self):
        return sorted(self.files, key=lambda p: -self.files[p]["t"])

    def target_row(self):
        rows = self.diffs.get(self.sel, ([], 0, 0))[0]
        recs = self.files.get(self.sel, {}).get("recs", [])
        if recs and recs[-1].get("edits"):
            e = recs[-1]["edits"][-1]
            old = set(e["old"].splitlines())
            fresh = {l for l in e["new"].splitlines() if l not in old and l.strip()}
            for i in range(len(rows) - 1, -1, -1):
                if rows[i][0] == "add" and rows[i][3] in fresh:
                    while i > 0 and rows[i - 1][0] in ("add", "del"):
                        i -= 1
                    return i
        return next((i for i, r in enumerate(rows) if r[0] in ("add", "del")), 0)

    def rel(self, p):
        r = os.path.relpath(p, self.home or os.getcwd())
        return p.replace(os.path.expanduser("~"), "~") if r.startswith("../..") else r

    def trim(self):
        """drop what a background session doesn't need in memory"""
        for v in self.views.values():
            v.drop_cells()
        self.diffs, self.dirty = {}, set(self.files)


# ── the app ────────────────────────────────────────────────────────────────
class App:
    def __init__(self):
        self.sessions = OrderedDict()   # sid -> Session (LRU)
        self.shown = None
        self.mode = "live"
        self.show_act = True
        self.click = {}                 # screen row -> [(x0, x1, path)]
        self.view = 10

    # sessions ----------------------------------------------------------------
    def logs(self):
        try:
            names = os.listdir(RUN)
        except FileNotFoundError:
            return {}
        out, now = {}, time.time()
        for n in names:
            if n.endswith(".jsonl"):
                p = os.path.join(RUN, n)
                try:
                    m = os.path.getmtime(p)
                except OSError:
                    continue
                if now - m < SESSION_MAX_AGE:
                    out[n[:-6]] = (p, m)
        return out

    @staticmethod
    def tmux_of(log):
        """the tmux pane in a log's last line (reads the tail only)"""
        try:
            with open(log, "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 65536))
                tail = f.read().decode(errors="replace").strip().splitlines()
            return json.loads(tail[-1]).get("tmux") if tail else None
        except (OSError, ValueError, IndexError):
            return None

    def pick(self):
        """the focused tmux pane's Claude, else the one that acted last"""
        logs = self.logs()
        if not logs:
            return None
        try:
            focus = open(os.path.join(RUN, "focus")).read().strip() or None
        except OSError:
            focus = None
        if focus:
            for sid, (p, _) in sorted(logs.items(), key=lambda kv: -kv[1][1]):
                s = self.sessions.get(sid)
                tm = s.tmux if s and s.tmux else self.tmux_of(p)
                if tm == focus:
                    return sid
            if self.shown in logs:   # focused pane isn't a Claude: stay put
                return self.shown
        return max(logs, key=lambda k: logs[k][1])

    def session(self, sid):
        s = self.sessions.get(sid)
        if s is None:
            s = Session(sid, os.path.join(RUN, sid + ".jsonl"))
            self.sessions[sid] = s
        self.sessions.move_to_end(sid)
        while len(self.sessions) > MAX_SESSIONS:
            self.sessions.popitem(last=False)
        return s

    def update(self):
        sid = self.pick()
        if sid is None:
            return
        if sid != self.shown:
            if self.shown in self.sessions:
                old = self.sessions[self.shown]
                old.settle_all()
                old.trim()
            self.shown = sid
            s = self.session(sid)
            s.read_new(animate=False)
            s.jump = True
            if s.tmux and not s.label:
                s.label = tmux_label(s.tmux)
        else:
            self.session(sid).read_new(animate=True)
        for other in list(self.sessions.values()):  # background: cheap catch-up
            if other.sid != self.shown and other.read_new(animate=False):
                other.trim()

    def cur(self):
        return self.sessions.get(self.shown)

    def busy(self, now):
        s = self.cur()
        if not s:
            return False
        moving = s.tick(now)
        v = s.views.get(s.active)
        if v:
            if any(now - t < FADE for _, _, t in v.fresh):
                moving = True
            if v.scan and now - v.scan[2] < 1.2:
                moving = True
        if s.term and now - s.term["t"] < 0.6:
            moving = True
        if s.why and now - s.why[1] < 0.6:
            moving = True
        if s.status and now - s.status[2] < 2.2:
            moving = True     # the status dot breathes a moment after
        if abs(s.top - s.target) > 0.05:
            moving = True
        return moving

    # drawing -----------------------------------------------------------------
    def frame(self, W, H, now):
        T.reload()
        self.click = {}
        s = self.cur()
        if s is None or not s.events:
            return self.empty(W, H)
        if self.mode == "live":
            return self.frame_live(s, W, H, now)
        s.refresh_diffs()
        return self.frame_changes(s, W, H, now)

    def title(self, s):
        head = Line()
        chip(head, " " + ICON_CLAUDE + " claude ", T.chip, T.accent, b=True)
        head.add("  " + (os.path.basename(s.home) if s.home else ""), T.fg, b=True)
        if s.label:
            head.add("  " + s.label, T.dim)
        elif s.branch:
            head.add("  " + ICON_BRANCH + " " + s.branch, T.dim)
        return head

    def footer(self, W, keys):
        for compact in (False, True):
            l = Line()
            for k, label, on in keys:
                chip(l, k, T.chip if on else T.quiet, T.accent if on else T.muted, b=True)
                if not compact:
                    l.add(" " + label, T.dim)
                l.add("  ")
            if l.width() <= W - 2:
                break
        pad = max(0, (W - l.width()) // 2)
        return Line().add(" " * pad).render(pad) + l.render(W - pad)

    def empty(self, W, H):
        lines = [""] * max(0, H // 2 - 3)
        for text, col, bold in ((ICON_CLAUDE, T.accent, True),
                                ("Waiting for Claude", T.fg, True),
                                ("It shows up here as soon as it reads,", T.dim, False),
                                ("runs or edits something.", T.dim, False)):
            pad = max(0, (W - width(text)) // 2)
            lines.append(Line().add(" " * pad).add(text, col, b=bold).render(W))
        lines += [""] * (H - 1 - len(lines))
        lines.append(self.footer(W, [("tab", "changes", False), ("q", "close", False)]))
        return lines

    # Live ----------------------------------------------------------------------
    def frame_live(self, s, W, H, now):
        right = Line()
        if s.status:
            tool, text, t = s.status
            icon, role, _ = ACT.get(tool, (0xF111, "dim", ""))
            live = s.anim is not None or now - t < 2.0
            col = getattr(T, role) if live else T.dim
            if live:
                pulse = 0.5 + 0.5 * math.sin(now * 7)
                right.add("● ", mix(T.dim, col, 0.35 + 0.65 * pulse))
            right.add(G(icon) + " ", col).add(text + " ", T.fg if live else T.muted)
        lines = [self.title(s).render(W, right)] + self.why_rows(s, W, now)

        # tabs: recently opened files, the active one lit, edited ones dotted
        tabs, x = Line().add(" "), 1
        for p in reversed(list(s.views)):
            on = p == s.active
            seg = Line()
            if on:
                chip(seg, " " + file_icon(p) + " " + os.path.basename(p) + " ", T.chip, T.fg, b=True)
            else:
                seg.add(" " + file_icon(p) + " ", T.dim).add(os.path.basename(p), T.muted)
            if p in s.files:
                seg.add(" ●", T.yellow)
            if x + seg.width() > W - 1:
                break
            tabs.segs += seg.segs
            self.click.setdefault(1, []).append((x, x + seg.width(), p))
            x += seg.width() + 2
            tabs.add("  ")
        lines.append(tabs.render(W))

        term = self.term_card(s, W, now)
        view = H - len(lines) - len(term) - 1
        self.view = max(view, 1)
        v = s.views.get(s.active)
        lines += self.editor(s, v, W, view, now) if v else [""] * view
        lines += term
        lines.append(self.footer(W, [
            ("tab", "changes", False), ("f", "following" if not s.manual else "follow", not s.manual),
            ("j k", "scroll", False), ("q", "close", False)]))
        return lines[:H]

    def settled_window(self, v, first, last, now):
        cells = v.cells()
        a = line_start(v.nl, first, len(v.text))
        b = line_start(v.nl, last, len(v.text))
        marks = [None] * (b - a)
        for fs, fe, t in v.fresh:
            if now - t < FADE:
                for i in range(max(fs, a), min(fe, b)):
                    marks[i - a] = ("fresh", t)
        cur = v.cursor - a if v.cursor is not None and a <= v.cursor <= b else None
        return split_lines(cells[a:b], marks, first, cur)

    def editor(self, s, v, W, view, now):
        anim = s.anim if isinstance(s.anim, EditAnim) and s.anim.view is v and not s.anim.done() else None
        total = v.nlines() if anim is None else len(anim.post_nl) + 1
        gw = max(3, len(str(total)))
        code_w = max(8, W - gw - 4)

        if anim is not None:
            la = bisect.bisect_left(anim.post_nl, anim.regs[anim.ri][2])
            back = max(view + 4, la - int(s.top) + 2)
            rows, first, cur, ghosts, recent = anim.window(back, view + 4)
        else:
            first = max(0, int(s.top) - 2)
            rows, first, cur = self.settled_window(v, first, min(v.nlines(), first + view + 4), now)
            ghosts, recent = v.ghosts, v.recent

        # follow the action: the cursor, else the read sweep
        focus_line = cur[0] if cur else (v.scan[0] if v.scan else None)
        if not s.manual and focus_line is not None:
            above = sum(min(len(g), GHOST_MAX + 1) for ln, g in ghosts.items()
                        if s.top <= ln <= focus_line)
            pos = focus_line - s.top + above
            if anim is not None or s.jump:
                if s.jump or not (view * 0.15 <= pos <= view * 0.7):
                    s.target = max(0.0, min(focus_line - view * 0.35, total - view * 0.5))
                s.jump = False
        if abs(s.target - s.top) > view:   # far: snap most of the way, glide the rest
            s.top = s.target - math.copysign(view * 0.4, s.target - s.top)
        s.top += (s.target - s.top) * 0.35
        if abs(s.target - s.top) < 0.05:
            s.top = s.target
        s.top = max(0.0, min(s.top, max(0, total - 1)))
        top = int(round(s.top))

        if anim is None and not (first <= top and top + view <= first + len(rows)):
            rows, first, cur = self.settled_window(v, top, min(v.nlines(), top + view + 1), now)

        live = anim is not None or (s.status and now - s.status[2] < 3)
        signs = {} if anim else v.signs
        out, ln = [], top
        while len(out) < view:
            idx = ln - first
            if ln >= total or idx < 0 or idx >= len(rows):
                out.append(Line().add(" " * (gw + 1) + "~", T.rule).render(W))
                ln += 1
                continue
            g = ghosts.get(ln)
            if g:
                shown = g if len(g) <= GHOST_MAX + 1 else g[:GHOST_MAX]
                for grow in shown:
                    if len(out) >= view:
                        break
                    out.append(self.ghost_row(grow, gw, W))
                if len(g) > len(shown) and len(out) < view:
                    out.append(Line(fill=T.del_bg).add("▎", T.red).add(
                        " " * (gw + 2) + f"… {len(g) - len(shown)} more removed", T.red, i=True).render(W))
                if len(out) >= view:
                    break
            out.append(self.code_row(rows[idx], ln, cur, W, gw, code_w, now, live, v, anim,
                                     signs.get(ln), ln in recent))
            ln += 1
        return out

    def ghost_row(self, grow, gw, W):
        l = Line(fill=T.del_bg)
        l.add("▎", T.red).add(" " * (gw - 1) + "-", T.red, b=True).add("  ")
        for (c, fg, bold, ital), mk in grow:
            l.add(c, mix(T.bg, fg or T.fg, 0.72), T.del_hi if mk == "del" else None, bold, ital)
        return l.render(W)

    def code_row(self, row, ln, cur, W, gw, code_w, now, live, v, anim, sign, recent):
        is_cur = cur is not None and cur[0] == ln
        row_bg = None
        if recent:
            row_bg = T.cur_add if (is_cur and live) else T.add_bg
        elif is_cur and live:
            row_bg = T.curline
        if v.scan and anim is None:
            s0, s1, t0 = v.scan
            if s0 <= ln <= s1:
                head = s0 + (s1 - s0 + 6) * min(1.0, (now - t0) / 0.6)
                d = head - ln
                if d >= 0:
                    f = max(0.0, 1.0 - d / 8.0) * max(0.0, 1.0 - max(0.0, now - t0 - 0.6) / 0.5)
                    if f > 0.01:
                        row_bg = mix(row_bg or T.bg, T.accent, 0.18 * f)
        if anim is not None and any(c[1] == "typing" for c in row):
            sign = "add"
        if recent and sign is None:
            sign = "add"
        sc = {"add": T.green, "mod": T.yellow, "del": T.red}.get(sign)
        l = Line(fill=row_bg)
        l.add("▎" if sign in ("add", "mod") else ("▁" if sign == "del" else " "), sc)
        l.add(f"{ln + 1:>{gw}} ", T.accent if is_cur and live else (T.green if recent else T.dim),
              b=is_cur and live)
        l.add(" ")
        start = 0
        if is_cur and cur[1] > code_w - 6:
            start = cur[1] - code_w + 12
            l.add("…", T.dim)
        base = row_bg or T.bg
        for ci in range(start, len(row) + (1 if is_cur else 0)):
            if ci < len(row):
                (c, fg, bold, ital), mk = row[ci]
            else:
                (c, fg, bold, ital), mk = (" ", None, False, False), None
            bg, col = None, fg or T.fg
            if mk == "sel":
                bg = T.del_hi
            elif mk == "typing":
                bg = T.add_hi
            elif isinstance(mk, tuple):
                age = (now - mk[1]) / FADE
                if age < 1:
                    bg = mix(base, T.add_hi, (1 - age) ** 1.5)
            if is_cur and ci == cur[1]:
                bg, col = (T.accent, T.bg) if live else (T.rule, col)
            l.add(c, col, bg, bold, ital)
        return l.render(W)

    def term_card(self, s, W, now):
        """the last command: what it is for (its description) in words, the
        command itself dim below, then the end of its output"""
        t = s.term
        if not t:
            return []
        age = now - t["t"]
        bg = T.quiet
        cmd = " ".join(t["cmd"].split())
        desc = " ".join((t.get("desc") or "").split())
        rows = []
        head = Line(fill=bg)
        head.add(" " + G(0xF120) + "  ", T.magenta)
        if desc and desc != cmd:
            head.add(desc, T.fg, b=True)
            rows.append(head)
            typed = cmd[:int(len(cmd) * age / 0.35)] if age < 0.35 else cmd
            rows.append(Line(fill=bg).add("    $ ", T.dim).add(typed, T.dim))
        else:
            typed = cmd[:int(len(cmd) * age / 0.35)] if age < 0.35 else cmd
            head.add("$ ", T.accent, b=True).add(typed, T.fg)
            rows.append(head)
        if s.status and s.status[0] == "Bash" and age >= 0.35:
            out = [ANSI_RE.sub("", l).expandtabs(4) for l in t["out"].rstrip("\n").split("\n")]
            out = [l for l in out if l.strip() and not NOISE_RE.match(l)][-5:]
            for l in out:
                rows.append(Line(fill=bg).add("    " + l, T.muted))
            if not out:
                rows.append(Line(fill=bg).add("    no output", T.dim, i=True))
        return [""] + [r.render(W) for r in rows]

    def why_rows(self, s, W, now, max_rows=2):
        """what Claude said it is doing, from the transcript: the "why" of
        the step on screen. Types itself in when it changes."""
        if not s.why:
            return []
        text, t0 = s.why
        age = now - t0
        n = len(text) if age >= 0.5 else int(len(text) * age / 0.5)
        words, rows, cur = text[:n].split(" "), [], ""
        room = W - 6
        cut = False
        for wd in words:
            if cur and width(cur) + 1 + width(wd) > room:
                rows.append(cur); cur = wd
                if len(rows) == max_rows:
                    cut = True
                    break
            else:
                cur = (cur + " " + wd) if cur else wd
        else:
            rows.append(cur)
        if cut and age >= 0.5:
            last = rows[-1]
            if width(last) > room - 2:
                last = last.rsplit(" ", 1)[0]   # whole words only
            rows[-1] = last.rstrip(" ,.;:") + " …"
        out = []
        for k, r in enumerate(rows[:max_rows]):
            l = Line()
            l.add(" " + (G(0xF27B) if k == 0 else " ") + "  ", T.accent)
            l.add(r, mix(T.muted, T.fg, 0.7))
            out.append(l.render(W))
        return out

    # Changes ---------------------------------------------------------------------
    def diff_lines(self, s, W):
        rows = s.diffs.get(s.sel, ([], 0, 0))[0]
        if not rows:
            return [], []
        marks = intraline(rows)
        hl = {}
        for side in ([i for i, r in enumerate(rows) if r[0] in ("ctx", "add")],
                     [i for i, r in enumerate(rows) if r[0] == "del"]):
            texts = [rows[i][3].replace("\t", "    ") for i in side]
            for i, cells in zip(side, highlight(texts, s.sel or "")):
                hl[i] = cells
        nums = [r[2] if r[2] is not None else r[1] for r in rows]
        gw = max(3, len(str(max([n for n in nums if n] or [0]))))
        code_w = max(W - gw - 4, 8)
        out, starts = [], []
        for idx, (kind, o, n, text) in enumerate(rows):
            starts.append(len(out))
            if kind == "hunk":
                out.append(Line().add(" " * (gw - 1) + ICON_DOTS + "  ", T.dim)
                           .add(text or "", T.muted, i=True))
                continue
            bg = {"add": T.add_bg, "del": T.del_bg}.get(kind)
            hi = {"add": T.add_hi, "del": T.del_hi}.get(kind)
            sign_fg = {"add": T.green, "del": T.red}.get(kind, T.dim)
            cells = hl.get(idx) or [(c, None, False, False) for c in text.replace("\t", "    ")]
            m = marks.get(idx, set())
            chunks, cur, acc = [], [], 0
            for pos, cell in enumerate(cells):
                w = cw(cell[0])
                if acc + w > code_w and cur:
                    chunks.append(cur); cur, acc = [], 0
                cur.append((pos, cell)); acc += w
            chunks.append(cur)
            no = n if n is not None else o
            for ci, chunk in enumerate(chunks):
                l = Line(fill=bg)
                l.add(f"{no:>{gw}}" if ci == 0 and no else " " * gw,
                      sign_fg if kind != "ctx" else T.dim)
                l.add(" " + ({"add": "+", "del": "-"}.get(kind, " ") if ci == 0 else " ") + " ",
                      sign_fg, b=True)
                for pos, (c, fg, bold, ital) in chunk:
                    col = fg or T.fg
                    if kind == "ctx":
                        col = mix(T.bg, col, 0.62)
                    l.add(c, col, hi if pos in m else None, bold, ital)
                out.append(l)
        return out, starts

    def frame_changes(self, s, W, H, now):
        files = s.ordered()
        ta = sum(s.diffs.get(p, ([], 0, 0))[1] for p in files)
        td = sum(s.diffs.get(p, ([], 0, 0))[2] for p in files)
        right = Line()
        if files:
            right.add(f"{len(files)} file{'s' * (len(files) != 1)}  ", T.muted)
            right.add(f"+{ta}", T.green, b=True).add("  ").add(f"−{td}", T.red, b=True).add(" ")
        lines = [self.title(s).render(W, right)] + self.why_rows(s, W, now, 1) + [""]

        n_files = min(len(files), 5 if H >= 30 else 3)
        n_act = (5 if H >= 34 else 3) if self.show_act and H >= 22 else 0
        lines.append(Line().add(" Changes", T.muted, b=True).render(W))
        if not files:
            lines.append(Line().add("   nothing changed yet", T.dim, i=True).render(W))
        idx = files.index(s.sel) if s.sel in files else 0
        first = max(0, min(idx - n_files // 2, len(files) - n_files))
        for p in files[first:first + n_files]:
            _, a, d = s.diffs.get(p, ([], 0, 0))
            on = p == s.sel
            bg = T.chip if on else None
            rel = s.rel(p)
            name, folder = os.path.basename(rel), os.path.dirname(rel)
            stat = Line(fill=bg)
            stat.add(f"+{a}", T.green, b=on).add(" ").add(f"−{d}", T.red, b=on).add("  ")
            tot = a + d
            g = 0 if not tot else max(1 if a else 0, min(5 - (1 if d else 0), round(5 * a / tot)))
            stat.add("■" * g, T.green).add("■" * (5 - g if tot else 0), T.red)
            stat.add("■" * (0 if tot else 5), T.rule)
            row = Line(fill=bg)
            row.add(CAP_L if on else " ", T.chip if on else None, False)
            row.add(" " + file_icon(p) + "  ", T.accent if on else T.muted)
            row.add(name, T.fg, b=on)
            room = W - row.width() - stat.width() - 6
            if folder and room > 6:
                row.add("  " + trunc_left(folder, room - 2), T.dim)
            line = row.render(W - 1, stat)
            line += (sgr(T.chip) + CAP_R + "\x1b[0m") if on else " "
            self.click[len(lines)] = [(0, W, p)]
            lines.append(line)

        if n_act:
            lines += ["", Line().add(" Activity", T.muted, b=True).render(W)]
            for k, e in enumerate(reversed(list(s.events)[-n_act:])):
                icon, role, _ = ACT.get(e["tool"], (0xF111, "dim", ""))
                what = s.rel(e["path"]) if e.get("path") else e.get("what", "") or e["tool"]
                what = " ".join(str(what).split())
                strength = 1.0 if k == 0 else max(0.35, 0.8 - 0.15 * k)
                tcol = mix(T.dim, T.fg, strength)
                l = Line().add("   " + G(icon) + "  ", mix(T.dim, getattr(T, role), max(strength, 0.6)))
                if e.get("path"):
                    d, b = os.path.split(what)
                    l.add(b, tcol, b=(k == 0))
                    if d:
                        l.add("  " + d, mix(T.dim, tcol, 0.3))
                else:
                    l.add(what, tcol, b=(k == 0))
                lines.append(l.render(W, Line().add(
                    time.strftime("%H:%M", time.localtime(e["t"])) + " ", T.dim)))

        lines.append("")
        dl, starts = self.diff_lines(s, W)
        view = H - len(lines) - 2
        if s.sel:
            _, a, d = s.diffs.get(s.sel, ([], 0, 0))
            hdr = Line().add(" ")
            chip(hdr, " " + file_icon(s.sel) + "  " + os.path.basename(s.sel) + " ", T.quiet, T.fg, b=True)
            hdr.add("  ").add(f"+{a}", T.green).add(" ").add(f"−{d}", T.red)
            pos = Line()
            if dl:
                pos.add(f"{min(s.scroll + 1, len(dl))}–{min(s.scroll + view, len(dl))} of {len(dl)} ", T.dim)
            lines.append(hdr.render(W, pos))
        else:
            lines.append(Line().add(" no file selected", T.dim, i=True).render(W))
        view = H - len(lines) - 1
        self.view = max(view, 1)
        if s.pending_row is not None and starts:
            row = s.target_row() if s.pending_row == "latest" else s.pending_row
            s.scroll = starts[min(row, len(starts) - 1)] - 3
            s.pending_row = None
        s.scroll = max(0, min(s.scroll, len(dl) - view))
        thumb = None
        if len(dl) > view > 0:
            size = max(1, view * view // len(dl))
            top = (view - size) * s.scroll // max(1, len(dl) - view)
            thumb = (top, top + size)
        for k in range(view):
            j = s.scroll + k
            body = dl[j].render(W - 1) if j < len(dl) else " " * (W - 1)
            bar = (sgr(T.accent if thumb[0] <= k < thumb[1] else T.rule) + "▐\x1b[0m") if thumb else " "
            lines.append(body + bar)
        lines.append(self.footer(W, [("tab", "live", False), ("n p", "file", False),
                                     ("a", "activity", self.show_act), ("q", "close", False)]))
        return lines[:H]

    # input -------------------------------------------------------------------
    def key(self, k):
        s = self.cur()
        if k == "q":
            return False
        if k == "\t":
            self.mode = "changes" if self.mode == "live" else "live"
            if s:
                s.pending_row, s.jump = "latest", True
            return True
        if s is None:
            return True
        if self.mode == "live":
            v = s.views.get(s.active)
            total = v.nlines() if v else 0
            half = max(1, self.view // 2)
            step = {"j": 1, "down": 1, "wheel_down": 3, "k": -1, "up": -1, "wheel_up": -3,
                    "\x04": half, "pgdn": half, "\x15": -half, "pgup": -half}.get(k)
            if step is not None:
                s.manual = True
                s.top = s.target = float(max(0, min(s.top + step, total - 1)))
            elif k == "g":
                s.manual, s.top, s.target = True, 0.0, 0.0
            elif k == "G":
                s.manual = True
                s.top = s.target = float(max(0, total - self.view))
            elif k in ("f", "\x1b"):
                s.manual, s.jump = False, True
            elif k.startswith("click:"):
                y, x = (int(n) for n in k[6:].split(","))
                for x0, x1, p in self.click.get(y, []):
                    if x0 <= x < x1 and p in s.views:
                        s.active, s.manual = p, True
                        s.top = s.target = 0.0
            return True
        files = s.ordered()
        if k in ("j", "down", "wheel_down"):
            s.scroll += 3 if k == "wheel_down" else 1
        elif k in ("k", "up", "wheel_up"):
            s.scroll = max(0, s.scroll - (3 if k == "wheel_up" else 1))
        elif k in ("\x04", "pgdn"):
            s.scroll += self.view // 2
        elif k in ("\x15", "pgup"):
            s.scroll = max(0, s.scroll - self.view // 2)
        elif k == "g":
            s.scroll = 0
        elif k == "G":
            s.scroll = 10 ** 9
        elif k in ("n", "J", "p", "K") and files:
            i = files.index(s.sel) if s.sel in files else 0
            s.sel = files[(i + (1 if k in ("n", "J") else -1)) % len(files)]
            s.follow_sel, s.pending_row = False, "latest"
        elif k == "a":
            self.show_act = not self.show_act
        elif k in ("f", "\x1b"):
            s.follow_sel = True
            if files:
                s.sel, s.pending_row = files[0], "latest"
        elif k.startswith("click:"):
            y, x = (int(n) for n in k[6:].split(","))
            for x0, x1, p in self.click.get(y, []):
                s.sel, s.follow_sel, s.pending_row = p, False, "latest"
        return True


def tmux_label(pane):
    try:
        r = subprocess.run(["tmux", "display", "-p", "-t", pane, "#S:#W"],
                           capture_output=True, text=True, timeout=2)
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


KEYS = {"\x1b[A": "up", "\x1b[B": "down", "\x1b[5~": "pgup", "\x1b[6~": "pgdn",
        "\x1bOA": "up", "\x1bOB": "down"}
MOUSE_RE = re.compile(r"\x1b\[<(\d+);(\d+);(\d+)([mM])")


def parse_keys(data):
    out, i = [], 0
    while i < len(data):
        m = MOUSE_RE.match(data, i)
        if m:
            b, x, y, kind = int(m[1]), int(m[2]), int(m[3]), m[4]
            if b == 64: out.append("wheel_up")
            elif b == 65: out.append("wheel_down")
            elif b == 0 and kind == "M": out.append(f"click:{y - 1},{x - 1}")
            i = m.end()
            continue
        for seq, name in KEYS.items():
            if data.startswith(seq, i):
                out.append(name); i += len(seq)
                break
        else:
            if data[i] == "\x1b" and i + 1 < len(data):
                m = re.match(r"\x1b\[[0-9;?]*[A-Za-z~]", data[i:])
                i += m.end() if m else 1
            else:
                out.append(data[i]); i += 1
    return out


def main():
    global T
    T = Theme()
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setcbreak(fd)
    w = sys.stdout.write
    w("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h")

    os.makedirs(RUN, mode=0o700, exist_ok=True)
    sock_path = os.path.join(RUN, f"pane-{os.getpid()}.sock")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        os.unlink(sock_path)
    except OSError:
        pass
    sock.bind(sock_path)

    wake_r, wake_w = os.pipe()
    signal.signal(signal.SIGWINCH, lambda *_: os.write(wake_w, b"w"))
    for sg in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sg, lambda *_: sys.exit(0))

    app = App()

    def draw(now):
        cols, rows = os.get_terminal_size(1)
        frame = app.frame(cols, rows, now)
        buf = ["\x1b[?2026h\x1b[H"]
        for k, l in enumerate(frame):
            buf.append(l + "\x1b[K")
            if k < len(frame) - 1:
                buf.append("\r\n")
        buf.append("\x1b[J\x1b[?2026l")
        w("".join(buf))
        sys.stdout.flush()

    try:
        app.update()
        now = time.monotonic()
        moving = app.busy(now)
        draw(now)
        while True:
            ready, _, _ = select.select([sock, fd, wake_r], [], [], 1 / FPS if moving else None)
            if sock in ready:
                while True:
                    try:
                        sock.recv(16, socket.MSG_DONTWAIT)
                    except BlockingIOError:
                        break
                app.update()
            if wake_r in ready:
                os.read(wake_r, 64)
            if fd in ready:
                data = os.read(fd, 4096).decode(errors="replace")
                if not data:
                    return
                for k in parse_keys(data):
                    if not app.key(k):
                        return
            now = time.monotonic()
            moving = app.busy(now)
            draw(now)
    finally:
        w("\x1b[?1006l\x1b[?1000l\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sock.close()
        try:
            os.unlink(sock_path)
        except OSError:
            pass


if __name__ == "__main__":
    main()
