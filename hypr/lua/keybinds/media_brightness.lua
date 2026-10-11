--------------------------------------------------------------------------------
-- Hyprland — keybinds/media_brightness.lua
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod

-- ==== Output volume ====
-- Each action is defined once and bound to both the Fn-layer media key and the
-- plain F-key (no Fn needed). Repeating + locked so they work on the lockscreen.
local VOL_ICONS = "/usr/share/icons/candy-icons/status/scalable/"
local VOL_PCT = [[$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2*100)}')]]
local function vol_toast(icon, body, with_bar)
	return string.format(
		[[dunstify -a "Volume" -i "%s%s" -r 72932 -u low -h string:x-dunst-stack-tag:volume %s"Volume" "%s"]],
		VOL_ICONS,
		icon,
		with_bar and ("-h int:value:" .. VOL_PCT .. " ") or "",
		body
	)
end

local volume = {
	up = {
		cmd = "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+ && " .. vol_toast("audio-volume-high.svg", VOL_PCT .. "%", true),
		keys = { "XF86AudioRaiseVolume", "F3" },
		opts = { repeating = true, locked = true },
	},
	down = {
		cmd = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- && " .. vol_toast("audio-volume-medium.svg", VOL_PCT .. "%", true),
		keys = { "XF86AudioLowerVolume", "F2" },
		opts = { repeating = true, locked = true },
	},
	mute = {
		cmd = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle && "
			.. vol_toast("audio-volume-muted-symbolic.svg", [[$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | grep -q MUTED && echo 'Muted' || echo 'Unmuted')]]),
		keys = { "XF86AudioMute", "F1" },
		opts = { locked = true },
	},
}
for _, v in pairs(volume) do
	for _, key in ipairs(v.keys) do
		hl.bind(key, hl.dsp.exec_cmd(v.cmd), v.opts)
	end
end

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
hl.bind(
	"F9",
	hl.dsp.exec_cmd("~/.config/custom_scripts/brightness.sh up"),
	{ repeating = true, locked = true }
)
hl.bind(
	"F8",
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
