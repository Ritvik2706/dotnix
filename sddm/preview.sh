#!/usr/bin/env bash
# Render the LUMEN theme at TRUE monitor resolution and screenshot it.
#
# Prefer this over `sddm-greeter-qt6 --test-mode`, whose window is a fixed
# 1600x900 — that aspect makes anything in the lower third look bottom-jammed
# and has caused two false layout calls already. See stub.py for how the
# greeter's context properties are faked.
#
# Usage:  ./preview.sh [out.png] [typed-text]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

OUT="${1:-/tmp/lumen-preview.png}"
TEXT="${2:-}"
RES="${RES:-2560x1440}"
W="${RES%x*}"; H="${RES#*x}"
MON="${MON:-eDP-1}"

D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
cp lumen/*.qml lumen/background.png "$D"/
python3 stub.py "$D" "$W" "$H" "$TEXT"

qml6 "$D/Main.qml" &
QP=$!
for _ in $(seq 1 40); do
    A=$(hyprctl clients -j | python3 -c "import json,sys;[print(c['address']) for c in json.load(sys.stdin) if c['class']=='org.qt-project.qml']" | head -1)
    [ -n "$A" ] && break
    sleep 0.25
done
[ -n "${A:-}" ] || { echo "preview window never appeared" >&2; kill $QP 2>/dev/null; exit 1; }

# Hyprland tiles the window to the layout, ignoring the size QML asks for, so
# float it and go fullscreen — the monitor is exactly $RES, giving a true 1:1
# render of what the greeter will draw at boot.
hyprctl dispatch setfloating "address:$A" >/dev/null || true
hyprctl dispatch focuswindow "address:$A" >/dev/null || true
hyprctl dispatch fullscreen 0 >/dev/null || true
sleep 1.5
grim -o "$MON" "$OUT"
kill $QP 2>/dev/null || true
wait $QP 2>/dev/null || true
echo "$OUT"
