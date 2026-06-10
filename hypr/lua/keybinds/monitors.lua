--------------------------------------------------------------------------------
-- Hyprland — keybinds/monitors.lua (multi-monitor management)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local notify = require("lua.notify")
local main = vars.mainMod

-- ===== Monitors (multi-monitor QoL) =====
hl.bind(main .. " + comma", function()
	hl.dispatch(hl.dsp.focus({ monitor = "l" }))
	notify.send("Monitor Focus", "Left Monitor", { app = "Monitor", icon = "desktop", replace_id = 72935, stack_tag = "monitor" })
end)

hl.bind(main .. " + period", function()
	hl.dispatch(hl.dsp.focus({ monitor = "r" }))
	notify.send("Monitor Focus", "Right Monitor", { app = "Monitor", icon = "desktop", replace_id = 72935, stack_tag = "monitor" })
end)

hl.bind(main .. " + SHIFT + comma", function()
	hl.dispatch(hl.dsp.window.move({ monitor = "l" }))
	notify.send("Window Moved", "To Left Monitor", { app = "Window", replace_id = 72936, stack_tag = "window" })
end)

hl.bind(main .. " + SHIFT + period", function()
	hl.dispatch(hl.dsp.window.move({ monitor = "r" }))
	notify.send("Window Moved", "To Right Monitor", { app = "Window", replace_id = 72936, stack_tag = "window" })
end)
