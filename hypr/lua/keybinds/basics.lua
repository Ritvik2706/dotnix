--------------------------------------------------------------------------------
-- Hyprland — keybinds/basics.lua (basic window management)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod
local alt = vars.altMod

-- ===== Basics =====
hl.bind(main .. " + RETURN", hl.dsp.exec_cmd(vars.term))
hl.bind(main .. " + T", hl.dsp.exec_cmd("~/.config/custom_scripts/tmux_popup.sh"))
hl.bind(main .. " + Q", hl.dsp.window.close())
hl.bind(main .. " + SHIFT + C", hl.dsp.exec_cmd("hyprctl reload"))
hl.bind(main .. " + SHIFT + E", hl.dsp.exit())

hl.bind(main .. " + " .. alt .. " + L", hl.dsp.exec_cmd("hyprlock")) -- Lock screen

hl.bind(main .. " + SHIFT + SPACE", hl.dsp.exec_cmd("~/.config/custom_scripts/toggle_transparency.sh"))

-- Bind settings
hl.config({
	binds = {
		scroll_event_delay = 0,
		hide_special_on_workspace_change = true,
	},
})
