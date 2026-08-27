#!/bin/sh
# Lock-screen network glyph.
#
# This used to shell out to nmcli. NetworkManager is NOT running on this
# machine (iwd + systemd-networkd are), so every refresh on the lock screen
# printed "Error: NetworkManager is not running." into hyprlock's stderr and
# rendered an empty label. Reading the kernel directly works under any
# backend and needs no daemon at all — which is the right property for
# something drawn on a lock screen.

# The interface actually carrying the default route, or nothing if offline.
iface=$(ip -o route get 1.1.1.1 2>/dev/null |
        awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')

[ -z "$iface" ] && { printf "Disconnected 󰤮⠀"; exit 0; }

case "$iface" in
    en*|eth*|usb*) printf "󰈀⠀\n"; exit 0 ;;
esac

# Wireless: link quality, which the kernel reports out of 70.
q=$(awk -v i="$iface:" '$1 == i {gsub(/\./, "", $3); print $3; exit}' /proc/net/wireless)
[ -z "$q" ] && { printf "Connecting 󱍸⠀"; exit 0; }

p=$((q * 100 / 70))
if   [ "$p" -ge 75 ]; then printf "󰤨⠀\n"
elif [ "$p" -ge 50 ]; then printf "󰤥⠀\n"
elif [ "$p" -ge 25 ]; then printf "󰤢⠀\n"
elif [ "$p" -gt  0 ]; then printf "󰤟⠀\n"
else                       printf "󰤯⠀\n"
fi
