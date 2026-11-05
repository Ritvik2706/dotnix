#!/usr/bin/env bash
# niri-patched-setup.sh — make the patched niri survive system updates.
#
#   system/niri-patched-setup.sh            install (asks for sudo once)
#   system/niri-patched-setup.sh uninstall  back to the plain drop-in
#
# Installs:
#   ~/.config/systemd/user/niri.service.d/niri-patched.conf
#       niri.service runs niri/scripts/niri-launch.sh: patched niri if it can
#       start, else stock niri plus a notification, never a dead login
#   /etc/pacman.d/hooks/90-niri-patched.hook  +  /usr/local/lib/niri-patched-hook
#       after every pacman transaction, niri/scripts/niri-patched.sh auto runs
#       in your session: rebuilds the patched niri if an update broke it,
#       re-applies the patches when Arch ships a newer niri, and tells you
set -euo pipefail

DOTNIX=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DROPIN_DIR=$HOME/.config/systemd/user/niri.service.d
HOOK=/etc/pacman.d/hooks/90-niri-patched.hook
HOOK_BIN=/usr/local/lib/niri-patched-hook
TOOL=$DOTNIX/niri/scripts/niri-patched.sh

if [[ ${1:-} == uninstall ]]; then
	rm -f "$DROPIN_DIR/niri-patched.conf"
	printf '[Service]\nExecStart=\nExecStart=%%h/.local/bin/niri --session\n' >"$DROPIN_DIR/squircle.conf"
	systemctl --user daemon-reload
	sudo rm -f "$HOOK" "$HOOK_BIN"
	echo "uninstalled (back to running ~/.local/bin/niri directly)"
	exit 0
fi

chmod +x "$DOTNIX/niri/scripts/niri-launch.sh" "$TOOL"

# ── user: the drop-in ─────────────────────────────────────────────────────
mkdir -p "$DROPIN_DIR"
rm -f "$DROPIN_DIR/squircle.conf"   # the old one: ran the patched binary bare
ln -sfn "$DOTNIX/system/systemd/niri-patched.conf" "$DROPIN_DIR/niri-patched.conf"
systemctl --user daemon-reload
echo "✓ niri.service runs the launcher (takes effect the next time niri starts)"

# ── root: the pacman hook ─────────────────────────────────────────────────
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/hook" <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Checking the patched niri still works...
When = PostTransaction
Exec = $HOOK_BIN
EOF
cat >"$tmp/bin" <<EOF
#!/bin/sh
# Installed by $DOTNIX/system/niri-patched-setup.sh.
# Hands the check to $USER's session (so it can notify, and build as $USER).
# Never fails the transaction.
uid=\$(id -u $USER 2>/dev/null) || exit 0
if [ -S "/run/user/\$uid/bus" ] && [ -x "$TOOL" ]; then
	systemd-run --machine=$USER@ --user --quiet --collect --nice=10 \\
		--unit="niri-patched-auto-\$(date +%s)" "$TOOL" auto >/dev/null 2>&1 \\
		&& echo "  patched niri: checking in the background — you'll get a notification if anything changes"
else
	echo "  patched niri: will be checked at the next login"
fi
exit 0
EOF
sudo install -Dm644 "$tmp/hook" "$HOOK"
sudo install -Dm755 "$tmp/bin" "$HOOK_BIN"
echo "✓ pacman hook installed ($HOOK)"

# ── state now ─────────────────────────────────────────────────────────────
if why=$("$TOOL" check); then echo "✓ patched niri: $why"; else echo "! patched niri: $why (it will be rebuilt)"; fi
