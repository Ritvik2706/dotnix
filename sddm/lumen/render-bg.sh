#!/usr/bin/env bash
# Bake the LUMEN background.
#
# The greeter runs as the unprivileged `sddm` user and cannot read anything
# under /home, so the wallpaper has to be copied into the theme directory.
# Since we're copying anyway, we bake the treatment into the
# pixels rather than reproducing it at runtime — the greeter's first frame is
# then instant on a cold boot, with no shader warm-up.
#
# The values come from the old hyprlock background{} block (that config has
# since been removed; these are what it used to do):
#   blur_passes = 3, blur_size = 5   ->  downscale/blur/upscale (kawase-alike)
#   brightness  = 0.68               ->  -modulate 68
#   vibrancy    = 0.17               ->  saturation 112
#   contrast    = 1.1                ->  -brightness-contrast 0x8
#
# The vignette is the one addition, not carried over: LUMEN's premise is
# that light is the material, so the frame falls off toward the corners and the
# luminous centre column reads as the source rather than as flat overlay.
#
# Usage: ./render-bg.sh [source-image] [blur-sigma]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

SRC="${1:-$(cd ../.. && pwd)/wallpapers/idk.png}"
SIGMA="${2:-24}"          # raise for a softer scene, lower to keep it legible
RES="${RES:-2560x1440}"

[[ -f "$SRC" ]] || { echo "no such wallpaper: $SRC" >&2; exit 1; }

W="${RES%x*}"; H="${RES#*x}"
# Diagonal of the frame, so the vignette's falloff is resolution-independent.
D=$(( (W * 3) / 2 ))

magick "$SRC" \
    -resize "${RES}^" -gravity center -extent "$RES" \
    -resize 12.5% -blur "0x$(( SIGMA / 8 ))" -resize 800% \
    -modulate 68,112 \
    -brightness-contrast 0x8 \
    \( -size "${D}x${D}" radial-gradient:'gray(100%)-gray(38%)' \
       -resize "${RES}!" -gravity center -extent "$RES" \) \
    -compose multiply -composite \
    background.png

echo "background.png  <-  $SRC  (sigma $SIGMA, $RES)"
