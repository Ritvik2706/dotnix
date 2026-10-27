#!/usr/bin/env bash
# focus-or-spawn.sh <app-id regex> <cmd...> — run-or-raise for niri.
#   Not open: launch it. Open: jump to its window on this workspace (this
#   project) if there is one, else its most recently used one anywhere.
#   Already on one: step to its next window, so pressing again cycles
#   through every window of that app.
set -euo pipefail

re=$1
shift

ws=$(niri msg -j workspaces | jq -r '.[] | select(.is_focused) | .id')
id=$(niri msg -j windows | jq -r --arg re "$re" --argjson ws "${ws:-0}" '
	[.[] | select((.app_id // "") | test($re))] as $m
	| if ($m | length) == 0 then empty
	  elif any($m[]; .is_focused) then
		($m | sort_by(.id)) as $s
		| ($s | map(.is_focused) | index(true)) as $i
		| $s[($i + 1) % ($s | length)].id
	  else
		$m | sort_by(.workspace_id != $ws, -(.focus_timestamp.secs // 0), -(.focus_timestamp.nanos // 0))
		| .[0].id
	  end')

if [[ -n $id ]]; then
	niri msg action focus-window --id "$id"
else
	setsid -f "$@" >/dev/null 2>&1
fi
