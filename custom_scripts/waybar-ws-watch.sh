#!/usr/bin/env bash
# waybar-ws-watch.sh
# Long-running listener on Hyprland's event socket (socket2). On any workspace-
# relevant event it pokes waybar (SIGRTMIN+1) so the per-workspace custom
# modules (waybar-ws.sh) refresh instantly instead of polling on a timer.
#
# Run as a hidden waybar custom module so waybar owns its lifecycle (it gets
# killed/respawned on reload, so no duplicate listeners accumulate).
set -euo pipefail

sock="$XDG_RUNTIME_DIR/hypr/${HYPRLAND_INSTANCE_SIGNATURE}/.socket2.sock"

# Kick once so pills are correct immediately on start.
pkill -RTMIN+1 waybar 2>/dev/null || true

# socat-free reader: nc isn't guaranteed either, so use a tiny python bridge.
python3 - "$sock" <<'PY'
import socket, sys, subprocess
sock = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
buf = b""
WAKE = (b"workspace", b"createworkspace", b"destroyworkspace",
        b"focusedmon", b"moveworkspace", b"activewindow")
while True:
    data = s.recv(4096)
    if not data:
        break
    buf += data
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        ev = line.split(b">>", 1)[0]
        if ev in WAKE:
            subprocess.run(["pkill", "-RTMIN+1", "waybar"])
PY
