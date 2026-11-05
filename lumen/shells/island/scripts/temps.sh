#!/usr/bin/env bash
# temps.sh — "<cpu> <gpu>" in whole degrees, for the card's stat rings. The GPU is -1
# while the dGPU sleeps: nvidia-smi would wake it, so it's only asked when awake.
set -uo pipefail

cpu=0
for h in /sys/class/hwmon/hwmon*; do
	if [[ $(<"$h/name") == coretemp ]]; then
		cpu=$(($(<"$h/temp1_input") / 1000))
		break
	fi
done

gpu=-1
if [[ $(</sys/bus/pci/devices/0000:01:00.0/power/runtime_status) == active ]]; then
	gpu=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null || echo -1)
fi

echo "$cpu ${gpu:--1}"
