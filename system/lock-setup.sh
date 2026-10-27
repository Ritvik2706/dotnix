#!/usr/bin/env bash
#
# Wire up the "one authentication surface" arrangement:
#
#     cold boot ─┐
#                ├─→ hyprlock  ─→ desktop
#     idle / lid ┘
#
# SDDM autologins straight into Hyprland, and hyprlock.service covers the
# session before anything is drawn. Boot and lock are then not two themes
# kept in sync — they are the same program. Howdy authenticates both, because
# there is only one thing left to authenticate against.
#
# THE TRADE, stated plainly: the session starts before anyone authenticates.
# Autostarted apps run behind the lock, and a hyprlock that never comes up
# means a bare desktop. That is why hyprlock.service retries forever rather
# than hitting a start limit. If that trade is not acceptable, don't run this
# — use SDDM as a real greeter instead (sddm/apply.sh) and keep hyprlock for
# locking only.
#
# Everything here is idempotent and reversible with --revert.
#
# Usage:
#   ./lock-setup.sh            wire it up
#   ./lock-setup.sh --check    read-only health check of the whole chain
#   ./lock-setup.sh --test     end-to-end: locks the screen, checks face unlock
#   ./lock-setup.sh --revert   back to a normal SDDM greeter
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO=$(cd .. && pwd)

USER_NAME=${SUDO_USER:-$USER}
# lumen-session: Hyprland or niri, whichever the island last switched to
# (system/lumen-session). It runs Hyprland through uwsm exactly as
# hyprland-uwsm.desktop did.
SESSION=lumen.desktop
AUTOLOGIN_CONF=/etc/sddm.conf.d/20-autologin.conf
HOWDY_CONF=/etc/howdy/config.ini
UNIT_SRC="$REPO/system/systemd/hyprlock.service"
UNIT_DST="$HOME/.config/systemd/user/hyprlock.service"
# The boot blackout. Autologin means Hyprland composites a real, unauthenticated
# desktop for ~400ms before hyprlock's surface exists, and hyprlock cannot start
# any earlier (it is a Wayland client of the compositor it covers). This unit
# darkens the panel before Hyprland's first frame; hypr/scripts/boot-unblank.sh
# brings it back once `hyprctl locked` is true.
BLANK_SRC="$REPO/system/systemd/hyprlock-blank.service"
BLANK_DST="$HOME/.config/systemd/user/hyprlock-blank.service"
# Face unlock runs BESIDE hyprlock, not inside its PAM stack, so the password
# field is live the instant the lock appears. See hypr/scripts/face-unlock.sh.
FACE_SRC="$REPO/system/systemd/hyprlock-face.service"
FACE_DST="$HOME/.config/systemd/user/hyprlock-face.service"
PAM_HYPRLOCK=/etc/pam.d/hyprlock
# Holds suspend until the lock screen has drawn, so a lid-close lock survives
# the wake without being swapped. See hypr/scripts/lock-sleep-guard.py.
GUARD_SRC="$REPO/system/systemd/lock-sleep-guard.service"
GUARD_DST="$HOME/.config/systemd/user/lock-sleep-guard.service"
# Every suspend, the kernel switches to a text console and back, and for a
# beat on wake you see that console: black, with a blinking cursor top-left.
# The switch itself is the kernel's call; the cursor is not. Hiding it turns
# that beat into plain black. (TTYs still work — Ctrl+Alt+F2 — you just won't
# see a cursor there; `setterm --cursor on` brings it back for that session.)
GRUB_DEFAULTS=/etc/default/grub
GRUB_CFG=/boot/grub/grub.cfg
CURSOR_PARAM=vt.global_cursor_default=0

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
WARNINGS=0
PROBLEMS=0

