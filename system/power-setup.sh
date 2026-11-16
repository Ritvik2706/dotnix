#!/usr/bin/env bash
# The root half of the laptop's power and heat policy (asks for sudo once):
#   the display ports are checked on wake   systemd/display-redetect.service
#   silent mode may cap the CPU's speed     tmpfiles/razer-fan.conf
# The fans, the power mode and profile, and the charge limit need no root and are
# razer/razer-fan.py's.
#
#   system/power-setup.sh             install, or update after editing any of those
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ac-power.service was an earlier try: the profile is razer-fan.py's now, and it
# held the dGPU awake on the charger.
sudo systemctl disable --now ac-power.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/ac-power.service /etc/udev/rules.d/71-ac-power.rules
echo auto | sudo tee /sys/bus/pci/devices/0000:01:00.0/power/control >/dev/null

sudo install -Dm644 systemd/display-redetect.service /etc/systemd/system/display-redetect.service
sudo install -Dm644 tmpfiles/razer-fan.conf /etc/tmpfiles.d/razer-fan.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/razer-fan.conf
sudo udevadm control --reload
sudo systemctl daemon-reload
sudo systemctl enable display-redetect.service
echo "installed"
