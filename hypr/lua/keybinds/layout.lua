--------------------------------------------------------------------------------
-- Hyprland — keybinds/layout.lua (layout, float, fullscreen controls)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local notify = require("lua.notify")
local main = vars.mainMod

-- ===== Layout / Float / Fullscreen =====
hl.bind(main .. " + F", function()
	hl.dispatch(hl.dsp.window.fullscreen({ mode = "fullscreen" }))
	notify.send("Window State", "Fullscreen Toggled")
end)

hl.bind(main .. " + SPACE", hl.dsp.exec_cmd("albert toggle"))

hl.bind(main .. " + U", function()
	hl.dispatch(hl.dsp.window.center())
	notify.send("Window", "Centered")
end)

hl.bind(main .. " + semicolon", function()
	hl.dispatch(hl.dsp.window.pseudo())
	notify.send("Window State", "Pseudo-tile Toggled")
end)

hl.bind(main .. " + apostrophe", function()
	hl.dispatch(hl.dsp.window.pin())
	notify.send("Window State", "Always-on-top Toggled")
end)

-- ===== Groups ===== (lived at the bottom of conf/rules/rules.conf)
-- Detach the current window from the group ("pull it out")
hl.bind(main .. " + SHIFT + U", hl.dsp.window.move({ out_of_group = true }))
-- Re-attach a focused window to the nearest group on the left.
-- NOTE: disabled — SUPER+SHIFT+I already moves the window to the previous
-- workspace (keybinds/workspaces.lua); the old config had both bound at once.
-- hl.bind(main .. " + SHIFT + I", hl.dsp.window.move({ into_group = "left" }))
