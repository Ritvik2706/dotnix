--------------------------------------------------------------------------------
-- Hyprland — workspaces.lua (was conf/screen/workspaces.conf)
--
-- Workspace → monitor pins. These are inert while only the laptop panel
-- exists; they kick in when external monitors named HDMI-A-1/HDMI-A-2 are
-- attached (the old desktop setup). Adjust output names when you dock.
--------------------------------------------------------------------------------

-- Main monitor (HDMI-A-2) - workspaces 1-10
for i = 1, 10 do
	hl.workspace_rule({ workspace = tostring(i), monitor = "HDMI-A-2" })
end

-- Left monitor (HDMI-A-1) - workspaces 11-18
for i = 11, 18 do
	hl.workspace_rule({ workspace = tostring(i), monitor = "HDMI-A-1" })
end

-- Special workspace tweaks
hl.workspace_rule({ workspace = "special", gaps_in = 5, gaps_out = 15 })