# The password-only stack for hyprlock. One line, and it must be exactly the
# chain the rest of the system logs in with, so a password that works on a
# TTY works here.
PAM_CONTENT='# Managed by dotnix — see system/lock-setup.sh
#
# Password only. Face unlock runs beside hyprlock (hypr/scripts/face-unlock.sh)
# so the field never waits on the camera.
#
# This is system-auth'"'"'s auth stack inlined, with ONE change on the pam_unix
# line: a prompt that ends WITHOUT an answer (authtok_err, conv_err, abort…)
# stops the stack without being recorded as a failure. A face unlock ends
# hyprlock'"'"'s open password prompt exactly that way, and through the stock
# stack each one counted as a wrong password — three face unlocks tripped
# pam_faillock and locked the account, sudo included, for 10 minutes.
# A wrong password is auth_err → default=bad → still recorded; lockout at 3
# wrong passwords is unchanged.
#
# And `nodelay` on preauth: pam_faillock otherwise asks libpam for a ~2s delay
# on ANY failed attempt — including that abandoned prompt — which kept
# hyprlock alive ~2s after every face unlock (a re-lock in that window was a
# no-op). Wrong passwords keep their ~2s throttle, which comes from pam_unix.
# Both verified against a scratch config and tally before use.
auth       requisite                   pam_nologin.so
auth       required                    pam_faillock.so      preauth nodelay
-auth      [success=2 default=ignore]  pam_systemd_home.so
auth       [success=1 authtok_err=die conv_err=die abort=die buf_err=die authinfo_unavail=die default=bad]  pam_unix.so  try_first_pass nullok
auth       [default=die]               pam_faillock.so      authfail
auth       optional                    pam_permit.so
auth       required                    pam_env.so
auth       required                    pam_faillock.so      authsucc'

# Everything that has to be true for face unlock to work. Warnings, never
# fatal: a broken face path still leaves the password, which is the point.
check_face() {
    local model=/etc/howdy/models/$USER_NAME.dat dev n
    [[ -r /usr/lib/howdy/compare.py ]] && ok "howdy installed" \
        || warn "howdy not installed — face unlock will stay off, password still works"
    if [[ -r $model ]]; then
        n=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$model" 2>/dev/null || echo "?")
        if [[ $n == "?" ]]; then warn "$model unreadable as JSON"
        elif (( n < 2 )); then warn "only $n face model enrolled — add more in other lighting: sudo howdy add"
        else ok "$n face models enrolled"; fi
    else
        warn "no face model for $USER_NAME — run: sudo howdy add"
    fi
    dev=$(sed -nE 's/^[[:space:]]*device_path[[:space:]]*=[[:space:]]*(.*)/\1/p' "$HOWDY_CONF" 2>/dev/null | head -1 || true)
    if [[ -z $dev ]]; then warn "no device_path in $HOWDY_CONF"
    elif [[ -r $dev && -w $dev ]]; then ok "camera $dev accessible to $USER_NAME"
    else warn "camera $dev not accessible to $USER_NAME (missing, or no uaccess/video group)"; fi
    if grep -qiE '^[[:space:]]*disabled[[:space:]]*=[[:space:]]*true' "$HOWDY_CONF" 2>/dev/null; then
        warn "howdy is disabled in $HOWDY_CONF — face unlock will not scan"
    fi
    [[ -x $REPO/hypr/scripts/face-unlock.sh ]] && ok "face-unlock.sh executable" \
        || bad "$REPO/hypr/scripts/face-unlock.sh is not executable"
}

