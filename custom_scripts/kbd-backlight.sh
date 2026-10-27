#!/usr/bin/env bash
# Razer keyboard backlight via razerkbd sysfs (requires openrazer group).
#   up | down   step it ~10% and show the lumen island's gauge
#   set PCT     set it (what the island's gauge calls when dragged or scrolled)
#   get         print the current percent
# sysfs drivers/ entries are symlinks: find needs -L to look inside them.
BRIGHTNESS_FILE=$(find -L /sys/bus/hid/drivers/razerkbd/ -maxdepth 2 -name "matrix_brightness" 2>/dev/null | head -1)
[[ -z "$BRIGHTNESS_FILE" ]] && exit 0

STEP=26  # ~10% of 255
CUR=$(cat "$BRIGHTNESS_FILE" 2>/dev/null || echo 128)

case "${1:-}" in
  up)   NEW=$(( CUR + STEP )); (( NEW > 255 )) && NEW=255 ;;
  down) NEW=$(( CUR - STEP )); (( NEW < 0 )) && NEW=0 ;;
  set)  NEW=$(( ${2:-50} * 255 / 100 )); (( NEW > 255 )) && NEW=255; (( NEW < 0 )) && NEW=0 ;;
  get)  echo $(( (CUR * 100 + 127) / 255 )); exit 0 ;;
  *)    echo "Usage: $0 {up|down|set PCT|get}"; exit 1 ;;
esac

echo "$NEW" > "$BRIGHTNESS_FILE"
PCT=$(( (NEW * 100 + 127) / 255 ))
[[ "$1" == set ]] && exit 0

# The island draws the gauge; a notification only if it isn't running.
"$HOME/.local/bin/lumen" --say island "emit kbd_$1 $PCT" >/dev/null 2>&1 ||
  notify-send -u low -h string:x-canonical-private-synchronous:kbd-backlight \
    -h int:value:"$PCT" "Keyboard Backlight" "${PCT}%"
