#!/usr/bin/env bash
#
# Face unlock for hyprlock — runs BESIDE the lock, never in front of it.
#
#   face-unlock.sh run           the scanner (hyprlock-face.service runs this)
#   face-unlock.sh rearm         "I'm here, look again" — safe to call anytime
#   face-unlock.sh lock-exited   hyprlock.service ExecStopPost bookkeeping
#
# ── WHY NOT pam_howdy ────────────────────────────────────────────────────
#
# hyprlock holds exactly one PAM conversation at a time. With pam_howdy
# stacked ahead of pam_unix that conversation belongs to the camera for the
# whole scan, so the lock screen ignores your typing until howdy gives up.
#
# Instead /etc/pam.d/hyprlock is password-only (system/lock-setup.sh), so the
# field is live the instant the lock appears, and this script runs howdy's own
# matcher (compare.py) in parallel. A match becomes an unlock via SIGUSR1,
# which hyprlock handles as "unlock now".
#
# It can only ever UNLOCK. Broken, missing, uninstalled, camera unplugged —
# the password path does not depend on any of it. (And it is not a new hole:
# any process running as you can already SIGUSR1 hyprlock.)
#
# ── WHEN IT LOOKS — the Face ID model ────────────────────────────────────
#
# A lock starts DORMANT. Scanning the moment the lock comes up is wrong both
# ways: after Super+Alt+L you are still in the chair, so the camera would let
# you straight back in and the lock would be pointless; after an idle lock the
# chair is empty and the scan is wasted.
#
# It looks when you come back to the machine:
#   · any input after 5s of none        (hypridle listener → rearm)
#   · the panel waking from idle-blank  (unblank.sh → rearm)
#   · waking from suspend / lid open    (resume-lock.sh → rearm)
#   · lid shut→open or panel off→on while locked (noticed here)
#   · SUPER+CTRL+ALT+F                  (forced rescan)
# and only while it can see anyone at all: lid open, panel on. Up to
# MAX_ATTEMPTS scans per arming, then dormant again until the next of those.
#
# ── WHEN IT REFUSES — password first ─────────────────────────────────────
#
# Like Face ID: after a restart (or full logout) the password must be used
# once before face unlock is allowed, and again if it has not been used for
# REQUIRE_PASSWORD_AFTER_HOURS. Someone who has your face but not your
# password cannot get in from a cold boot. "Password used" is recorded by
# `lock-exited`, in $XDG_RUNTIME_DIR, which the system wipes on reboot.
#
# ── WHAT YOU SEE ─────────────────────────────────────────────────────────
#
# One quiet line under the dots (hyprlock.conf reads $STATUS_FILE). Empty
# unless there is something worth saying.
set -uo pipefail

# ── policy ────────────────────────────────────────────────────────────────
MAX_ATTEMPTS=3                    # scans per arming (~6s each here)
MAX_CAM_ERRORS=4                  # camera busy/missing: tries before giving up
CAM_RETRY_SECS=1.5                # …spaced so a camera still waking from
                                  # suspend (~2-3s here) is caught, not given up on
REQUIRE_PASSWORD_AFTER_BOOT=1     # 1 = password once per boot before face works
REQUIRE_PASSWORD_AFTER_HOURS=48   # 0 = never expire
LOCK_WAIT_SECS=10                 # how long `run` waits for the lock to engage
REARM_FRESH_SECS=5                # a rearm older than this is ignored at start

# ── paths ─────────────────────────────────────────────────────────────────
COMPARE=/usr/lib/howdy/compare.py
HOWDY_CONF=/etc/howdy/config.ini
FACE_UNIT=hyprlock-face.service
LOCK_UNIT=hyprlock.service
USER=${USER:-$(id -un)}
STATE=${XDG_RUNTIME_DIR:-/run/user/$UID}/face-unlock
STATUS_FILE=$STATE/status
REARM_FILE=$STATE/rearm
PASSWORD_OK=$STATE/password-ok
FACE_SIGNALLED=$STATE/face-signalled

mkdir -p -m 700 "$STATE" 2>/dev/null