# ──────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
    say "lock units"
    for u in hyprlock hyprlock-blank hyprlock-face lock-sleep-guard; do
        if [[ -L $HOME/.config/systemd/user/$u.service && -e $HOME/.config/systemd/user/$u.service ]]; then
            ok "$u.service linked"
        else
            bad "$u.service not linked — run ./lock-setup.sh"
        fi
    done
    [[ $(systemctl --user is-enabled hyprlock.service 2>/dev/null) == enabled ]] \
        && ok "hyprlock.service enabled" || bad "hyprlock.service not enabled"

    say "PAM"
    if [[ ! -r $PAM_HYPRLOCK ]]; then bad "$PAM_HYPRLOCK missing — hyprlock cannot authenticate"
    elif grep -q pam_howdy "$PAM_HYPRLOCK"; then bad "$PAM_HYPRLOCK still has pam_howdy — typing will block during scans"
    elif ! grep -q "authtok_err=die" "$PAM_HYPRLOCK"; then bad "$PAM_HYPRLOCK is outdated — every face unlock counts as a failed password (faillock lockouts) — re-run ./lock-setup.sh"
    elif ! grep -q "preauth nodelay" "$PAM_HYPRLOCK"; then warn "$PAM_HYPRLOCK is outdated — hyprlock lingers ~2s after a face unlock — re-run ./lock-setup.sh"
    else ok "$PAM_HYPRLOCK is password-only, face unlocks don't count as failures"; fi
    n=$(faillock --user "$USER_NAME" 2>/dev/null | grep -c " V$" || true)
    if (( n >= 3 )); then bad "account locked by faillock ($n recent failures) — sudo will reject your password; clear: faillock --user $USER_NAME --reset"
    elif (( n > 0 )); then warn "$n recent failed auth(s) on record (3 locks the account for 10 min)"
    else ok "no failed auths on record"; fi
    [[ -r /etc/pam.d/login ]] && ok "/etc/pam.d/login present" || bad "/etc/pam.d/login missing"

    say "wake"
    if [[ -f $GRUB_DEFAULTS ]]; then
        grep -q "$CURSOR_PARAM" /proc/cmdline && ok "console cursor hidden (no blinking cursor on wake)" \
            || { grep -q "$CURSOR_PARAM" "$GRUB_DEFAULTS" && warn "console cursor fix installed — takes effect after reboot" \
                 || warn "console cursor visible on wake — run ./lock-setup.sh"; }
    fi
    grep -q 'switch:on:Lid Switch' "$REPO/hypr/lua/keybinds/power_notifications.lua" \
        && ok "locks on lid close" || bad "no lid-close lock bind"
    if systemd-inhibit --list --no-pager 2>/dev/null | grep -q "^lock-sleep-guard"; then
        ok "suspend waits for the lock to draw (lock-sleep-guard holding)"
    else
        bad "lock-sleep-guard is not holding sleep — wake will swap the lock (black flash)"
    fi
    last=$(journalctl --user -t lock-sleep-guard -n 1 -q -o cat --grep "sleeping" 2>/dev/null || true)
    [[ -n $last ]] && echo "    last suspend: $last"

    say "face unlock"
    check_face
    pw=${XDG_RUNTIME_DIR:-/run/user/$UID}/face-unlock/password-ok
    if [[ -e $pw ]]; then
        ok "password used $(( (EPOCHSECONDS - $(stat -c %Y "$pw")) / 60 )) min ago — face unlock allowed"
    else
        warn "password not used since boot — face unlock waits for one password unlock"
    fi
    pgrep -x hypridle >/dev/null && ok "hypridle running (delivers the 'you are back' rearm)" \
        || bad "hypridle not running — face unlock will only arm on wake/lid/Super+Ctrl+Alt+F"
    grep -q "face-unlock.sh rearm" "$REPO/hypr/hypridle.conf" && ok "hypridle rearm listener configured" \
        || bad "hypridle.conf has no face-unlock rearm listener"
    echo
    echo "  recent scanner log:"
    out=$(journalctl --user -t face-unlock -n 10 --no-pager -q -o short 2>/dev/null)
    [[ -n $out ]] && sed 's/^/    /' <<<"$out" || echo "    (nothing yet)"

    say "$PROBLEMS problem(s), $WARNINGS warning(s)"
    (( PROBLEMS == 0 ))
    exit
fi

