--------------------------------------------------------------------------------
-- Hyprland — keybinds/mouse.lua (was conf/keybinds/mouse.conf)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod

-- Move/resize windows with mainMod + LMB/RMB and dragging
hl.bind(main .. " + mouse:272", hl.dsp.window.drag(), { mouse = true }) -- left click
hl.bind(main .. " + mouse:273", hl.dsp.window.resize(), { mouse = true }) -- right click

-- Scroll through existing workspaces with mainMod + scroll
hl.bind(main .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(main .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))

hl.config({
	misc = {
		middle_click_paste = false, -- Disable middle-click paste
	},

	binds = {
		pass_mouse_when_bound = false,
	},

	cursor = {
		sync_gsettings_theme = true, -- Sync cursor theme with system
		-- Hardware cursors (was 2/auto, which chose software cursors on this hybrid
		-- laptop and baked the pointer into screen captures: the lumen island's
		-- lens captures the screen behind its glass and smeared the cursor at its
		-- edges). eDP-2 runs on the Intel iGPU, which does hardware cursors fine.
		no_hardware_cursors = 0,
		enable_hyprcursor = true, -- Enable Hyprland's cursor system
		warp_on_change_workspace = 2, -- Cursor warping behavior
		no_warps = true, -- Disable cursor warping
	},
})
