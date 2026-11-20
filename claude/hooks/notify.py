#!/usr/bin/env python3
"""Stop / Notification hook: a desktop notification (lumen shows it as an
island banner) when Claude finishes or needs you, unless you're already
looking at this Claude: its tmux pane is the active one and the ghostty
window showing that tmux session is niri's focused window.

Clicking it (if the notification server offers actions) focuses that window
and pane."""
import json
import os
import re
import shutil
import subprocess
import sys


def run(*argv, timeout=2):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def ppid(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return int(f.read().rsplit(")", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        return 0


def ancestors(pid):
    out = []
    while pid > 1 and len(out) < 30:
        out.append(pid)
        pid = ppid(pid)
    return out


def terminal_window(pane):
    """niri window id of the ghostty showing this pane's tmux session, and
    whether you're looking at the pane right now."""
    if not pane:
        return None, False
    info = run("tmux", "display", "-p", "-t", pane, "#{session_name}\t#{window_active}\t#{pane_active}")
    if not info:
        return None, False
    session, win_active, pane_active = info.split("\t")
    clients = run("tmux", "list-clients", "-t", session, "-F", "#{client_pid}").split()
    try:
        windows = json.loads(run("niri", "msg", "-j", "windows") or "[]")
    except ValueError:
        windows = []
    by_pid = {w.get("pid"): w for w in windows}
    win = None
    for c in clients:
        for a in ancestors(int(c)):
            if a in by_pid:
                win = by_pid[a]
                break
        if win:
            break
    if not win:
        return None, False
    looking = bool(win.get("is_focused")) and win_active == "1" and pane_active == "1"
    return win.get("id"), looking


def plain(text, n=140):
    text = re.sub(r"```.*?```", " ", text or "", flags=re.S)
    text = re.sub(r"[*_`#>|]+", "", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 1].rsplit(" ", 1)[0] + "…"


def main():
    try:
        e = json.load(sys.stdin)
    except ValueError:
        return
    if not shutil.which("notify-send"):
        return
    event = e.get("hook_event_name")
    project = os.path.basename(e.get("cwd") or os.getcwd())
    if event == "Stop":
        if e.get("stop_hook_active"):
            return
        title = f"Claude finished · {project}"
        body = plain(e.get("last_assistant_message")) or "Done."
        urgency = "normal"
    elif event == "Notification":
        kind = e.get("notification_type") or ""
        if kind == "idle_prompt":      # the Stop banner already said so
            return
        title = e.get("title") or f"Claude needs you · {project}"
        if project not in title:
            title += f" · {project}"
        body = plain(e.get("message")) or "Waiting for you."
        urgency = "critical" if "permission" in kind else "normal"
    else:
        return

    pane = os.environ.get("TMUX_PANE")
    win_id, looking = terminal_window(pane)
    if looking:
        return

    # Detach so Claude isn't held up; wait for a click to focus the terminal.
    if os.fork():
        return
    os.setsid()
    act = run("notify-send", "-a", "Claude Code", "-u", urgency, "-A", "focus=Open",
              "--wait", title, body, timeout=600)
    if act == "focus":
        if win_id is not None:
            run("niri", "msg", "action", "focus-window", "--id", str(win_id))
        if pane:
            run("tmux", "switch-client", "-t", pane)
            run("tmux", "select-window", "-t", pane)
            run("tmux", "select-pane", "-t", pane)


if __name__ == "__main__":
    main()