# ──────────────────────────────────────────────────────────────────────────
# End-to-end test of the real thing, on the real lock. Every step is a claim
# the design makes; each is checked against the compositor and systemd rather
# than assumed. If face unlock fails to let you in, the password still does.
if [[ "${1:-}" == "--test" ]]; then
    FACE="$REPO/hypr/scripts/face-unlock.sh"
    ST=${XDG_RUNTIME_DIR:-/run/user/$UID}/face-unlock
    pass() { ok "$*"; }
    fail() { bad "$*"; }
    is_locked() { [[ $(hyprctl locked 2>/dev/null) == true ]]; }
    ms_since() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }

    is_locked && { echo "already locked — run this from an unlocked session" >&2; exit 1; }
    grep -q pam_howdy "$PAM_HYPRLOCK" 2>/dev/null \
        && { echo "$PAM_HYPRLOCK still has pam_howdy — run ./lock-setup.sh first" >&2; exit 1; }
    [[ -e $FACE_DST ]] || { echo "hyprlock-face.service not linked — run ./lock-setup.sh first" >&2; exit 1; }
    [[ -e $ST/password-ok ]] || { echo "face unlock is waiting for a password unlock since boot — lock and unlock once with your password, then re-run" >&2; exit 1; }
    grep -q "authtok_err=die" "$PAM_HYPRLOCK" \
        || { echo "$PAM_HYPRLOCK is outdated (face unlocks would count as failed passwords) — run ./lock-setup.sh first" >&2; exit 1; }
    pw_before=$(stat -c %Y "$ST/password-ok")
    fails_before=$(faillock --user "$USER_NAME" 2>/dev/null | grep -c " V$" || true)

    cat <<'EOF'

  The screen will lock in 3 seconds.
  Sit normally, facing the screen, and DON'T touch anything — the test
  wakes face unlock itself. If it can't recognise you within ~25s, type
  your password; the test will notice and report.
EOF
    sleep 3
    since=$(date '+%Y-%m-%d %H:%M:%S')

    say "1. lock"
    systemctl --user start hyprlock.service
    for _ in {1..50}; do is_locked && break; sleep 0.1; done
    is_locked && pass "session locked" || { fail "session did not lock"; exit 1; }
    for _ in {1..30}; do systemctl --user is-active --quiet hyprlock-face.service && break; sleep 0.1; done
    systemctl --user is-active --quiet hyprlock-face.service \
        && pass "scanner started with the lock" || fail "scanner did not start"

    say "2. dormant — a fresh lock must not let you straight back in"
    sleep 7
    is_locked && pass "still locked after 7s with you in front of the camera" \
        || fail "unlocked without being asked — a manual lock would be pointless"
    [[ -z $(cat "$ST/status" 2>/dev/null) ]] && pass "status line quiet" \
        || fail "status line not quiet: $(cat "$ST/status")"

    say "3. rearm — you came back"
    t0=$(date +%s%N)
    "$FACE" rearm
    saw_scan=0
    for _ in {1..300}; do
        [[ $(cat "$ST/status" 2>/dev/null) == "Looking for you…" ]] && saw_scan=1
        is_locked || break
        sleep 0.1
    done
    (( saw_scan )) && pass "status showed \"Looking for you…\"" || warn "never saw the scanning status"
    if is_locked; then
        fail "not recognised within 30s — status: \"$(cat "$ST/status" 2>/dev/null)\""
        echo "    type your password to finish; waiting…"
        while is_locked; do sleep 0.5; done
    else
        pass "unlocked by face in $(ms_since "$t0")ms after rearm"
    fi

    say "4. aftermath"
    t1=$(date +%s%N)
    for _ in {1..100}; do systemctl --user is-active --quiet hyprlock.service || break; sleep 0.05; done
    gone=$(ms_since "$t1")
    if systemctl --user is-active --quiet hyprlock.service; then
        fail "hyprlock still running 5s after unlock — a re-lock in that window is a no-op"
    elif (( gone > 1500 )); then
        warn "hyprlock lingered ${gone}ms after unlock"
    else
        pass "hyprlock exited ${gone}ms after unlock"
    fi
    [[ $(systemctl --user show hyprlock.service -p ExecMainStatus --value) == 0 ]] \
        && pass "clean exit (status 0) — Restart=on-failure will not re-lock" \
        || fail "hyprlock exit status $(systemctl --user show hyprlock.service -p ExecMainStatus --value)"
    sleep 1.5
    is_locked && fail "screen re-locked after unlock" || pass "stayed unlocked"
    systemctl --user is-active --quiet hyprlock-face.service \
        && fail "scanner still running after unlock" || pass "scanner stopped, camera released"
    pw_after=$(stat -c %Y "$ST/password-ok" 2>/dev/null || echo 0)
    if [[ $saw_scan == 1 && $pw_after == "$pw_before" ]]; then
        pass "face unlock not mistaken for a password unlock"
    elif [[ $pw_after != "$pw_before" ]]; then
        warn "password unlock recorded (expected if you typed it)"
    fi
    fails_after=$(faillock --user "$USER_NAME" 2>/dev/null | grep -c " V$" || true)
    if (( fails_after > fails_before )); then
        fail "faillock recorded $(( fails_after - fails_before )) failure(s) — face unlocks are counting as wrong passwords"
    else
        pass "no failed-password record from the face unlock (faillock untouched)"
    fi
    [[ -z $(cat "$ST/status" 2>/dev/null) ]] && pass "status line cleared for next lock" \
        || fail "status line left behind: $(cat "$ST/status")"

    say "scanner log"
    journalctl --user -t face-unlock --since "$since" --no-pager -o cat | sed 's/^/    /'

    say "$PROBLEMS problem(s), $WARNINGS warning(s)"
    (( PROBLEMS == 0 ))
    exit
