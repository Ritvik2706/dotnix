--------------------------------------------------------------------------------
-- Hyprland — keybinds/power_notifications.lua (power, idle, notifications)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local notify = require("lua.notify")
local main = vars.mainMod
local alt = vars.altMod

-- ===== Power / Idle / Notifications =====
hl.bind(main .. " + SHIFT + B", function()
	hl.dispatch(hl.dsp.dpms({ action = "off" }))
	notify.send("Display", "Screen Off", { app = "Display", icon = "desktop", replace_id = 72938, stack_tag = "power" })
end, { locked = true })

-- ===== LOCK SCREEN ESCAPE HATCH =====
-- SUPER + CTRL + ALT + L, and it is `locked = true` on purpose: locked binds
-- are the ONLY input Hyprland still routes while a session lock is up, so
-- this reaches you even when hyprlock itself has stopped responding.
--
-- It exists because hyprlock can wedge: an instance that locked while the
-- panel was off may never render a frame, and since the unlock fades out
-- through that same render path, it can authenticate you and still never let
-- you in — a dimmed, frozen desktop that swallows every keystroke. That has
-- cost a hard reboot. hypr/scripts/resume-lock.sh now prevents the usual
-- cause; this is the manual lever for whatever it does not.
--
-- Restarting is NOT an unlock and does not expose the desktop: under
-- ext-session-lock a client that dies without sending `unlock` leaves the
-- compositor locked, so the screen stays covered until the new hyprlock
-- takes over. Worst case you land on Hyprland's red lockdead screen, which
-- is still locked and which the next restart clears.
hl.bind(
	main .. " + CTRL + " .. alt .. " + L",
	hl.dsp.exec_cmd("systemctl --user restart hyprlock.service"),
	{ locked = true }
)

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
