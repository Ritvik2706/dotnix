--------------------------------------------------------------------------------
-- Hyprland — keybinds/media_brightness.lua
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod

-- ==== Output volume ====
-- Each action is defined once and bound to both the Fn-layer media key and the
-- plain F-key (no Fn needed). Repeating + locked so they work on the lockscreen.
-- The lumen island draws the gauge itself (it watches the volume); the key also
-- tells it which way was pressed, so it can stretch when pushed past an end.
-- (Full path: Hyprland's PATH has no ~/.local/bin.)
local ISLAND = [[~/.local/bin/lumen --say island "emit vol_key %d" >/dev/null 2>&1]]

local volume = {
	up = {
		cmd = "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+; " .. string.format(ISLAND, 1),
		keys = { "XF86AudioRaiseVolume", "F3" },
		opts = { repeating = true, locked = true },
	},
	down = {
		cmd = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-; " .. string.format(ISLAND, -1),
		keys = { "XF86AudioLowerVolume", "F2" },
		opts = { repeating = true, locked = true },
	},
	mute = {
		cmd = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
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
-- Fn+F11/F12 are captured by the driver; plain F10 (down) and F11 (up) instead
hl.bind(
	"F10",
	hl.dsp.exec_cmd("~/.config/custom_scripts/kbd-backlight.sh down"),
	{ repeating = true, locked = true }
)
hl.bind(
	"F11",
	hl.dsp.exec_cmd("~/.config/custom_scripts/kbd-backlight.sh up"),
	{ repeating = true, locked = true }
)

hl.bind(main .. " + N", hl.dsp.exec_cmd("~/.config/custom_scripts/toggle_wlsunset.sh"))