fi

# ──────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--revert" ]]; then
    say "removing autologin"
    sudo rm -f "$AUTOLOGIN_CONF"

    # DISABLE, don't delete: hyprlock.service is still how every lock is
    # taken (hypridle's lock_cmd, SUPER+ALT+L, eww). Deleting it — as this
    # used to — left a machine that silently never locked again. Disabling
    # only drops "lock at session start", which is what autologin needed.
    say "disabling lock-at-login"
    systemctl --user disable hyprlock.service 2>/dev/null || true
    systemctl --user disable --now hyprlock-blank.service 2>/dev/null || true

    # Face unlock goes with the PAM change it was built around: once
    # pam_howdy is back in the stack, a parallel scanner would only fight it
    # for the camera. hyprlock.service's Wants= on a missing unit is inert.
    say "removing parallel face unlock"
    systemctl --user stop hyprlock-face.service 2>/dev/null || true
    rm -f "$FACE_DST"
    systemctl --user disable --now lock-sleep-guard.service 2>/dev/null || true
    rm -f "$GUARD_DST"
    systemctl --user daemon-reload
    # Leave nothing dark behind: if the revert lands while the blackout is up,
    # the panel would otherwise stay at zero with no unit left to undo it.
    brightnessctl -q -r 2>/dev/null || brightnessctl -q set 40% 2>/dev/null || true

    if [[ -f "$PAM_HYPRLOCK.dotnix-bak" ]]; then
        say "restoring $PAM_HYPRLOCK"
        sudo mv "$PAM_HYPRLOCK.dotnix-bak" "$PAM_HYPRLOCK"
    fi

    if [[ -f $GRUB_DEFAULTS ]] && grep -q "$CURSOR_PARAM" "$GRUB_DEFAULTS"; then
        say "restoring the console cursor"
        sudo sed -i -E "s/$CURSOR_PARAM ?//; s/ $CURSOR_PARAM//" "$GRUB_DEFAULTS"
        sudo grub-mkconfig -o "$GRUB_CFG" >/dev/null 2>&1 \
            && echo "  removed $CURSOR_PARAM (after next boot)" \
            || echo "  grub-mkconfig failed — run: sudo grub-mkconfig -o $GRUB_CFG" >&2
    fi

    if [[ -f "$HOWDY_CONF.dotnix-bak" ]]; then
        say "restoring howdy config"
        sudo mv "$HOWDY_CONF.dotnix-bak" "$HOWDY_CONF"
    fi

    echo
    echo "reverted. SDDM will ask for a password on next boot; idle/manual"
    echo "locking still goes through hyprlock.service as before."
    echo "the LUMEN greeter theme is untouched — see sddm/apply.sh"
    exit 0
