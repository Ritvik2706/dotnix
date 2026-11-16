#!/usr/bin/env bash
# record.sh <at WxH+X+Y | output NAME> — the screenshot UI's r key (patched niri).
# The lumen island records it (coral capsule beside the pill: click it, or
# Mod+Shift+V, to stop). Without the island, wf-recorder records it here;
# Mod+Shift+V (pkill -INT) stops that one too.
# Videos go to ~/Videos/Recordings.
set -uo pipefail
island="$HOME/.config/lumen/shells/island/scripts/record.sh"

if "$HOME/.local/bin/lumen" --say island "text rec_at $*" >/dev/null 2>&1; then
	exit 0
fi
exec "$island" "$@" >/dev/null
