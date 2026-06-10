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
		no_hardware_cursors = 2, -- Hardware cursor settings
		enable_hyprcursor = true, -- Enable Hyprland's cursor system
		warp_on_change_workspace = 2, -- Cursor warping behavior
		no_warps = true, -- Disable cursor warping
	},
})