fi

# ── preflight ─────────────────────────────────────────────────────────────
# Run as yourself, not under sudo: the units go in YOUR systemd --user and
# $HOME. sudo is called for the few system files, and asked for up front so
# it cannot fail halfway through with the PAM file half-written.
if [[ $EUID -eq 0 ]]; then
    echo "run this as your user, not root — it calls sudo itself" >&2
    exit 1
fi
command -v hyprlock >/dev/null || { echo "hyprlock is not installed" >&2; exit 1; }
[[ -r /etc/pam.d/login ]] || { echo "/etc/pam.d/login missing — refusing to point hyprlock at it" >&2; exit 1; }
for f in "$UNIT_SRC" "$BLANK_SRC" "$FACE_SRC" "$GUARD_SRC" "$REPO/hypr/scripts/face-unlock.sh" "$REPO/hypr/scripts/lock-sleep-guard.py"; do
    [[ -f $f ]] || { echo "missing $f" >&2; exit 1; }
done
if command -v systemd-analyze >/dev/null; then
    for f in "$UNIT_SRC" "$FACE_SRC" "$GUARD_SRC"; do
        systemd-analyze --user verify "$f" >/dev/null 2>&1 \
            || { echo "unit failed to verify: $f" >&2; systemd-analyze --user verify "$f"; exit 1; }
    done
fi
chmod +x "$REPO/hypr/scripts/face-unlock.sh"
sudo -v || { echo "sudo is needed for /etc/pam.d and /etc/sddm.conf.d" >&2; exit 1; }
chmod +x "$REPO/system/lumen-session"
sudo install -m 644 "$REPO/system/lumen.desktop" /usr/share/wayland-sessions/lumen.desktop
[[ -f /usr/share/wayland-sessions/$SESSION ]] \
    || { echo "session file $SESSION not found" >&2; exit 1; }

# ── 1. the lock unit ──────────────────────────────────────────────────────
# Linked, not copied, so edits in the repo are live after a daemon-reload.
say "installing hyprlock.service"
mkdir -p "$(dirname "$UNIT_DST")"
ln -sfn "$UNIT_SRC" "$UNIT_DST"
ln -sfn "$BLANK_SRC" "$BLANK_DST"
ln -sfn "$FACE_SRC" "$FACE_DST"
ln -sfn "$GUARD_SRC" "$GUARD_DST"
systemctl --user daemon-reload
systemctl --user enable lock-sleep-guard.service
systemctl --user restart lock-sleep-guard.service
systemctl --user enable hyprlock.service
systemctl --user enable hyprlock-blank.service
echo "  enabled — the session will now come up locked, behind a dark panel"

# ── 1b. password-only PAM for hyprlock ───────────────────────────────────
# hyprlock runs one PAM conversation at a time, so `auth sufficient
# pam_howdy.so` ahead of the password meant no typing until the face scan
# timed out. howdy now runs in parallel (hyprlock-face.service) and unlocks
# with SIGUSR1; PAM only ever asks for the password.
say "making $PAM_HYPRLOCK password-only"
# Back up the ORIGINAL once (never overwrite it with our own version on a
# re-run), then write atomically: a half-written PAM file is a lock screen
# that can never unlock. Written beside the target, then renamed over it.
if [[ -f $PAM_HYPRLOCK && ! -f $PAM_HYPRLOCK.dotnix-bak ]]; then
    sudo cp -p "$PAM_HYPRLOCK" "$PAM_HYPRLOCK.dotnix-bak"
