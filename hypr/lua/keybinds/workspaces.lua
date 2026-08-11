--------------------------------------------------------------------------------
-- Hyprland — keybinds/workspaces.lua (workspace management)
--------------------------------------------------------------------------------

local vars = require("lua.vars")
local main = vars.mainMod

-- ===== Workspaces =====
-- Main monitor - workspaces 1-10; secondary monitor - workspaces 11-20
for i = 1, 10 do
	local key = i % 10 -- 10 maps to key 0
	hl.bind(main .. " + " .. key, hl.dsp.focus({ workspace = i }))
	hl.bind(main .. " + CTRL + " .. key, hl.dsp.focus({ workspace = i + 10 }))

	-- Move focused window to workspace (auto-follows)
	hl.bind(main .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
	hl.bind(main .. " + CTRL + SHIFT + " .. key, hl.dsp.window.move({ workspace = i + 10 }))
end

-- ===== TV workspaces (Hisense over HDMI-A-1) =====
for i = 1, 3 do
	hl.bind("ALT + F" .. i, hl.dsp.focus({ workspace = 20 + i }))
	hl.bind("ALT + SHIFT + F" .. i, hl.dsp.window.move({ workspace = 20 + i }))
end

hl.bind(main .. " + TAB", hl.dsp.focus({ workspace = "previous" }))

-- Quick next/prev workspace
hl.bind(main .. " + I", hl.dsp.focus({ workspace = "r-1" }))
hl.bind(main .. " + O", hl.dsp.focus({ workspace = "r+1" }))

-- Move focused window to next/prev workspace (relative)
hl.bind(main .. " + SHIFT + I", hl.dsp.window.move({ workspace = "-1" }))
hl.bind(main .. " + SHIFT + O", hl.dsp.window.move({ workspace = "+1" }))
