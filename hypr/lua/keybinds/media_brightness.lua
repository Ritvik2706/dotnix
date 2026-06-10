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

-- Brightness control for focused monitor using brightnessctl with ddcci
hl.bind(main .. " + bracketleft", hl.dsp.exec_cmd("~/.config/custom_scripts/brightnessControl.sh -"), { repeating = true, locked = true })
hl.bind(main .. " + bracketright", hl.dsp.exec_cmd("~/.config/custom_scripts/brightnessControl.sh +"), { repeating = true, locked = true })

-- Alternative brightness keys (F keys)
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("~/.config/custom_scripts/brightnessControl.sh +"), { repeating = true, locked = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("~/.config/custom_scripts/brightnessControl.sh -"), { repeating = true, locked = true })

-- Volume wheel + Shift for brightness control
hl.bind("SHIFT + XF86AudioRaiseVolume", hl.dsp.exec_cmd("~/.config/custom_scripts/brightnessControl.sh +"), { repeating = true, locked = true })
hl.bind("SHIFT + XF86AudioLowerVolume", hl.dsp.exec_cmd("~/.config/custom_scripts/brightnessControl.sh -"), { repeating = true, locked = true })

hl.bind(main .. " + N", hl.dsp.exec_cmd("~/.config/custom_scripts/toggle_wlsunset.sh"))
