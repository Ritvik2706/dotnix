#!/usr/bin/env bash
#
# Install the LUMEN SDDM theme.
#
# SDDM's greeter runs as the unprivileged `sddm` user, which cannot read
# anything under /home — so unlike every other config in this repo, the theme
# cannot be symlinked out of the checkout. It has to be COPIED into
# /usr/share/sddm/themes, which is why this lives in apply.sh rather than in
# install.sh's symlink pass. Re-run it after editing the theme.
#
# Usage:
#   ./apply.sh            install the theme and select it
#   ./apply.sh --revert   go back to SDDM's built-in default
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

THEME=lumen
DEST=/usr/share/sddm/themes/$THEME
CONF=/etc/sddm.conf.d/10-lumen.conf

if [[ "${1:-}" == "--revert" ]]; then
    sudo rm -f "$CONF"
    echo "reverted — SDDM will use its built-in theme on next boot"
    echo "(the theme itself is still installed at $DEST; rm -rf it to remove)"
    exit 0
fi

command -v magick >/dev/null || { echo "imagemagick is required" >&2; exit 1; }

# Bake the background if it has not been rendered yet.
[[ -f "$THEME/background.png" ]] || "$THEME"/render-bg.sh

echo "installing $THEME -> $DEST"
sudo rm -rf "$DEST"
sudo mkdir -p "$DEST"
sudo cp -r "$THEME"/. "$DEST"/
sudo chmod -R a+rX "$DEST"

# The greeter cannot read the repo, so drop the render script's source path
# hint rather than leaving a dangling reference in the installed copy.
sudo rm -f "$DEST/render-bg.sh"

sudo mkdir -p /etc/sddm.conf.d
sudo tee "$CONF" >/dev/null <<CONFEOF
# Managed by dotnix — see sddm/apply.sh
[Theme]
Current=$THEME
CONFEOF

echo
echo "done. verify without rebooting:"
echo "    sddm-greeter-qt6 --test-mode --theme $DEST"
echo "revert with:  ./apply.sh --revert"
