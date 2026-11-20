#!/usr/bin/env python3
"""PostToolUse: log what Claude just did for the side pane (claude/pane.py).

Appends one JSON line per tool call to
$XDG_RUNTIME_DIR/claude-pane/<session>.jsonl and pings every open pane over
its unix socket, so panes redraw on events instead of polling. Never fails
the tool call: any error just exits 0.

Each record carries the Claude's tmux pane ($TMUX_PANE), so the pane can show
the Claude you're looking at. `activity.py --focus <pane id>` is run by a
tmux hook (tmux/tmux.conf) when the focused tmux pane changes: it records it
in $XDG_RUNTIME_DIR/claude-pane/focus and pings the panes.

Shell commands: `activity.py --pre` (PreToolUse, Bash) notes when the command
starts; afterwards the record lists the files in the command's git repo that
changed since then ("changed"), so files Claude changes through commands
(sed, scripts) count as changed too.

Logs over 8 MB are rotated (the pane notices and re-reads).
"""
import json
import os
import socket
import subprocess
import sys
import time

MAX_TEXT = 200_000  # cap stored edit text / original file
MAX_LOG = 8 << 20
DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "claude-pane")


def ping(msg=b"1"):
    """Wake the panes (datagram sockets pane-<pid>.sock); drop dead ones."""
    for name in os.listdir(DIR):
        if not name.endswith(".sock"):
            continue
        p = os.path.join(DIR, name)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            s.sendto(msg, p)
        except (ConnectionRefusedError, FileNotFoundError):
            try:
                os.unlink(p)
            except OSError:
                pass
        except OSError:
            pass
        finally:
            s.close()


def narration(transcript):
    """What Claude last said it was doing (its newest text since your last
    message), read from the end of the session transcript: the pane shows it
    as the "why" of each step."""
    try:
        with open(transcript, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 512 * 1024))
            lines = f.read().decode(errors="replace").splitlines()[1:]
    except (OSError, TypeError):
        return None
    for line in reversed(lines):
        if '"assistant"' not in line and '"user"' not in line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        content = (d.get("message") or {}).get("content")
        if d.get("type") == "user":
            if isinstance(content, str) or (isinstance(content, list) and any(
                    b.get("type") == "text" for b in content if isinstance(b, dict))):
                return None   # your message: nothing said since
            continue          # a tool result
        if d.get("type") == "assistant" and isinstance(content, list):
            texts = [b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip()]
            if texts:
                return " ".join(texts[-1].split())[:600]
    return None


def pre_path(ev):
    return os.path.join(DIR, "pre-" + str(ev.get("tool_use_id") or ev.get("session_id") or "x"))


def changed_since(cwd, t0):
    """files in cwd's git repo modified since t0 (tracked or not, max 50)"""
    try:
        root = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                              capture_output=True, text=True, timeout=3).stdout.strip()
        if not root:
            return []
        out = subprocess.run(["git", "-C", root, "status", "--porcelain=v1", "-z", "-uall"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    found = []
    for item in out.split("\0"):
        if len(item) < 4:
            continue
        p = os.path.join(root, item[3:])
        if "__pycache__" in p or p.endswith((".pyc", ".o")):
            continue
        try:
            if os.path.isfile(p) and os.path.getmtime(p) >= t0 - 0.5:
                found.append(p)
        except OSError:
            pass
        if len(found) >= 50:
            break
    return found


def main():
    ev = json.load(sys.stdin)
    sid = ev.get("session_id") or "unknown"
    tool = ev.get("tool_name") or "?"
    ti = ev.get("tool_input") or {}
    rec = {"t": time.time(), "cwd": ev.get("cwd") or os.getcwd(), "tool": tool}
    if os.environ.get("TMUX_PANE"):
        rec["tmux"] = os.environ["TMUX_PANE"]
    why = narration(ev.get("transcript_path"))
    if why:
        rec["why"] = why

    resp = ev.get("tool_response")
    path = ti.get("file_path") or ti.get("notebook_path")
    if path:
        rec["path"] = path
    if tool in ("Edit", "MultiEdit"):
        edits = ti.get("edits") or [{"old_string": ti.get("old_string", ""),
                                     "new_string": ti.get("new_string", ""),
                                     "replace_all": ti.get("replace_all", False)}]
        rec["edits"] = [{"old": e.get("old_string", "")[:MAX_TEXT],
                         "new": e.get("new_string", "")[:MAX_TEXT],
                         "all": bool(e.get("replace_all"))} for e in edits]
    elif tool == "Write":
        rec["content"] = (ti.get("content") or "")[:MAX_TEXT]
    elif tool == "Read":
        rec["offset"], rec["limit"] = ti.get("offset"), ti.get("limit")
    elif tool == "Bash":
        rec["what"] = ti.get("description") or ti.get("command", "")
        rec["cmd"] = (ti.get("command") or "")[:500]
        if isinstance(resp, dict):
            out = (resp.get("stdout") or "") + (resp.get("stderr") or "")
            rec["out"] = out[-2000:]
        try:  # files the command changed (see --pre)
            pp = pre_path(ev)
            t0 = float(open(pp).read())
            os.unlink(pp)
            ch = changed_since(rec["cwd"], t0)
            if ch:
                rec["changed"] = ch
        except (OSError, ValueError):
            pass
    # the file before the edit, when Claude Code reports it (lets the pane
    # replay the edit exactly)
    if tool in ("Edit", "MultiEdit", "Write") and isinstance(resp, dict):
        orig = resp.get("originalFile")
        if isinstance(orig, str) and len(orig) <= MAX_TEXT:
            rec["orig"] = orig
    elif tool in ("Grep", "Glob"):
        rec["what"] = ti.get("pattern", "")
        if ti.get("path"):
            rec["where"] = ti["path"]
    elif tool in ("WebFetch",):
        rec["what"] = ti.get("url", "")
    elif tool in ("WebSearch",):
        rec["what"] = ti.get("query", "")
    elif tool in ("Agent", "Task"):
        rec["what"] = ti.get("description", "")
    elif tool == "Skill":
        rec["what"] = ti.get("skill", "")

    os.makedirs(DIR, mode=0o700, exist_ok=True)
    log = os.path.join(DIR, sid + ".jsonl")
    try:
        if os.path.getsize(log) > MAX_LOG:
            os.replace(log, log + ".old")
    except OSError:
        pass
    with open(log, "a") as f:
        f.write(json.dumps(rec) + "\n")
    ping()


try:
    if len(sys.argv) == 2 and sys.argv[1] == "--pre":
        ev = json.load(sys.stdin)
        os.makedirs(DIR, mode=0o700, exist_ok=True)
        with open(pre_path(ev), "w") as f:
            f.write(str(time.time()))
        for name in os.listdir(DIR):  # interrupted commands leave theirs behind
            q = os.path.join(DIR, name)
            if name.startswith("pre-") and time.time() - os.path.getmtime(q) > 3600:
                os.unlink(q)
    elif len(sys.argv) == 3 and sys.argv[1] == "--focus":
        os.makedirs(DIR, mode=0o700, exist_ok=True)
        with open(os.path.join(DIR, "focus"), "w") as f:
            f.write(sys.argv[2])
        ping(b"f")
    else:
        main()
except Exception:
    pass
sys.exit(0)
