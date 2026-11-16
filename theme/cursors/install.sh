#!/usr/bin/env bash
set -euo pipefail
cursor_source="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cursor_theme=Bibata-Modern-Ice-MiddleFinger
cursor_icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons"
mkdir -p "$cursor_icons"
if [[ ! -e "$cursor_icons/$cursor_theme" && ! -L "$cursor_icons/$cursor_theme" ]]; then
    ln -s "$cursor_source/$cursor_theme" "$cursor_icons/$cursor_theme"
elif [[ "$(readlink -f "$cursor_icons/$cursor_theme")" != "$cursor_source/$cursor_theme" ]]; then
    printf 'Refusing to replace existing theme: %s\n' "$cursor_icons/$cursor_theme" >&2
    exit 1
fi
gsettings set org.gnome.desktop.interface cursor-theme "$cursor_theme"
gsettings set org.gnome.desktop.interface cursor-size 21
printf 'Installed %s\n' "$cursor_theme"
