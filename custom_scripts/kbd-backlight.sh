#!/usr/bin/env bash
# Razer keyboard backlight via razerkbd sysfs (requires openrazer group)
BRIGHTNESS_FILE=$(find /sys/bus/hid/drivers/razerkbd/ -name "matrix_brightness" -maxdepth 4 2>/dev/null | head -1)
[[ -z "$BRIGHTNESS_FILE" ]] && exit 0

STEP=26  # ~10% of 255

CUR=$(cat "$BRIGHTNESS_FILE" 2>/dev/null || echo 128)

case "${1:-}" in
  up)
    NEW=$(( CUR + STEP ))
    (( NEW > 255 )) && NEW=255
    ;;
  down)
    NEW=$(( CUR - STEP ))
    (( NEW < 0 )) && NEW=0
    ;;
  *)
    echo "Usage: $0 {up|down}"
    exit 1
    ;;
esac

echo "$NEW" > "$BRIGHTNESS_FILE"
PCT=$(( NEW * 100 / 255 ))

dunstify -a "Keyboard" -r 72935 -u low \
  -h string:x-dunst-stack-tag:kbd-backlight \
  -h int:value:"$PCT" \
  "Keyboard Backlight" "${PCT}%"
