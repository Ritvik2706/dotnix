#!/usr/bin/env bash
# switch-wm.sh [niri|hyprland] — hand the session to the other compositor.
# lumen-session (dotnix/system) sees the request when this compositor exits
# and starts the other in the same login, without locking again. With no
# argument, whichever one isn't running. Refused while the screen is locked.
set -uo pipefail
RUN=${XDG_RUNTIME_DIR:-/run/user/$UID}

if [[ -n ${NIRI_SOCKET:-} && -S $NIRI_SOCKET ]]; then cur=niri; else cur=hyprland; fi
to=${1:-$([[ $cur == niri ]] && echo hyprland || echo niri)}
[[ $to == "$cur" ]] && exit 0
pidof -q hyprlock && { echo "the screen is locked" >&2; exit 1; }
# Outside lumen-session nothing would start the other one: the session would just end.
pgrep -u "$UID" -f 'dotnix/system/lumen-session' >/dev/null || { echo "not running under lumen-session" >&2; exit 2; }

"$(dirname "${BASH_SOURCE[0]}")/restore-apps.sh" save
printf '%s\n' "$to" >"$RUN/lumen-switch"
if [[ $cur == niri ]]; then
	niri msg action quit --skip-confirmation
else
	uwsm stop >/dev/null 2>&1 || hyprctl dispatch 'hl.dsp.exit()' >/dev/null
fi
