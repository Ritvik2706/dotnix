# niri-socket.sh — sourced: after niri is restarted in place, $NIRI_SOCKET (inherited
# by whatever outlived it, the island and what it runs) names a socket that is gone.
# Point it at the live one: niri.<display>.<pid>.sock of a niri still running, newest
# first. Nothing changes on Hyprland (no NIRI_SOCKET) or while the old one is there.
if [[ -n ${NIRI_SOCKET:-} && ! -S $NIRI_SOCKET ]]; then
	for _s in $(ls -t "${XDG_RUNTIME_DIR:-/run/user/$UID}"/niri.*.sock 2>/dev/null); do
		_p=${_s%.sock}; _p=${_p##*.}
		if [[ -S $_s && -d /proc/$_p ]]; then export NIRI_SOCKET=$_s; break; fi
	done
	unset _s _p
fi
