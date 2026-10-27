#!/usr/bin/env bash
# privacy.sh — what is listening or watching, for the island's privacy dots:
# prints "mic cam screen" as 0/1. The microphone: an application recording
# from a source that is not a monitor (recording what plays doesn't count).
# The camera: the webcam driver in use (its module count goes up while a
# program has the camera open; no scan of every process, as fuser does). The screen: a portal
# screencast stream (xdg-desktop-portal-hyprland makes one node per screencast).
mon="$(pactl list sources short 2>/dev/null | awk '$2 ~ /\.monitor$/ {print $1}' | paste -sd, -)"
mic="$(pactl -f json list source-outputs 2>/dev/null | jq --arg m ",$mon," '[.[] | .source as $s | select(($m | contains("," + ($s | tostring) + ",")) | not)] | length' 2>/dev/null)"
[[ "${mic:-0}" -gt 0 ]] && mic=1 || mic=0
cam=0; [[ "$(cat /sys/module/uvcvideo/refcnt 2>/dev/null || echo 0)" -gt 0 ]] && cam=1
scr=0; pw-cli ls Node 2>/dev/null | grep -qiE 'node.name = "(xdg-desktop-portal-hyprland|xdph|.*screencast)' && scr=1
echo "$mic $cam $scr"
