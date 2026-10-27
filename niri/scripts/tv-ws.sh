#!/usr/bin/env bash
# tv-ws.sh focus|move <n> — Hyprland's Mod+Ctrl+N "secondary monitor
# workspaces": jump to (or send the focused column to) workspace N on the TV,
# whichever monitor you're on now.
set -euo pipefail

OUT=HDMI-A-1
if ! niri msg -j outputs | jq -e --arg o "$OUT" 'has($o)' >/dev/null; then
	notify-send -a Niri -t 1500 "TV not connected" "$OUT is not plugged in"
	exit 0
fi

case $1 in
focus)
	niri msg action focus-monitor "$OUT"
	niri msg action focus-workspace "$2"
	;;
move)
	niri msg action move-column-to-monitor "$OUT"
	niri msg action move-column-to-workspace "$2"
	;;
*) echo "usage: ${0##*/} focus|move <n>" >&2; exit 2 ;;
esac
