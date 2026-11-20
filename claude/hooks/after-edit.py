#!/usr/bin/env python3
"""PostToolUse checks after Claude edits a file. Exit 2 + stderr hands Claude
a problem to fix (the edit itself has already happened).

  - island.luau: run the island's logic headless (a monitor name that doesn't
    exist, so nothing is drawn) and report a syntax/runtime error. Otherwise
    the running island keeps its old logic and nothing says why.
  - icon glyphs: an Edit whose text didn't land verbatim (private-use glyphs
    can be dropped), or a script that gained raw private-use glyphs (the tools
    can turn \\uXXXX escapes into raw glyphs).
"""
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
LUMEN = os.path.join(HOME, ".local/bin/lumen")
ISLAND_DIRS = [os.path.join(HOME, "github/config/dotnix/lumen/shells/island"),
               os.path.join(HOME, ".config/lumen/shells/island")]
PUA = re.compile("[\ue000-\uf8ff\U000f0000-\U000ffffd\U00100000-\U0010fffd]")
SCRIPT_EXT = (".sh", ".py", ".bash", ".zsh", ".lua", ".luau", ".js", ".ts")

problems = []


def check_island(path):
    d = os.path.dirname(path)
    if not os.access(LUMEN, os.X_OK) or not os.path.exists(os.path.join(d, "island.plm")):
        return
    try:
        r = subprocess.run([LUMEN, "--scene", "island.plm", "--screen", "NO-SUCH-SCREEN",
                            "--seconds", "2", "--no-hud"], cwd=d, capture_output=True,
                           text=True, timeout=25)
    except (subprocess.TimeoutExpired, OSError):
        return
    out = (r.stdout + r.stderr).splitlines()
    bad = [l for l in out if re.search(r"syntax error|runtime error|stays as it was|error:", l, re.I)
           and "polkit" not in l]
    if bad:
        problems.append("island.luau failed lumen's logic check (the running island would keep "
                        "its old logic):\n  " + "\n  ".join(bad[:6]))


def main():
    try:
        e = json.load(sys.stdin)
    except ValueError:
        return
    tool, ti = e.get("tool_name"), e.get("tool_input") or {}
    cwd = e.get("cwd") or os.getcwd()
    path = os.path.realpath(os.path.join(cwd, ti.get("file_path") or ""))
    if not os.path.isfile(path):
        return

    if os.path.basename(path) == "island.luau" and any(
            path.startswith(os.path.realpath(d) + os.sep) for d in ISLAND_DIRS):
        check_island(path)

    try:
        text = open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        text = None
    if text is not None:
        edits = ti.get("edits") or ([ti] if tool == "Edit" else [])
        for ed in edits:
            new = ed.get("new_string") or ""
            if PUA.search(new) and new not in text:
                problems.append(f"{path}: an edit with icon glyphs didn't land verbatim (glyphs "
                                "dropped?). Patch those lines with a script using explicit codepoints.")
        added = "".join(ed.get("new_string") or "" for ed in edits) if edits else (ti.get("content") or "")
        if path.endswith(SCRIPT_EXT) and PUA.search(added):
            lines = [str(i) for i, l in enumerate(text.splitlines(), 1) if PUA.search(l)][:8]
            if lines:
                problems.append(f"{path}: raw private-use (Nerd Font) glyphs written on line(s) "
                                f"{', '.join(lines)}. If they were meant as escapes (\\uXXXX), convert "
                                "them back; raw glyphs are invisible in many views and fragile to edit.")

    if problems:
        print("\n".join(problems), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
