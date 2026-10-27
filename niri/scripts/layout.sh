#!/usr/bin/env bash
# layout.sh save|restore — carry niri's window layout across a compositor switch.
#
# restore-apps.sh relaunches the apps; this puts them back. `save` (called by
# restore-apps.sh save, on niri) records for every window: its app, the
# workspace it was on (index and name), its column and place in the column,
# its width, and whether it floated. `restore` (startup.sh) waits for the
# relaunched windows, then rebuilds that: workspaces in order, project names,
# columns left to right, stacked windows, widths. Windows are matched by app
# id, in order, so two Zen windows land in the two Zen slots.
#
# Only a layout saved in the last two minutes is used: a plain login, or a
# switch in from Hyprland, starts fresh.
set -uo pipefail

FILE=${XDG_RUNTIME_DIR:-/tmp}/niri-layout.json
MAX_AGE=120
# From config.kdl's layout: struts left + right, gaps, border width. niri sizes
# a column at proportion p as p * (screen - struts - gap) - gap, border
# included, which is what turns a window's pixels back into the p it was at.
STRUTS=32 GAP=8 BORDER=2

case ${1:-} in
save)
	ws=$(niri msg -j workspaces)
	width=$(niri msg -j focused-output | jq '.logical.width')
	niri msg -j windows | jq --argjson ws "$ws" --argjson W "${width:-1600}" \
		--argjson S "$STRUTS" --argjson G "$GAP" --argjson B "$BORDER" '
		($ws | map({key: (.id | tostring), value: .}) | from_entries) as $w
		| map({
				app: .app_id,
				idx: $w[.workspace_id | tostring].idx,
				name: $w[.workspace_id | tostring].name,
				col: (.layout.pos_in_scrolling_layout[0] // 0),
				row: (.layout.pos_in_scrolling_layout[1] // 0),
				floating: .is_floating,
				width: ((.layout.window_size[0] + 2 * $B + $G) / ($W - $S - $G) * 1000 | round / 10),
				focused: .is_focused
			})
		| sort_by(.idx, .col, .row)' >"$FILE"
	;;
restore)
	[[ -s $FILE ]] || exit 0
	(($(date +%s) - $(stat -c %Y "$FILE") < MAX_AGE)) || { rm -f "$FILE"; exit 0; }
	saved=$(<"$FILE")
	rm -f "$FILE"

	# Wait (up to ~30s) until every saved app has as many windows as before.
	need=$(jq -c 'group_by(.app) | map({key: .[0].app, value: length}) | from_entries' <<<"$saved")
	for _ in $(seq 60); do
		have=$(niri msg -j windows | jq -c 'group_by(.app_id) | map({key: .[0].app_id, value: length}) | from_entries')
		jq -e --argjson h "$have" 'to_entries | all(($h[.key] // 0) >= .value)' <<<"$need" >/dev/null && break
		sleep 0.5
	done
	sleep 0.5

	# Pair each saved slot with a live window of the same app, oldest first.
	plan=$(niri msg -j windows | jq -c --argjson s "$saved" '
		(group_by(.app_id) | map({key: .[0].app_id, value: (sort_by(.id) | map(.id))}) | from_entries) as $live
		| reduce ($s | to_entries[]) as $e ({used: {}, out: []};
			($e.value.app) as $a | (.used[$a] // 0) as $n
			| if ($live[$a] // [])[$n] then
				.used[$a] = $n + 1 | .out += [$e.value + {id: $live[$a][$n]}]
			  else . end)
		| .out')

	# Saved workspaces, in order, become 1, 2, ...
	order=$(jq -r '[.[].idx] | unique | .[]' <<<"$plan")
	target=1
	for idx in $order; do
		jq -c --argjson i "$idx" '.[] | select(.idx == $i)' <<<"$plan" >"$FILE.ws"
		name=$(jq -r 'select(.name != null) | .name' "$FILE.ws" | head -n1)

		# Everything for this workspace over there first, in saved order.
		while read -r w; do
			id=$(jq -r .id <<<"$w")
			niri msg action move-window-to-workspace --window-id "$id" --focus false "$target"
		done <"$FILE.ws"

		# Then columns left to right: each tiled window to its column, a
		# window lower in a column folded into the one before it.
		pos=0
		while read -r w; do
			id=$(jq -r .id <<<"$w")
			niri msg action focus-window --id "$id"
			if [[ $(jq -r .floating <<<"$w") == true ]]; then
				niri msg action move-window-to-floating --id "$id"
				continue
			fi
			niri msg action move-window-to-tiling --id "$id"
			if (($(jq -r .row <<<"$w") > 1)); then
				niri msg action move-column-to-index $((pos + 1))
				niri msg action consume-or-expel-window-left
			else
				pos=$((pos + 1))
				niri msg action move-column-to-index "$pos"
				niri msg action set-column-width "$(jq -r .width <<<"$w")%"
			fi
		done <"$FILE.ws"

		[[ -n $name ]] && niri msg action set-workspace-name --workspace "$target" "$name"
		target=$((target + 1))
	done
	rm -f "$FILE.ws"

	# Back to the window that had focus.
	id=$(jq -r 'map(select(.focused)) | .[0].id // empty' <<<"$plan")
	[[ -n $id ]] && niri msg action focus-window --id "$id"
	;;
*)
	echo "usage: ${0##*/} save|restore" >&2
	exit 2
	;;
esac
