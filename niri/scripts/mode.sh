#!/usr/bin/env bash
# mode.sh perf|opaque|off — live look overrides, niri's answer to Hyprland's
# `hl.config{}` / `hyprctl keyword` toggles.
#   perf    (Mod+F12):         no animations, blur or shadows (battery, games)
#   opaque  (Mod+Shift+Space): every window fully opaque, no frost
# Each call toggles that mode. The overrides live in ../mode.kdl, which
# config.kdl includes last so it wins; with every mode off the file is put
# back exactly as committed, so git only sees it while a mode is on.
set -euo pipefail

FILE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/mode.kdl"

on=$(sed -n '1s|^// on:||p' "$FILE" 2>/dev/null)
case ${1:-} in
perf | opaque)
	if [[ " $on " == *" $1 "* ]]; then on=${on// $1/}; was=on; else on="$on $1"; was=off; fi ;;
off) on= ;;
*) echo "usage: ${0##*/} perf|opaque|off" >&2; exit 2 ;;
esac

{
	echo "// on:$on"
	echo "// Written by scripts/mode.sh — the live look toggles. Leave empty here."
	if [[ " $on " == *" perf "* ]]; then
		echo 'animations { off; }'
		echo 'layout { shadow { off; }; }'
		echo 'blur { off; }'
	fi
	if [[ " $on " == *" opaque "* ]]; then
		echo 'window-rule { opacity 1.0; background-effect { blur false; }; }'
	fi
} >"$FILE"
# niri also watches includes; the explicit reload just makes it immediate.
niri msg action load-config-file >/dev/null 2>&1 || true

[[ ${1} == off ]] && exit 0
case $1 in
perf) title="Performance mode"; body="no animations, blur, shadows" ;;
opaque) title="Opaque mode"; body="no transparency or frost" ;;
esac
[[ $was == off ]] && state=ON || state=OFF
notify-send -a Niri -t 1500 "$title $state" "$body"
