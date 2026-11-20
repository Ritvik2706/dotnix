#!/usr/bin/env bash
# Opens a folder (or shows a file in its folder) in the island's files window:
# what `xdg-open DIR` and "show in folder" run (lumen-files.desktop). Without a
# running island, Thunar.
target=${1:-$HOME}
target=${target#file://}
target=$(printf '%b' "${target//%/\\x}")
if ! ~/.local/bin/lumen --say island "text fnd_ext $target" >/dev/null 2>&1; then
    exec thunar "$target"
fi
