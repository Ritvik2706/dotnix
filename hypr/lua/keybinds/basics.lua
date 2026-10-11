--------------------------------------------------------------------------------
-- Hyprland — keybinds/basics.lua (basic window management)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod
local alt = vars.altMod
local notify = require("lua.notify")

-- ===== Basics =====
hl.bind(main .. " + RETURN", hl.dsp.exec_cmd(vars.term))
hl.bind(main .. " + SHIFT + T", hl.dsp.exec_cmd("~/.config/custom_scripts/tmux_popup.sh")) -- moved off SUPER+T (zoom)
hl.bind(main .. " + Q", hl.dsp.window.close())
hl.bind(main .. " + C", hl.dsp.exec_cmd("copyq show"))
hl.bind(main .. " + SHIFT + C", hl.dsp.exec_cmd("hyprctl reload"))

-- Exit asks first: SUPER+SHIFT+E arms it, then E (or Y) quits, anything
-- else in the submap (Esc/Return/N) backs out. Protects against a stray chord
-- killing the whole session.
hl.bind(main .. " + SHIFT + E", function()
	hl.dispatch(hl.dsp.submap("confirm_exit"))
	notify.send("Exit Hyprland?", "Press E to quit, Esc to cancel", { app = "Session", icon = "desktop", replace_id = 72947, urgency = "critical", stack_tag = "session" })
end)

hl.define_submap("confirm_exit", function()
	for _, key in ipairs({ "E", "Y" }) do
		hl.bind(key, hl.dsp.exit())
	end
	for _, key in ipairs({ "ESCAPE", "RETURN", "N" }) do
		hl.bind(key, function()
			hl.dispatch(hl.dsp.submap("reset"))
			hl.exec_cmd("dunstctl close-all")
		end)
	end
end)

hl.bind(main .. " + " .. alt .. " + L", hl.dsp.exec_cmd("systemctl --user start hyprlock.service")) -- Lock screen

hl.bind(main .. " + SHIFT + SPACE", hl.dsp.exec_cmd("~/.config/custom_scripts/toggle_transparency.sh"))

-- Bind settings
hl.config({
	binds = {
		scroll_event_delay = 0,
		hide_special_on_workspace_change = true,
	},
})