log()    { printf '%s\n' "$*"; }
# Atomic, so hyprlock's label never reads a half-written line.
status() { printf '%s' "$1" > "$STATUS_FILE.tmp" 2>/dev/null && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE" 2>/dev/null; return 0; }
# The compositor is the authority on whether the session is covered (see
# lock-state.sh: Hyprland's word, or under niri, hyprlock still running).
# shellcheck source=lock-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lock-state.sh"
locked() { session_locked; }
# A sleep that a trapped signal (the rearm nudge) cuts short.
nap()    { sleep "$1" & local p=$!; wait "$p" 2>/dev/null; kill "$p" 2>/dev/null; return 0; }
age()    { local m; m=$(stat -c %Y "$1" 2>/dev/null) || return 1; echo $(( EPOCHSECONDS - m )); }

# ══ rearm ═══════════════════════════════════════════════════════════════
# Called from hypridle on EVERY return from 5s of idle, locked or not, so the
# unlocked path must be cheap and must never start anything.
#
# The nudge is SIGURG, not USR1, on purpose: its default disposition is
# IGNORE. A scanner that has not installed its trap yet shrugs it off instead
# of dying, and picks the request up from $REARM_FILE instead — the file is the
# message, the signal only makes it prompt.
cmd_rearm() {
    if systemctl --user is-active --quiet "$FACE_UNIT"; then
        : > "$REARM_FILE"
        systemctl --user kill --kill-whom=main -s URG "$FACE_UNIT" 2>/dev/null
        # Called from hypridle (stdout nowhere): say so in the scanner's log.
        logger -t face-unlock "rearm: you're back — scanner nudged" 2>/dev/null
        return 0
    fi
    locked || return 0
    logger -t face-unlock "rearm: locked with no scanner — starting one" 2>/dev/null
    # Locked but no scanner (it is between restarts, or died): start one.
    # Requisite= on the unit makes this a no-op unless hyprlock.service is
    # active — it can never be the thing that locks the screen.
    : > "$REARM_FILE"
    systemctl --user start --no-block "$FACE_UNIT" 2>/dev/null
    return 0
}

# ══ lock-exited ═════════════════════════════════════════════════════════
# hyprlock.service ExecStopPost. Decides whether that exit was a PASSWORD
# unlock, which is what the password-first policy keys on.
#
#   compositor unlocked + no face marker → password unlock → record it
#   compositor unlocked + face marker    → face unlock     → nothing
#   compositor still locked              → crash or swap   → nothing
cmd_lock_exited() {
    local by_face=0 r
    [[ -e $FACE_SIGNALLED ]] && by_face=1
    rm -f "$FACE_SIGNALLED" "$REARM_FILE"
    # This runs in the middle of every swap, where the screen has no lock
    # client until we return — so be fast. systemd says how hyprlock ended:
    # an unlock is always a clean exit 0; a swap (SIGTERM) or crash is not,
    # and needs no compositor round-trips at all.
    if [[ -n ${EXIT_CODE:-} && ( $EXIT_CODE != exited || ${EXIT_STATUS:-} != 0 ) ]]; then
        return 0
    fi
    # Clean exit. hyprlock unlocks before it exits (measured: unlock at
    # ~0.85s, exit later still), so the compositor has normally long caught
    # up; a short grace covers the rest without stalling a swap that
    # happened to exit 0.
    # niri can't be asked, but needs no asking: under ext-session-lock a clean
    # exit 0 from hyprlock IS the unlock (it only exits after unlocking).
    if [[ -n ${NIRI_SOCKET:-} ]]; then
        if (( ! by_face )); then
            : > "$PASSWORD_OK"
            log "password unlock recorded"
        fi
        return 0
    fi
    for _ in {1..4}; do
        r=$(hyprctl locked 2>/dev/null)
        case $r in
            false)
                if (( ! by_face )); then
                    : > "$PASSWORD_OK"
                    log "password unlock recorded"
                fi
                return 0 ;;
            true) sleep 0.05 ;;
            *)    return 0 ;;   # Hyprland gone (logout): nothing to record
        esac
    done
    return 0
}

# ══ run ═════════════════════════════════════════════════════════════════
policy_block=""
password_policy_ok() {
    local a
    if [[ ! -e $PASSWORD_OK ]]; then
        if (( REQUIRE_PASSWORD_AFTER_BOOT )); then
            policy_block="Password required after restart"
            return 1
        fi
        return 0
    fi
    if (( REQUIRE_PASSWORD_AFTER_HOURS > 0 )); then
        a=$(age "$PASSWORD_OK") || a=0
        if (( a > REQUIRE_PASSWORD_AFTER_HOURS * 3600 )); then
            policy_block="Password required for face unlock"
            return 1
        fi
    fi
    return 0
}

