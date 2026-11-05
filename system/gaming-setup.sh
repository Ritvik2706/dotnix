#!/usr/bin/env bash
# gaming-setup.sh — the root half of the gaming setup. Run once: sudo system/gaming-setup.sh
#  · ntsync: Wine's fast sync, which the kernel has but nothing was loading
#  · zram 8 GiB (was 4): 15 GiB of RAM is tight with a game and a browser
#  · split-lock mitigation off: Wine games trip it (298 traps logged from one game),
#    and each trap deliberately stalls the thread
#  · nvidia-powerd: NVIDIA's Dynamic Boost, which shares power between CPU and GPU
#    on this laptop, as Windows does
set -euo pipefail

echo ntsync >/etc/modules-load.d/ntsync.conf
modprobe ntsync

cat >/etc/systemd/zram-generator.conf <<'CONF'
[zram0]
compression-algorithm = zstd
zram-size = 8192
CONF

echo 'kernel.split_lock_mitigate = 0' >/etc/sysctl.d/90-gaming.conf
sysctl -q -p /etc/sysctl.d/90-gaming.conf

systemctl enable --now nvidia-powerd

echo "done: ntsync loaded; zram 8 GiB from the next reboot; split-lock off; nvidia-powerd running"
