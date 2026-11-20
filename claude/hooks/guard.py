#!/usr/bin/env python3
"""PreToolUse guard: blocks the moves that break the patched-niri workflow
(see niri/scripts/niri-patched.sh). Exit 2 + stderr = blocked, and Claude reads
why. Anything it can't parse is let through: a guard, not a sandbox.

  - installing a niri binary by hand into ~/.local/bin (niri or niri.prev):
    only `niri-patched.sh build` may (it checks, keeps niri.prev, clears the
    crash marker)
  - editing dotnix niri/patches/*.patch directly: they are an export of the
    dotnix-patches branch in ~/github/projects/niri
"""
import json
import os
import re
import shlex
import sys

HOME = os.path.expanduser("~")
BIN = os.path.join(HOME, ".local/bin")
PATCHES = os.path.join(HOME, "github/config/dotnix/niri/patches") + os.sep
NIRI_REPO = os.path.join(HOME, "github/projects/niri")

FLOW = ("Patched-niri flow: commit on branch `dotnix-patches` in ~/github/projects/niri, "
        "export with `git format-patch -q --no-signature -o ~/github/config/dotnix/niri/patches "
        "<base>..dotnix-patches` (clear old *.patch first), install ONLY with "
        "`~/github/config/dotnix/niri/scripts/niri-patched.sh build`.")


def block(why):
    print(f"Blocked by dotnix guard: {why}\n{FLOW}", file=sys.stderr)
    sys.exit(2)


def niri_target(path, cwd):
    p = os.path.normpath(os.path.join(cwd, os.path.expanduser(path)))
    return p in (os.path.join(BIN, "niri"), os.path.join(BIN, "niri.prev"))


def check_bash(cmd, cwd):
    if "niri-patched.sh" in cmd:
        return
    # redirections straight into the binary
    if re.search(r">\s*['\"]?(~|\$HOME|" + re.escape(HOME) + r")/\.local/bin/niri(\.prev)?(['\"\s;&|)]|$)", cmd):
        block("writing ~/.local/bin/niri by redirection")
    for seg in re.split(r"&&|\|\||[;|\n]", cmd):
        try:
            argv = shlex.split(seg)
        except ValueError:
            continue
        while argv and ("=" in argv[0] and not argv[0].startswith("-") or argv[0] in ("sudo", "doas", "command", "env")):
            argv = argv[1:]
        if not argv:
            continue
        tool = os.path.basename(argv[0])
        args = [a for a in argv[1:] if not a.startswith("-")]
        if tool in ("cp", "install", "mv", "ln", "rsync", "tee", "dd") and args:
            dests = [a[3:] for a in args if a.startswith("of=")] if tool == "dd" else (args if tool == "tee" else [args[-1]])
            for d in dests:
                dd = os.path.normpath(os.path.join(cwd, os.path.expanduser(d)))
                src_is_niri = any(os.path.basename(a.rstrip("/")) == "niri" for a in args[:-1])
                if niri_target(d, cwd) or (dd == BIN and src_is_niri):
                    block(f"`{tool}` into ~/.local/bin/niri by hand")
        if tool == "cargo" and "install" in argv[1:2]:
            if NIRI_REPO in os.path.normpath(cwd) or any(NIRI_REPO in os.path.expanduser(a) or a.rstrip("/").endswith("projects/niri") for a in argv):
                block("`cargo install` of niri")


def main():
    try:
        e = json.load(sys.stdin)
    except ValueError:
        return
    tool, ti, cwd = e.get("tool_name"), e.get("tool_input") or {}, e.get("cwd") or os.getcwd()
    if tool == "Bash":
        check_bash(ti.get("command", ""), cwd)
    elif tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        path = os.path.realpath(os.path.join(cwd, ti.get("file_path") or ti.get("notebook_path") or ""))
        if path.startswith(PATCHES) and path.endswith(".patch"):
            block("niri/patches/*.patch are generated; edit the commit on dotnix-patches instead")


if __name__ == "__main__":
    main()
