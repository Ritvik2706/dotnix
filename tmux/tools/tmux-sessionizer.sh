#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [directory]\n' "$0" >&2
  exit 2
elif [[ $# -eq 1 ]]; then
  selected=$1
else
  selected=$(find ~/github ~/github/projects -mindepth 1 -maxdepth 1 -type d 2>/dev/null | fzf) || exit 0
fi

[[ -n "$selected" ]] || exit 0
if ! selected=$(cd -- "$selected" && pwd -P); then
  exit 1
fi

# Canonical paths keep symlinks in the same session; a path digest separates
# projects with identical basenames. Linux and WSL provide sha256sum.
path_hash=$(printf '%s' "$selected" | sha256sum)
selected_name="$(basename -- "$selected" | tr '.:' '__')-${path_hash:0:12}"

# Ask the actual tmux server, rather than looking for unrelated tmux processes.
if ! tmux has-session -t "=$selected_name" 2>/dev/null; then
  tmux new-session -ds "$selected_name" -c "$selected" || {
    # Another invocation may have created the session concurrently.
    tmux has-session -t "=$selected_name" 2>/dev/null || exit 1
  }
fi

if [[ -z "${TMUX:-}" ]]; then
  tmux attach-session -t "=$selected_name"
else
  tmux switch-client -t "=$selected_name"
fi