fi
printf '%s\n' "$PAM_CONTENT" | sudo tee "$PAM_HYPRLOCK.dotnix-new" >/dev/null
sudo chmod 644 "$PAM_HYPRLOCK.dotnix-new"
sudo mv -f "$PAM_HYPRLOCK.dotnix-new" "$PAM_HYPRLOCK"
if [[ $(cat "$PAM_HYPRLOCK") == "$PAM_CONTENT" ]]; then
    echo "  $PAM_HYPRLOCK (backup: $PAM_HYPRLOCK.dotnix-bak)"
else
    echo "  $PAM_HYPRLOCK did not read back as written — restoring backup" >&2
    [[ -f $PAM_HYPRLOCK.dotnix-bak ]] && sudo cp -p "$PAM_HYPRLOCK.dotnix-bak" "$PAM_HYPRLOCK"
    exit 1
fi

# ── 2. autologin ──────────────────────────────────────────────────────────
# Relogin=false on purpose: with Relogin=true an explicit logout would drop
# you straight back into a new session, making it impossible to reach the
# greeter (or another session) without editing this file from a TTY.
say "configuring autologin for $USER_NAME"
sudo mkdir -p /etc/sddm.conf.d
sudo tee "$AUTOLOGIN_CONF" >/dev/null <<EOF
# Managed by dotnix — see system/lock-setup.sh
# The greeter is bypassed at boot; hyprlock is the authentication surface.
[Autologin]
User=$USER_NAME
Session=$SESSION
Relogin=false
EOF
echo "  $AUTOLOGIN_CONF"

# ── 3. howdy ──────────────────────────────────────────────────────────────
# Tuned for the IR sensor rather than for a webcam. /dev/video2 on this
# machine is the GREY 8-bit stream — the Windows-Hello IR sensor, exposed
# under the RGB camera's name — which is the correct device and already set.
if [[ -f "$HOWDY_CONF" ]]; then
    say "tuning howdy"
    [[ -f "$HOWDY_CONF.dotnix-bak" ]] || sudo cp "$HOWDY_CONF" "$HOWDY_CONF.dotnix-bak"

    set_key() {  # set_key <key> <value> <why>
        sudo sed -i -E "s|^[[:space:]]*#?[[:space:]]*($1)[[:space:]]*=.*|\1 = $2|" "$HOWDY_CONF"
        printf '  %-16s %-6s %s\n' "$1" "$2" "$3"
    }

    # dark_threshold is a SKIP threshold, not a floor: compare.py computes
    # `darkness` as the percentage of pixels in the darkest eighth of the
    # histogram and skips the frame when darkness > dark_threshold. So a LOWER
    # value throws away MORE frames. 60 is upstream's default and correct;
    # raise it toward 80 (never lower it) if the log ever says "All frames
    # were too dark".
    set_key dark_threshold 60 "upstream default; lower values discard MORE frames"

    # Evidence-based: every successful unlock in this machine's journal came
    # back in ~2s. 4s was already enough when someone is actually there, and
    # every extra second is spent by the UNATTENDED scans (see below), not by
    # you. 5 leaves a little room for the IR exposure to settle in the dark.
    set_key timeout 5 "successes land in ~2s; the rest is unattended burn"

    # Suppress "Identified face as ritvik" — hyprlock renders PAM messages in
    # the field, and a success message flashing where the dots are is noise.
    set_key no_confirmation true "no PAM chatter in the dot row"

    # Never scan while the lid is shut (a closed lid means a black frame and
    # a guaranteed failed attempt) or over SSH.
    set_key abort_if_lid_closed true "a shut lid can only fail"
    set_key abort_if_ssh true "never face-auth a remote session"

    echo
    echo "  NOT changed: certainty=4.2 (default is 3.5 — yours is already"
    echo "  permissive, which trades false rejects for false accepts). Lower"
    echo "  it toward 3.5 if you want face unlock to be stricter."
