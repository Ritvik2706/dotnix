--------------------------------------------------------------------------------
-- Hyprland — keybinds/media_brightness.lua
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod

-- ==== Output volume (basic controls) ====
-- (was bindel/bindl: repeating + locked so they work on the lockscreen)
hl.bind(
	"XF86AudioRaiseVolume",
	hl.dsp.exec_cmd(
		[[wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+ && dunstify -a "Volume" -i "/usr/share/icons/candy-icons/status/scalable/audio-volume-high.svg" -r 72932 -u low -h string:x-dunst-stack-tag:volume -h int:value:$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2*100)}') "Volume" "$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2*100)}')%"]]
	),
	{ repeating = true, locked = true }
)

hl.bind(
	"XF86AudioLowerVolume",
	hl.dsp.exec_cmd(
		[[wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- && dunstify -a "Volume" -i "/usr/share/icons/candy-icons/status/scalable/audio-volume-medium.svg" -r 72932 -u low -h string:x-dunst-stack-tag:volume -h int:value:$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2*100)}') "Volume" "$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2*100)}')%"]]
	),
	{ repeating = true, locked = true }
)

hl.bind(
	"XF86AudioMute",
	hl.dsp.exec_cmd(
		[[wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle && dunstify -a "Volume" -i "/usr/share/icons/candy-icons/status/scalable/audio-volume-muted-symbolic.svg" -r 72932 -u low -h string:x-dunst-stack-tag:volume "Volume" "$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | grep -q MUTED && echo 'Muted' || echo 'Unmuted')"]]
	),
	{ locked = true }
)

-- Display brightness (Fn+F7/F8 on Razer Blade) — requires brightnessctl
-- Install: sudo pacman -S brightnessctl
-- brightness.sh auto-detects nvidia_wmi_ec_backlight
hl.bind(
	"XF86MonBrightnessUp",
	hl.dsp.exec_cmd("~/.config/custom_scripts/brightness.sh up"),
	{ repeating = true, locked = true }
)
hl.bind(
	"XF86MonBrightnessDown",
	hl.dsp.exec_cmd("~/.config/custom_scripts/brightness.sh down"),
	{ repeating = true, locked = true }
)

-- Keyboard backlight (Razer — via razerkbd sysfs, needs openrazer group)
-- Fn+F11/F12 are captured by the driver; use explicit SUPER binds instead
hl.bind(
	main .. " + F10",
	hl.dsp.exec_cmd("~/.config/custom_scripts/kbd-backlight.sh down"),
	{ repeating = true, locked = true }
)
hl.bind(
	main .. " + F11",
	hl.dsp.exec_cmd("~/.config/custom_scripts/kbd-backlight.sh up"),
	{ repeating = true, locked = true }
)

hl.bind(main .. " + N", hl.dsp.exec_cmd("~/.config/custom_scripts/toggle_wlsunset.sh"))
