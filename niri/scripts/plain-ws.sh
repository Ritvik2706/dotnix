#!/usr/bin/env bash
# plain-ws.sh focus|move|send — Mod+6: the laptop's first workspace that is not
# a fixed home (the first plain or project one). It has no name to go by, and
# an index only means the focused monitor, so this finds it from either monitor.
#   focus  go there        move  take the column along        send  throw it, stay
set -euo pipefail

OUT=eDP-2
FIXED='^(browser|terminal|docs|tools|media|TV [7890])$'

idx=$(niri msg -j workspaces | jq -r --arg o "$OUT" --arg f "$FIXED" '
	[.[] | select(.output == $o and ((.name // "") | test($f) | not))] | min_by(.idx).idx')
from=$(niri msg -j focused-output | jq -r .name)

case ${1:-} in
focus)
	niri msg action focus-monitor "$OUT"
	niri msg action focus-workspace "$idx"
	;;
move)
	[[ $from == "$OUT" ]] || niri msg action move-column-to-monitor "$OUT"
	niri msg action move-column-to-workspace "$idx"
	;;
send)
	[[ $from == "$OUT" ]] || niri msg action move-column-to-monitor "$OUT"
	niri msg action move-column-to-workspace --focus false "$idx"
	[[ $from == "$OUT" ]] || niri msg action focus-monitor "$from"
	;;
*) echo "usage: ${0##*/} focus|move|send" >&2; exit 2 ;;
esac
