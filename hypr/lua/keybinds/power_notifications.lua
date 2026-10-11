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

-- Caffeine: keep the machine awake while the FOCUSED window exists (movie,
-- long build, presentation). Per-window idle_inhibit, which hypridle honours
-- even with ignore_dbus_inhibit = true; hypridle itself keeps running, so
-- lid-close still locks before suspend. Press again on the same window to undo.
local caffeinated = {}
hl.bind(main .. " + CTRL + I", function()
	local w = hl.get_active_window()
	if not w then
		return
	end
	local on = not caffeinated[w.address]
	caffeinated[w.address] = on or nil
	hl.dispatch(hl.dsp.window.set_prop({ prop = "idle_inhibit", value = on and "always" or "none" }))
	notify.send(on and "Caffeine ON" or "Caffeine OFF", (on and "Staying awake for " or "Idle restored for ") .. w.class, { app = "Idle", icon = "desktop", replace_id = 72946, stack_tag = "idle" })
end)

-- Dunst (notification center)
hl.bind(main .. " + BACKSPACE", function()
	hl.exec_cmd("dunstctl close-all")
	notify.send("Notifications", "All Cleared", { app = "Notifications", icon = "muted", replace_id = 72940, stack_tag = "notifications" })
end, { locked = true })

hl.bind(main .. " + SHIFT + BACKSPACE", hl.dsp.exec_cmd("dunstctl history-pop"), { locked = true })

-- Performance / battery mode: one toggle. ON kills animations, blur and
-- shadows live; OFF is a config reload, so it always restores exactly what the
-- files say (no hardcoded "restore" values to drift out of sync).
-- The Blade has no Scroll Lock key, so it also lives on SUPER+F12.
local perf_on = false
local function toggle_perf()
	perf_on = not perf_on
	if perf_on then
		hl.config({
			animations = { enabled = false },
			decoration = { blur = { enabled = false }, shadow = { enabled = false } },
		})
		notify.send("Performance Mode", "ON (no animations, blur, shadows)", { app = "Performance", replace_id = 72941, urgency = "normal", stack_tag = "performance" })
	else
		hl.exec_cmd("hyprctl reload")
		notify.send("Performance Mode", "OFF (config restored)", { app = "Performance", replace_id = 72941, urgency = "normal", stack_tag = "performance" })
	end
end
hl.bind(main .. " + Scroll_Lock", toggle_perf)
hl.bind(main .. " + F12", toggle_perf)
