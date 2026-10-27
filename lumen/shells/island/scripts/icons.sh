#!/usr/bin/env bash
# icons.sh — app icons from the WhiteSur-dark icon theme (waybar's), for the
# island. Reads icon names on stdin, one per line; prints, for each, the path
# of that icon in WhiteSur-dark (then WhiteSur, which it is built from), or
# "-" when the theme has none (the island then falls back to the app's own).
# A name that is already a path is passed through.
themes=("$HOME/.local/share/icons/WhiteSur-dark" "/usr/share/icons/WhiteSur-dark" "$HOME/.local/share/icons/WhiteSur" "/usr/share/icons/WhiteSur")
dirs=(apps/scalable apps/32 apps/22 apps/16)
while IFS= read -r name; do
	out="-"
	if [[ "$name" == /* ]]; then
		[[ -f "$name" ]] && out="$name"
	elif [[ -n "$name" ]]; then
		for t in "${themes[@]}"; do
			for d in "${dirs[@]}"; do
				for ext in svg png; do
					if [[ -f "$t/$d/$name.$ext" ]]; then out="$t/$d/$name.$ext"; break 3; fi
				done
			done
		done
	fi
	printf '%s\n' "$out"
done