lid_open() {
    # No lid, or no ACPI node for it, counts as open.
    local f
    for f in /proc/acpi/button/lid/*/state; do
        [[ -r $f ]] || return 0
        [[ $(< "$f") == *open* ]] || return 1
    done
    return 0
}
# panel_on: lock-state.sh (the kernel's DPMS, under either compositor)
present()  { lid_open && panel_on; }   # lid first: a file read, no fork

scan() {
    # compare.py ALWAYS tries to launch howdy-gtk (a GTK popup that would
    # land on your desktop as you are let in) and only skips it when the
    # binary is not on PATH. So: a scrubbed environment with no PATH and no
    # display. The deadline is howdy's own timeout plus model load; past
    # that it is a hung camera, not a slow match.
    local t
    t=$(sed -nE 's/^[[:space:]]*timeout[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$HOWDY_CONF" 2>/dev/null | head -1)
    timeout -k 2 $(( ${t:-5} + 10 )) \
        /usr/bin/env -i PATH=/var/empty HOME="$HOME" USER="$USER" LANG="${LANG:-C.UTF-8}" \
        /usr/bin/python "$COMPARE" "$USER"
}

unlock() {
    locked || return 0   # a password unlock beat us to it
    : > "$FACE_SIGNALLED"
    log "face matched — unlocking"
    local try
    for try in 1 2; do
        systemctl --user kill --kill-whom=main -s USR1 "$LOCK_UNIT" 2>/dev/null
        for _ in {1..30}; do
            locked || return 0
            nap 0.1
        done
        log "still locked ${try}×3s after SIGUSR1"
    done
    # Matched, signalled twice, still locked: the wedged-hyprlock case that
    # resume-lock.sh exists for. Say so, and point at the escape hatch.
    rm -f "$FACE_SIGNALLED"
    status "Recognized, but the lock is stuck · Super+Ctrl+Alt+L"
    log "hyprlock did not unlock — wedged instance?"
    return 1
}

cmd_run() {
    exec 9> "$STATE/lock"
    flock -n 9 || { log "another scanner is running"; return 0; }

    local nudged=0
    trap 'nudged=1' URG
    # Never leave a line behind for the next lock to open on.
    trap 'status ""; pkill -P $$ 2>/dev/null' EXIT
    # Stopped by systemd (hyprlock exited): a normal end, not a failure.
    trap 'exit 0' TERM INT HUP

    if [[ ! -r $COMPARE ]]; then
        log "howdy is not installed — face unlock off"
        return 0
    fi
    if grep -qiE '^[[:space:]]*disabled[[:space:]]*=[[:space:]]*true' "$HOWDY_CONF" 2>/dev/null; then
        # pam_howdy honours this switch; compare.py does not.
        log "howdy is disabled in $HOWDY_CONF — face unlock off"
        return 0
    fi

    # Pulled in by hyprlock.service, so we usually start a beat BEFORE the
    # lock has engaged. Wait for it rather than mistaking "not yet" for
    # "already unlocked".
    local i
    for (( i = 0; i < LOCK_WAIT_SECS * 10; i++ )); do
        locked && break
        nap 0.1
    done
    locked || { log "session never locked — nothing to do"; return 0; }

    if ! password_policy_ok; then
        log "face unlock withheld: $policy_block"
        status "$policy_block"
        while locked; do nap 2; done
        return 0
    fi

    # A rearm can arrive before we exist (resume-lock.sh swaps hyprlock and
    # rearms in the same breath). Honour it only if it is that fresh — a
    # leftover from hours ago must not make a manual lock scan instantly.
    # Clear the nudge flag BEFORE reading the file: a rearm landing in
    # between then still arms us on the first loop instead of being lost.
    local armed=0 a
    nudged=0
    if a=$(age "$REARM_FILE") && (( a <= REARM_FRESH_SECS )); then
        armed=1
    fi
    rm -f "$REARM_FILE"

    local attempts=0 cam_errors=0 away=0 rc
    status ""
    if (( armed )); then log "ready — armed"; else log "ready — dormant until you come back"; fi

    while :; do
        locked || return 0

        if (( nudged )) || [[ -e $REARM_FILE ]]; then
            nudged=0
            rm -f "$REARM_FILE"
            armed=1 attempts=0 cam_errors=0
            present || log "armed, but not present yet (lid shut or panel off)"
        fi

        if ! present; then
            away=1
            nap 1
            continue
        fi

        if (( ! armed )); then
            if (( away )); then
                armed=1 attempts=0 cam_errors=0     # you came back
            else
                nap 1
                continue
            fi
        fi
        away=0

        status "Looking for you…"
        scan
        rc=$?

        case $rc in
            0)
                unlock && return 0
                armed=0
                ;;
            11|124|137)
                # 11 no match in time; 124/137 we killed a hung scan.
                attempts=$(( attempts + 1 ))
                log "no match (rc=$rc), attempt $attempts/$MAX_ATTEMPTS"
                if (( attempts >= MAX_ATTEMPTS )); then
                    armed=0
                    status "Not recognized · press Shift to try again"
                fi
                ;;
            13)
                log "all frames too dark"
                armed=0
                status "Too dark for face unlock"
                ;;
            14)
                cam_errors=$(( cam_errors + 1 ))
                log "camera unavailable ($cam_errors/$MAX_CAM_ERRORS)"
                if (( cam_errors >= MAX_CAM_ERRORS )); then
                    armed=0
                    status "Camera unavailable"
                else
                    nap "$CAM_RETRY_SECS"
                fi
                ;;
            10)
                log "no face model enrolled — run: sudo howdy add"
                armed=0
                status "Face unlock isn't set up"
                ;;
            *)
                # 1 missing dlib data, 12 bad args, a python crash. Stay
                # dormant: a rearm will try again, and the password works.
                log "howdy failed (rc=$rc)"
                armed=0
                status ""
                ;;
        esac
    done
}

case ${1:-} in
    run)         cmd_run ;;
    rearm)       cmd_rearm ;;
    lock-exited) cmd_lock_exited ;;
    *)           echo "usage: ${0##*/} run|rearm|lock-exited" >&2; exit 2 ;;
esac
