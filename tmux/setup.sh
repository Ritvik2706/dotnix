#!/usr/bin/env bash

# Tmux setup: checks dependencies, links the config, installs TPM.
# Works on any distro — installs nothing itself, just tells you what's missing.

set -e

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check dependencies
missing=()
for cmd in tmux git fzf; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing dependencies: ${missing[*]}"
  echo "Install them with your package manager, e.g.:"
  echo "  pacman -S ${missing[*]}    # Arch/Manjaro"
  echo "  apt install ${missing[*]}  # Debian/Ubuntu"
  exit 1
fi

# Symlink ~/.config/tmux to this directory
if [ ! -e ~/.config/tmux ]; then
  mkdir -p ~/.config
  ln -s "$CONFIG_DIR" ~/.config/tmux
  echo "Linked ~/.config/tmux -> $CONFIG_DIR"
elif [ "$(readlink -f ~/.config/tmux)" != "$CONFIG_DIR" ]; then
  echo "Warning: ~/.config/tmux exists and doesn't point here ($(readlink -f ~/.config/tmux))"
fi

# Install TPM (plugins themselves install on first tmux start, or prefix+I)
if [ ! -d "$CONFIG_DIR/plugins/tpm" ]; then
  echo "Installing TPM..."
  git clone https://github.com/tmux-plugins/tpm "$CONFIG_DIR/plugins/tpm"
fi

# Make scripts executable
chmod +x "$CONFIG_DIR"/tools/*.sh "$CONFIG_DIR"/layouts/*/apply_layout.sh

echo ""
echo "Done. Start tmux (prefix is Ctrl+a); plugins install automatically,"
echo "or force it with prefix+I."
