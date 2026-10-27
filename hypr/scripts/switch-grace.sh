#!/usr/bin/env bash
# switch-grace.sh — ExecCondition of hyprlock.service and hyprlock-blank.service.
#
# Exits 1 (systemd: skip this start, not a failure) for 15s after lumen-session
# has switched compositors, since that hand-over happens inside a session that
# was unlocked when the switch was asked for (switch-wm.sh refuses while
# locked). Any other time, 0: lock as usual. The flag lives in the runtime
# dir, so it never survives a reboot, and lumen-session clears it at login.
f=${XDG_RUNTIME_DIR:-/run/user/$UID}/lumen-switch-unlocked
[[ -f $f ]] && (($(date +%s) - $(stat -c %Y "$f") < 15)) && exit 1
exit 0
