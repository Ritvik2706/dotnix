#!/usr/bin/env bash
# tether-dedupe — keep exactly one path to the iPhone hotspot.
#
# Connecting over USB tethering (ipheth) *and* Wi-Fi hotspot at the same time
# puts two addresses on the same 172.20.10.0/28 with two default routes via the
# same gateway. WebRTC gathers an ICE host candidate on each, then sends DTLS
# out the lower-metric USB link using a NAT binding the phone made for the Wi-Fi
# source — the phone drops the replies and Discord hangs on "DTLS connecting".
#
# USB tethering is the better link, so when it comes up we soft-block Wi-Fi and
# unblock it when the cable goes away. The stamp file means we only ever undo a
# block we made ourselves — a deliberate `rfkill block wifi` is left alone.
#
# Run with --once to evaluate a single time; with no arguments it watches
# netlink and re-evaluates on every address/link change (how the service runs).
# udev's "add" fires before DHCP has assigned the tether an address, which is
# why this watches addresses rather than device nodes.

set -uo pipefail

STAMP=/run/tether-dedupe.blocked
LOG_TAG=tether-dedupe

log() { logger -t "$LOG_TAG" -- "$*"; }

# An ipheth interface only counts once it actually carries an IPv4 address.
tether_active() {
  local path iface driver
  for path in /sys/class/net/*; do
    [ -e "$path/device/driver" ] || continue
    driver=$(basename "$(readlink -f "$path/device/driver")")
    [ "$driver" = ipheth ] || continue
    iface=$(basename "$path")
    ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet ' && return 0
  done
  return 1
}

evaluate() {
  if tether_active; then
    [ -e "$STAMP" ] && return
    if rfkill block wlan; then
      : > "$STAMP"
      log "iPhone USB tether up — Wi-Fi soft-blocked to keep ICE on one interface"
    else
      log "iPhone USB tether up but 'rfkill block wlan' failed"
    fi
  else
    [ -e "$STAMP" ] || return
    rm -f "$STAMP"
    if rfkill unblock wlan; then
      log "iPhone USB tether gone — Wi-Fi restored"
    else
      log "iPhone USB tether gone but 'rfkill unblock wlan' failed"
    fi
  fi
}

evaluate
[ "${1-}" = --once ] && exit 0

# Coalesce the burst of events a single plug/unplug produces: drain anything
# that arrives within a second of the first, then evaluate once.
ip monitor address link 2>/dev/null | while read -r _; do
  while read -r -t 1 _; do :; done
  evaluate
done
