#!/usr/bin/env bash
# restore-apps.sh save|restore — carry the open apps across a compositor switch.
#
# Windows can't outlive the compositor they belong to, so switch-wm.sh saves
# what each window was started as (its process's command line) and the new
# compositor's autostart relaunches them: browsers reopen their tabs, Ghostty
# reattaches to tmux. Restore only acts right after a switch (switch-grace.sh)
# and skips what the autostart already starts.
set -uo pipefail
RUN=${XDG_RUNTIME_DIR:-/run/user/$UID}
LIST=$RUN/lumen-switch-apps

case ${1:-} in
	save)
		# The pid of each window, from whichever compositor is running.
		if [[ -n ${NIRI_SOCKET:-} && -S $NIRI_SOCKET ]]; then
			pids=$(niri msg -j windows | jq -r '.[].pid // empty')
			# And where each window was, for when niri comes back.
			"$HOME/.config/niri/scripts/layout.sh" save
		else
			pids=$(hyprctl clients -j | jq -r '.[] | select(.mapped) | .pid')
		fi
		: >"$LIST"
		for pid in $pids; do
			[[ -r /proc/$pid/cmdline ]] || continue
			# One line per app, its arguments NUL-separated, kept as given.
			tr '\0' '\037' </proc/"$pid"/cmdline >>"$LIST"
			echo >>"$LIST"
		done
		sort -u -o "$LIST" "$LIST"
		;;
	restore)
		[[ -s $LIST ]] || exit 0
		"$HOME/.config/hypr/scripts/switch-grace.sh" && exit 0   # 0 = no switch just happened
		while IFS= read -r line; do
			IFS=$'\037' read -r -a argv <<<"$line"
			((${#argv[@]})) || continue
			name=${argv[0]##*/}
			case $name in
				# Already started by the autostart, or tied to the old compositor.
				ghostty | lumen | awww-daemon | hyprlock | Hyprland | niri | xwayland-satellite | Xwayland) continue ;;
			esac
			setsid -f "${argv[@]}" >/dev/null 2>&1 </dev/null
		done <"$LIST"
		rm -f "$LIST"
		;;
	*) echo "usage: ${0##*/} save|restore" >&2; exit 2 ;;
esac
