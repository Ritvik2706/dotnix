# Sourced by the lock scripts (face-unlock.sh, sleep-lock.sh, resume-lock.sh):
# the few questions they ask the session, answered under Hyprland or niri.
# NIRI_SOCKET marks a niri session, as in unblank.sh and boot-unblank.sh.

# Is the session covered by the lock? Hyprland knows exactly. niri has no
# such query, but hyprlock only exits after it has unlocked (and niri keeps the
# session locked if it dies), so "hyprlock is running" means locked. Only a
# literal yes counts: an unreachable compositor must never look locked.
session_locked() {
    if [[ -n ${NIRI_SOCKET:-} ]]; then
        pidof -q hyprlock
    else
        [[ $(hyprctl locked 2>/dev/null) == "true" ]]
    fi
}

# Is any panel lit? From the kernel, not the compositor, so it is the same
# answer under both: a connected, enabled connector whose DPMS is On. Both
# Hyprland's dpms off and niri's power-off-monitors switch it Off.
panel_on() {
    local c e d
    for c in /sys/class/drm/card*-*/; do
        e="" d=""
        { read -r e < "$c/enabled"; read -r d < "$c/dpms"; } 2>/dev/null
        [[ $e == enabled && $d == On ]] && return 0
    done
    return 1
}

# Switch the panels back on.
panel_wake() {
    if [[ -n ${NIRI_SOCKET:-} ]]; then
        niri msg action power-on-monitors >/dev/null 2>&1
    else
        hyprctl dispatch 'hl.dsp.dpms({action="on"})' >/dev/null 2>&1
    fi
}