else
    echo "howdy config not found at $HOWDY_CONF — skipping" >&2
fi

# ── face unlock ───────────────────────────────────────────────────────────
say "face unlock"
check_face

# Face unlock wants one password unlock per boot first. You have just proved
# the password to sudo, so count that — otherwise the very first lock after
# installing would say "Password required after restart" with no restart.
STATE_DIR=${XDG_RUNTIME_DIR:-/run/user/$UID}/face-unlock
mkdir -p -m 700 "$STATE_DIR" && : > "$STATE_DIR/password-ok"

# ── 4. hide the console cursor on wake ────────────────────────────────────
if [[ -f $GRUB_DEFAULTS && -f $GRUB_CFG ]] && command -v grub-mkconfig >/dev/null; then
    say "console cursor"
    if grep -q "$CURSOR_PARAM" "$GRUB_DEFAULTS"; then
        echo "  already set"
    elif grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT="' "$GRUB_DEFAULTS"; then
        [[ -f $GRUB_DEFAULTS.dotnix-bak ]] || sudo cp -p "$GRUB_DEFAULTS" "$GRUB_DEFAULTS.dotnix-bak"
        sudo sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\")/\1$CURSOR_PARAM /" "$GRUB_DEFAULTS"
        # grub-mkconfig builds into grub.cfg.new and only renames over the real
        # file on success, so a failure here leaves the old boot menu intact.
        # grub.cfg is root-only (0600): the check must read it as root too, or a
        # successful build looks like a failure and gets rolled back.
        if sudo grub-mkconfig -o "$GRUB_CFG" >/dev/null 2>&1 && sudo grep -q "$CURSOR_PARAM" "$GRUB_CFG"; then
            ok "$CURSOR_PARAM added — takes effect after next reboot"
        else
            warn "grub-mkconfig failed; restoring $GRUB_DEFAULTS"
            sudo cp -p "$GRUB_DEFAULTS.dotnix-bak" "$GRUB_DEFAULTS"
        fi
    else
        warn "no GRUB_CMDLINE_LINUX_DEFAULT line in $GRUB_DEFAULTS — skipped"
    fi
fi

# hypridle reads its config once. Restart it inside the Hyprland session
# (not as a child of this shell) so it picks up the face-unlock listener.
if pgrep -x hypridle >/dev/null && command -v hyprctl >/dev/null; then
    pkill -x hypridle
    for _ in {1..20}; do pgrep -x hypridle >/dev/null || break; sleep 0.1; done
    hyprctl dispatch 'hl.dsp.exec_cmd("hypridle")' >/dev/null
    sleep 0.5
    pgrep -x hypridle >/dev/null && ok "hypridle restarted" || warn "hypridle did not come back — start it: hypridle &"
fi

# ── done ──────────────────────────────────────────────────────────────────
say "done"
cat <<EOF
Test BEFORE rebooting, in this order:

  1. lock now, without touching the session:
         systemctl --user start hyprlock.service
     you can type immediately. Face unlock stays quiet until you come back:
     sit still ~5s, then tap Shift — "Looking for you…" appears under the
     dots and it unlocks. Live log: journalctl --user -t face-unlock -f

  2. confirm it locks itself on the next session start:
         systemctl --user is-enabled hyprlock.service     # -> enabled

  3. run the end-to-end test (locks the screen, checks face unlock):
         $REPO/system/lock-setup.sh --test

Keep a TTY open (Ctrl+Alt+F2) the first time you reboot. If anything goes
wrong you can log in there and run:  $REPO/system/lock-setup.sh --revert
EOF
