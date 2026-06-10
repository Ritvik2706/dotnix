--------------------------------------------------------------------------------
-- Hyprland — keybinds/power_notifications.lua (power, idle, notifications)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local notify = require("lua.notify")
local main = vars.mainMod

-- ===== Power / Idle / Notifications =====
hl.bind(main .. " + SHIFT + B", function()
	hl.dispatch(hl.dsp.dpms({ action = "off" }))
	notify.send("Display", "Screen Off", { app = "Display", icon = "desktop", replace_id = 72938, stack_tag = "power" })
end, { locked = true })

-- Idle inhibit toggle: disabled — SUPER+I is taken by "previous workspace"
-- (the old config had both bound, and `hyprctl dispatch inhibit_idle` no
-- longer exists). If you want it back, pick a free key and use:
-- hl.bind(main .. " + ???", hl.dsp.window.set_prop({ prop = "idle_inhibit", value = "always" }), { locked = true })

-- Dunst (notification center)
hl.bind(main .. " + BACKSPACE", function()
	hl.exec_cmd("dunstctl close-all")
	notify.send("Notifications", "All Cleared", { app = "Notifications", icon = "muted", replace_id = 72940, stack_tag = "notifications" })
end, { locked = true })

hl.bind(main .. " + SHIFT + BACKSPACE", hl.dsp.exec_cmd("dunstctl history-pop"), { locked = true })

-- Performance mode (toggle animations & opacity live)
hl.bind(main .. " + Scroll_Lock", function()
	hl.config({
		animations = { enabled = false },
		decoration = { active_opacity = 1.0, inactive_opacity = 1.0 },
	})
	notify.send("Performance Mode", "ON (No Animations)", { app = "Performance", replace_id = 72941, urgency = "normal", stack_tag = "performance" })
end, { locked = true })

hl.bind(main .. " + SHIFT + Scroll_Lock", function()
	hl.config({
		animations = { enabled = true },
		decoration = { active_opacity = 0.95, inactive_opacity = 0.9 },
	})
	notify.send("Performance Mode", "OFF (Animations Restored)", { app = "Performance", replace_id = 72941, urgency = "normal", stack_tag = "performance" })
end, { locked = true })
