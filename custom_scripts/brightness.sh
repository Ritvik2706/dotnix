#!/usr/bin/env bash
set -euo pipefail

# --- Prefer the real panel device over acpi shim (matches what Waybar likely uses) ---
# You can force it permanently by exporting BACKLIGHT_DEV=intel_backlight in your shell,
# or just let this auto-pick.
BACKLIGHT_DEV="${BACKLIGHT_DEV:-}"
if [[ -z "$BACKLIGHT_DEV" ]]; then
  for d in intel_backlight apple_backlight amdgpu_bl0 nvidia_wmi_ec_backlight acpi_video0; do
    [[ -d "/sys/class/backlight/$d" ]] && BACKLIGHT_DEV="$d" && break
  done
fi
bctl() { brightnessctl ${BACKLIGHT_DEV:+-d "$BACKLIGHT_DEV"} "$@"; }

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/bright"
mkdir -p "$STATE_DIR"
PREV_FILE="$STATE_DIR/prev"     # stores last brightness for toggles
LOCK_FILE="$STATE_DIR/boost.lock"

notify() {
  # $1: title  $2: percent (int)  $3: body (optional)
  command -v notify-send >/dev/null 2>&1 || return 0
  local body="${3:-$2%}"
  notify-send -u low -t 900 \
    -h string:x-canonical-private-synchronous:sys-bright \
    -h int:value:"$2" "$1" "$body"
}

# The lumen island's brightness gauge: told at once (its service only looks
# every 0.7 s) and which way, so it can stretch when pushed past an end.
# Falls back to a notification if the island isn't running.
osd() {
  # $1: up|down  $2: percent
  "$HOME/.local/bin/lumen" --say island "emit bright_$1 $2" >/dev/null 2>&1 || notify "Brightness" "$2"
}

# Round to nearest integer percent to avoid “sticking” from truncation.
get_pct() {
  local cur max
  cur=$(bctl get)
  max=$(bctl max)
  if [[ -z "$cur" || -z "$max" || "$max" -eq 0 ]]; then
    echo 0; return
  fi
  # rounded = floor((cur*100 + max/2) / max)
  echo $(( (cur * 100 + max / 2) / max ))
}

set_pct() {
  local p="$1"
  (( p < 1 )) && p=1
  (( p > 100 )) && p=100
  bctl set "${p}%">/dev/null
  echo "$p"
}

step_up() {
  local p="$1"
  if   (( p < 10 ));  then echo 2
  elif (( p < 30 ));  then echo 4
  elif (( p < 70 ));  then echo 6
  elif (( p < 90 ));  then echo 8
  else                    echo 4
  fi
}
step_down() {
  local p="$1"
  if   (( p <= 5 ));  then echo 1
  elif (( p <= 15 )); then echo 2
  elif (( p <= 30 )); then echo 3
  elif (( p <= 60 )); then echo 5
  elif (( p <= 85 )); then echo 8
  else                    echo 10
  fi
}

kbdev() {
  # best-effort detection for keyboard backlight device
  brightnessctl --list 2>/dev/null | awk -F"'" '/kbd_backlight/ {print $2; exit}'
}

kbd_pct() {
  local dev="$1"
  local cur max
  cur=$(brightnessctl -d "$dev" get)
  max=$(brightnessctl -d "$dev" max)
  echo $(( (cur * 100 + max / 2) / max ))
}

kbd_set() {
  local dev="$1" p="$2"
  (( p < 0 )) && p=0
  (( p > 100 )) && p=100
  brightnessctl -d "$dev" set "${p}%">/dev/null
  echo "$p"
}

# --- Small helper to “escape” the very-dim zone cleanly ---
# When you’re < 10%, we jump to at least 12% to break out of rounding/granularity quirks.
escape_low_zone_up() {
  local cur="$1" inc="$2" target
  target=$(( cur + inc ))
  if (( cur < 10 && target < 12 )); then
    echo 12
  else
    echo "$target"
  fi
}

case "${1:-}" in
  up)
    cur=$(get_pct)
    inc=$(step_up "$cur")
    target=$(escape_low_zone_up "$cur" "$inc")
    new=$(set_pct "$target")

    # If for any reason we’re still stuck <10 after setting >=10, force 12% once.
    now=$(get_pct)
    if (( target >= 10 && now < 10 )); then
      new=$(set_pct 12)
      now=$(get_pct)
    fi
    osd up "$now"
    ;;
  down)
    cur=$(get_pct); dec=$(step_down "$cur"); new=$((cur - dec))
    new=$(set_pct "$new"); osd down "$new"
    ;;
  focus)  # toggle ~18% <-> previous
    cur=$(get_pct)
    if [[ -f "$PREV_FILE" ]]; then
      prev=$(cat "$PREV_FILE" || echo 50)
      rm -f "$PREV_FILE"
      new=$(set_pct "$prev"); osd up "$new"
    else
      echo "$cur" > "$PREV_FILE"
      new=$(set_pct 18); osd down "$new"
    fi
    ;;
  boost)  # temporary 100% for 15s, then restore
    if [[ -f "$LOCK_FILE" ]]; then exit 0; fi
    cur=$(get_pct)
    echo "1" > "$LOCK_FILE"
    echo "$cur" > "$PREV_FILE"
    set_pct 100 >/dev/null; osd up 100
    ( sleep 15; \
      if [[ -f "$PREV_FILE" ]]; then prev=$(cat "$PREV_FILE"); set_pct "$prev" >/dev/null; osd down "$prev"; fi; \
      rm -f "$LOCK_FILE" ) >/dev/null 2>&1 &
    ;;
  kbd-up)
    dev=$(kbdev) || true
    [[ -z "${dev:-}" ]] && exit 0
    cur=$(kbd_pct "$dev"); new=$((cur + 8)); new=$(kbd_set "$dev" "$new")
    notify "Keyboard backlight" "$new"
    ;;
  kbd-down)
    dev=$(kbdev) || true
    [[ -z "${dev:-}" ]] && exit 0
    cur=$(kbd_pct "$dev"); new=$((cur - 8)); new=$(kbd_set "$dev" "$new")
    notify "Keyboard backlight" "$new"
    ;;
  *)
    echo "Usage: brightness.sh {up|down|focus|boost|kbd-up|kbd-down}"
    ;;
esac

