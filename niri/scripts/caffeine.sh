#!/usr/bin/env bash
# caffeine.sh — keep the machine awake (Mod+Ctrl+I). niri has no per-window
# idle_inhibit like Hyprland, so this pauses idle handling as a whole by
# stopping hypridle, and starts it again on the next press. Closing the lid
# still locks: that path is niri's switch-events -> sleep-lock.sh.
set -euo pipefail

if pgrep -x hypridle >/dev/null; then
	pkill -x hypridle
	notify-send -a Idle -t 2000 "Caffeine ON" "Staying awake until Mod+Ctrl+I again"
else
	setsid -f hypridle >/dev/null 2>&1
	notify-send -a Idle -t 2000 "Caffeine OFF" "Idle lock and sleep restored"
fi
