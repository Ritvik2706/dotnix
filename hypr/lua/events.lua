--------------------------------------------------------------------------------
-- Hyprland — events.lua
-- Runtime event handlers (workspace changes, window events, etc.)
--------------------------------------------------------------------------------

-- Hide Waybar on workspace 2, show it everywhere else.
-- Waybar's SIGUSR1 just toggles visibility, so a flag file remembers whether
-- we've hidden it. execs.lua clears this flag whenever it actually (re)launches
-- waybar, so a fresh bar starts visible & in sync. We must NOT clear it here:
-- this handler re-runs on every `hyprctl reload`, but a reload does not restart
-- waybar — wiping the flag then desyncs it from the bar's real state and
-- inverts the visibility.
local FLAG = "/tmp/waybar-hidden"

hl.on("workspace.active", function()
	local ws = hl.get_active_workspace()
	if not ws then return end

	if ws.name == "2" then
		-- Hide only if it's currently shown.
		hl.exec_cmd("sh -c '[ -f " .. FLAG .. " ] || { pkill -SIGUSR1 waybar; touch " .. FLAG .. "; }'")
	else
		-- Show only if it's currently hidden.
		hl.exec_cmd("sh -c '[ -f " .. FLAG .. " ] && { pkill -SIGUSR1 waybar; rm -f " .. FLAG .. "; }'")
	end
end)
